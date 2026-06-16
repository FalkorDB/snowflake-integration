# FalkorDB Snowflake Native App

FalkorDB is a high-performance graph database that runs natively within your Snowflake environment, enabling you to transform relational data into graph structures and execute powerful Cypher queries without leaving Snowflake.

---

## Overview

FalkorDB Graph Database for Snowflake enables data teams to unlock the power of connected data through native graph analytics and AI-driven insights directly within their Snowflake environment. Transform your Snowflake tables into graph structures, execute Cypher queries, and leverage GraphRAG capabilities—all running securely within your Snowflake account.

---

## Prerequisites

Before installing this app, ensure you have:

- **Snowflake Account**: Active Snowflake account with ACCOUNTADMIN role privileges (required for granting application privileges)
- **Compute Resources**: Ability to create compute pools and warehouses in your account
- **Existing Data** (optional): Snowflake tables containing the data you wish to analyze as graphs, or use the built-in sample data

**No External Credentials Required**: This app runs entirely within your Snowflake environment. No external API keys, passwords, or third-party service credentials are needed. All data processing occurs within your Snowflake account boundaries.

---

## Key Features

- **Seamless Data Import**: Load data directly from Snowflake tables into graph structures using simple SQL procedures
- **Native Cypher Support**: Execute powerful Cypher queries on your graph data through familiar SQL interfaces
- **GraphRAG Integration**: Transform raw data into contextual knowledge for AI and LLM applications
- **Secure & Self-Contained**: All code and dependencies run within your Snowflake account—no remote code execution
- **Fully Transparent**: All application code is human-readable and auditable (no obfuscation)
- **Enterprise-Ready**: Built on Snowpark Container Services for scalable, production-grade performance

---

## Architecture

![Architecture Diagram](falkor_snowflake_arch.png)

---

## Installation & Quick Start

### Step 1: Install the Application

1. Navigate to the Snowflake Marketplace and locate "FalkorDB Graph Database"
2. Click "Get" to install the application in your Snowflake account
3. Grant the requested privileges when prompted:
   - `BIND SERVICE ENDPOINT`: Allows the app to expose internal service endpoints
   - `CREATE COMPUTE POOL`: Allows the app to create compute pools automatically
   - `CREATE WAREHOUSE`: Allows the app to create warehouses automatically
   - `IMPORTED PRIVILEGES ON SNOWFLAKE DB`: Allows the Agent `text_to_cypher` tool to call Snowflake Cortex model functions
4. Complete the installation process

### Step 2: Bind Your Data Table

After installation, bind a table from your account to the application:

1. Navigate to **Data Products** → **Apps** in Snowsight
2. Click on your installed FalkorDB app instance
3. Go to the **Permissions** tab
4. Under **Object access privileges**, find **Consumer Data Table**
5. Click **Select Data** and choose the table containing your graph data
6. Grant SELECT privilege when prompted

The table you bind will be used by the `load_csv` procedure to import data into graph structures.

### Step 3: Initialize the Application

The app will automatically create the required compute pool and warehouse when you start it:

```sql
-- Initialize FalkorDB - it will create compute pool and warehouse automatically
CALL <app_instance_name>.app_public.start_app('FALKORDB_POOL', 'FALKORDB_WH');
```

**Default Resource Configuration**:
- **Compute Pool**: `CPU_X64_S` instance family, 1 node, auto-resume enabled. Exact CPU/RAM can vary by Snowflake region; check with `SHOW COMPUTE POOL INSTANCE FAMILIES;`
- **FalkorDB Container**: requests 1 CPU / 2GB RAM and can use up to 2 CPU / 4GB RAM by default
- **Warehouse**: `XSMALL` size, initially suspended, auto-suspend after 300 seconds

To use a larger Snowflake warehouse for SQL/procedure execution, resize it after creation:

```sql
ALTER WAREHOUSE FALKORDB_WH SET WAREHOUSE_SIZE = 'SMALL';
-- or
ALTER WAREHOUSE FALKORDB_WH SET WAREHOUSE_SIZE = 'MEDIUM';
```

Larger warehouses consume more Snowflake credits while running.

**Custom FalkorDB Container Resources**: For larger graphs, pass explicit CPU/memory options when starting the app:

