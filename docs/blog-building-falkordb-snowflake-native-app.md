# FalkorDB on Snowflake: Native graph database for cloud data warehouse

## Highlights

FalkorDB brings graph database capabilities to Snowflake through a Native App that turns relational tables into queryable knowledge graphs without moving data outside Snowflake's security boundary.

- **Reference binding** enables secure access to consumer tables through Snowflake's Native App framework
- **Snowflake Container Services (SPCS)** runs the FalkorDB engine with isolated compute and automatic scaling
- **Cypher queries** provide graph traversal, pattern matching, and relationship analysis on Snowflake data
- **Cost-aware design** documents compute pool lifecycle management to prevent unexpected charges

Most data warehouse users stuff relationship queries into multi-table JOINs until performance collapses, or they export data to external graph systems and lose security isolation. Neither approach gives you native graph query capabilities within the data warehouse boundary.

FalkorDB's Snowflake Native App takes a different path: it runs graph queries directly on your Snowflake tables using Cypher while keeping data in place. The graph engine runs in Snowflake Container Services, so queries stay fast and data stays governed by Snowflake's security model.

## Native App for graph queries

This walkthrough shows the architecture of FalkorDB on Snowflake—how reference binding provides secure data access, how SPCS hosts the graph engine, and how to manage the compute resources for production workloads.

By the end, you'll understand the key patterns for building Native Apps on Snowflake: reference binding for data access, service functions for containerized workloads, and release directives for marketplace distribution.

### Why graph queries matter for Snowflake data

When you need to find connections, patterns, or paths in relational data, SQL becomes verbose and slow. Questions like "who knows who," "what's connected to what," or "shortest path between entities" require either complex recursive CTEs or multiple self-joins.

Graph queries handle this natively. Cypher turns a 50-line SQL query with 8 JOINs into a single pattern match:

```cypher
-- Find friends of friends
MATCH (person:Person {name: 'Alice'})-[:KNOWS*2]-(friend_of_friend)
RETURN DISTINCT friend_of_friend.name
```

FalkorDB brings this query model to Snowflake without requiring data export, ETL pipelines, or separate graph databases.

## Run FalkorDB on Snowflake

Install FalkorDB directly from Snowflake Marketplace. Navigate to Marketplace, search for "FalkorDB," and click Get to install into your Snowflake account. The installation creates the app with necessary permissions and roles.

Start the FalkorDB service to create the compute infrastructure:

```sql
USE DATABASE falkordb;

-- Start service (creates compute pool and warehouse)
CALL app_public.start_app('falkordb_pool', 'falkordb_wh');

-- Check service status
CALL app_public.get_service_status();
```

Wait for status `READY` (typically 2-3 minutes). The service runs FalkorDB engine in Snowflake Container Services, providing API endpoints for graph operations.

## Bind your data with reference binding

Snowflake Native Apps can't directly access consumer data—they need explicit permission through reference binding. This provides security isolation while enabling data access through a clean UI workflow.

To bind a table:

1. Navigate to **Data Products → Apps → FalkorDB**
2. Go to **Security → References**
3. Click **+ Add** next to "Consumer Data Table"
4. Select your database, schema, and table
5. Click **Save**

That's it. FalkorDB can now securely access your table data without requiring manual GRANT statements or passing table names as strings. Reference binding provides the structured permission model that Native Apps require while keeping the user experience simple.

## Load data into graphs

With a table bound, load it into a graph using `load_csv` which takes a graph name and a Cypher query:

```sql
-- Load customer data into graph (using MERGE to prevent duplicates on reload)
CALL app_public.load_csv(
  'customer_graph',
  'LOAD CSV FROM ''file://consumer_data.csv'' AS row
   MERGE (c:Customer {id: row[0]})
   ON CREATE SET c.name = row[1], c.email = row[2], c.city = row[3]
   ON MATCH SET c.name = row[1], c.email = row[2], c.city = row[3]'
);
```

The procedure exports the bound table to CSV staging, passes it to the FalkorDB engine via service function, and cleans up temporary files. Access columns by index: `row[0]`, `row[1]`, etc. (0-indexed).

**MERGE vs CREATE**: Use MERGE to safely reload data without duplicates. MERGE matches existing nodes by key property (e.g., `id`) and updates them, or creates new ones if they don't exist. Use CREATE only for one-time bulk loads where duplicates aren't a concern.

### Query the graph

Run Cypher queries using `graph_query`:

```sql
-- Find all customers in a specific city
CALL app_public.graph_query('customer_graph',
  'MATCH (c:Customer {city: ''New York''}) 
   RETURN c.name, c.email'
);

-- Find relationships (if you loaded edge data)
CALL app_public.graph_query('social_graph',
  'MATCH (a:Person)-[r:KNOWS]->(b:Person) 
   RETURN a.name, r.since, b.name'
);

-- Shortest path between entities
CALL app_public.graph_query('social_graph',
  'MATCH path = shortestPath(
     (a:Person {name: ''Alice''})-[:KNOWS*]-(b:Person {name: ''Eve''})
   )
   RETURN path'
);
```

Graph queries return results as structured data that you can further process in Snowflake or visualize using FalkorDB Browser.

## Incremental updates with MERGE

When source data changes, you don't need to delete and recreate the entire graph. FalkorDB supports MERGE with ON CREATE and ON MATCH directives for upsert operations:

