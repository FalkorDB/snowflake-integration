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
- FalkorDB container resource options control the request/limit inside the compute pool.
- The app creates an `XSMALL` warehouse and `CPU_X64_S` compute pool by default if they do not already exist.
- The default FalkorDB container resources request 1 CPU / 2GB RAM and limit at 2 CPU / 4GB RAM.
- `graph_query` can write Cypher query results into durable Snowflake tables when called with `write.outputTable` options.
- The Snowflake Agent can use `text_to_cypher` for difficult natural-language graph questions before calling `run_cypher`.
- The Agent should show generated and executed Cypher in user-facing answers.

## Standard setup flow

```sql
CALL <app_instance_name>.app_public.start_app(
  'FALKORDB_POOL',
  'FALKORDB_WH'
);

CALL <app_instance_name>.app_public.get_service_status();
CALL <app_instance_name>.app_public.graph_list();
```

To open the FalkorDB Browser, which lets users visually explore graphs, inspect nodes and relationships, and run Cypher queries interactively:

```sql
SHOW ENDPOINTS IN SERVICE <app_instance_name>.app_public.st_spcs;

SELECT "ingress_url" AS browser_url
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" = 'falkordb-browser';
```

Open the returned `browser_url` in a web browser after the service is `READY`.

For custom FalkorDB container allocation:

```sql
CALL <app_instance_name>.app_public.stop_app();
CALL <app_instance_name>.app_public.start_app(
  'FALKORDB_POOL',
  'FALKORDB_WH',
  OBJECT_CONSTRUCT(
    'cpuRequest', 2,
    'memoryRequest', '4G',
    'cpuLimit', 4,
    'memoryLimit', '8G'
  )
);
```

Explain resource options as:
- `cpuRequest` / `memoryRequest`: reserved resources Snowflake uses for scheduling the container on the compute pool node.
- `cpuLimit` / `memoryLimit`: maximum resources the FalkorDB container can use.
- Requests must fit the selected compute pool; if they are too large, Snowflake can fail scheduling or report insufficient resources.

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
CALL <app_instance_name>.app_public.graph_query(
  'my_graph',
  'MATCH (n) RETURN n.name AS name LIMIT 100',
  OBJECT_CONSTRUCT(
    'write', OBJECT_CONSTRUCT(
      'outputTable', 'RESULT_DB.RESULT_SCHEMA.GRAPH_QUERY_RESULTS'
    )
  )
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
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE <consumer_role>;
```

Then use Snowflake UI: AI & ML -> Agents or Snowflake Intelligence.

The deployed agent can load data only from the already-bound `consumer_data_table` reference. It should ask for a graph name if missing, generate `LOAD CSV FROM 'file://consumer_data.csv' AS row ...` mapping Cypher from the table columns, prefer `MERGE`, and ask for confirmation before running the load tool.

For difficult graph questions, the deployed agent should call `text_to_cypher(input_agent_name, graph_name, user_question)` before `run_cypher`. The tool uses a default Snowflake Cortex model and FalkorDB graph schema context to generate Cypher, and returns the generated `cypher` plus the `schema_context` used. The schema context is labels, relationship types, property keys, and graph stats from the selected FalkorDB graph, not the Snowflake source schema. The role using the agent should have both `SNOWFLAKE.CORTEX_AGENT_USER` and `SNOWFLAKE.CORTEX_USER`.

When answering query requests, show the Cypher query. `text_to_cypher` returns the generated `cypher`, and `run_cypher` returns both the executed `cypher_query` and `result`.
