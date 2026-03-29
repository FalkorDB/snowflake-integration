#!/usr/bin/env python3
"""
push_to_hubspot.py

Reads metrics_report.json (produced by export_metrics.py) and pushes data
to HubSpot:
  - One Company record per unique Snowflake consumer account
  - One Deal record per install event (TRIAL / PURCHASE)

Required env var:
  HUBSPOT_ACCESS_TOKEN - Private App token from HubSpot

Optional env var:
  METRICS_FILE - path to metrics_report.json (default: metrics_report.json)

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

# Custom properties to create in HubSpot for Snowflake data
CUSTOM_COMPANY_PROPERTIES = [
    {"name": "sf_account_locator",        "label": "Snowflake Account Locator",       "type": "string",   "fieldType": "text"},
    {"name": "sf_org_name",               "label": "Snowflake Org Name",              "type": "string",   "fieldType": "text"},
    {"name": "sf_region",                 "label": "Snowflake Region",                "type": "string",   "fieldType": "text"},
    {"name": "sf_app_version",            "label": "FalkorDB App Version",            "type": "string",   "fieldType": "text"},
    {"name": "sf_app_patch",              "label": "FalkorDB App Patch",              "type": "string",   "fieldType": "text"},
    {"name": "sf_health_status",          "label": "Health Status",                   "type": "string",   "fieldType": "text"},
    {"name": "sf_health_updated_on",      "label": "Health Status Updated On",        "type": "string",   "fieldType": "text"},
    {"name": "sf_installed_on",           "label": "App Install Date",                "type": "string",   "fieldType": "text"},
    {"name": "sf_upgrade_state",          "label": "Upgrade State",                   "type": "string",   "fieldType": "text"},
    {"name": "sf_unique_users_1d",        "label": "Unique Users (1 day)",            "type": "number",   "fieldType": "number"},
    {"name": "sf_unique_users_7d",        "label": "Unique Users (7 days)",           "type": "number",   "fieldType": "number"},
    {"name": "sf_unique_users_28d",       "label": "Unique Users (28 days)",          "type": "number",   "fieldType": "number"},
    {"name": "sf_jobs",                   "label": "Snowflake Jobs (period)",         "type": "number",   "fieldType": "number"},
]


def ensure_custom_properties(token: str) -> None:
    """Create custom company properties in HubSpot if they don't exist yet."""
    url = f"{HUBSPOT_BASE}/crm/v3/properties/companies"
    resp = requests.get(url, headers=_headers(token), timeout=15)
    resp.raise_for_status()
    existing = {p["name"] for p in resp.json().get("results", [])}

    for prop in CUSTOM_COMPANY_PROPERTIES:
        if prop["name"] in existing:
            continue
        payload = {
            "name": prop["name"],
            "label": prop["label"],
            "type": prop["type"],
            "fieldType": prop["fieldType"],
            "groupName": "companyinformation",
        }
        r = requests.post(url, headers=_headers(token), json=payload, timeout=15)
        if r.ok:
            log.info("Created custom property: %s", prop["name"])
        else:
            log.warning("Could not create property %s: %s", prop["name"], r.text)


# ---------------------------------------------------------------------------
# HubSpot helpers
# ---------------------------------------------------------------------------

def _headers(token: str) -> dict:
    return {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }


def search_company(token: str, account_locator: str) -> str | None:
    """Return HubSpot company id by name (using account_locator as the name key)."""
    url = f"{HUBSPOT_BASE}/crm/v3/objects/companies/search"
    payload = {
        "filterGroups": [
            {
                "filters": [
                    {
                        "propertyName": "name",
                        "operator": "EQ",
                        "value": account_locator,
                    }
                ]
            }
        ],
        "properties": ["name"],
        "limit": 1,
    }
    resp = requests.post(url, headers=_headers(token), json=payload, timeout=15)
    resp.raise_for_status()
    results = resp.json().get("results", [])
    return results[0]["id"] if results else None


def upsert_company(token: str, account_name: str, extra_props: dict) -> str:
    """Create or update a HubSpot Company. Returns the company id."""
    account_locator = extra_props.get("sf_account_locator") or account_name
    existing_id = search_company(token, account_locator)
    # Allow standard HubSpot properties + our custom sf_* properties
    allowed = {"name", "industry", "description", "phone", "city", "country"}
    custom = {p["name"] for p in CUSTOM_COMPANY_PROPERTIES}
    props = {"name": account_locator, **{k: v for k, v in extra_props.items() if k in allowed | custom}}

    if existing_id:
        url = f"{HUBSPOT_BASE}/crm/v3/objects/companies/{existing_id}"
        resp = requests.patch(url, headers=_headers(token), json={"properties": props}, timeout=15)
        if not resp.ok:
            log.error("HubSpot PATCH error %s: %s", resp.status_code, resp.text)
        resp.raise_for_status()
        log.info("Updated company '%s' (id=%s)", account_name, existing_id)
        return existing_id
    else:
        url = f"{HUBSPOT_BASE}/crm/v3/objects/companies"
        resp = requests.post(url, headers=_headers(token), json={"properties": props}, timeout=15)
        if not resp.ok:
            log.error("HubSpot POST error %s: %s", resp.status_code, resp.text)
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

        if not account_locator:
            log.warning("Skipping install row with missing account_locator (account: %s)", account_name)
            continue

        current_version = install.get("current_version", "")
        current_patch = str(install.get("current_patch", ""))
        upgrade_state = install.get("upgrade_state", "")
        health_status = install.get("last_health_status", "")
        health_updated = str(install.get("last_health_status_updated_on", ""))
        installed_on = str(install.get("current_installed_on", ""))
        org_name = install.get("consumer_organization_name", "")
        region = install.get("consumer_snowflake_region", "")

        company_props = {
            "industry": "COMPUTER_SOFTWARE",
            "description": f"FalkorDB Snowflake Native App | Org: {org_name} | Region: {region}",
            "sf_account_locator":   account_locator,
            "sf_org_name":          org_name,
            "sf_region":            region,
            "sf_app_version":       current_version,
            "sf_app_patch":         current_patch,
            "sf_health_status":     health_status,
            "sf_health_updated_on": health_updated,
            "sf_installed_on":      installed_on,
            "sf_upgrade_state":     upgrade_state,
        }
        company_id = upsert_company(token, account_name, company_props)

        # --- Deal: one per install ---
        deal_name = f"Snowflake Install - {account_name} - {install_date}"
        deal_props = {
            "pipeline": "default",
            "dealstage": "appointmentscheduled",
            "closedate": install_date,
            "amount": "0",
        }
        create_deal(token, deal_name, deal_props, company_id)


def push_consumer_activity(token: str, activity: list[dict]) -> None:
    """Update Company records with latest usage metrics."""
    # Group by locator (stable unique key), take the most recent row
    latest: dict[str, dict] = {}
    for row in activity:
        locator = row.get("consumer_account_locator", "")
        if not locator:
            log.warning("Skipping activity row with missing account_locator")
            continue
        if locator not in latest or row.get("event_date", "") > latest[locator].get("event_date", ""):
            latest[locator] = row

    for locator, row in latest.items():
        props = {
            "sf_unique_users_1d":  row.get("unique_users_1d", 0),
            "sf_unique_users_7d":  row.get("unique_users_7d", 0),
            "sf_unique_users_28d": row.get("unique_users_28d", 0),
            "sf_jobs":             row.get("jobs", 0),
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

    log.info("Ensuring custom HubSpot properties exist...")
    ensure_custom_properties(token)

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