```sql
CALL <app_instance_name>.app_public.start_app(
    'FALKORDB_POOL',
    'FALKORDB_WH',
    OBJECT_CONSTRUCT(
        'cpuRequest', 1,
        'memoryRequest', '2G',
        'cpuLimit', 2,
        'memoryLimit', '4G'
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

To change container resources after the service is already running, stop it first:

```sql
CALL <app_instance_name>.app_public.stop_app();
CALL <app_instance_name>.app_public.start_app(
    'FALKORDB_POOL',
    'FALKORDB_WH',
    OBJECT_CONSTRUCT('cpuRequest', 2, 'memoryRequest', '4G', 'cpuLimit', 4, 'memoryLimit', '8G')
);
```

**Advanced**: If you need a larger Snowflake compute pool or warehouse, create them manually **before** calling `start_app()`:

```sql
-- Optional: Create custom compute pool (if you need different specs)
CREATE COMPUTE POOL FALKORDB_POOL
    MIN_NODES = 1
    MAX_NODES = 3
    INSTANCE_FAMILY = CPU_X64_M  -- Larger instance
    AUTO_RESUME = TRUE;

-- Optional: Create custom warehouse (if you need different size)
CREATE WAREHOUSE FALKORDB_WH WITH
    WAREHOUSE_SIZE = 'MEDIUM'    -- Larger warehouse
    AUTO_SUSPEND = 600
    AUTO_RESUME = TRUE;

-- Then initialize (will use your existing resources)
CALL <app_instance_name>.app_public.start_app('FALKORDB_POOL', 'FALKORDB_WH');
```

**Important**: Replace `<app_instance_name>` with the name you chose during installation.

### Step 4: Verify Table Binding (Optional)

You can verify the table binding at any time:

```sql
CALL <app_instance_name>.app_public.check_bound_table();
```

To change the bound table, return to the **Permissions** tab in the app UI.

### Step 5: Load Your Data

Import data from your bound table into a graph structure:

```sql
-- Example: Create a social network graph from your bound table
CALL <app_instance_name>.app_public.load_csv(
    'social_network',
    'LOAD CSV FROM ''file://consumer_data.csv'' AS row MERGE (p:Person {id: row[0]}) ON CREATE SET p.name = row[1] ON MATCH SET p.name = row[1]'
);
```

**Note**:
- The table is automatically retrieved from your Config UI binding—no need to specify it as a parameter
- The Cypher query must include `LOAD CSV FROM 'file://...' AS row` to access the CSV data via `row[0]`, `row[1]`, etc.
- The file name in the `file://...` clause is a placeholder; the app passes the actual staged CSV filename to the FalkorDB service for each load.
- Large tables can be exported as multiple CSV parts. The app loads each part sequentially, so use idempotent Cypher such as `MERGE` for reload-safe imports.
- For large `MERGE` loads, create an index on the matched label/property before loading, for example: `CALL <app_instance_name>.app_public.graph_query('social_network', 'CREATE INDEX ON :Person(id)');`
- If the bound table has no rows, `load_csv` returns an empty array and does not call the FalkorDB load endpoint.

#### Multi-part CSV staging behavior

`load_csv` exports the bound table into a unique folder under `@app_public.staging`. Snowflake may write one CSV file or split a large export into multiple part files. The app lists that folder, validates the generated file names, sorts them lexicographically for deterministic retries, and copies each part to the stage root before calling the FalkorDB service. The root copy preserves the existing service contract: `load_csv_raw` receives a flat `csv_file` name mounted at `/var/lib/FalkorDB/import`, not a nested stage path.

After loading, the app removes both the temporary folder and the root-level copies. Cleanup failures are returned as errors so leaked staged files are visible. Multi-part loads are sequential, not transactional across all parts; if one part loads and a later part fails, the graph changes from the earlier part remain. Use `MERGE` or delete/recreate the graph when retrying loads that must be idempotent, and do not rely on source row order across generated part files. When using `MERGE` on large multi-part loads, create an index on the matched key first, such as `CREATE INDEX ON :Airport(id)`, to avoid scanning existing nodes for each row in later parts.

### Step 6: Query Your Graph

Execute Cypher queries to analyze relationships and patterns:

```sql
-- Find all persons in the graph
CALL <app_instance_name>.app_public.graph_query(
    'social_network',
    'MATCH (n:Person) RETURN n.name, n.id LIMIT 10'
);

-- Find connections between people
CALL <app_instance_name>.app_public.graph_query(
    'social_network',
    'MATCH (p1:Person)-[r:KNOWS]->(p2:Person) 
     RETURN p1.name, p2.name'
);
```

---

## Quick Start with Sample Data

Want to try FalkorDB without setting up your own data? Use the built-in sample data loader:

