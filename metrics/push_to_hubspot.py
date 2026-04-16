#!/usr/bin/env python3
"""
push_to_hubspot.py

Reads the subscription export (produced by export_metrics.py) and upserts
one HubSpot subscription record per Snowflake consumer using the exact
14 fields defined in hubspot_field_mapping.json.

HubSpot fields pushed per consumer:
  cloud_region, cloud_vendor, cloud_version, cloud_provider,
  falkordb_version, hs_recurring_billing_start_date, hs_status,
  db_name, hs_name, node_instance_type, deployment_type,
  hs_last_modified_at, subscription_plan, email

Required env var:
  HUBSPOT_ACCESS_TOKEN - Private App token from HubSpot

Optional env var:
  METRICS_FILE - path to export JSON (default: metrics_report.json)

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

# The 14 HubSpot subscription fields we manage
SUBSCRIPTION_FIELDS = [
    "cloud_region",
    "cloud_vendor",
    "cloud_version",
    "cloud_provider",
    "falkordb_version",
    "hs_recurring_billing_start_date",
    "hs_status",
    "db_name",
    "hs_name",
    "deployment_type",
    "hs_last_modified_at",
    "subscription_plan",
    "email",
]

# Custom properties to ensure exist in HubSpot (subscription object)
CUSTOM_SUBSCRIPTION_PROPERTIES = [
    {"name": "cloud_region",         "label": "Cloud Region",          "type": "string",   "fieldType": "text"},
    {"name": "cloud_vendor",         "label": "Cloud Vendor",          "type": "string",   "fieldType": "text"},
    {"name": "cloud_version",        "label": "Cloud Version",         "type": "string",   "fieldType": "text"},
    {"name": "cloud_provider",       "label": "Cloud Provider",        "type": "string",   "fieldType": "text"},
    {"name": "falkordb_version",     "label": "FalkorDB Version",      "type": "string",   "fieldType": "text"},
    {"name": "db_name",              "label": "DB Name",               "type": "string",   "fieldType": "text"},
    {"name": "deployment_type",      "label": "Deployment Type",       "type": "string",   "fieldType": "text"},
    {"name": "subscription_plan",    "label": "Subscription Plan",     "type": "string",   "fieldType": "text"},
    {"name": "email",                "label": "Consumer Email",        "type": "string",   "fieldType": "text"},
]


# ---------------------------------------------------------------------------
# HubSpot helpers
# ---------------------------------------------------------------------------

def _headers(token: str) -> dict:
    return {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }


def ensure_custom_properties(token: str) -> None:
    """Create custom subscription properties in HubSpot if they don't exist yet."""
    # Step 1: Ensure the property group exists
    group_url = f"{HUBSPOT_BASE}/crm/v3/properties/subscriptions/groups"
    group_resp = requests.get(group_url, headers=_headers(token), timeout=15)
    group_resp.raise_for_status()
    existing_groups = {g["name"] for g in group_resp.json().get("results", [])}

    group_name = "falkordb_snowflake"
    if group_name not in existing_groups:
        r = requests.post(
            group_url,
            headers=_headers(token),
            json={"name": group_name, "label": "FalkorDB Snowflake"},
            timeout=15,
        )
        if r.ok:
            log.info("Created property group: %s", group_name)
        else:
            log.warning("Could not create property group: %s — %s", r.status_code, r.text)

    # Step 2: Create custom properties in that group
    url = f"{HUBSPOT_BASE}/crm/v3/properties/subscriptions"
    resp = requests.get(url, headers=_headers(token), timeout=15)
    resp.raise_for_status()
    existing = {p["name"] for p in resp.json().get("results", [])}

    for prop in CUSTOM_SUBSCRIPTION_PROPERTIES:
        if prop["name"] in existing:
            continue
        payload = {
            "name": prop["name"],
            "label": prop["label"],
            "type": prop["type"],
            "fieldType": prop["fieldType"],
            "groupName": group_name,
        }
        r = requests.post(url, headers=_headers(token), json=payload, timeout=15)
        if r.ok:
            log.info("Created custom property: %s", prop["name"])
        else:
            log.warning("Could not create property %s: %s — %s", prop["name"], r.status_code, r.text)


def search_subscription(token: str, hs_name: str) -> str | None:
    """Find an existing subscription by hs_name."""
    url = f"{HUBSPOT_BASE}/crm/v3/objects/subscriptions/search"
    payload = {
        "filterGroups": [
            {
                "filters": [
                    {
                        "propertyName": "hs_name",
                        "operator": "EQ",
                        "value": hs_name,
                    }
                ]
            }
        ],
        "properties": ["hs_name"],
        "limit": 1,
    }
    resp = requests.post(url, headers=_headers(token), json=payload, timeout=15)
    resp.raise_for_status()
    results = resp.json().get("results", [])
    return results[0]["id"] if results else None


def upsert_subscription(token: str, properties: dict) -> str:
    """Create or update a HubSpot subscription. Returns the subscription id."""
    hs_name = properties.get("hs_name", "")
    existing_id = search_subscription(token, hs_name)

    if existing_id:
        url = f"{HUBSPOT_BASE}/crm/v3/objects/subscriptions/{existing_id}"
        resp = requests.patch(url, headers=_headers(token), json={"properties": properties}, timeout=15)
        if not resp.ok:
            log.error("HubSpot PATCH error %s: %s", resp.status_code, resp.text)
        resp.raise_for_status()
        log.info("Updated subscription '%s' (id=%s)", hs_name, existing_id)
        return existing_id
    else:
        url = f"{HUBSPOT_BASE}/crm/v3/objects/subscriptions"
        resp = requests.post(url, headers=_headers(token), json={"properties": properties}, timeout=15)
        if not resp.ok:
            log.error("HubSpot POST error %s: %s", resp.status_code, resp.text)
        resp.raise_for_status()
        new_id = resp.json()["id"]
        log.info("Created subscription '%s' (id=%s)", hs_name, new_id)
        return new_id


# ---------------------------------------------------------------------------
# Main logic
# ---------------------------------------------------------------------------

def load_report(path: str) -> dict:
    with open(path) as f:
        return json.load(f)


def push_subscriptions(token: str, subscriptions: list[dict]) -> None:
    """Upsert one HubSpot subscription per consumer record."""
    for sub in subscriptions:
        hs_name = sub.get("hs_name", "")
        if not hs_name:
            log.warning("Skipping subscription with empty hs_name: %s", sub)
            continue

        # Only send the 14 fields we care about
        properties = {field: str(sub.get(field, "")) for field in SUBSCRIPTION_FIELDS}
        upsert_subscription(token, properties)


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

    log.info("Ensuring custom HubSpot subscription properties exist...")
    ensure_custom_properties(token)

    subscriptions = report.get("subscriptions", [])
    log.info("Found %d subscription records to push.", len(subscriptions))

    if subscriptions:
        push_subscriptions(token, subscriptions)
    else:
        log.info("No subscription records found in report.")

    log.info("Done. Pushed %d subscriptions with 14 fields each.", len(subscriptions))


if __name__ == "__main__":
    main()
