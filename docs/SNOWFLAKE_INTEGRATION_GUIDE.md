# FalkorDB Snowflake Integration Guide

## Overview

FalkorDB is available as a Snowflake Native App, allowing you to run graph database operations directly within your Snowflake environment. This integration enables you to:

- Load data from Snowflake tables into graph structures
- Query relationships using Cypher query language
- Analyze connected data without moving it outside Snowflake
- Leverage graph algorithms on your existing data warehouse

## Installation

### From Snowflake Marketplace

1. Navigate to **Snowflake Marketplace**
2. Search for **"FalkorDB"**
3. Click **Get** to install the app
4. Select your target database and warehouse
5. Click **Get** to complete installation

### Initial Setup

After installation, start the FalkorDB service:

```sql
-- Start the service (creates compute pool and warehouse)
-- Replace <app_instance_name> with your installed app name
CALL <app_instance_name>.app_public.start_app('FALKORDB_POOL', 'FALKORDB_WH');

-- Check service status
CALL <app_instance_name>.app_public.get_service_status();
```

**Note**: Replace `<app_instance_name>` with the name you chose during installation.

Wait for the service status to show `READY` before proceeding (typically 2-3 minutes).

Default resources use a `CPU_X64_S` compute pool with FalkorDB container resources of 1 CPU / 2GB RAM requested and 2 CPU / 4GB RAM limit. For larger graph loads, start the app with explicit resource options:

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

Resource option meanings:

| Option | Meaning | Example |
|---|---|---|
| `cpuRequest` | CPU reserved for scheduling the FalkorDB container | `1`, `1.5`, `500m` |
| `memoryRequest` | Memory reserved for scheduling the FalkorDB container | `2G`, `4Gi` |
| `cpuLimit` | Maximum CPU the FalkorDB container can use | `2`, `4` |
| `memoryLimit` | Maximum memory the FalkorDB container can use before it is constrained by SPCS | `4G`, `8Gi` |

Requests must fit on the selected compute pool node. If the requested CPU/memory is larger than the pool can schedule, Snowflake will fail to schedule the service or report insufficient resources. Limits should be greater than or equal to requests and cannot effectively exceed the node capacity of the selected compute pool.

### Open the FalkorDB Browser

FalkorDB Browser is a web UI for exploring your graphs visually, inspecting nodes and relationships, and running Cypher queries interactively against the FalkorDB service.

After `get_service_status()` shows the service is ready, get the public browser URL:

```sql
SHOW ENDPOINTS IN SERVICE <app_instance_name>.app_public.st_spcs;

SELECT "ingress_url" AS browser_url
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" = 'falkordb-browser';
```

Open the returned `browser_url` in your web browser to use the FalkorDB Browser UI. If the endpoint is not ready yet, wait for the service status to become `READY` and run the endpoint query again.

To change container resources after the service is already running, call `stop_app()` first, then start with the desired options.

## Basic Usage

### Creating a Graph from Direct Queries

The simplest way to create a graph is using direct Cypher queries:

```sql
-- Create nodes
CALL <app_instance_name>.app_public.graph_query('my_graph',
  'CREATE (:Person {name: ''Alice'', age: 30}),
          (:Person {name: ''Bob'', age: 25})'
);

-- Create relationships
CALL <app_instance_name>.app_public.graph_query('my_graph',
  'MATCH (a:Person {name: ''Alice''}), (b:Person {name: ''Bob''})
   CREATE (a)-[:KNOWS {since: 2020}]->(b)'
);

-- Query the graph
CALL <app_instance_name>.app_public.graph_query('my_graph',
  'MATCH (p:Person) RETURN p.name, p.age'
);
```

### Loading Data from Snowflake Tables

To load data from your existing Snowflake tables, you need to bind a table reference:

#### Step 1: Bind Your Table

1. In Snowflake UI, go to **Data Products** → **Apps**
2. Find and click on **FalkorDB**
3. Go to **Security** → **References**
4. Click **+ Add** next to "Consumer Data Table"
5. Select your database, schema, and table
6. Click **Save**

**Important**: Your table must have a header row or column names. CSV headers will be converted to UPPERCASE by Snowflake.

#### Step 2: Load Data Using CSV

