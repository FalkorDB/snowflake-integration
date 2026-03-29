#!/usr/bin/env python3
"""Export Snowflake Marketplace usage metrics for the FalkorDB Native App.

Queries Snowflake's built-in provider analytics views (DATA_SHARING_USAGE)
and outputs a JSON report with install counts, active installs, consumer
activity, and listing telemetry.

Environment variables (required):
    SNOWFLAKE_ACCOUNT   - Snowflake account identifier (e.g. xyz12345.us-east-1)
    SNOWFLAKE_USER      - Service account username
    SNOWFLAKE_WAREHOUSE - Warehouse name (e.g. WH_METRICS)

Authentication (one of):
    SNOWFLAKE_PRIVATE_KEY - PEM-encoded private key string (for CI/CD)
    SNOWFLAKE_PASSWORD    - Password (fallback, not recommended for CI/CD)
"""

import argparse
import json
import os
import sys
import uuid
from datetime import datetime, timezone

import snowflake.connector
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import serialization


def get_connection(connection_name=None):
    """Create a Snowflake connection.

    If connection_name is given, uses the named connection from the local
    Snowflake CLI config (~/.snowflake/connections.toml or config.toml).
    Otherwise falls back to environment variables.
    """
    if connection_name:
        return snowflake.connector.connect(
            connection_name=connection_name,
            database="SNOWFLAKE",
            schema="DATA_SHARING_USAGE",
        )

    account = os.environ.get("SNOWFLAKE_ACCOUNT")
    user = os.environ.get("SNOWFLAKE_USER")
    warehouse = os.environ.get("SNOWFLAKE_WAREHOUSE", "WH_METRICS")

    if not account or not user:
        print(
            "Error: Provide --connection <name> or set SNOWFLAKE_ACCOUNT and SNOWFLAKE_USER.",
            file=sys.stderr,
        )
        sys.exit(1)

    connect_args = {
        "account": account,
        "user": user,
        "warehouse": warehouse,
        "database": "SNOWFLAKE",
        "schema": "DATA_SHARING_USAGE",
    }

    private_key_pem = os.environ.get("SNOWFLAKE_PRIVATE_KEY")
    if private_key_pem:
        p_key = serialization.load_pem_private_key(
            private_key_pem.encode("utf-8"),
            password=None,
            backend=default_backend(),
        )
        pkb = p_key.private_bytes(
            encoding=serialization.Encoding.DER,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        )
        connect_args["private_key"] = pkb
    elif os.environ.get("SNOWFLAKE_PASSWORD"):
        connect_args["password"] = os.environ["SNOWFLAKE_PASSWORD"]
    else:
        print(
            "Error: Either SNOWFLAKE_PRIVATE_KEY or SNOWFLAKE_PASSWORD is required.",
            file=sys.stderr,
        )
        sys.exit(1)

    return snowflake.connector.connect(**connect_args)


def run_query(cursor, sql, params=None):
    """Execute a query and return results as a list of dicts."""
    cursor.execute(sql, params)
    columns = [desc[0].lower() for desc in cursor.description]
    rows = []
    for row in cursor:
        record = {}
        for col, val in zip(columns, row, strict=True):
            # Convert date/datetime to ISO string for JSON serialization
            if hasattr(val, "isoformat"):
                val = val.isoformat()
            record[col] = val
        rows.append(record)
    return rows


def query_cumulative_installs(cursor, listing_filter):
    """Query 1: Total installs across all time."""
    return run_query(
        cursor,
        """
        SELECT
            listing_name,
            listing_display_name,
            event_type,
            COUNT(*) AS total_count
        FROM snowflake.data_sharing_usage.listing_events_daily
        WHERE listing_name LIKE %s
          AND event_type IN ('GET', 'TRIAL', 'PURCHASE')
        GROUP BY 1, 2, 3
        """,
        (listing_filter,),
    )


def query_daily_trends(cursor, listing_filter, days):
    """Query 2: Daily install/uninstall trends."""
    return run_query(
        cursor,
        """
        SELECT
            event_date,
            listing_name,
            listing_display_name,
            event_type,
            COUNT(*) AS daily_count
        FROM snowflake.data_sharing_usage.listing_events_daily
        WHERE listing_name LIKE %s
          AND event_date >= DATEADD(day, -%s, CURRENT_DATE())
        GROUP BY 1, 2, 3, 4
        ORDER BY 1 DESC
        """,
        (listing_filter, days),
    )


def query_active_installs(cursor, listing_filter):
    """Query 3: Currently active app installations."""
    return run_query(
        cursor,
        """
        SELECT
            consumer_account_name,
            consumer_organization_name,
            consumer_account_locator,
            consumer_snowflake_region,
            package_name,
            application_name_hash,
            current_version,
            current_patch,
            created_on,
            current_installed_on,
            upgrade_state,
            last_health_status,
            last_health_status_updated_on,
            listing_name,
            listing_display_name
        FROM snowflake.data_sharing_usage.application_state
        WHERE package_name LIKE %s
        """,
        (listing_filter,),
    )


