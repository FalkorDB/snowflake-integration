---
name: falkordb-snowflake-native-app-skill
description: Help users install, configure, load data into, query, size, troubleshoot, and use the FalkorDB Snowflake Native App with Cypher, Snowpark Container Services, and Cortex Agents.
allowed-tools:
  - sql
  - text
---

# FalkorDB Snowflake Native App Skill

Use this skill when the user asks about FalkorDB inside Snowflake, Snowflake Native Apps, graph loading, Cypher, SPCS compute pools, warehouse sizing, FalkorDB resource profiles, or FalkorDB Cortex Agent setup.

## Core concepts

- The Snowflake warehouse runs SQL, procedures, staging, and Cortex Agent tool execution.
- The Snowpark Container Services compute pool runs the FalkorDB container.
- The FalkorDB profile controls the container request/limit inside the compute pool.
- The app creates an `XSMALL` warehouse and `CPU_X64_S` compute pool by default if they do not already exist.
- The default FalkorDB profile is `SMALL`.
- `graph_query_to_table` writes Cypher query results into durable Snowflake tables as `ROW_INDEX` and `ROW_DATA`.

## Standard setup flow

```sql
CALL <app_instance_name>.app_public.start_app(
  'FALKORDB_POOL',
  'FALKORDB_WH'
);

CALL <app_instance_name>.app_public.get_service_status();
CALL <app_instance_name>.app_public.graph_list();
```

For larger FalkorDB container allocation:

```sql
CALL <app_instance_name>.app_public.stop_app();
CALL <app_instance_name>.app_public.start_app_with_profile(
  'FALKORDB_POOL',
  'FALKORDB_WH',
  'LARGE'
);
```

## Loading data

The app loads data from the bound `consumer_data_table` reference.

```sql
CALL <app_instance_name>.app_public.load_csv(
  'my_graph',
  'LOAD CSV FROM ''file://consumer_data.csv'' AS row
   MERGE (n:Node {id: row[0]})
   SET n.name = row[1]'
);
```

Prefer `MERGE` for retry-safe loads. For large loads, create an index before loading:

```sql
CALL <app_instance_name>.app_public.graph_query(
  'my_graph',
  'CREATE INDEX ON :Node(id)'
);
```

## Querying

```sql
CALL <app_instance_name>.app_public.graph_query(
  'my_graph',
  'MATCH (n) RETURN count(n) AS node_count'
);
```

To persist query results in Snowflake:

```sql
CALL <app_instance_name>.app_public.graph_query_to_table(
  'my_graph',
  'MATCH (n) RETURN n.name AS name LIMIT 100',
  'RESULT_DB.RESULT_SCHEMA.GRAPH_QUERY_RESULTS'
);
```

## Cortex Agent

Create the agent only after the FalkorDB service is running and graphs are loaded.

```sql
USE WAREHOUSE FALKORDB_WH;

CALL <app_instance_name>.graph.create_agent(
  'FALKORDB_GRAPH_AGENT',
  'SOURCE_DB.SOURCE_SCHEMA',
  'WORKING_DB.WORKING_SCHEMA'
);
```

The consumer role must have:

```sql
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_AGENT_USER TO ROLE <consumer_role>;
```

Then use Snowflake UI: AI & ML -> Agents or Snowflake Intelligence.
