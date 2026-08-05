#!/bin/bash

# Shared configuration and helpers for the demo lifecycle scripts
# (demo_start.sh, demo_stop.sh, demo_status.sh).
#
# Override any value with an environment variable, e.g.
#   FALKORDB_POOL=MY_POOL ./scripts/demo_start.sh

APP_NAME="${FALKORDB_APP_NAME:-falkordb_app_instance}"
APP_ROLE="${FALKORDB_ROLE:-consumer_role}"
POOL_NAME="${FALKORDB_POOL:-POOL_CONSUMER}"
WH_NAME="${FALKORDB_WAREHOUSE:-WH_CONSUMER}"
SNOW_CONNECTION="${FALKORDB_SNOW_CONNECTION:-}"

SNOW_ARGS=(--role "$APP_ROLE")
if [ -n "$SNOW_CONNECTION" ]; then
    SNOW_ARGS+=(--connection "$SNOW_CONNECTION")
fi

# Run SQL and show the result to the user.
run_sql() {
    snow sql "${SNOW_ARGS[@]}" -q "$1"
}

# Run SQL quietly, printing raw JSON on stdout for parsing.
run_sql_json() {
    snow sql "${SNOW_ARGS[@]}" --format JSON -q "$1" 2>/dev/null
}

# Run SQL and ignore failures (used for best-effort suspends).
run_sql_quiet() {
    snow sql "${SNOW_ARGS[@]}" -q "$1" >/dev/null 2>&1
}

# Extract the first value for a key from arbitrarily nested `snow --format JSON`
# output. Snowflake nests JSON inside strings (VARIANT columns), so this walks
# into embedded JSON documents too.
json_key() {
    python3 -c '
import json, re, sys

key = sys.argv[1].lower()
raw = sys.stdin.read()
match = re.search(r"[\[{].*[\]}]", raw, re.S)
if not match:
    sys.exit(0)
try:
    data = json.loads(match.group(0))
except Exception:
    sys.exit(0)

def walk(node):
    if isinstance(node, str):
        stripped = node.strip()
        if stripped[:1] in ("[", "{"):
            try:
                return walk(json.loads(stripped))
            except Exception:
                return []
        return []
    if isinstance(node, list):
        found = []
        for item in node:
            found += walk(item)
        return found
    if isinstance(node, dict):
        found = []
        for name, value in node.items():
            if name.lower() == key and value is not None and not isinstance(value, (list, dict)):
                found.append(str(value))
            found += walk(value)
        return found
    return []

values = walk(data)
if values:
    print(values[0])
' "$1"
}

# All service instance statuses reported by SYSTEM$GET_SERVICE_STATUS,
# comma separated (e.g. "READY" or "PENDING").
service_statuses() {
    run_sql_json "CALL ${APP_NAME}.app_public.get_service_status();" | python3 -c '
import json, re, sys

raw = sys.stdin.read()
match = re.search(r"[\[{].*[\]}]", raw, re.S)
if not match:
    print("UNKNOWN")
    sys.exit(0)
try:
    data = json.loads(match.group(0))
except Exception:
    print("UNKNOWN")
    sys.exit(0)

def walk(node):
    if isinstance(node, str):
        stripped = node.strip()
        if stripped[:1] in ("[", "{"):
            try:
                return walk(json.loads(stripped))
            except Exception:
                return []
        return []
    if isinstance(node, list):
        found = []
        for item in node:
            found += walk(item)
        return found
    if isinstance(node, dict):
        found = []
        if "status" in node:
            found.append(str(node["status"]).upper())
        for value in node.values():
            found += walk(value)
        return found
    return []

statuses = walk(data)
print(",".join(statuses) if statuses else "UNKNOWN")
'
}

# Current state of the compute pool (ACTIVE / IDLE / SUSPENDED / STARTING ...).
compute_pool_state() {
    run_sql_json "SHOW COMPUTE POOLS LIKE '${POOL_NAME}';" | json_key "state"
}

# Public URL of the FalkorDB Browser endpoint, empty until the service is ready.
browser_url() {
    run_sql_json "SHOW ENDPOINTS IN SERVICE ${APP_NAME}.app_public.st_spcs;
SELECT \"ingress_url\" AS browser_url
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE \"name\" = 'falkordb-browser';" | json_key "browser_url"
}

print_config() {
    echo "   Connection role : $APP_ROLE"
    echo "   Application     : $APP_NAME"
    echo "   Compute pool    : $POOL_NAME"
    echo "   Warehouse       : $WH_NAME"
}
