#!/bin/bash

# Bring the whole FalkorDB demo up with one command.
#
#   1. Start the compute pool, warehouse and the FalkorDB service
#   2. Wait until the service is READY
#   3. Upload the Air Routes CSVs into Snowflake tables
#   4. Create the graph indexes  (before any data is loaded)
#   5. Load the airports, then the routes, then compute route distances
#   6. Print the FalkorDB Browser URL
#
# Safe to run repeatedly: a cold start (nothing exists yet) and a warm start
# (resuming what demo_down.sh suspended) both go through the same path.
#
# Usage: ./scripts/demo_up.sh [--skip-upload] [--no-data]
#   --skip-upload   Snowflake tables already exist from a previous run; only
#                   rebuild the graph (skips re-uploading ~11 MB of CSV).
#   --no-data       Only start the service, load nothing.
#
# Override any setting with an environment variable:
#   FALKORDB_APP_NAME   (default falkordb_app_instance)
#   FALKORDB_ROLE       (default consumer_role)
#   FALKORDB_POOL       (default POOL_CONSUMER)
#   FALKORDB_WAREHOUSE  (default WH_CONSUMER)
#   FALKORDB_DEMO_DB    (default ROUTES_DEMO)
#   FALKORDB_READY_TIMEOUT_SECS  (default 900) wait for the service to report READY
#   FALKORDB_QUERY_TIMEOUT_SECS  (default 300) wait for it to accept a query
#
# When the demo is over run ./scripts/demo_down.sh — the compute pool bills per
# node-hour for as long as it is active and nothing suspends it automatically.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="${FALKORDB_APP_NAME:-falkordb_app_instance}"
APP_ROLE="${FALKORDB_ROLE:-consumer_role}"
POOL_NAME="${FALKORDB_POOL:-POOL_CONSUMER}"
WH_NAME="${FALKORDB_WAREHOUSE:-WH_CONSUMER}"
DEMO_DB="${FALKORDB_DEMO_DB:-ROUTES_DEMO}"
GRAPH_NAME="${FALKORDB_GRAPH:-airroutes}"
READY_TIMEOUT_SECS="${FALKORDB_READY_TIMEOUT_SECS:-900}"
QUERY_TIMEOUT_SECS="${FALKORDB_QUERY_TIMEOUT_SECS:-300}"

AIRPORTS_CSV="$REPO_ROOT/examples/airroutes/airports.csv"
ROUTES_CSV="$REPO_ROOT/examples/airroutes/routes.csv"

SNOW_ARGS=(--role "$APP_ROLE")
[ -n "${FALKORDB_SNOW_CONNECTION:-}" ] && SNOW_ARGS+=(--connection "$FALKORDB_SNOW_CONNECTION")

SKIP_UPLOAD=false
LOAD_DATA=true

for arg in "$@"; do
    case "$arg" in
        --skip-upload) SKIP_UPLOAD=true ;;
        --no-data)     LOAD_DATA=false ;;
        -h|--help)     sed -n '3,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "❌ Unknown option: $arg"; exit 1 ;;
    esac
done

SQL_TMP="$(mktemp -t falkordb_demo)"

