#!/bin/bash

# Shut the FalkorDB demo down so nothing keeps billing.
#
# The compute pool is what costs money: it bills per node-hour while it is
# active. AUTO_SUSPEND_SECS only fires once the pool is *idle*, which never
# happens while the FalkorDB service is running — so the pool must be suspended
# explicitly. That is exactly what this script (and app_public.stop_app) does.
#
# Usage: ./scripts/demo_down.sh [--drop]
#   (default)  Suspend the service and the compute pool. The application and the
#              service definition stay, so demo_up.sh restarts in seconds.
#   --drop     Drop the service instead of suspending it. Use this when you want
#              to restart with different container resources.
#
# Graphs are not persisted (the app mounts no volume for graph data), so
# demo_up.sh reloads the data either way.
#
# Override any setting with an environment variable:
#   FALKORDB_APP_NAME   (default falkordb_app_instance)
#   FALKORDB_ROLE       (default consumer_role)
#   FALKORDB_POOL       (default POOL_CONSUMER)
#   FALKORDB_WAREHOUSE  (default WH_CONSUMER)

APP_NAME="${FALKORDB_APP_NAME:-falkordb_app_instance}"
APP_ROLE="${FALKORDB_ROLE:-consumer_role}"
POOL_NAME="${FALKORDB_POOL:-POOL_CONSUMER}"
WH_NAME="${FALKORDB_WAREHOUSE:-WH_CONSUMER}"

SNOW_ARGS=(--role "$APP_ROLE")
[ -n "${FALKORDB_SNOW_CONNECTION:-}" ] && SNOW_ARGS+=(--connection "$FALKORDB_SNOW_CONNECTION")

MODE="suspend"

for arg in "$@"; do
    case "$arg" in
        --drop)    MODE="drop" ;;
        -h|--help) sed -n '3,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "❌ Unknown option: $arg"; exit 1 ;;
    esac
done

run_sql()       { snow sql "${SNOW_ARGS[@]}" -q "$1"; }
run_sql_quiet() { snow sql "${SNOW_ARGS[@]}" -q "$1" >/dev/null 2>&1; }
run_sql_json()  { snow sql "${SNOW_ARGS[@]}" --format JSON -q "$1" 2>/dev/null; }

json_key() {
    python3 -c '
import json, re, sys
key = sys.argv[1].lower()
m = re.search(r"[\[{].*[\]}]", sys.stdin.read(), re.S)
if not m: sys.exit(0)
try: data = json.loads(m.group(0))
except Exception: sys.exit(0)
def walk(n):
    if isinstance(n, str):
        s = n.strip()
        if s[:1] in ("[", "{"):
            try: return walk(json.loads(s))
            except Exception: return []
        return []
    if isinstance(n, list):
        return [v for i in n for v in walk(i)]
    if isinstance(n, dict):
        out = []
        for k, v in n.items():
            if k.lower() == key and v is not None and not isinstance(v, (list, dict)):
                out.append(str(v))
            out += walk(v)
        return out
    return []
vals = walk(data)
if vals: print(vals[0])
' "$1"
}

echo "🛑 FalkorDB Demo — DOWN"
echo "======================="
echo "   Role        : $APP_ROLE"
echo "   Application : $APP_NAME"
echo "   Compute pool: $POOL_NAME"
echo "   Warehouse   : $WH_NAME"
echo ""

# ---------------------------------------------------------------------------
# Step 1: ask the app to release its own compute. This covers the case where
# start_app() created the pool, so the application owns it and can ALTER it.
# ---------------------------------------------------------------------------
APP_STEP_OK=false

if [ "$MODE" = "drop" ]; then
    echo "📦 Step 1/3: Dropping the service and suspending the app-owned compute pool..."
    run_sql "CALL ${APP_NAME}.app_public.stop_app('${POOL_NAME}');" && APP_STEP_OK=true
else
    echo "📦 Step 1/3: Suspending the service and the app-owned compute pool..."
    run_sql "CALL ${APP_NAME}.app_public.suspend_app();" && APP_STEP_OK=true
fi

if [ "$APP_STEP_OK" = false ]; then
    echo "⚠️  The app could not release its own compute (see the error above)."
    echo "   Most likely the installed app predates suspend_app/stop_app(pool)."
    echo "   Step 2 will try to suspend the pool from outside instead."
fi
echo ""

