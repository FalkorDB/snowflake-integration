#!/bin/bash

# Load the Air Routes dataset (examples/airroutes) into Snowflake and build the
# `airroutes` graph in FalkorDB - the full webinar demo, from the command line.
#
# Everything the README does by hand is scripted here, including the table
# binding, which is done with register_callback + SYSTEM$REFERENCE rather than
# the app's Permissions UI.
#
# Usage: ./scripts/demo_load_airroutes.sh [--skip-upload] [--keep-graph]
#   --skip-upload   Reuse the Snowflake tables from a previous run and only
#                   rebuild the graph (saves re-uploading ~11 MB of CSV).
#   --keep-graph    Do not drop the graph first. Only safe with --skip-upload
#                   on an empty graph, since routes are created, not merged.
#
# Requires the service to be READY (./scripts/demo_start.sh).

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/demo_common.sh
source "$SCRIPT_DIR/demo_common.sh"

DEMO_DB="${FALKORDB_DEMO_DB:-ROUTES_DEMO}"
GRAPH_NAME="${FALKORDB_AIRROUTES_GRAPH:-airroutes}"
AIRPORTS_CSV="$REPO_ROOT/examples/airroutes/airports.csv"
ROUTES_CSV="$REPO_ROOT/examples/airroutes/routes.csv"

SKIP_UPLOAD=false
KEEP_GRAPH=false

for arg in "$@"; do
    case "$arg" in
        --skip-upload) SKIP_UPLOAD=true ;;
        --keep-graph) KEEP_GRAPH=true ;;
        -h|--help) sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "❌ Unknown option: $arg"; exit 1 ;;
    esac
done

for csv in "$AIRPORTS_CSV" "$ROUTES_CSV"; do
    if [ ! -f "$csv" ]; then
        echo "❌ Missing dataset file: $csv"
        exit 1
    fi
done

SQL_TMP="$(mktemp -t falkordb_airroutes)"
trap 'rm -f "$SQL_TMP"' EXIT

run_sql_file() {
    snow sql "${SNOW_ARGS[@]}" -f "$SQL_TMP"
}

echo "✈️  Air Routes Demo Loader"
echo "=========================="
print_config
echo "   Snowflake DB    : $DEMO_DB"
echo "   Graph           : $GRAPH_NAME"
echo ""

# The graph steps go through the running service, so fail early with a useful
# message rather than midway through an 11 MB upload.
case "$(service_statuses)" in
    *READY*) ;;
    *)
        echo "❌ The FalkorDB service is not READY. Start it first:"
        echo "   ./scripts/demo_start.sh --dataset none"
        exit 1
        ;;
esac

# Step 1: Snowflake tables.
# Column order matters: the app exports the bound table to CSV without a header,
# so row[0], row[1], ... in the Cypher below are these columns in this order.
# Only the columns the demo uses are loaded, which also drops the free-text
# `keywords` column and the link columns from the export.
if [ "$SKIP_UPLOAD" = false ]; then
    echo "📤 Step 1: Uploading CSVs into ${DEMO_DB}..."

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

    snow sql "${SNOW_ARGS[@]}" -q "PUT 'file://${AIRPORTS_CSV}' @${DEMO_DB}.PUBLIC.AIRROUTES_STAGE AUTO_COMPRESS=TRUE OVERWRITE=TRUE;
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
    echo "✅ Tables loaded"
else
    echo "⏭️  Step 1: Skipping upload (--skip-upload)"
fi
echo ""

# Step 2: Start from a clean graph and create the indexes BEFORE loading.
# Without them the routes load does a full scan of ~48k airports per row.
echo "🧹 Step 2: Resetting the graph and creating indexes..."
if [ "$KEEP_GRAPH" = false ]; then
    run_sql_quiet "CALL ${APP_NAME}.app_public.graph_delete('${GRAPH_NAME}');" || true
fi

cat > "$SQL_TMP" <<EOF
CALL ${APP_NAME}.app_public.graph_query('${GRAPH_NAME}',
    'CREATE INDEX FOR (a:Airport) ON (a.id)');
CALL ${APP_NAME}.app_public.graph_query('${GRAPH_NAME}',
    'CREATE INDEX FOR (a:Airport) ON (a.iata_code)');
EOF
run_sql_file
echo "✅ Indexes created"
echo ""

# Step 3: Bind AIRPORTS and load the nodes.
# register_callback + SYSTEM\$REFERENCE is the scriptable equivalent of picking the
# table in the app's Permissions tab. The reference is single-valued, so binding a
# new table replaces the previous one.
echo "🛫 Step 3: Binding AIRPORTS and loading airport nodes..."
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
echo "✅ Airports loaded"
echo ""

# Step 4: Rebind to ROUTES and create the relationships.
echo "🛬 Step 4: Binding ROUTES and creating route relationships..."
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
echo "✅ Routes created"
echo ""

# Step 5: Edge weights, so shortest_path() has something to minimize.
echo "📐 Step 5: Computing route distances (distance_km)..."
cat > "$SQL_TMP" <<EOF
CALL ${APP_NAME}.app_public.graph_query('${GRAPH_NAME}',
    'MATCH (src:Airport)-[r:ROUTE]->(dst:Airport)
     SET r.distance_km = round(distance(
           point({latitude: src.latitude, longitude: src.longitude}),
           point({latitude: dst.latitude, longitude: dst.longitude})) / 1000)');
EOF
run_sql_file
echo "✅ Distances computed"
echo ""

# Step 6: Sanity check.
echo "🔍 Step 6: Verifying the graph..."
cat > "$SQL_TMP" <<EOF
CALL ${APP_NAME}.app_public.graph_query('${GRAPH_NAME}',
    'MATCH (a:Airport) RETURN count(a) AS airports');
CALL ${APP_NAME}.app_public.graph_query('${GRAPH_NAME}',
    'MATCH ()-[r:ROUTE]->() RETURN count(r) AS routes');
EOF
run_sql_file
echo ""

echo "🎉 Air routes graph '${GRAPH_NAME}' is ready."
echo ""
echo "   Try the shortest route from Sydney to JFK:"
echo "   snow sql --role ${APP_ROLE} -q \"CALL ${APP_NAME}.app_public.shortest_path('${GRAPH_NAME}', 'Airport', 'iata_code', 'SYD', 'JFK', 'ROUTE', 'distance_km');\""
echo ""
echo "   Or rank the biggest hubs:"
echo "   snow sql --role ${APP_ROLE} -q \"CALL ${APP_NAME}.app_public.page_rank('${GRAPH_NAME}', 'Airport', 'ROUTE', 'iata_code', 10);\""
echo ""
echo "💡 Graph data is wiped when the service stops, so re-run this after each demo_start.sh."
echo "   Use --skip-upload to rebuild the graph without re-uploading the CSVs."
echo ""
