#!/usr/bin/env python3
"""
push_to_hubspot.py

Reads metrics_report.json (produced by export_metrics.py) and pushes data
to HubSpot:
  - One Company record per unique Snowflake consumer account
  - One Deal record per install event (TRIAL / PURCHASE)

Required env var:
  HUBSPOT_ACCESS_TOKEN  – Private App token from HubSpot

Optional env var:
  METRICS_FILE  – path to metrics_report.json (default: metrics_report.json)

Usage:
  python metrics/push_to_hubspot.py
"""

import json
import os
import sys
import logging
from datetime import datetime

import requests

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger(__name__)

HUBSPOT_BASE = "https://api.hubapi.com"


# ---------------------------------------------------------------------------
# HubSpot helpers
# ---------------------------------------------------------------------------

def _headers(token: str) -> dict:
    return {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }


def search_company(token: str, account_locator: str) -> str | None:
    """Return HubSpot company id by snowflake_account_locator (stable unique key)."""
    url = f"{HUBSPOT_BASE}/crm/v3/objects/companies/search"
    payload = {
        "filterGroups": [
            {
                "filters": [
                    {
                        "propertyName": "snowflake_account_locator",
                        "operator": "EQ",
                        "value": account_locator,
                    }
                ]
            }
        ],
        "properties": ["name", "snowflake_account_locator"],
        "limit": 1,
    }
    resp = requests.post(url, headers=_headers(token), json=payload, timeout=15)
    resp.raise_for_status()
    results = resp.json().get("results", [])
    return results[0]["id"] if results else None


def upsert_company(token: str, account_name: str, extra_props: dict) -> str:
    """Create or update a HubSpot Company. Returns the company id."""
    account_locator = extra_props.get("snowflake_account_locator", account_name)
    existing_id = search_company(token, account_locator)
    props = {"name": account_name, **extra_props}

    if existing_id:
        url = f"{HUBSPOT_BASE}/crm/v3/objects/companies/{existing_id}"
        resp = requests.patch(url, headers=_headers(token), json={"properties": props}, timeout=15)
        resp.raise_for_status()
        log.info("Updated company '%s' (id=%s)", account_name, existing_id)
        return existing_id
    else:
        url = f"{HUBSPOT_BASE}/crm/v3/objects/companies"
        resp = requests.post(url, headers=_headers(token), json={"properties": props}, timeout=15)
        resp.raise_for_status()
        new_id = resp.json()["id"]
        log.info("Created company '%s' (id=%s)", account_name, new_id)
        return new_id


def search_deal(token: str, deal_name: str) -> str | None:
    """Return HubSpot deal id if a deal with this name already exists."""
    url = f"{HUBSPOT_BASE}/crm/v3/objects/deals/search"
    payload = {
        "filterGroups": [
            {
                "filters": [
                    {
                        "propertyName": "dealname",
                        "operator": "EQ",
                        "value": deal_name,
                    }
                ]
            }
        ],
        "properties": ["dealname"],
        "limit": 1,
    }
    resp = requests.post(url, headers=_headers(token), json=payload, timeout=15)
    resp.raise_for_status()
    results = resp.json().get("results", [])
    return results[0]["id"] if results else None


def create_deal(token: str, deal_name: str, props: dict, company_id: str) -> str:
    """Create a deal and associate it with a company. Returns deal id."""
    existing_id = search_deal(token, deal_name)
    if existing_id:
        log.info("Deal '%s' already exists (id=%s), skipping.", deal_name, existing_id)
        return existing_id

    url = f"{HUBSPOT_BASE}/crm/v3/objects/deals"
    payload = {
        "properties": {"dealname": deal_name, **props},
        "associations": [
            {
                "to": {"id": company_id},
                "types": [
                    {
                        "associationCategory": "HUBSPOT_DEFINED",
                        "associationTypeId": 5,  # deal → company
                    }
                ],
            }
        ],
    }
    resp = requests.post(url, headers=_headers(token), json=payload, timeout=15)
    resp.raise_for_status()
    new_id = resp.json()["id"]
    log.info("Created deal '%s' (id=%s) linked to company %s", deal_name, new_id, company_id)
    return new_id


