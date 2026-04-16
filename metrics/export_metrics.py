#!/usr/bin/env python3
"""Export Snowflake Marketplace data for 14 HubSpot subscription fields.

Queries only the Snowflake provider views needed for the field mapping
defined in hubspot_field_mapping.json and outputs one record per consumer.

Sources:
  - APPLICATION_STATE  → cloud_region, cloud_vendor, cloud_version,
                          hs_recurring_billing_start_date, hs_status,
                          db_name, hs_name, hs_last_modified_at
  - LISTING_EVENTS_DAILY → deployment_type, subscription_plan, email

Hardcoded (no Snowflake source):
  - cloud_provider = "snowflake"
  - node_instance_type = "none"
  - falkordb_version = "need to add this" (until app_metadata is deployed)

Environment variables (required):
    SNOWFLAKE_ACCOUNT   - Snowflake account identifier
    SNOWFLAKE_USER      - Service account username
    SNOWFLAKE_WAREHOUSE - Warehouse name

Authentication (one of):
    SNOWFLAKE_PRIVATE_KEY - PEM-encoded private key string (for CI/CD)
    SNOWFLAKE_PASSWORD    - Password (fallback)
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
    """Create a Snowflake connection."""
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
            if hasattr(val, "isoformat"):
                val = val.isoformat()
            record[col] = val
        rows.append(record)
    return rows


# ---------------------------------------------------------------------------
# Snowflake queries — only the fields needed for the 14 HubSpot mappings
# ---------------------------------------------------------------------------

def query_application_state(cursor, listing_filter):
    """Pull per-consumer install data from APPLICATION_STATE.

    Fields used for: cloud_region, cloud_vendor, cloud_version,
    hs_recurring_billing_start_date, hs_status, db_name, hs_name,
    hs_last_modified_at.
    """
    return run_query(
        cursor,
        """
        SELECT
            consumer_account_locator,
            consumer_account_name,
            consumer_snowflake_region,
            current_version,
            current_patch,
            created_on,
            upgrade_state,
            last_upgraded_on
        FROM snowflake.data_sharing_usage.application_state
        WHERE package_name LIKE %s
        """,
        (listing_filter,),
    )


def query_listing_events(cursor, listing_filter):
    """Pull per-consumer event data from LISTING_EVENTS_DAILY.

    Fields used for: deployment_type, subscription_plan, email.
    """
    return run_query(
        cursor,
        """
        SELECT
            consumer_account_locator,
            consumer_account_name,
            event_type,
            consumer_email
        FROM snowflake.data_sharing_usage.listing_events_daily
        WHERE listing_name LIKE %s
          AND event_type IN ('GET', 'TRIAL', 'PURCHASE')
        """,
        (listing_filter,),
    )


# ---------------------------------------------------------------------------
# Transform helpers (matching hubspot_field_mapping.json transforms)
# ---------------------------------------------------------------------------

def transform_region(snowflake_region: str) -> str:
    """AWS_US_WEST_2 → us-west-2"""
    if not snowflake_region:
        return ""
    parts = snowflake_region.split("_", 1)
    return parts[1].lower().replace("_", "-") if len(parts) > 1 else snowflake_region.lower()


def transform_vendor(snowflake_region: str) -> str:
    """AWS_US_WEST_2 → aws"""
    if not snowflake_region:
        return ""
    return snowflake_region.split("_", 1)[0].lower()


def transform_version(current_version: str, current_patch) -> str:
    """V2 + 18 → V2.18"""
    v = str(current_version or "")
    p = str(current_patch or "")
    return f"{v}.{p}" if v and p else v or p or ""


def transform_status(upgrade_state: str) -> str:
    """COMPLETE → active, DISABLED → inactive, PENDING → pending"""
    mapping = {"COMPLETE": "active", "DISABLED": "inactive", "PENDING": "pending"}
    return mapping.get(str(upgrade_state or "").upper(), str(upgrade_state or "").lower())


def transform_deployment_type(event_type: str) -> str:
    """TRIAL → free, PURCHASE → paid, GET → free"""
    mapping = {"TRIAL": "free", "PURCHASE": "paid", "GET": "free"}
    return mapping.get(str(event_type or "").upper(), "free")


def transform_subscription_plan(event_type: str) -> str:
    """TRIAL → falkordb_free, PURCHASE → falkordb_paid"""
    mapping = {"TRIAL": "falkordb_free", "PURCHASE": "falkordb_paid", "GET": "falkordb_free"}
    return mapping.get(str(event_type or "").upper(), "falkordb_free")


def transform_date(val) -> str:
    """Extract date portion from ISO datetime string."""
    s = str(val or "")
    return s[:10] if s else ""


def transform_hs_name(locator: str) -> str:
    """FLB05576 → instance-flb05576"""
    return f"instance-{locator.lower()}" if locator else ""


# ---------------------------------------------------------------------------
# Build per-consumer subscription records
# ---------------------------------------------------------------------------

def build_subscriptions(app_state_rows, events_rows):
    """Merge APPLICATION_STATE + LISTING_EVENTS_DAILY into 14-field records per consumer.

    Key = consumer_account_locator (stable unique identifier).
    """
    # Index events by locator — keep the most significant event type
    # Priority: PURCHASE > TRIAL > GET
    event_priority = {"PURCHASE": 3, "TRIAL": 2, "GET": 1}
    events_by_locator: dict[str, dict] = {}
    for row in events_rows:
        locator = row.get("consumer_account_locator", "")
        if not locator:
            continue
        existing = events_by_locator.get(locator)
        row_priority = event_priority.get(str(row.get("event_type", "")).upper(), 0)
        if not existing or row_priority > event_priority.get(str(existing.get("event_type", "")).upper(), 0):
            events_by_locator[locator] = row
        # Prefer rows that have email
        if row.get("consumer_email") and not events_by_locator[locator].get("consumer_email"):
            events_by_locator[locator]["consumer_email"] = row["consumer_email"]

    subscriptions = []
    for install in app_state_rows:
        locator = install.get("consumer_account_locator", "")
        if not locator:
            continue

        region_raw = install.get("consumer_snowflake_region", "") or ""
        event_row = events_by_locator.get(locator, {})
        event_type = event_row.get("event_type", "")
        last_upgraded = install.get("last_upgraded_on")
        created_on = install.get("created_on")

        subscription = {
            "cloud_region": transform_region(region_raw),
            "cloud_vendor": transform_vendor(region_raw),
            "cloud_version": transform_version(
                install.get("current_version"), install.get("current_patch")
            ),
            "cloud_provider": "snowflake",
            "falkordb_version": "need to add this",
            "hs_recurring_billing_start_date": transform_date(created_on),
            "hs_status": transform_status(install.get("upgrade_state")),
            "db_name": install.get("consumer_account_name", ""),
            "hs_name": transform_hs_name(locator),
            "deployment_type": transform_deployment_type(event_type),
            "hs_last_modified_at": transform_date(last_upgraded) or transform_date(created_on),
            "subscription_plan": transform_subscription_plan(event_type),
            "email": event_row.get("consumer_email") or "",
        }
        subscriptions.append(subscription)

    return subscriptions


def main():
    parser = argparse.ArgumentParser(
        description="Export Snowflake data for HubSpot subscriptions (14 fields per consumer)"
    )
    parser.add_argument(
        "--listing-filter",
        default=os.environ.get("LISTING_FILTER", "%FALKORDB%"),
        help="SQL LIKE pattern for listing/package name filter (default: %%FALKORDB%%)",
    )
    parser.add_argument(
        "--output",
        default=None,
        help="Output file path (default: stdout)",
    )
    parser.add_argument(
        "--connection",
        default=None,
        help="Snowflake CLI connection name from ~/.snowflake/config.toml",
    )
    args = parser.parse_args()

    print(
        f"Connecting to Snowflake (connection: {args.connection or 'env vars'})...",
        file=sys.stderr,
    )
    conn = get_connection(connection_name=args.connection)
    cursor = conn.cursor()

    try:
        print(f"Querying Snowflake (filter: {args.listing_filter})...", file=sys.stderr)

        app_state = query_application_state(cursor, args.listing_filter)
        print(f"  APPLICATION_STATE: {len(app_state)} rows", file=sys.stderr)

        events = query_listing_events(cursor, args.listing_filter)
        print(f"  LISTING_EVENTS_DAILY: {len(events)} rows", file=sys.stderr)

        subscriptions = build_subscriptions(app_state, events)
        print(f"  Built {len(subscriptions)} subscription records", file=sys.stderr)

        report = {
            "export_timestamp": datetime.now(timezone.utc).isoformat(),
            "run_id": str(uuid.uuid4()),
            "listing_filter": args.listing_filter,
            "subscription_count": len(subscriptions),
            "subscriptions": subscriptions,
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
