#!/usr/bin/env bash

# Usage: ./logs.sh [instanceId] [lines]
# Defaults: instanceId=0, lines=500

CONTAINER="falkordb-server"
INSTANCE_ID="${1:-0}"
LINES="${2:-500}"

# Status via app procedure
snow sql -q "use role consumer_role; use database FALKORDB_APP_INSTANCE; call app_public.get_service_status();"

# Extra diagnostics: service and container state
snow sql -q "use role consumer_role; use database FALKORDB_APP_INSTANCE; show services like 'ST_SPCS';"
snow sql -q "use role consumer_role; use database FALKORDB_APP_INSTANCE; describe service app_public.st_spcs;"
snow sql -q "use role consumer_role; use database FALKORDB_APP_INSTANCE; show service containers in service app_public.st_spcs;"

# Logs via app procedure
snow sql -q "use role consumer_role; use database FALKORDB_APP_INSTANCE; call app_public.get_service_logs('$INSTANCE_ID', '$CONTAINER', $LINES);"