# ---------------------------------------------------------------------------
# Step 2: suspend the pool from the consumer side too. When the pool was created
# by scripts/instantiate.sql the consumer owns it and the app cannot suspend it,
# so this is the step that actually stops the bill in that setup.
#
# A pool created by the *app* is owned by the application, and an outside role
# needs OPERATE on it, which it does not have by default. So a failure here is
# only harmless when step 1 already succeeded — otherwise nothing has stopped
# and we must say so rather than reassure the user.
# ---------------------------------------------------------------------------
echo "💤 Step 2/3: Suspending the compute pool as ${APP_ROLE} (in case the consumer owns it)..."
if run_sql_quiet "ALTER COMPUTE POOL ${POOL_NAME} SUSPEND;"; then
    echo "✅ Compute pool suspend issued"
elif [ "$APP_STEP_OK" = true ]; then
    echo "ℹ️  Not needed or not permitted for ${APP_ROLE} (already handled in step 1)"
else
    echo "❌ Could not suspend the pool from outside either, and step 1 failed."
    echo "   ${APP_ROLE} needs OPERATE on a pool the application owns:"
    echo "   snow sql --role ACCOUNTADMIN -q \"GRANT OPERATE ON COMPUTE POOL ${POOL_NAME} TO ROLE ${APP_ROLE};\""
    echo "   snow sql --role ${APP_ROLE} -q \"ALTER COMPUTE POOL ${POOL_NAME} SUSPEND;\""
fi

run_sql_quiet "ALTER WAREHOUSE ${WH_NAME} SUSPEND;" \
    && echo "✅ Warehouse suspended" \
    || echo "ℹ️  Warehouse already suspended"
echo ""

# ---------------------------------------------------------------------------
# Step 3: confirm nothing is left running. A pool bills in ACTIVE, IDLE,
# STOPPING and RESIZING - only SUSPENDED is free - so STOPPING is not good
# enough and we poll until it settles.
# ---------------------------------------------------------------------------
echo "🔍 Step 3/3: Verifying the compute pool state..."
state=""
waited=0
while [ "$waited" -le 120 ]; do
    # LIKE treats _ as a single-character wildcard, so 'POOL_CONSUMER' can match
    # more than one pool and the first row read may belong to a different one.
    # The name is compared exactly instead, so this reports the state of the pool
    # this script actually started.
    state="$(run_sql_json "SHOW COMPUTE POOLS LIKE '${POOL_NAME}'; SELECT \"state\" AS exact_state FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) WHERE UPPER(\"name\") = UPPER('${POOL_NAME}');" | json_key "exact_state")"
    state_upper="$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')"

    case "$state_upper" in
        STOPPING|SUSPENDING)
            [ "$waited" -eq 0 ] && echo "   ...pool is ${state_upper}, which still bills. Waiting for SUSPENDED..."
            sleep 15
            waited=$((waited + 15))
            ;;
        *)
            break
            ;;
    esac
done

case "$state_upper" in
    SUSPENDED)
        echo "✅ Compute pool ${POOL_NAME} is SUSPENDED — nothing is billing."
        ;;
    STOPPING|SUSPENDING)
        echo "⏳ Compute pool ${POOL_NAME} is still ${state_upper} after ${waited}s."
        echo "   It is shutting down and stops billing once it reaches SUSPENDED."
        echo "   Confirm with: snow sql --role ${APP_ROLE} -q \"SHOW COMPUTE POOLS LIKE '${POOL_NAME}';\""
        ;;
    "")
        echo "⚠️  Could not read the state of ${POOL_NAME} with role ${APP_ROLE}."
        echo "   Check it manually: SHOW COMPUTE POOLS LIKE '${POOL_NAME}';"
        ;;
    *)
        echo "⚠️  Compute pool ${POOL_NAME} is still ${state_upper} — it is STILL BILLING."
        echo "   If the application owns the pool, grant OPERATE first, then suspend:"
        echo "   snow sql --role ACCOUNTADMIN -q \"GRANT OPERATE ON COMPUTE POOL ${POOL_NAME} TO ROLE ${APP_ROLE};\""
        echo "   snow sql --role ${APP_ROLE} -q \"ALTER COMPUTE POOL ${POOL_NAME} SUSPEND;\""
        ;;
esac

echo ""
echo "💡 Restart with: ./scripts/demo_up.sh"
echo ""
