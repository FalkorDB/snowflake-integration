# FalkorDB Snowflake Native App Demo

This demo simulates a user (consumer) of Snowflake that has tables with data, and a FalkorDB app published into the Snowflake marketplace with staging folder that can accept data from the consumer.

## How to Start the Demo

Follow these 3 steps in order to set up the complete demo:

### Step 1: Setup Consumer

Set up the consumer database, schema, tables, and load initial CSV data:

```bash
./scripts/setup_consumer.sh
```

### Step 2: Setup App  

Set up application infrastructure, build/push Docker image, and publish the app package:

```bash
./scripts/setup_app.sh
```

### Step 3: Instantiate App

Create an app instance and configure staging connections:

```bash
./scripts/instansiate_app.sh
```

## How to Run the Demo (day to day)

After the one-time setup above, use the demo lifecycle scripts. They exist because
the compute pool bills per node-hour for as long as it is active, and **nothing
suspends it automatically** — the FalkorDB service is a long-running container, so
the pool is never idle and `AUTO_SUSPEND_SECS` never fires.

```bash
./scripts/demo_start.sh    # resume/create compute, start the service, load demo data, print the browser URL
./scripts/demo_status.sh   # show what is running and whether anything is billing
./scripts/demo_stop.sh     # suspend the service and the compute pool so nothing bills
```

`demo_start.sh` reloads the sample graph on every run because graph data is not
persisted (the service mounts a stage for CSV staging only). Pass `--no-data` to
skip it.

Defaults can be overridden with environment variables:
`FALKORDB_APP_NAME`, `FALKORDB_ROLE`, `FALKORDB_POOL`, `FALKORDB_WAREHOUSE`,
`FALKORDB_SNOW_CONNECTION`.

Use `demo_stop.sh` between demos and the teardown scripts below only when you want
to remove the environment entirely.

## How to Use the Demo

Once the demo is running, you can call the FalkorDB app procedure:

```bash
# Call the load_csv procedure as specified in architecture
# load_csv(graph, table, cypher_query) that:
# 1. loads data from table to staging area with the name table.csv
# 2. calls the service function load_csv(graph, table.csv, cypher_query) 
# 3. keeps the result, deletes table.csv from staging and returns the result

# Example usage:
snow sql -q "
USE APPLICATION falkordb_app_instance;
CALL app_public.load_csv('social_graph', 'social_nodes', 'CREATE (:Person {name: \$name, label: \$node_label})');
"
```

You can also call other procedures:

```bash
curl -X 'GET' \
  'http://localhost:8080/list_graphs' \
  -H 'accept: application/json'
```

## How to Stop the Demo

### Quick Teardown (All Steps)

Run the complete teardown in one command:

```bash
./scripts/teardown.sh
```

### Manual Teardown (Step by Step)

Or follow these 3 steps in reverse order to clean up the demo:

### Step 1: Uninstantiate App

Remove the app instance and clean up instantiation:

```bash
./scripts/uninstansiate_app.sh
```

### Step 2: Teardown App

Remove the application package and infrastructure:

```bash
./scripts/teardown_app.sh  
```

### Step 3: Teardown Consumer

Remove the consumer database and related resources:

```bash
./scripts/teardown_consumer.sh
```

## View Container Logs

To view container logs while the demo is running:

```bash
./scripts/logs.sh
```

## Architecture

This demo follows the architecture specified in `architecture.md` with exactly 3 setup scripts and 3 teardown scripts, implementing the staging workflow where the consumer calls `load_csv(graph, table, cypher_query)` to process data through the FalkorDB app.