```sql
-- 1. Make sure the service is running
CALL <app_instance_name>.app_public.get_service_status();

-- 2. Load sample social network (5 people with relationships)
CALL <app_instance_name>.app_public.load_sample_social_network();

-- 3. Query the sample data
CALL <app_instance_name>.app_public.graph_query(
    'demo_social_network',
    'MATCH (p:Person) RETURN p.name, p.age, p.city'
);

-- 4. Find relationships in the sample network
CALL <app_instance_name>.app_public.graph_query(
    'demo_social_network',
    'MATCH (a:Person)-[r:KNOWS]->(b:Person) 
     RETURN a.name, b.name, r.since'
);
```

---

## Available Procedures

The FalkorDB app provides the following SQL procedures for graph management and querying:

### Graph Management

**`start_app(poolname VARCHAR, whname VARCHAR)`**
- Initializes the FalkorDB service with specified compute pool and warehouse names
- Automatically creates the compute pool (CPU_X64_S) and warehouse (XSMALL) if they don't exist
- Uses the default FalkorDB container resources: 1 CPU / 2GB request, 2 CPU / 4GB limit
- If resources already exist, uses them instead of creating new ones
- Example: `CALL app_public.start_app('FALKORDB_POOL', 'FALKORDB_WH');`

**`start_app(poolname VARCHAR, whname VARCHAR, options OBJECT)`**
- Initializes the FalkorDB service with explicit container CPU/memory request and limit options
- Supported options: `cpuRequest`, `memoryRequest`, `cpuLimit`, `memoryLimit`
- `cpuRequest`/`memoryRequest` are used by Snowflake to schedule the container on a compute pool node
- `cpuLimit`/`memoryLimit` cap how much CPU/memory the container can use
- If requests are too large for the selected compute pool, Snowflake will fail to schedule the service or report insufficient resources
- Requires the service not to already exist; call `stop_app()` first when changing resources
- Example: `CALL app_public.start_app('FALKORDB_POOL', 'FALKORDB_WH', OBJECT_CONSTRUCT('cpuRequest', 2, 'memoryRequest', '4G', 'cpuLimit', 4, 'memoryLimit', '8G'));`

**`load_csv(graph_name VARCHAR, cypher_query VARCHAR)`**
- Imports data from your bound table (configured during installation) into a graph structure
- Uses the table reference you selected in the Config UI
- Automatically stages data, loads one or more CSV parts into FalkorDB, and cleans up temporary files
- Example: `CALL app_public.load_csv('my_graph', 'LOAD CSV FROM ''file://consumer_data.csv'' AS row MERGE (n:Node {prop: row[0]})');`
- **Note**: The Cypher query must include `LOAD CSV FROM 'file://...' AS row` clause to access CSV columns via `row[0]`, `row[1]`, etc.

**`graph_list()`**
- Returns a list of all graphs created in your FalkorDB instance
- Example: `CALL app_public.graph_list();`

**`graph_delete(graph_name VARCHAR)`**
- Permanently deletes a specified graph and all its data
- Example: `CALL app_public.graph_delete('my_graph');`

**`load_sample_social_network()`**
- Creates a demo social network graph with sample data for testing
- Creates 5 person nodes (Alice, Bob, Carol, David, Eve) with relationships
- Graph name: `demo_social_network`
- Example: `CALL app_public.load_sample_social_network();`

### Graph Querying

**`graph_query(graph_name VARCHAR, cypher_query VARCHAR)`**
- Executes Cypher queries against a specified graph
- Returns query results in Snowflake-compatible format
- Example: `CALL app_public.graph_query('my_graph', 'MATCH (n) RETURN n LIMIT 10');`

**`graph_query(graph_name VARCHAR, cypher_query VARCHAR, options OBJECT)`**
- Executes a Cypher query and optionally writes the returned rows to a durable Snowflake table
- The output table is created or replaced with `ROW_INDEX NUMBER` and `ROW_DATA VARIANT`
- To write back, pass `OBJECT_CONSTRUCT('write', OBJECT_CONSTRUCT('outputTable', 'DATABASE.SCHEMA.TABLE'))`
- Example:

```sql
CALL <app_instance_name>.app_public.graph_query(
    'airroutes',
    'MATCH (a:Airport) RETURN a.code AS code, a.name AS name LIMIT 100',
    OBJECT_CONSTRUCT(
        'write', OBJECT_CONSTRUCT(
            'outputTable', 'AIRROUTES_DB.RESULTS.AIRPORT_QUERY_RESULTS'
        )
    )
);
```

The app must have permission to create the output table in the target schema:

```sql
GRANT CREATE TABLE ON SCHEMA AIRROUTES_DB.RESULTS TO APPLICATION <app_instance_name>;
```

### Cortex Agent Integration

The agent is created after the normal FalkorDB setup flow. It does not start the service by itself. It can load data only from an already-bound `consumer_data_table` reference after the user confirms the generated LOAD CSV mapping.