```sql
-- Reload data safely - updates existing nodes, creates new ones
CALL app_public.load_csv(
  'customer_graph',
  'LOAD CSV FROM ''file://consumer_data.csv'' AS row
   MERGE (c:Customer {id: row[0]})
   ON CREATE SET c.name = row[1], c.city = row[2], c.created = timestamp()
   ON MATCH SET c.name = row[1], c.city = row[2], c.updated = timestamp()'
);
```

MERGE matches nodes by key property (`id` in this example). If the node exists, ON MATCH updates it. If not, ON CREATE creates it. This enables continuous data pipelines without duplicates or full graph rebuilds.

## Compute pool lifecycle and cost management

Snowflake Container Services run on compute pools, which charge differently than warehouses. Understanding this distinction matters for production deployments.

### Compute pool states

Unlike warehouses (which auto-suspend when idle), compute pools have three states:
- **ACTIVE** = running and charging
- **IDLE** = no workload but still charging  
- **SUSPENDED** = stopped and not charging

Warehouses suspend automatically after inactivity. Compute pools don't—they remain ACTIVE until explicitly suspended.

### Managing pool lifecycle

Check pool status regularly:

```sql
SHOW COMPUTE POOLS;
```

Suspend when not in use:

```sql
ALTER COMPUTE POOL falkordb_pool SUSPEND;
```

Resume when needed:

```sql
ALTER COMPUTE POOL falkordb_pool RESUME;
```

FalkorDB's documentation clearly explains this lifecycle so users understand cost implications and can manage pools appropriately for their workload patterns.

## Technical architecture

### Core components

The FalkorDB Native App consists of several integrated components:

1. **Snowflake Container Services (SPCS)**
   - Runs FalkorDB engine in isolated compute pools
   - Provides API endpoints for graph operations
   - Scales with workload demand

2. **Service functions**
   - `load_csv_raw()` - graph loading endpoint
   - `graph_query_raw()` - Cypher query execution
   - `graph_list_raw()` - enumerate graphs
   - `graph_delete_raw()` - graph removal

3. **Wrapper procedures**
   - `load_csv()` - JavaScript wrapper handling CSV export/import with automatic cleanup
   - `graph_query()` - SQL wrapper for Cypher queries
   - Error handling and resource management

4. **Reference binding system**
   - `register_callback()` - handles table binding operations
   - `check_bound_table()` - validates reference state
   - `copy_bound_table_to_stage()` - exports consumer data to staging

### Data flow

```
Consumer Table
    ↓ (bind via UI)
Reference Binding System
    ↓ (COPY INTO)
Staging Area (@app_public.staging)
    ↓ (load_csv_raw API call)
FalkorDB Engine (SPCS)
    ↓ (Cypher CREATE)
Graph Storage
    ↓ (graph_query API call)
Results → Consumer
```

## Key implementation patterns

| Pattern | Implementation | Purpose |
|---------|---------------|---------|
| **Security isolation** | Reference binding with callbacks | Structured, UI-based data access without manual grants |
| **Cost management** | Explicit pool suspension | Prevent continuous charges on ACTIVE pools |
| **Data loading** | CSV staging + service functions | Bridge relational tables to graph structures |
| **Privilege documentation** | Clear README on ACCOUNTADMIN requirements | Enable consumers to perform administrative operations |

## FAQ

### Why use a graph database for Snowflake data instead of SQL JOINs?

Graph queries handle relationship traversal and pattern matching natively. Multi-hop queries (friends-of-friends, supply chain paths, fraud detection rings) that require complex recursive CTEs or multiple self-joins in SQL become simple pattern matches in Cypher.

### How does FalkorDB handle updates to source data?

FalkorDB supports MERGE with ON CREATE and ON MATCH directives for upsert operations. Users can update existing nodes or create new ones without duplicating data. Use MERGE in your Cypher queries to match nodes by key properties—if the node exists, it updates; if not, it creates. This enables incremental updates without deleting and recreating entire graphs.

### What privileges do I need to manage compute pools?

Compute pool operations (SUSPEND, RESUME) require either the OPERATE privilege on the specific pool or ACCOUNTADMIN role. Application procedures run with app roles (`app_admin`, `app_user`) which have limited privileges by design.

### How do I verify which version is served from Marketplace?

Use `SHOW RELEASE DIRECTIVES IN APPLICATION PACKAGE falkordb_app_pkg;` to see which version is marked DEFAULT. The marketplace automatically serves the DEFAULT directive—no need to recreate listings when pushing new patches.

## References and citations

- [Snowflake Native Apps Documentation](https://docs.snowflake.com/en/developer-guide/native-apps/native-apps-about)
- [Snowflake Container Services](https://docs.snowflake.com/en/developer-guide/snowpark-container-services/overview)
- [FalkorDB Documentation](https://docs.falkordb.com/)
- [Cypher Query Language](https://opencypher.org/)

## Resources

- **Try FalkorDB**: [Snowflake Marketplace](https://app.snowflake.com/marketplace/)
- **Documentation**: [Integration guide](https://github.com/FalkorDB/snowflake-integration/blob/main/docs/SNOWFLAKE_INTEGRATION_GUIDE.md)
- **Repository**: [github.com/FalkorDB/snowflake-integration](https://github.com/FalkorDB/snowflake-integration)
- **FalkorDB**: [falkordb.com](https://www.falkordb.com)

---

**Author**: Naseem Ali  
Naseem is a Software Engineer at FalkorDB, working across the AI team and core infrastructure. Contributes to GraphRAG-SDK, leads automation and testing efforts, and develops full-stack features using Python and TypeScript.