# ---------------------------------------------------------------------------
# Main logic
# ---------------------------------------------------------------------------

def load_report(path: str) -> dict:
    with open(path) as f:
        return json.load(f)


def push_installs(token: str, installs: list[dict]) -> None:
    """Upsert one Company per active install record (from active_installs query)."""
    for install in installs:
        account_name = install.get("consumer_account_name", "Unknown")
        account_locator = install.get("consumer_account_locator", "")
        install_date = install.get("created_on", "")
        current_version = install.get("current_version", "")
        upgrade_state = install.get("upgrade_state", "")

        # --- Company ---
        company_props = {
            "snowflake_account_locator": account_locator,
            "snowflake_install_date": install_date,
            "snowflake_listing": "FalkorDB Graph Database",
            "industry": "Technology",
        }
        company_id = upsert_company(token, account_name, company_props)

        # --- Deal: create one per install as a new "Snowflake Install" deal ---
        deal_name = f"Snowflake Install – {account_name} – {install_date}"
        deal_props = {
            "pipeline": "default",
            "dealstage": "appointmentscheduled",
            "closedate": install_date,
            "amount": "0",
            "snowflake_current_version": current_version,
            "snowflake_upgrade_state": upgrade_state,
        }
        create_deal(token, deal_name, deal_props, company_id)


def push_consumer_activity(token: str, activity: list[dict]) -> None:
    """Update Company records with latest usage metrics."""
    # Group by locator (stable unique key), take the most recent row
    latest: dict[str, dict] = {}
    for row in activity:
        locator = row.get("consumer_account_locator", "Unknown")
        if locator not in latest or row.get("event_date", "") > latest[locator].get("event_date", ""):
            latest[locator] = row

    for locator, row in latest.items():
        props = {
            "snowflake_unique_users_1d": str(row.get("unique_users_1d", 0)),
            "snowflake_unique_users_7d": str(row.get("unique_users_7d", 0)),
            "snowflake_unique_users_28d": str(row.get("unique_users_28d", 0)),
            "snowflake_jobs_last_28d": str(row.get("jobs", 0)),
            "snowflake_last_activity_date": row.get("event_date", ""),
        }
        existing_id = search_company(token, locator)
        if existing_id:
            url = f"{HUBSPOT_BASE}/crm/v3/objects/companies/{existing_id}"
            resp = requests.patch(url, headers=_headers(token), json={"properties": props}, timeout=15)
            resp.raise_for_status()
            log.info("Updated activity metrics for locator '%s'", locator)
        else:
            log.warning("Company with locator '%s' not found in HubSpot, skipping activity update.", locator)


def main() -> None:
    token = os.environ.get("HUBSPOT_ACCESS_TOKEN")
    if not token:
        log.error("HUBSPOT_ACCESS_TOKEN env var is required.")
        sys.exit(1)

    metrics_file = os.environ.get("METRICS_FILE", "metrics_report.json")
    if not os.path.exists(metrics_file):
        log.error("Metrics file not found: %s", metrics_file)
        sys.exit(1)

    report = load_report(metrics_file)
    log.info("Loaded report generated at: %s", report.get("export_timestamp", "unknown"))

    summary = report.get("summary", {})
    log.info(
        "Summary → installs: %s active, %s all-time | consumers: %s",
        summary.get("active_installs_now", 0),
        summary.get("total_installs_all_time", 0),
        summary.get("unique_consumers_in_period", 0),
    )

    data = report.get("metrics", {})

    installs = data.get("active_installs", [])
    if installs:
        log.info("Processing %d active install records...", len(installs))
        push_installs(token, installs)
    else:
        log.info("No active install records found in report.")

    activity = data.get("consumer_activity", [])
    if activity:
        log.info("Processing %d consumer activity records...", len(activity))
        push_consumer_activity(token, activity)
    else:
        log.info("No consumer activity records found in report.")

    log.info("Done.")


if __name__ == "__main__":
    main()
