# Snowflake Marketplace Metrics

Automated daily export of FalkorDB Native App usage metrics from Snowflake's provider analytics views. Outputs a JSON report suitable for import into HubSpot or other CRM/analytics tools.

## What it measures

| Metric | Source View | Latency |
|--------|-------------|---------|
| **Cumulative installs** (GET/TRIAL/PURCHASE) | `LISTING_EVENTS_DAILY` | Up to 2 days |
| **Daily install/uninstall trends** | `LISTING_EVENTS_DAILY` | Up to 2 days |
| **Currently active installs** (version, health) | `APPLICATION_STATE` | ~10 minutes |
| **Consumer activity** (jobs, unique users 1d/7d/28d) | `LISTING_CONSUMPTION_DAILY` | Up to 2 days |
| **Listing engagement** (clicks, views, CTR) | `LISTING_TELEMETRY_DAILY` | Up to 2 days |

## One-time setup

### 1. Create Snowflake service account

Generate an RSA key pair:

```bash
openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out metrics_bot_key.p8 -nocrypt
openssl rsa -in metrics_bot_key.p8 -pubout -out metrics_bot_key.pub
```

Then run the setup script in Snowflake (as ACCOUNTADMIN), replacing `<YOUR_RSA_PUBLIC_KEY>` with the contents of `metrics_bot_key.pub` (without header/footer lines):

```bash
snow sql -f sql/setup_metrics_role.sql
```

### 2. Configure GitHub secrets

Go to **Settings → Secrets and variables → Actions** in this repository and add:

| Secret | Value |
|--------|-------|
| `SNOWFLAKE_ACCOUNT` | Your Snowflake account identifier (e.g., `xyz12345.us-east-1`) |
| `SNOWFLAKE_USER` | `sf_metrics_bot` |
| `SNOWFLAKE_PRIVATE_KEY` | Full PEM private key from `metrics_bot_key.p8` |
| `SNOWFLAKE_WAREHOUSE` | `WH_METRICS` |

## How to run

### Automatic (daily)

The workflow runs automatically every day at **06:00 UTC** via cron schedule.

### GitHub UI (manual)

1. Go to the **Actions** tab in this repository
2. Select **"Export Snowflake Marketplace Metrics"** from the left sidebar
3. Click **"Run workflow"**
4. (Optional) Override `listing_filter` or `days` parameters
5. Click the green **"Run workflow"** button

### curl / API (programmatic)

Requires a GitHub token with `actions:write` permission:

```bash
curl -X POST \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github.v3+json" \
  https://api.github.com/repos/FalkorDB/snowflake-integration/actions/workflows/export-metrics.yml/dispatches \
  -d '{"ref":"main","inputs":{"listing_filter":"%FALKORDB%","days":"90"}}'
```

## Output

The workflow produces a JSON artifact (`sf-metrics-<run_id>`) retained for 90 days. Download from the workflow run's **Artifacts** section.

### JSON schema

```json
{
  "export_timestamp": "2026-03-23T06:00:00+00:00",
  "run_id": "uuid",
  "listing_filter": "%FALKORDB%",
  "lookback_days": 90,
  "metrics": {
    "cumulative_installs": [
      { "listing_name": "...", "event_type": "GET", "total_count": 142 }
    ],
    "daily_trends": [
      { "event_date": "2026-03-22", "event_type": "GET", "daily_count": 3 }
    ],
    "active_installs": [
      { "consumer_account_name": "...", "current_version": "V1", "last_health_status": "OK" }
    ],
    "consumer_activity": [
      { "event_date": "2026-03-22", "consumer_account_name": "...", "jobs": 45, "unique_users_1d": 3 }
    ],
    "listing_telemetry": [
      { "event_date": "2026-03-22", "event_type": "LISTING VIEW", "event_count": 25 }
    ]
  },
  "summary": {
    "total_installs_all_time": 142,
    "active_installs_now": 87,
    "healthy_installs": 85,
    "total_jobs_in_period": 12540,
    "unique_consumers_in_period": 42
  }
}
```

## Local development

```bash
pip install -r metrics/requirements.txt

export SNOWFLAKE_ACCOUNT="your-account"
export SNOWFLAKE_USER="sf_metrics_bot"
export SNOWFLAKE_PRIVATE_KEY="$(cat metrics_bot_key.p8)"
export SNOWFLAKE_WAREHOUSE="WH_METRICS"

python metrics/export_metrics.py --output report.json
```

## Future: HubSpot integration

When ready to push data to HubSpot, add a workflow step after the export:

```yaml
- name: Push to HubSpot
  env:
    HUBSPOT_API_KEY: ${{ secrets.HUBSPOT_API_KEY }}
  run: python metrics/push_to_hubspot.py --input metrics_report.json
```

The JSON structure is designed so `active_installs` maps to HubSpot companies (keyed by `consumer_organization_name`) and `consumer_activity` maps to engagement metrics on those company records.
