# FalkorDB Snowflake Native App

FalkorDB is a high-performance graph database that runs natively within your Snowflake environment, enabling you to transform relational data into graph structures and execute powerful Cypher queries without leaving Snowflake.

---

## Overview

FalkorDB Graph Database for Snowflake enables data teams to unlock the power of connected data through native graph analytics and AI-driven insights directly within their Snowflake environment. Transform your Snowflake tables into graph structures, execute Cypher queries, and leverage GraphRAG capabilities—all running securely within your Snowflake account.

---

## Prerequisites

Before installing this app, ensure you have:

- **Snowflake Account**: Active Snowflake account with ACCOUNTADMIN role privileges
- **Existing Data**: Snowflake tables containing the data you wish to analyze as graphs
- **Compute Resources**: Sufficient credits for running compute pools and warehouses

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
   - `CREATE COMPUTE POOL`: Enables the app to create container runtime environments
   - `CREATE WAREHOUSE`: Enables the app to create SQL compute resources
   - `BIND SERVICE ENDPOINT`: Allows the app to expose internal service endpoints
4. Complete the installation process

### Step 2: Initialize the Application

After installation, initialize the FalkorDB service by calling the `start_app()` procedure. The app will automatically create the required compute pool and warehouse:

```sql
-- Initialize FalkorDB with default resource names
CALL <app_instance_name>.app_public.start_app('FALKORDB_POOL', 'FALKORDB_WH');
```

**Important**: Replace `<app_instance_name>` with the name you chose during installation.

**Note**: After `start_app()` completes, the graph database procedures (`load_csv()`, `graph_query()`, `graph_list()`, `graph_delete()`) will be created and ready to use. These procedures depend on the FalkorDB service being running.

### Step 3: Load Your Data

Import data from your Snowflake tables into a graph structure:

```sql
-- Example: Create a social network graph from a Snowflake table
CALL <app_instance_name>.app_public.load_csv(
    'social_network',                          -- Graph name
    'my_database.my_schema.users_table',      -- Source table
    'CREATE (:Person {id: $id, name: $name})' -- Cypher mapping
);
```

### Step 4: Query Your Graph

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

## Available Procedures

The FalkorDB app provides the following SQL procedures for graph management and querying:

### Graph Management

**`start_app(poolname VARCHAR, whname VARCHAR)`**
- Initializes the FalkorDB service with specified compute resources
- Automatically creates the compute pool and warehouse if they don't exist
- Example: `CALL app_public.start_app('FALKORDB_POOL', 'FALKORDB_WH');`

**`load_csv(graph_name VARCHAR, table_name VARCHAR, cypher_query VARCHAR)`**
- Imports data from a Snowflake table into a graph structure
- Automatically stages data, loads it into FalkorDB, and cleans up temporary files
- Example: `CALL app_public.load_csv('my_graph', 'schema.table', 'CREATE (:Node {prop: $column})');`

**`graph_list()`**
- Returns a list of all graphs created in your FalkorDB instance
- Example: `CALL app_public.graph_list();`

**`graph_delete(graph_name VARCHAR)`**
- Permanently deletes a specified graph and all its data
- Example: `CALL app_public.graph_delete('my_graph');`

### Graph Querying

**`graph_query(graph_name VARCHAR, cypher_query VARCHAR)`**
- Executes Cypher queries against a specified graph
- Returns query results in Snowflake-compatible format
- Example: `CALL app_public.graph_query('my_graph', 'MATCH (n) RETURN n LIMIT 10');`

### Administrative Functions

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

2. **Initialization**: When you call `start_app()`, the app:
   - Creates a compute pool for running the FalkorDB container service
   - Creates a warehouse for SQL query processing
   - Launches the FalkorDB graph database service

3. **Data Loading**: When you call `load_csv()`, the app:
   - Exports your specified Snowflake table to a CSV file in a staging area
   - Mounts the CSV file to the FalkorDB container
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
