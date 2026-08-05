#!/bin/bash

# Stop the FalkorDB demo so nothing keeps billing.
#
# The compute pool is what costs money: it bills per node-hour while it is active,
# and AUTO_SUSPEND_SECS only fires once the pool is idle, which never happens while
# the FalkorDB service is running. So the pool has to be suspended explicitly.
#
# Usage: ./scripts/demo_stop.sh [--drop]
#   (default)   Suspend the service and the compute pool. The app and the service
#               definition stay in place, so demo_start.sh restarts in seconds.
#   --drop      Drop the service instead of suspending it. Use this when you want
#               to restart with different container resources.
#
# Note: graphs are not persisted (no volume for graph data), so demo_start.sh
# reloads the sample data either way.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/demo_common.sh
source "$SCRIPT_DIR/demo_common.sh"

MODE="suspend"

for arg in "$@"; do
    case "$arg" in
        --drop) MODE="drop" ;;
        -h|--help) sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "❌ Unknown option: $arg"; exit 1 ;;
    esac
done

echo "🛑 FalkorDB Demo Stop"
echo "====================="
print_config
echo ""

# Step 1: Ask the app to release its own compute. This covers a pool the app
# created itself via start_app().
if [ "$MODE" = "drop" ]; then
    echo "📦 Step 1: Dropping the service and suspending the app-owned compute pool..."
    run_sql "CALL ${APP_NAME}.app_public.stop_app('${POOL_NAME}');"
else
    echo "📦 Step 1: Suspending the service and the app-owned compute pool..."
    run_sql "CALL ${APP_NAME}.app_public.suspend_app();"
fi
echo ""

# Step 2: Suspend the pool from the consumer side too. When the pool was created
# by scripts/instantiate.sql the consumer owns it and the app cannot suspend it,
# so this is the step that actually stops the bill in that setup.
echo "💤 Step 2: Suspending the compute pool as ${APP_ROLE} (in case the consumer owns it)..."
if run_sql_quiet "ALTER COMPUTE POOL ${POOL_NAME} SUSPEND;"; then
    echo "✅ Compute pool suspend issued"
else
    echo "ℹ️  Compute pool suspend not needed or not permitted for ${APP_ROLE} (already handled in step 1)"
fi

run_sql_quiet "ALTER WAREHOUSE ${WH_NAME} SUSPEND;" && echo "✅ Warehouse suspended" || echo "ℹ️  Warehouse already suspended"
echo ""

# Step 3: Confirm nothing is left running.
echo "🔍 Step 3: Verifying compute pool state..."
state="$(compute_pool_state)"
state_upper="$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')"

case "$state_upper" in
    SUSPENDED|STOPPING|SUSPENDING)
        echo "✅ Compute pool ${POOL_NAME} is ${state_upper} — no compute is billing."
        ;;
    "")
        echo "⚠️  Could not read the state of ${POOL_NAME} with role ${APP_ROLE}."
        echo "   Check it manually: SHOW COMPUTE POOLS LIKE '${POOL_NAME}';"
        ;;
    *)
        echo "⚠️  Compute pool ${POOL_NAME} is still ${state_upper} — it is STILL BILLING."
        echo "   Suspend it with a role that owns the pool:"
        echo "   snow sql --role ACCOUNTADMIN -q \"ALTER COMPUTE POOL ${POOL_NAME} SUSPEND;\""
        ;;
esac

echo ""
echo "💡 Restart with: ./scripts/demo_start.sh"
echo ""