For difficult graph questions, the agent can call its `text_to_cypher` tool before execution. This tool uses a default Snowflake Cortex model to generate FalkorDB Cypher from the FalkorDB graph schema and the user's question, then the agent can explain the generated query and call `run_cypher`.

The graph schema passed to `text_to_cypher` is the FalkorDB schema for the selected graph: labels, relationship types, property keys, and basic graph stats. It is not the Snowflake source schema passed to `graph.create_agent`.

Required flow:

```sql
-- 1. Start FalkorDB
CALL <app_instance_name>.app_public.start_app(
    'FALKORDB_POOL',
    'FALKORDB_WH'
);

-- 2. Load or create graphs as usual, then verify they exist
CALL <app_instance_name>.app_public.graph_list();

-- 3. Create the Snowflake Cortex Agent
USE WAREHOUSE FALKORDB_WH;
CALL <app_instance_name>.graph.create_agent(
    'FALKORDB_GRAPH_AGENT',
    'SOURCE_DB.SOURCE_SCHEMA',
    'WORKING_DB.WORKING_SCHEMA'
);
```

**`graph.create_agent(agent_name VARCHAR, source_schema VARCHAR, working_schema VARCHAR)`**
- Creates a Snowflake Cortex Agent that can be used from **AI & ML → Agents** or Snowflake Intelligence
- Wires the agent to FalkorDB tools for listing graphs, inspecting graph schema, checking graph stats, generating Cypher from natural language with `text_to_cypher`, loading already-bound Snowflake table data, and running Cypher through the Native App service
- Uses the caller role's default/current warehouse as the agent tool execution warehouse, matching the Snowflake Cortex Agent custom-tool flow
- Arguments:

| Argument | What to pass | Example |
|---|---|---|
| `agent_name` | Name for the Snowflake Agent object to create | `FALKORDB_GRAPH_AGENT` |
| `source_schema` | Fully qualified schema where the original Snowflake source data lives | `AIRROUTES_DB.PUBLIC` |
| `working_schema` | Fully qualified schema the agent can use for generated/intermediate outputs | `AIRROUTES_DB.PUBLIC` |

- Example:

```sql
USE WAREHOUSE FALKORDB_WH;
CALL <app_instance_name>.graph.create_agent(
    'FALKORDB_GRAPH_AGENT',
    'SOURCE_DB.SOURCE_SCHEMA',
    'WORKING_DB.WORKING_SCHEMA'
);
```

The consumer role that uses the agent must have Snowflake Cortex Agent access:

```sql
USE ROLE ACCOUNTADMIN;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_AGENT_USER TO ROLE <consumer_role>;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE <consumer_role>;

-- Required by the Native App so text_to_cypher can resolve SNOWFLAKE.CORTEX.COMPLETE.
GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO APPLICATION <app_instance_name>;
```

Minimal setup template:

```sql
USE ROLE ACCOUNTADMIN;

CREATE ROLE IF NOT EXISTS FALKORDB_AGENT_ROLE;
GRANT APPLICATION ROLE <app_instance_name>.app_admin TO ROLE FALKORDB_AGENT_ROLE;
GRANT APPLICATION ROLE <app_instance_name>.app_user TO ROLE FALKORDB_AGENT_ROLE;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_AGENT_USER TO ROLE FALKORDB_AGENT_ROLE;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE FALKORDB_AGENT_ROLE;
GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO APPLICATION <app_instance_name>;

GRANT USAGE ON DATABASE SOURCE_DB TO ROLE FALKORDB_AGENT_ROLE;
GRANT USAGE ON SCHEMA SOURCE_DB.SOURCE_SCHEMA TO ROLE FALKORDB_AGENT_ROLE;
GRANT SELECT ON ALL TABLES IN SCHEMA SOURCE_DB.SOURCE_SCHEMA TO ROLE FALKORDB_AGENT_ROLE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA SOURCE_DB.SOURCE_SCHEMA TO ROLE FALKORDB_AGENT_ROLE;

GRANT USAGE ON DATABASE WORKING_DB TO ROLE FALKORDB_AGENT_ROLE;
GRANT USAGE ON SCHEMA WORKING_DB.WORKING_SCHEMA TO ROLE FALKORDB_AGENT_ROLE;
GRANT CREATE TABLE ON SCHEMA WORKING_DB.WORKING_SCHEMA TO ROLE FALKORDB_AGENT_ROLE;
GRANT CREATE VIEW ON SCHEMA WORKING_DB.WORKING_SCHEMA TO ROLE FALKORDB_AGENT_ROLE;
```

After creating the agent, open **AI & ML → Agents** and select `FALKORDB_GRAPH_AGENT`.