```sql
-- Example: Load customer data (using MERGE to prevent duplicates on reload)
-- Assumes your bound table has columns: ID, NAME, EMAIL, CITY
CALL <app_instance_name>.app_public.load_csv(
  'customer_graph',
  'LOAD CSV FROM ''file://consumer_data.csv'' AS row
   MERGE (c:Customer {id: row[0]})
   ON CREATE SET c.name = row[1], c.email = row[2], c.city = row[3]
   ON MATCH SET c.name = row[1], c.email = row[2], c.city = row[3]'
);
```

**Note**:
- The table is automatically retrieved from your Config UI binding—no need to specify it as a parameter
- The Cypher query must include `LOAD CSV FROM 'file://consumer_data.csv' AS row` to access the CSV data
- Access columns using `row[0]`, `row[1]`, `row[2]`, etc. (0-indexed)
- The file name in the `file://...` clause is a placeholder; the app passes the actual staged CSV filename to the FalkorDB service for each load.
- Use MERGE instead of CREATE to safely reload data without duplicates
- Large bound tables can be exported as multiple CSV parts. The app loads each part sequentially, sorted lexicographically by staged file name.
- For large `MERGE` loads, create an index on the matched label/property before loading, for example: `CALL <app_instance_name>.app_public.graph_query('my_graph', 'CREATE INDEX ON :Customer(id)');`
- If the bound table has no rows, `load_csv` returns an empty array and does not call the FalkorDB load endpoint.

### Multi-part CSV staging behavior

`load_csv` exports the bound table into a unique folder under `@app_public.staging`. Snowflake may write one CSV file or split a large export into multiple part files. The app lists that folder, validates each generated filename, sorts the names lexicographically for deterministic retries, and copies each part to the stage root before calling the FalkorDB service.

The stage-root copy is intentional. The container mounts `@app_public.staging` at `/var/lib/FalkorDB/import`, and the existing `load_csv_raw` service contract expects `csv_file` to be a flat filename in that import directory. The generated folder path is kept internal to the Snowflake wrapper so existing Cypher examples with `LOAD CSV FROM 'file://consumer_data.csv'` continue to work as a placeholder while the service receives the actual staged filename for each part.

After loading, the app removes both the temporary export folder and the root-level copies used by the service. If cleanup fails, `load_csv` returns an error that includes the cleanup failure instead of silently leaving files behind. If the bound table has no rows, there are no part files to load; the procedure removes the temporary folder and returns `[]`.

Multi-part loads are sequential and are not rolled back as a single unit. If one part succeeds and a later part fails, graph changes from the successful part remain. Prefer idempotent `MERGE` queries for retry-safe imports, and avoid relying on source row order across generated part files. When using `MERGE` on large multi-part loads, create an index on the matched key first, such as `CREATE INDEX ON :Airport(id)`, to avoid scanning existing nodes for each row in later parts.

### Querying Graphs

Use `graph_query()` to run Cypher queries:

```sql
-- Find all customers
CALL <app_instance_name>.app_public.graph_query('customer_graph',
  'MATCH (c:Customer) RETURN c.name, c.email LIMIT 10'
);

-- Find relationships
CALL <app_instance_name>.app_public.graph_query('social_graph',
  'MATCH (a:Person)-[r:KNOWS]->(b:Person) 
   RETURN a.name, r.since, b.name'
);

-- Pathfinding
CALL <app_instance_name>.app_public.graph_query('social_graph',
  'MATCH path = (a:Person {name: ''Alice''})-[:KNOWS*1..3]-(b:Person {name: ''Eve''})
   RETURN path'
);
```

### Writing Query Results Back to Snowflake

Pass a `write.outputTable` option to `graph_query()` when you want Cypher query results to persist as a Snowflake table:

```sql
CALL <app_instance_name>.app_public.graph_query(
  'social_graph',
  'MATCH (p:Person) RETURN p.name AS name, p.age AS age',
  OBJECT_CONSTRUCT(
    'write', OBJECT_CONSTRUCT(
      'outputTable', 'EXAMPLE_DB.RESULT_SCHEMA.PERSON_RESULTS'
    )
  )
);
```

The output table is created or replaced with:

```text
ROW_INDEX NUMBER
ROW_DATA  VARIANT
```

The application needs permission to create the output table:

```sql
GRANT CREATE TABLE ON SCHEMA EXAMPLE_DB.RESULT_SCHEMA TO APPLICATION <app_instance_name>;
```

### Managing Graphs

```sql
-- List all graphs
CALL <app_instance_name>.app_public.graph_list();

-- Delete a graph
CALL <app_instance_name>.app_public.graph_delete('my_graph');
```

## Complete Example: Social Network

### Step 1: Create Sample Data Table

```sql
-- Create a table with social network data
CREATE OR REPLACE TABLE social_data (
  person_id INT,
  name VARCHAR,
  age INT,
  city VARCHAR,
  knows_id INT,
  knows_since INT
);

-- Insert sample data
INSERT INTO social_data VALUES
  (1, 'Alice', 30, 'New York', 2, 2020),
  (2, 'Bob', 25, 'San Francisco', 3, 2019),
  (3, 'Carol', 35, 'Seattle', 5, 2018),
  (4, 'David', 28, 'Boston', 5, 2022),
  (5, 'Eve', 32, 'Chicago', NULL, NULL);
```

### Step 2: Bind the Table

Follow the UI steps above to bind `social_data` table to FalkorDB.

### Step 3: Load Nodes

```sql
-- Load person nodes using MERGE (prevents duplicates on reload)
CALL <app_instance_name>.app_public.load_csv(
  'social_network',
  'LOAD CSV FROM ''file://consumer_data.csv'' AS row 
   MERGE (p:Person {id: toInteger(row[0])})
   ON CREATE SET 
     p.name = row[1],
     p.age = toInteger(row[2]),
     p.city = row[3],
     p.created = timestamp()
   ON MATCH SET
     p.name = row[1],
     p.age = toInteger(row[2]),
     p.city = row[3],
     p.updated = timestamp()'
);
```

**Note**: 
- Columns are accessed by index: `row[0]` = person_id, `row[1]` = name, `row[2]` = age, `row[3]` = city
- MERGE on `id` ensures no duplicates when reloading data
- Use CREATE instead of MERGE if you want one-time bulk loading

### Step 4: Load Relationships

For relationships, you'll need to bind a table that represents edges:

```sql
-- Create relationships table
CREATE OR REPLACE TABLE social_relationships AS
SELECT person_id, knows_id, knows_since
FROM social_data
WHERE knows_id IS NOT NULL;
```

Bind `social_relationships` and load:

```sql
CALL <app_instance_name>.app_public.load_csv(
  'social_network',
  'LOAD CSV FROM ''file://consumer_data.csv'' AS row 
   MATCH (a:Person {id: toInteger(row[0])})
   MATCH (b:Person {id: toInteger(row[1])})
   MERGE (a)-[r:KNOWS]->(b)
   ON CREATE SET r.since = toInteger(row[2]), r.created = timestamp()
   ON MATCH SET r.since = toInteger(row[2]), r.updated = timestamp()'
);
```

**Note**: For relationships table: `row[0]` = person_id, `row[1]` = knows_id, `row[2]` = knows_since

### Step 5: Query the Graph

```sql
-- Find all friends of Alice
CALL <app_instance_name>.app_public.graph_query('social_network',
  'MATCH (a:Person {name: ''Alice''})-[:KNOWS]->(friend)
   RETURN friend.name, friend.city'
);

-- Find friend-of-friend connections
CALL <app_instance_name>.app_public.graph_query('social_network',
  'MATCH (a:Person {name: ''Alice''})-[:KNOWS*2]-(fof)
   WHERE fof.name <> ''Alice''
   RETURN DISTINCT fof.name, fof.city'
);

-- Find shortest path between two people
CALL <app_instance_name>.app_public.graph_query('social_network',
  'MATCH path = shortestPath(
     (a:Person {name: ''Alice''})-[:KNOWS*]-(b:Person {name: ''Eve''})
   )
   RETURN path'
);
```

## Quick Start with Sample Data

FalkorDB includes a sample data loader for testing:

```sql
-- 1. Make sure the service is running
CALL <app_instance_name>.app_public.get_service_status();

-- 2. Load built-in sample social network (5 people with relationships)
CALL <app_instance_name>.app_public.load_sample_social_network();

-- 3. Query the sample data
CALL <app_instance_name>.app_public.graph_query('demo_social_network',
  'MATCH (p:Person) RETURN p.name, p.age, p.city'
);

-- 4. Find relationships in the sample network
CALL <app_instance_name>.app_public.graph_query('demo_social_network',
  'MATCH (a:Person)-[r:KNOWS]->(b:Person) 
   RETURN a.name, b.name, r.since'
);
```