# Once step 1 runs, compute is started and billing. Any later failure - or a
# Ctrl-C - must say so loudly, otherwise the pool keeps costing money silently.
# That is the exact failure mode this demo exists to prevent.
COMPUTE_STARTED=false
cleanup() {
    status=$?
    rm -f "$SQL_TMP"
    if [ "$status" -ne 0 ] && [ "$COMPUTE_STARTED" = true ]; then
        echo ""
        echo "🚨 demo_up.sh failed, but the compute pool is already running AND BILLING."
        echo "   Stop it now:"
        echo "   FALKORDB_APP_NAME=${APP_NAME} FALKORDB_ROLE=${APP_ROLE} FALKORDB_POOL=${POOL_NAME} FALKORDB_WAREHOUSE=${WH_NAME} ./scripts/demo_down.sh"
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

run_sql()       { snow sql "${SNOW_ARGS[@]}" -q "$1"; }
run_sql_file()  { snow sql "${SNOW_ARGS[@]}" -f "$SQL_TMP"; }
run_sql_quiet() { snow sql "${SNOW_ARGS[@]}" -q "$1" >/dev/null 2>&1; }
run_sql_json()  { snow sql "${SNOW_ARGS[@]}" --format JSON -q "$1" 2>/dev/null; }

# Snowflake nests JSON inside VARIANT strings, so this walks into embedded
# JSON documents as well as plain nested objects.
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

service_statuses() {
    run_sql_json "CALL ${APP_NAME}.app_public.get_service_status();" | python3 -c '
import json, re, sys
m = re.search(r"[\[{].*[\]}]", sys.stdin.read(), re.S)
if not m: print("UNKNOWN"); sys.exit(0)
try: data = json.loads(m.group(0))
except Exception: print("UNKNOWN"); sys.exit(0)
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
        out = [str(n["status"]).upper()] if "status" in n else []
        for v in n.values(): out += walk(v)
        return out
    return []
s = walk(data)
print(",".join(s) if s else "UNKNOWN")
'
}

echo "🚀 FalkorDB Demo — UP"
echo "====================="
echo "   Role        : $APP_ROLE"
echo "   Application : $APP_NAME"
echo "   Compute pool: $POOL_NAME"
echo "   Warehouse   : $WH_NAME"
echo "   Snowflake DB: $DEMO_DB"
echo "   Graph       : $GRAPH_NAME"
echo ""

if [ "$LOAD_DATA" = true ] && [ "$SKIP_UPLOAD" = false ]; then
    for csv in "$AIRPORTS_CSV" "$ROUTES_CSV"; do
        [ -f "$csv" ] || { echo "❌ Missing dataset file: $csv"; exit 1; }
    done
fi

# ---------------------------------------------------------------------------
# Step 1: compute pool + warehouse + service.
# start_app() is idempotent: it creates what is missing and resumes whatever
# demo_down.sh suspended.
# ---------------------------------------------------------------------------
echo "⚙️  Step 1/6: Starting compute pool, warehouse and service..."
COMPUTE_STARTED=true
run_sql "CALL ${APP_NAME}.app_public.start_app('${POOL_NAME}', '${WH_NAME}');"
echo ""

# ---------------------------------------------------------------------------
# Step 2: wait for READY. A cold start pulls the container image, so this can
# take a few minutes.
# ---------------------------------------------------------------------------
echo "⏳ Step 2/6: Waiting for the service to become READY (timeout ${READY_TIMEOUT_SECS}s)..."
elapsed=0
statuses=""
while [ "$elapsed" -lt "$READY_TIMEOUT_SECS" ]; do
    statuses="$(service_statuses)"

    case "$statuses" in
        *FAILED*)
            echo "❌ Service reported FAILED: $statuses"
            echo "   Logs: snow sql --role $APP_ROLE -q \"CALL ${APP_NAME}.app_public.get_service_logs('0', 'falkordb-server', 100);\""
            exit 1
            ;;
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
        echo "   Run ./scripts/demo_down.sh to stop billing."
        exit 1
        ;;
esac

# The service spec declares no readinessProbe, so Snowflake reports READY as soon
# as the container starts - before FalkorDB is listening on its port. Querying
# straight away returns "Connection refused" from the service function, so wait
# for a query to actually succeed rather than trusting the status.
echo "   Waiting for FalkorDB to accept queries..."
probe_elapsed=0
probe_ok=false
while [ "$probe_elapsed" -lt "$QUERY_TIMEOUT_SECS" ]; do
    if run_sql_quiet "CALL ${APP_NAME}.app_public.graph_query('${GRAPH_NAME}', 'RETURN 1');"; then
        probe_ok=true
        break
    fi
    sleep 10
    probe_elapsed=$((probe_elapsed + 10))
    printf '   ...%ss waiting for the query endpoint\n' "$probe_elapsed"
done

if [ "$probe_ok" != true ]; then
    echo "❌ Service is READY but never accepted a query within ${QUERY_TIMEOUT_SECS}s."
    echo "   The container is up but FalkorDB is not listening. Check the logs:"
    echo "   snow sql --role ${APP_ROLE} -q \"CALL ${APP_NAME}.app_public.get_service_logs('0', 'falkordb-server', 100);\""
    echo "   A service resumed from a long suspend can wedge; ./scripts/demo_down.sh --drop then re-run this script."
    exit 1
fi
echo "✅ FalkorDB is accepting queries (after ${probe_elapsed}s)"
echo ""
echo ""

if [ "$LOAD_DATA" = false ]; then
    echo "⏭️  Steps 3-5 skipped (--no-data)"
else

# ---------------------------------------------------------------------------
# Step 3: Snowflake tables.
# Column order matters: the app exports a bound table to CSV *without a header*,
# so row[0], row[1], ... in the Cypher below are these columns in this order.
# Only the columns the demo uses are loaded, which also drops the comma-heavy
# free-text `keywords` column so quoting cannot shift the row[n] indexes.
# ---------------------------------------------------------------------------
if [ "$SKIP_UPLOAD" = false ]; then
    echo "📤 Step 3/6: Uploading the Air Routes CSVs into ${DEMO_DB}..."

    cat > "$SQL_TMP" <<EOF
