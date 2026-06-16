# FalkorDB Snowflake SQL Reference

## Start app

```sql
CALL <app_instance_name>.app_public.start_app('FALKORDB_POOL', 'FALKORDB_WH');
```

## Open FalkorDB Browser

Use FalkorDB Browser to visually explore graphs, inspect nodes and relationships, and run Cypher queries interactively.

```sql
SHOW ENDPOINTS IN SERVICE <app_instance_name>.app_public.st_spcs;

SELECT "ingress_url" AS browser_url
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" = 'falkordb-browser';
```

## Start with custom container resources

```sql
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

Default container resources request 1 CPU / 2GB RAM and limit at 2 CPU / 4GB RAM.

Option meanings:

| Option | Meaning |
|---|---|
| `cpuRequest` | CPU reserved for scheduling |
| `memoryRequest` | Memory reserved for scheduling |
| `cpuLimit` | Maximum CPU the container can use |
| `memoryLimit` | Maximum memory the container can use |

Requests must fit the selected compute pool node; otherwise Snowflake can fail scheduling or report insufficient resources.

## Warehouse resize

```sql
ALTER WAREHOUSE FALKORDB_WH SET WAREHOUSE_SIZE = 'SMALL';
ALTER WAREHOUSE FALKORDB_WH SET WAREHOUSE_SIZE = 'MEDIUM';
```

## Create Cortex Agent

```sql
USE WAREHOUSE FALKORDB_WH;

CALL <app_instance_name>.graph.create_agent(
  'FALKORDB_GRAPH_AGENT',
  'SOURCE_DB.SOURCE_SCHEMA',
  'WORKING_DB.WORKING_SCHEMA'
);
```

## Agent grants

```sql
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_AGENT_USER TO ROLE <consumer_role>;

CALL <app_instance_name>.graph.get_agent_caller_grants(
  'FALKORDB_GRAPH_AGENT'
);
```

## Query graph

```sql
CALL <app_instance_name>.app_public.graph_query(
  'my_graph',
  'MATCH (n) RETURN count(n) AS node_count'
);
```

## Write query results to Snowflake

```sql
GRANT CREATE TABLE ON SCHEMA RESULT_DB.RESULT_SCHEMA TO APPLICATION <app_instance_name>;

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

## Load CSV

```sql
CALL <app_instance_name>.app_public.load_csv(
  'my_graph',
  'LOAD CSV FROM ''file://consumer_data.csv'' AS row
   MERGE (n:Node {id: row[0]})
   SET n.name = row[1]'
);
```
