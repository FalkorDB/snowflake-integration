# FalkorDB Snowflake SQL Reference

## Start app

```sql
CALL <app_instance_name>.app_public.start_app('FALKORDB_POOL', 'FALKORDB_WH');
```

## Start with profile

```sql
CALL <app_instance_name>.app_public.start_app_with_profile(
  'FALKORDB_POOL',
  'FALKORDB_WH',
  'LARGE'
);
```

Profiles:

| Profile | Request | Limit |
|---|---|---|
| `SMALL` | 0.5 CPU / 512MB RAM | 1 CPU / 1GB RAM |
| `MEDIUM` | 1 CPU / 2GB RAM | 2 CPU / 4GB RAM |
| `LARGE` | 2 CPU / 4GB RAM | 4 CPU / 6GB RAM |

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

## Load CSV

```sql
CALL <app_instance_name>.app_public.load_csv(
  'my_graph',
  'LOAD CSV FROM ''file://consumer_data.csv'' AS row
   MERGE (n:Node {id: row[0]})
   SET n.name = row[1]'
);
```