CREATE DATABASE IF NOT EXISTS ${DEMO_DB};
CREATE SCHEMA IF NOT EXISTS ${DEMO_DB}.PUBLIC;
CREATE STAGE IF NOT EXISTS ${DEMO_DB}.PUBLIC.AIRROUTES_STAGE;

-- All columns are VARCHAR on purpose: the Cypher casts with toInteger()/toFloat(),
-- and text columns keep placeholder values such as 'UNKNOWN' from failing the load.
CREATE OR REPLACE TABLE ${DEMO_DB}.PUBLIC.AIRPORTS (
    id VARCHAR, ident VARCHAR, type VARCHAR, name VARCHAR,
    latitude_deg VARCHAR, longitude_deg VARCHAR, elevation_ft VARCHAR,
    continent VARCHAR, iso_country VARCHAR, iso_region VARCHAR,
    municipality VARCHAR, scheduled_service VARCHAR,
    icao_code VARCHAR, iata_code VARCHAR
);

CREATE OR REPLACE TABLE ${DEMO_DB}.PUBLIC.ROUTES (
    airline VARCHAR, airline_id VARCHAR,
    source_airport VARCHAR, source_airport_id VARCHAR,
    destination_airport VARCHAR, destination_airport_id VARCHAR,
    codeshare VARCHAR, stops VARCHAR, equipment VARCHAR
);
EOF
    run_sql_file

    run_sql "PUT 'file://${AIRPORTS_CSV}' @${DEMO_DB}.PUBLIC.AIRROUTES_STAGE AUTO_COMPRESS=TRUE OVERWRITE=TRUE;
PUT 'file://${ROUTES_CSV}' @${DEMO_DB}.PUBLIC.AIRROUTES_STAGE AUTO_COMPRESS=TRUE OVERWRITE=TRUE;"

    cat > "$SQL_TMP" <<EOF
COPY INTO ${DEMO_DB}.PUBLIC.AIRPORTS
FROM (
    SELECT \$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10, \$11, \$12, \$13, \$14
    FROM @${DEMO_DB}.PUBLIC.AIRROUTES_STAGE/airports.csv.gz
)
FILE_FORMAT = (TYPE = CSV SKIP_HEADER = 1 FIELD_OPTIONALLY_ENCLOSED_BY = '"')
ON_ERROR = ABORT_STATEMENT;

COPY INTO ${DEMO_DB}.PUBLIC.ROUTES
FROM @${DEMO_DB}.PUBLIC.AIRROUTES_STAGE/routes.csv.gz
FILE_FORMAT = (TYPE = CSV SKIP_HEADER = 1 FIELD_OPTIONALLY_ENCLOSED_BY = '"')
ON_ERROR = ABORT_STATEMENT;

SELECT 'AIRPORTS' AS table_name, COUNT(*) AS row_count FROM ${DEMO_DB}.PUBLIC.AIRPORTS
UNION ALL
SELECT 'ROUTES', COUNT(*) FROM ${DEMO_DB}.PUBLIC.ROUTES;
EOF
    run_sql_file
    echo "✅ Snowflake tables loaded"
else
    echo "⏭️  Step 3/6: Reusing existing ${DEMO_DB} tables (--skip-upload)"
fi
echo ""

# ---------------------------------------------------------------------------
# Step 4: clean graph + indexes, BEFORE any data is loaded.
# Without the iata_code index the routes load does a full scan of ~48k airports
# for every one of the ~67k route rows.
# ---------------------------------------------------------------------------
echo "🔑 Step 4/6: Creating a clean graph and its indexes (before loading)..."
run_sql_quiet "CALL ${APP_NAME}.app_public.graph_delete('${GRAPH_NAME}');" || true

cat > "$SQL_TMP" <<EOF
CALL ${APP_NAME}.app_public.graph_query('${GRAPH_NAME}',
    'CREATE INDEX FOR (a:Airport) ON (a.id)');
CALL ${APP_NAME}.app_public.graph_query('${GRAPH_NAME}',
    'CREATE INDEX FOR (a:Airport) ON (a.iata_code)');
EOF
run_sql_file
echo "✅ Indexes created"
echo ""

