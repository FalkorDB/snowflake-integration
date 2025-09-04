#!/usr/bin/env bash

# Usage: ./logs.sh [instanceId] [lines]
# Defaults: instanceId=0, lines=500

CONTAINER="falkordb-server"
INSTANCE_ID="${1:-0}"
LINES="${2:-500}"

# Status via app procedure
snow sql -q "use role consumer_role; use database FALKORDB_APP_INSTANCE; call app_public.get_service_status();"

# Logs via app procedure
snow sql -q "use role consumer_role; use database FALKORDB_APP_INSTANCE; call app_public.get_service_logs('$INSTANCE_ID', '$CONTAINER', $LINES);"