## Important Notes

### Data Updates and Duplicates

**Using MERGE for Upserts**: FalkorDB supports MERGE with ON CREATE and ON MATCH directives to prevent duplicate nodes when reloading data.

**Recommended Approach**: Use MERGE instead of CREATE for data that may be updated:

```sql
-- Using MERGE to prevent duplicates
CALL <app_instance_name>.app_public.load_csv(
  'my_graph',
  'LOAD CSV FROM ''file://consumer_data.csv'' AS row 
   MERGE (p:Person {id: row[0]})
   ON CREATE SET p.name = row[1], p.email = row[2], p.created = timestamp()
   ON MATCH SET p.name = row[1], p.email = row[2], p.updated = timestamp()'
);

-- Run this multiple times - updates existing nodes, no duplicates!
```

**CREATE vs MERGE**:
- **CREATE**: Always creates new nodes (use for one-time bulk loads)
- **MERGE**: Matches existing or creates new (use for incremental updates)

Large bound tables may load as multiple CSV parts. If one part succeeds and a later part fails, already-loaded graph changes are not rolled back, so prefer idempotent `MERGE` queries for any load that may be retried.

For large `MERGE` loads, create an index on the property used to match nodes before calling `load_csv`. Without an index, later CSV parts can slow down because FalkorDB must scan the nodes already loaded by earlier parts.

```sql
CALL <app_instance_name>.app_public.graph_query(
  'my_graph',
  'CREATE INDEX ON :Person(id)'
);
```

**Alternative**: If you need to fully replace data, delete and recreate:

```sql
CALL <app_instance_name>.app_public.graph_delete('my_graph');
CALL <app_instance_name>.app_public.load_csv('my_graph', '...');
```

### CSV Data Access

When using `load_csv`, access CSV columns by index using `row[0]`, `row[1]`, `row[2]`, etc.:

```cypher
-- Example: First column is ID, second is NAME, third is EMAIL
LOAD CSV FROM 'file://consumer_data.csv' AS row 
CREATE (:Person {id: row[0], name: row[1], email: row[2]})
```