# ---------------------------------------------------------------------------
# Step 5: bind each table and load it.
# register_callback + SYSTEM\$REFERENCE is the scriptable equivalent of picking
# the table in the app's Permissions tab. The reference is single-valued, so
# binding ROUTES simply replaces the AIRPORTS binding.
# ---------------------------------------------------------------------------
echo "🛫 Step 5/6: Binding AIRPORTS and loading airport nodes..."
cat > "$SQL_TMP" <<EOF
CALL ${APP_NAME}.app_public.register_callback(
    'consumer_data_table',
    'ADD',
    SYSTEM\$REFERENCE('TABLE', '${DEMO_DB}.PUBLIC.AIRPORTS', 'PERSISTENT', 'SELECT')
);

CALL ${APP_NAME}.app_public.load_csv('${GRAPH_NAME}',
    'LOAD CSV FROM ''file://consumer_data.csv'' AS row
     MERGE (a:Airport {id: toInteger(row[0])})
     SET a.ident = row[1], a.type = row[2], a.name = row[3],
         a.latitude = toFloat(row[4]), a.longitude = toFloat(row[5]),
         a.elevation_ft = toInteger(row[6]), a.continent = row[7],
         a.iso_country = row[8], a.iso_region = row[9],
         a.municipality = row[10], a.scheduled_service = row[11],
         a.icao_code = row[12], a.iata_code = row[13]');
EOF
run_sql_file

echo "🛬 Binding ROUTES and creating route relationships..."
cat > "$SQL_TMP" <<EOF
CALL ${APP_NAME}.app_public.register_callback(
    'consumer_data_table',
    'ADD',
    SYSTEM\$REFERENCE('TABLE', '${DEMO_DB}.PUBLIC.ROUTES', 'PERSISTENT', 'SELECT')
);

CALL ${APP_NAME}.app_public.load_csv('${GRAPH_NAME}',
    'LOAD CSV FROM ''file://consumer_data.csv'' AS row
     MATCH (src:Airport {iata_code: row[2]})
     MATCH (dst:Airport {iata_code: row[4]})
     CREATE (src)-[r:ROUTE]->(dst)
     SET r.airline = row[0], r.airline_id = row[1],
         r.source_airport = row[2], r.destination_airport = row[4],
         r.stops = toInteger(row[7]), r.equipment = row[8]');
EOF
run_sql_file

echo "📐 Computing route distances (distance_km) so shortest_path has a weight..."
cat > "$SQL_TMP" <<EOF
CALL ${APP_NAME}.app_public.graph_query('${GRAPH_NAME}',
    'MATCH (src:Airport)-[r:ROUTE]->(dst:Airport)
     SET r.distance_km = round(distance(
           point({latitude: src.latitude, longitude: src.longitude}),
           point({latitude: dst.latitude, longitude: dst.longitude})) / 1000)');

CALL ${APP_NAME}.app_public.graph_query('${GRAPH_NAME}',
    'MATCH (a:Airport) RETURN count(a) AS airports');
CALL ${APP_NAME}.app_public.graph_query('${GRAPH_NAME}',
    'MATCH ()-[r:ROUTE]->() RETURN count(r) AS routes');
EOF
run_sql_file
echo "✅ Graph '${GRAPH_NAME}' loaded"
echo ""

fi

# ---------------------------------------------------------------------------
# Step 6: the endpoint.
# ---------------------------------------------------------------------------
echo "🌐 Step 6/6: Resolving the FalkorDB Browser URL..."
url="$(run_sql_json "SHOW ENDPOINTS IN SERVICE ${APP_NAME}.app_public.st_spcs;
SELECT \"ingress_url\" AS browser_url
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE \"name\" = 'falkordb-browser';" | json_key "browser_url")"

echo ""
echo "🎉 Demo is up!"
if [ -n "$url" ]; then
    echo "   FalkorDB Browser: https://${url#https://}"
else
    echo "   ⚠️  Endpoint not published yet — re-run in a minute."
fi

if [ "$LOAD_DATA" = true ]; then
    echo ""
    echo "   Shortest route Sydney → JFK:"
    echo "   snow sql --role ${APP_ROLE} -q \"CALL ${APP_NAME}.app_public.shortest_path('${GRAPH_NAME}', 'Airport', 'iata_code', 'SYD', 'JFK', 'ROUTE', 'distance_km');\""
    echo ""
    echo "   Biggest hubs:"
    echo "   snow sql --role ${APP_ROLE} -q \"CALL ${APP_NAME}.app_public.page_rank('${GRAPH_NAME}', 'Airport', 'ROUTE', 'iata_code', 10);\""
fi

echo ""
echo "💡 When you are done:  ./scripts/demo_down.sh"
echo "   The compute pool bills per node-hour until you run it."
echo ""