def query_consumer_activity(cursor, listing_filter, days):
    """Query 4: Per-consumer job and user activity."""
    return run_query(
        cursor,
        """
        SELECT
            event_date,
            listing_name,
            listing_display_name,
            consumer_account_name,
            consumer_organization,
            consumer_account_locator,
            jobs,
            unique_users_1d,
            unique_users_7d,
            unique_users_28d
        FROM snowflake.data_sharing_usage.listing_consumption_daily
        WHERE listing_name LIKE %s
          AND event_date >= DATEADD(day, -%s, CURRENT_DATE())
        ORDER BY event_date DESC
        """,
        (listing_filter, days),
    )


def query_listing_telemetry(cursor, listing_filter, days):
    """Query 5: Listing engagement (clicks, views, CTR)."""
    return run_query(
        cursor,
        """
        SELECT
            event_date,
            listing_name,
            listing_display_name,
            event_type,
            action,
            event_count,
            consumer_accounts_daily,
            consumer_accounts_28d
        FROM snowflake.data_sharing_usage.listing_telemetry_daily
        WHERE listing_name LIKE %s
          AND event_date >= DATEADD(day, -%s, CURRENT_DATE())
        ORDER BY event_date DESC
        """,
        (listing_filter, days),
    )


def build_summary(cumulative, active, activity):
    """Compute high-level summary metrics."""
    total_installs = sum(r.get("total_count", 0) for r in cumulative)
    active_count = len(active)
    healthy_count = sum(
        1 for r in active if r.get("last_health_status") == "OK"
    )
    total_jobs = sum(r.get("jobs", 0) for r in activity)

    # Unique consumers in activity data (approximate for the lookback window)
    consumer_accounts = {
        r.get("consumer_account_locator") for r in activity if r.get("consumer_account_locator")
    }

    return {
        "total_installs_all_time": total_installs,
        "active_installs_now": active_count,
        "healthy_installs": healthy_count,
        "total_jobs_in_period": total_jobs,
        "unique_consumers_in_period": len(consumer_accounts),
    }


def main():
    parser = argparse.ArgumentParser(
        description="Export Snowflake Marketplace metrics for FalkorDB Native App"
    )
    parser.add_argument(
        "--listing-filter",
        default=os.environ.get("LISTING_FILTER", "%FALKORDB%"),
        help="SQL LIKE pattern for listing name filter (default: %%FALKORDB%%)",
    )
    parser.add_argument(
        "--days",
        type=int,
        default=int(os.environ.get("LOOKBACK_DAYS", "90")),
        help="Lookback window in days for historical queries (default: 90)",
    )
    parser.add_argument(
        "--output",
        default=None,
        help="Output file path (default: stdout)",
    )
    parser.add_argument(
        "--connection",
        default=None,
        help="Snowflake CLI connection name from ~/.snowflake/config.toml (e.g. myconnection)",
    )
    args = parser.parse_args()

    print(
        f"Connecting to Snowflake (connection: {args.connection or 'env vars'})...",
        file=sys.stderr,
    )
    conn = get_connection(connection_name=args.connection)
    cursor = conn.cursor()

    try:
        print(f"Querying metrics (filter: {args.listing_filter}, days: {args.days})...", file=sys.stderr)

        cumulative = query_cumulative_installs(cursor, args.listing_filter)
        print(f"  Cumulative installs: {len(cumulative)} rows", file=sys.stderr)

        daily_trends = query_daily_trends(cursor, args.listing_filter, args.days)
        print(f"  Daily trends: {len(daily_trends)} rows", file=sys.stderr)

        active = query_active_installs(cursor, args.listing_filter)
        print(f"  Active installs: {len(active)} rows", file=sys.stderr)

        activity = query_consumer_activity(cursor, args.listing_filter, args.days)
        print(f"  Consumer activity: {len(activity)} rows", file=sys.stderr)

        telemetry = query_listing_telemetry(cursor, args.listing_filter, args.days)
        print(f"  Listing telemetry: {len(telemetry)} rows", file=sys.stderr)

        report = {
            "export_timestamp": datetime.now(timezone.utc).isoformat(),
            "run_id": str(uuid.uuid4()),
            "listing_filter": args.listing_filter,
            "lookback_days": args.days,
            "metrics": {
                "cumulative_installs": cumulative,
                "daily_trends": daily_trends,
                "active_installs": active,
                "consumer_activity": activity,
                "listing_telemetry": telemetry,
            },
            "summary": build_summary(cumulative, active, activity),
        }

        output_json = json.dumps(report, indent=2, default=str)

        if args.output:
            with open(args.output, "w") as f:
                f.write(output_json)
            print(f"Report written to {args.output}", file=sys.stderr)
        else:
            print(output_json)

        print("Done.", file=sys.stderr)

    finally:
        cursor.close()
        conn.close()


if __name__ == "__main__":
    main()