When the agent generates or runs a Cypher query, it should show the Cypher in the response. The `run_cypher` tool returns both the executed `cypher_query` and the query result, and `text_to_cypher` returns the generated `cypher` before execution.

For loading data, the user/admin must bind the `consumer_data_table` reference first. The agent can help generate the `LOAD CSV FROM 'file://consumer_data.csv' AS row ...` mapping Cypher, ask which graph to load into if missing, and call its load tool after confirmation. The agent does not create the Snowflake reference binding itself.

**`graph.get_agent_caller_grants(agent_name VARCHAR)`**
- Prints optional `GRANT CALLER` statements for the configured source and working schemas
- Example: `CALL <app_instance_name>.graph.get_agent_caller_grants('FALKORDB_GRAPH_AGENT');`

**`graph.drop_agent(agent_name VARCHAR)`**
- Drops the Cortex Agent and its app-owned agent artifacts
- Example: `CALL <app_instance_name>.graph.drop_agent('FALKORDB_GRAPH_AGENT');`

### Cortex Code Skill

The repository also includes a Cortex Code skill at:

```text
.cortex/skills/falkordb-snowflake-native-app-skill
```

Use it with Cortex Code when you want help writing FalkorDB Snowflake SQL, Cypher loading queries, container resource options, or Cortex Agent setup.

Install or register the skill in Cortex Code, then verify:

```text
/skill list
```

You can invoke it explicitly with:

```text
$falkordb-snowflake-native-app-skill
```

### Administrative Functions

**`check_bound_table()`**
- Verifies that a table reference is properly bound to the application
- Returns success message if bound, error message if not
- Example: `CALL app_public.check_bound_table();`

**`get_service_status()`**
- Returns the current status of the FalkorDB service

**`get_service_logs(container_name VARCHAR, num_lines INTEGER)`**
- Retrieves service logs for troubleshooting

**`get_service_containers()`**
- Lists all running FalkorDB service containers

---

## How It Works

FalkorDB operates entirely within your Snowflake environment using Snowpark Container Services:

1. **Installation**: When you install the app, it registers the necessary privileges and creates application roles within your Snowflake account

2. **Resource Creation**: You create a compute pool and warehouse in your account and grant the necessary permissions to the application

3. **Initialization**: When you call `start_app()`, the app:
   - Creates a service using your provided compute pool and warehouse
   - Launches the FalkorDB graph database container
   - Creates wrapper procedures for graph operations

3. **Data Loading**: When you call `load_csv()`, the app:
   - Exports your specified Snowflake table to one or more CSV files in a staging area
   - Mounts the CSV files to the FalkorDB container
   - Executes your Cypher query to map CSV data into graph structures
   - Automatically cleans up temporary files

4. **Querying**: When you call `graph_query()`, the app:
   - Routes your Cypher query to the FalkorDB service endpoint
   - Executes the query against the specified graph
   - Returns results in Snowflake-compatible format

All processing occurs within your Snowflake account boundaries—no data leaves your environment.

---

## Security Compliance

This app **fully conforms** to Snowflake's [security requirements for application code](https://docs.snowflake.com/en/developer-guide/native-apps/security-app-requirements#security-requirements-for-application-code):

- **No Remote Code Execution**: All code is packaged within the app—no external code is loaded or executed
- **Full Transparency**: All code (including JavaScript) is human-readable with no obfuscation
- **Dependency Security**: All dependencies are included and free of critical/high CVEs
- **No Hardcoded Secrets**: No API keys, passwords, or credentials are stored in plain text
- **Isolated Execution**: All operations run within your Snowflake account boundaries

---

## Support & Resources

### Documentation
- **FalkorDB Documentation**: [https://docs.falkordb.com](https://docs.falkordb.com)
- **Cypher Query Language**: [https://docs.falkordb.com/cypher](https://docs.falkordb.com/cypher)
- **Snowflake Native Apps**: [https://docs.snowflake.com/en/developer-guide/native-apps](https://docs.snowflake.com/en/developer-guide/native-apps)

### Community & Support
- **GitHub Repository**: [https://github.com/FalkorDB/snowflake-integration](https://github.com/FalkorDB/snowflake-integration)
- **Report Issues**: Open an issue on our GitHub repository
- **Community Forum**: Join the FalkorDB community discussions

### Contact
For enterprise support inquiries, please visit [https://falkordb.com](https://falkordb.com)

---

## License

This Snowflake Native App is provided by FalkorDB. Please refer to the [LICENSE](https://github.com/FalkorDB/snowflake-integration/blob/main/LICENSE) file for terms and conditions.
