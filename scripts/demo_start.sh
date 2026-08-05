#!/bin/bash

# Start the FalkorDB demo: bring up compute, start the service, load demo data,
# and print the FalkorDB Browser URL.
#
# Safe to run repeatedly. It handles a cold start (nothing exists yet) and a warm
# start (resuming what demo_stop.sh suspended) through the same idempotent path.
#
# Usage: ./scripts/demo_start.sh [--dataset social|airroutes|none]
#   --dataset social      Load the small sample social network (default).
#   --dataset airroutes   Load the full air routes dataset (examples/airroutes).
#   --dataset none        Start the service only.
#   --no-data             Same as --dataset none.
#
# Run ./scripts/demo_stop.sh when the demo is over: the compute pool bills per
# node-hour for as long as it is active, and nothing suspends it automatically.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/demo_common.sh
source "$SCRIPT_DIR/demo_common.sh"

DATASET="${FALKORDB_DATASET:-social}"
READY_TIMEOUT_SECS="${FALKORDB_READY_TIMEOUT_SECS:-900}"

while [ $# -gt 0 ]; do
    case "$1" in
        --no-data) DATASET="none" ;;
        --dataset)
            shift
            DATASET="${1:-}"
            ;;
        --dataset=*) DATASET="${1#--dataset=}" ;;
        -h|--help) sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "❌ Unknown option: $1"; exit 1 ;;
    esac
    shift
done

case "$DATASET" in
    social|airroutes|none) ;;
    *) echo "❌ Unknown dataset: $DATASET (expected social, airroutes or none)"; exit 1 ;;
esac

echo "🚀 FalkorDB Demo Start"
echo "======================"
print_config
echo ""

# Step 1: Compute pool + warehouse + service.
# start_app() is idempotent: it creates what is missing and resumes what was
# suspended by demo_stop.sh.
echo "⚙️  Step 1: Starting compute pool, warehouse and service..."
run_sql "CALL ${APP_NAME}.app_public.start_app('${POOL_NAME}', '${WH_NAME}');"
echo "✅ Compute and service requested"
echo ""

# Step 2: Wait for the service to report READY. A cold start pulls the container
# image, so this can take a few minutes.
echo "⏳ Step 2: Waiting for the service to become READY (timeout ${READY_TIMEOUT_SECS}s)..."
elapsed=0
statuses=""
while [ "$elapsed" -lt "$READY_TIMEOUT_SECS" ]; do
    statuses="$(service_statuses)"

    case "$statuses" in
        *FAILED*)
            echo "❌ Service reported FAILED: $statuses"
            echo "   Inspect logs: snow sql --role $APP_ROLE -q \"CALL ${APP_NAME}.app_public.get_service_logs('0', 'falkordb-server', 100);\""
            exit 1
            ;;
    esac

    case "$statuses" in
        *PENDING*|*STARTING*|*SUSPENDING*|*UNKNOWN*) ;;
        *READY*)
            echo "✅ Service is READY (after ${elapsed}s)"
            break
            ;;
    esac

    printf '   ...%ss elapsed (status: %s)\n' "$elapsed" "$statuses"
    sleep 15
    elapsed=$((elapsed + 15))
done

case "$statuses" in
    *READY*) ;;
    *)
        echo "❌ Service did not become READY within ${READY_TIMEOUT_SECS}s (last status: ${statuses:-none})"
        echo "   Re-run ./scripts/demo_status.sh to keep watching, or ./scripts/demo_stop.sh to stop billing."
        exit 1
        ;;
esac
echo ""

# Step 3: Load demo data.
# Graphs live only in the container: app/src/falkordb.yaml mounts a stage for CSV
# staging but no volume for graph data, so every stop wipes the graphs and they
# have to be reloaded on each start.
if [ "$DATASET" = "social" ]; then
    echo "📊 Step 3: Loading sample graph (demo_social_network)..."
    run_sql "CALL ${APP_NAME}.app_public.load_sample_social_network();"
    echo "✅ Sample graph loaded"
elif [ "$DATASET" = "airroutes" ]; then
    echo "📊 Step 3: Loading the air routes dataset..."
    "$SCRIPT_DIR/demo_load_airroutes.sh"
else
    echo "⏭️  Step 3: Skipping demo data (--dataset none)"
fi
echo ""

# Step 4: Endpoint.
echo "🌐 Step 4: Resolving the FalkorDB Browser URL..."
url="$(browser_url)"
echo ""
echo "🎉 Demo is up!"
if [ -n "$url" ]; then
    echo "   FalkorDB Browser: https://${url#https://}"
else
    echo "   ⚠️  Endpoint not published yet. Re-run ./scripts/demo_status.sh in a minute."
fi
echo ""
echo "💡 When you are done: ./scripts/demo_stop.sh  (the compute pool bills until you do)"
echo ""