The CSV data comes from your bound table (configured in the app's Permissions tab).

### Cost Management

FalkorDB runs on Snowflake Compute Pools, which charge based on usage:

- **ACTIVE** pools charge continuously (even when idle)
- **SUSPENDED** pools don't charge

**Always suspend when not in use:**

```sql
-- Outside the app, using ACCOUNTADMIN
USE ROLE ACCOUNTADMIN;
SHOW COMPUTE POOLS;
ALTER COMPUTE POOL falkordb_pool SUSPEND;

-- Resume when needed
ALTER COMPUTE POOL falkordb_pool RESUME;
```

### Service Management

```sql
-- Stop the service (doesn't delete compute pool)
CALL <app_instance_name>.app_public.stop_app();

-- Restart the service
CALL <app_instance_name>.app_public.start_app('FALKORDB_POOL', 'FALKORDB_WH');

-- Check logs (if issues occur)
CALL <app_instance_name>.app_public.get_service_logs('0', 'falkordb', 100);

-- List containers
CALL <app_instance_name>.app_public.get_service_containers();
```

### Cortex Agent Integration

FalkorDB can create a Snowflake Cortex Agent so users can work with graph data from **AI & ML → Agents** or Snowflake Intelligence instead of only the browser UI. The agent uses Snowflake custom tools backed by the Native App service to list graphs, inspect labels/relationships/properties, check graph stats, generate Cypher, load already-bound Snowflake table data, and run Cypher queries.

The schema context passed to `text_to_cypher` comes from the selected FalkorDB graph: labels, relationship types, property keys, and basic graph stats. It is not the Snowflake source schema passed to `graph.create_agent`.

Create the agent after the FalkorDB service has been started:

```sql
USE WAREHOUSE FALKORDB_WH;

CALL <app_instance_name>.graph.create_agent(
  'FALKORDB_GRAPH_AGENT',
  'SOURCE_DB.SOURCE_SCHEMA',
  'WORKING_DB.WORKING_SCHEMA'
);
```

Grant the Snowflake Cortex Agent role to the consumer role that will use the agent:

```sql
USE ROLE ACCOUNTADMIN;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_AGENT_USER TO ROLE <consumer_role>;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE <consumer_role>;
```

Minimal role and schema setup:

```sql
USE ROLE ACCOUNTADMIN;

CREATE ROLE IF NOT EXISTS FALKORDB_AGENT_ROLE;
GRANT APPLICATION ROLE <app_instance_name>.app_admin TO ROLE FALKORDB_AGENT_ROLE;
GRANT APPLICATION ROLE <app_instance_name>.app_user TO ROLE FALKORDB_AGENT_ROLE;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_AGENT_USER TO ROLE FALKORDB_AGENT_ROLE;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE FALKORDB_AGENT_ROLE;

GRANT USAGE ON DATABASE SOURCE_DB TO ROLE FALKORDB_AGENT_ROLE;
GRANT USAGE ON SCHEMA SOURCE_DB.SOURCE_SCHEMA TO ROLE FALKORDB_AGENT_ROLE;
GRANT SELECT ON ALL TABLES IN SCHEMA SOURCE_DB.SOURCE_SCHEMA TO ROLE FALKORDB_AGENT_ROLE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA SOURCE_DB.SOURCE_SCHEMA TO ROLE FALKORDB_AGENT_ROLE;

GRANT USAGE ON DATABASE WORKING_DB TO ROLE FALKORDB_AGENT_ROLE;
GRANT USAGE ON SCHEMA WORKING_DB.WORKING_SCHEMA TO ROLE FALKORDB_AGENT_ROLE;
GRANT CREATE TABLE ON SCHEMA WORKING_DB.WORKING_SCHEMA TO ROLE FALKORDB_AGENT_ROLE;
GRANT CREATE VIEW ON SCHEMA WORKING_DB.WORKING_SCHEMA TO ROLE FALKORDB_AGENT_ROLE;
```

Then open **AI & ML → Agents** and select `FALKORDB_GRAPH_AGENT`. Example prompts:

```text
What graphs are available?
Inspect my graph schema and suggest useful Cypher queries.
Find the top connected nodes in my graph.
Generate a Cypher query for this question and run it.
How do I load my bound Snowflake table into FalkorDB?
```

When the agent generates or runs Cypher, it should show the Cypher query in the response. The `text_to_cypher` tool returns the generated `cypher`, and the `run_cypher` tool returns both the executed `cypher_query` and the result.

For loading data, the user/admin must bind the `consumer_data_table` reference first. The agent can generate the `LOAD CSV FROM 'file://consumer_data.csv' AS row ...` mapping Cypher, ask which graph to load into when the graph name is missing, and call its load tool after confirmation. The agent does not create the Snowflake reference binding itself.

To print optional caller grants for the configured source and working schemas:

```sql
CALL <app_instance_name>.graph.get_agent_caller_grants('FALKORDB_GRAPH_AGENT');
```

To remove the agent and its app-owned artifacts:

```sql
CALL <app_instance_name>.graph.drop_agent('FALKORDB_GRAPH_AGENT');
```

### Cortex Code Skill

The repository includes a Cortex Code skill for FalkorDB Snowflake workflows:

```text
.cortex/skills/falkordb-snowflake-native-app-skill
```

Use it when you want AI coding assistance for installation SQL, resource sizing, loading data, Cypher queries, and Cortex Agent setup. Register the skill in Cortex Code, verify it with:

```text
/skill list
```

Then invoke it explicitly if needed:

```text
$falkordb-snowflake-native-app-skill
```

## Cypher Query Language Basics

### Creating Nodes

```cypher
-- Simple node
CREATE (:Label {property: 'value'})

-- Multiple properties
CREATE (:Person {name: 'Alice', age: 30, city: 'NYC'})

-- Multiple nodes
CREATE (:Person {name: 'Alice'}), (:Person {name: 'Bob'})
```

### Creating Relationships

```cypher
-- Match existing nodes and create relationship
MATCH (a:Person {name: 'Alice'}), (b:Person {name: 'Bob'})
CREATE (a)-[:KNOWS {since: 2020}]->(b)

-- Bidirectional (two relationships)
MATCH (a:Person {name: 'Alice'}), (b:Person {name: 'Bob'})
CREATE (a)-[:KNOWS]->(b), (b)-[:KNOWS]->(a)
```

### Querying

```cypher
-- Match all nodes with label
MATCH (p:Person) RETURN p

-- Match with filter
MATCH (p:Person {city: 'NYC'}) RETURN p.name, p.age

-- Match relationships
MATCH (a:Person)-[r:KNOWS]->(b:Person) RETURN a.name, b.name

-- Pattern matching
MATCH (a:Person)-[:KNOWS]->(b:Person)-[:KNOWS]->(c:Person)
RETURN a.name, b.name, c.name
```

### Advanced Queries

```cypher
-- Shortest path
MATCH path = shortestPath((a:Person {name: 'Alice'})-[:KNOWS*]-(b:Person {name: 'Eve'}))
RETURN path

-- Variable length paths
MATCH (a:Person)-[:KNOWS*1..3]-(b:Person)
RETURN DISTINCT a.name, b.name

-- Aggregation
MATCH (p:Person)-[:KNOWS]->(friend)
RETURN p.name, COUNT(friend) AS friend_count
ORDER BY friend_count DESC
```

## Troubleshooting

### "Reference NOT bound" Error

**Problem**: `load_csv()` fails with reference error.

**Solution**: Ensure you've bound a table via the UI (Apps → FalkorDB → Security → References → Add).

### Service Not Starting

**Problem**: `get_service_status()` shows error state.

**Solution**: 
```sql
-- Check logs
CALL <app_instance_name>.app_public.get_service_logs('0', 'falkordb', 200);

-- Restart service
CALL <app_instance_name>.app_public.stop_app();
CALL <app_instance_name>.app_public.start_app('FALKORDB_POOL', 'FALKORDB_WH');
```

### Duplicate Nodes After Reload

**Problem**: Running `load_csv()` twice creates duplicate nodes when using CREATE.

**Solution**: Use MERGE instead of CREATE for upsert behavior:
```sql
-- Recommended: Use MERGE (no duplicates)
CALL <app_instance_name>.app_public.load_csv('my_graph', 
  'LOAD CSV FROM ''file://consumer_data.csv'' AS row 
   MERGE (n:Node {id: row[0]})
   ON CREATE SET n.name = row[1]
   ON MATCH SET n.name = row[1]');

-- Alternative: Delete graph first, then reload
CALL <app_instance_name>.app_public.graph_delete('my_graph');
CALL <app_instance_name>.app_public.load_csv('my_graph',
  'LOAD CSV FROM ''file://consumer_data.csv'' AS row
   MERGE (n:Node {id: row[0]})
   ON CREATE SET n.name = row[1]
   ON MATCH SET n.name = row[1]');
```

### Column Not Found in CSV

**Problem**: Cypher query can't access CSV columns.

**Solution**: Use index-based access: `row[0]`, `row[1]`, `row[2]`, etc. (not `row.COLUMNNAME`)

```cypher
-- Correct
LOAD CSV FROM 'file://consumer_data.csv' AS row MERGE (p:Person {id: row[0]}) ON CREATE SET p.name = row[1]

-- Incorrect
MERGE (p:Person {id: row.ID}) ON CREATE SET p.name = row.NAME
```

## Performance Tips

1. **Create indexes** on frequently queried properties
2. **Use specific labels** in MATCH clauses to reduce search space
3. **Limit result sets** for exploration: `RETURN ... LIMIT 100`
4. **Batch large loads** into smaller transactions if timeouts occur

## Additional Resources

- **Cypher Query Language**: [OpenCypher Documentation](https://opencypher.org/)
- **FalkorDB GitHub**: [github.com/FalkorDB/FalkorDB](https://github.com/FalkorDB/FalkorDB)
- **Snowflake Native Apps**: [Snowflake Documentation](https://docs.snowflake.com/en/developer-guide/native-apps/native-apps-about)

## Support

For issues, questions, or feature requests:
- **GitHub Issues**: [FalkorDB Snowflake Integration](https://github.com/FalkorDB/snowflake-integration/issues)
- **Community**: FalkorDB Discord/Slack (check GitHub README for links)

---

**Last Updated**: February 2026  
**Version**: 2.0 (Patch 18)
