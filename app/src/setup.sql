CREATE APPLICATION ROLE IF NOT EXISTS app_admin;
CREATE APPLICATION ROLE IF NOT EXISTS app_user;

-- Create schema for the application
CREATE SCHEMA IF NOT EXISTS app_public;
GRANT USAGE ON SCHEMA app_public TO APPLICATION ROLE app_admin;
GRANT USAGE ON SCHEMA app_public TO APPLICATION ROLE app_user;

-- Create staging area for CSV exports
CREATE STAGE IF NOT EXISTS app_public.staging;
GRANT READ, WRITE ON STAGE app_public.staging TO APPLICATION ROLE app_admin;
GRANT READ, WRITE ON STAGE app_public.staging TO APPLICATION ROLE app_user;

CREATE OR ALTER VERSIONED SCHEMA v1;
GRANT USAGE ON SCHEMA v1 TO APPLICATION ROLE app_admin;

-- Helper procedure to request table access using Permission SDK
CREATE OR REPLACE PROCEDURE app_public.request_table_access(table_name VARCHAR)
    RETURNS VARIANT
    LANGUAGE PYTHON
    RUNTIME_VERSION = '3.8'
    PACKAGES = ('snowflake-snowpark-python')
    HANDLER = 'request_access'
    EXECUTE AS OWNER
AS
$$
def request_access(session, table_name):
    """Request SELECT privilege on a table via UI popup (if Permission SDK available)"""
    try:
        import snowflake.permissions as permissions
        # Request reference to the table
        permissions.request_reference(table_name)
        return {"status": "success", "message": f"Access requested for {table_name}"}
    except ModuleNotFoundError:
        return {"status": "unavailable", "message": "Permission SDK not available in this region. Please grant access manually: GRANT SELECT ON TABLE " + table_name + " TO APPLICATION <app_name>;"}
    except Exception as e:
        return {"status": "error", "message": str(e)}
$$;
GRANT USAGE ON PROCEDURE app_public.request_table_access(VARCHAR) TO APPLICATION ROLE app_admin;
GRANT USAGE ON PROCEDURE app_public.request_table_access(VARCHAR) TO APPLICATION ROLE app_user;


CREATE OR REPLACE PROCEDURE app_public.start_app(poolname VARCHAR, whname VARCHAR)
    RETURNS string
    LANGUAGE sql
    AS $$
BEGIN
        -- Create compute pool if it doesn't exist
        EXECUTE IMMEDIATE 'CREATE COMPUTE POOL IF NOT EXISTS IDENTIFIER(?) 
            MIN_NODES = 1 
            MAX_NODES = 1
            INSTANCE_FAMILY = CPU_X64_S
            AUTO_RESUME = TRUE'
            USING (poolname);
        
        -- Create warehouse if it doesn't exist
        EXECUTE IMMEDIATE 'CREATE WAREHOUSE IF NOT EXISTS IDENTIFIER(?)
            WITH WAREHOUSE_SIZE = ''XSMALL''
            INITIALLY_SUSPENDED = TRUE
            AUTO_SUSPEND = 300
            AUTO_RESUME = TRUE'
            USING (whname);
        
        -- Create the service using IDENTIFIER for both pool and warehouse
        EXECUTE IMMEDIATE 'CREATE SERVICE IF NOT EXISTS app_public.st_spcs
            IN COMPUTE POOL IDENTIFIER(?)
            FROM SPECIFICATION_FILE = ''falkordb.yaml''
            QUERY_WAREHOUSE = IDENTIFIER(?)'
            USING (poolname, whname);
    GRANT USAGE ON SERVICE app_public.st_spcs TO APPLICATION ROLE app_user;
    GRANT SERVICE ROLE app_public.st_spcs!ALL_ENDPOINTS_USAGE TO APPLICATION ROLE app_user;
    -- Also grant to app_admin for operational tasks
    GRANT USAGE ON SERVICE app_public.st_spcs TO APPLICATION ROLE app_admin;
    GRANT SERVICE ROLE app_public.st_spcs!ALL_ENDPOINTS_USAGE TO APPLICATION ROLE app_admin;
   

    -- Create load_csv service function 
    EXECUTE IMMEDIATE 'CREATE OR REPLACE FUNCTION app_public.load_csv_raw(request OBJECT)
        RETURNS VARIANT
        SERVICE=app_public.st_spcs
        ENDPOINT=''api''
        AS ''/load_csv''';
    
    -- Create wrapper procedure for load_csv, load the data from consumer_table as csv file named consumer_table.csv to in the staging area and then call load_csv_raw  
    EXECUTE IMMEDIATE 'CREATE OR REPLACE PROCEDURE app_public.load_csv(graph_name VARCHAR, consumer_table VARCHAR, cypher_query VARCHAR)
        RETURNS VARIANT
        LANGUAGE JAVASCRIPT
        AS
        ''
        // Try to request access via Permission SDK (optional, may not be available in all regions)
        try {
            var requestAccess = snowflake.execute({
                sqlText: "CALL app_public.request_table_access(?)",
                binds: [CONSUMER_TABLE]
            });
        } catch (err) {
            // Permission SDK not available - user must grant manually
            // This is expected and OK
        }
        
        var randomId = Math.abs(Math.floor(Math.random() * 1000000));
        var csvFilename = CONSUMER_TABLE + "_" + randomId + ".csv";
        
        // Export data to CSV
        var copyQuery = "COPY INTO @app_public.staging/" + csvFilename + 
                       " FROM (SELECT * FROM " + CONSUMER_TABLE + ")" +
                       " FILE_FORMAT = (TYPE = CSV COMPRESSION = NONE)" +
                       " SINGLE = TRUE";
        snowflake.execute({sqlText: copyQuery});
        
        try {
            // Call load_csv_raw
            var result = snowflake.execute({
                sqlText: "SELECT app_public.load_csv_raw({''''graph_name'''': ?, ''''csv_file'''': ?, ''''cypher_query'''': ?})",
                binds: [GRAPH_NAME, csvFilename, CYPHER_QUERY]
            });
            
            // Clean up CSV file
            snowflake.execute({
                sqlText: "REMOVE @app_public.staging/" + csvFilename
            });
            
            return result.next() ? result.getColumnValue(1) : null;
        } catch (err) {
            // Clean up on error
            try {
                snowflake.execute({
                    sqlText: "REMOVE @app_public.staging/" + csvFilename
                });
            } catch (cleanupErr) {
                // Ignore cleanup errors
            }
            throw err;
        }
        ''';

    
    EXECUTE IMMEDIATE 'GRANT USAGE ON FUNCTION app_public.load_csv_raw(OBJECT) TO APPLICATION ROLE app_admin';
    EXECUTE IMMEDIATE 'GRANT USAGE ON FUNCTION app_public.load_csv_raw(OBJECT) TO APPLICATION ROLE app_user';
    EXECUTE IMMEDIATE 'GRANT USAGE ON PROCEDURE app_public.load_csv(VARCHAR, VARCHAR, VARCHAR) TO APPLICATION ROLE app_admin';
    EXECUTE IMMEDIATE 'GRANT USAGE ON PROCEDURE app_public.load_csv(VARCHAR, VARCHAR, VARCHAR) TO APPLICATION ROLE app_user';

    -- Create graph_query service function 
    EXECUTE IMMEDIATE 'CREATE OR REPLACE FUNCTION app_public.graph_query_raw(request OBJECT)
        RETURNS STRING
        SERVICE=app_public.st_spcs
        ENDPOINT=''api''
        AS ''/graph_query''';
    
    -- Create wrapper procedure for graph_query
    EXECUTE IMMEDIATE 'CREATE OR REPLACE PROCEDURE app_public.graph_query(graph_name VARCHAR, query VARCHAR)
        RETURNS STRING
        LANGUAGE SQL
        AS
        ''BEGIN
            RETURN app_public.graph_query_raw({''''graph_name'''': :graph_name, ''''query'''': :query});
        END''';
    
    EXECUTE IMMEDIATE 'GRANT USAGE ON FUNCTION app_public.graph_query_raw(OBJECT) TO APPLICATION ROLE app_admin';
    EXECUTE IMMEDIATE 'GRANT USAGE ON FUNCTION app_public.graph_query_raw(OBJECT) TO APPLICATION ROLE app_user';
    EXECUTE IMMEDIATE 'GRANT USAGE ON PROCEDURE app_public.graph_query(VARCHAR, VARCHAR) TO APPLICATION ROLE app_admin';
    EXECUTE IMMEDIATE 'GRANT USAGE ON PROCEDURE app_public.graph_query(VARCHAR, VARCHAR) TO APPLICATION ROLE app_user';

    -- Create graph_list service function 
    EXECUTE IMMEDIATE 'CREATE OR REPLACE FUNCTION app_public.graph_list_raw(request OBJECT)
        RETURNS STRING
        SERVICE=app_public.st_spcs
        ENDPOINT=''api''
        AS ''/graph_list''';
    
    -- Create wrapper procedure for graph_list
    EXECUTE IMMEDIATE 'CREATE OR REPLACE PROCEDURE app_public.graph_list()
        RETURNS STRING
        LANGUAGE SQL
        AS
        ''BEGIN
            RETURN app_public.graph_list_raw({});
        END''';
    
    EXECUTE IMMEDIATE 'GRANT USAGE ON FUNCTION app_public.graph_list_raw(OBJECT) TO APPLICATION ROLE app_admin';
    EXECUTE IMMEDIATE 'GRANT USAGE ON FUNCTION app_public.graph_list_raw(OBJECT) TO APPLICATION ROLE app_user';
    EXECUTE IMMEDIATE 'GRANT USAGE ON PROCEDURE app_public.graph_list() TO APPLICATION ROLE app_admin';
    EXECUTE IMMEDIATE 'GRANT USAGE ON PROCEDURE app_public.graph_list() TO APPLICATION ROLE app_user';

    -- Create graph_delete service function 
    EXECUTE IMMEDIATE 'CREATE OR REPLACE FUNCTION app_public.graph_delete_raw(request OBJECT)
        RETURNS STRING
        SERVICE=app_public.st_spcs
        ENDPOINT=''api''
        AS ''/graph_delete''';
    
    -- Create wrapper procedure for graph_delete
    EXECUTE IMMEDIATE 'CREATE OR REPLACE PROCEDURE app_public.graph_delete(graph_name VARCHAR)
        RETURNS STRING
        LANGUAGE SQL
        AS
        ''BEGIN
            RETURN app_public.graph_delete_raw({''''graph_name'''': :graph_name});
        END''';
    
    EXECUTE IMMEDIATE 'GRANT USAGE ON FUNCTION app_public.graph_delete_raw(OBJECT) TO APPLICATION ROLE app_admin';
    EXECUTE IMMEDIATE 'GRANT USAGE ON FUNCTION app_public.graph_delete_raw(OBJECT) TO APPLICATION ROLE app_user';
    EXECUTE IMMEDIATE 'GRANT USAGE ON PROCEDURE app_public.graph_delete(VARCHAR) TO APPLICATION ROLE app_admin';
    EXECUTE IMMEDIATE 'GRANT USAGE ON PROCEDURE app_public.graph_delete(VARCHAR) TO APPLICATION ROLE app_user';

RETURN 'Service started. Check status, and when ready, get URL';
END;
$$;
GRANT USAGE ON PROCEDURE app_public.start_app(VARCHAR, VARCHAR) TO APPLICATION ROLE app_admin;

CREATE OR REPLACE PROCEDURE app_public.stop_app()
    RETURNS string
    LANGUAGE sql
    AS
$$
BEGIN
    DROP SERVICE IF EXISTS app_public.st_spcs;
END
$$;
GRANT USAGE ON PROCEDURE app_public.stop_app() TO APPLICATION ROLE app_admin;

-- Helpers to fetch service status and logs without requiring external application role switching
CREATE OR REPLACE PROCEDURE app_public.get_service_status()
    RETURNS VARIANT
    LANGUAGE SQL
    EXECUTE AS OWNER
AS
$$
DECLARE
    service_name STRING DEFAULT 'app_public.st_spcs';
BEGIN
    RETURN SYSTEM$GET_SERVICE_STATUS(:service_name);
END
$$;
GRANT USAGE ON PROCEDURE app_public.get_service_status() TO APPLICATION ROLE app_admin;
GRANT USAGE ON PROCEDURE app_public.get_service_status() TO APPLICATION ROLE app_user;

CREATE OR REPLACE PROCEDURE app_public.get_service_logs(instance_id STRING, container STRING, lines INTEGER)
    RETURNS STRING
    LANGUAGE SQL
    EXECUTE AS OWNER
AS
$$
DECLARE
    service_name STRING DEFAULT 'app_public.st_spcs';
BEGIN
    RETURN SYSTEM$GET_SERVICE_LOGS(:service_name, instance_id, container, lines);
END
$$;
GRANT USAGE ON PROCEDURE app_public.get_service_logs(STRING, STRING, INTEGER) TO APPLICATION ROLE app_admin;
GRANT USAGE ON PROCEDURE app_public.get_service_logs(STRING, STRING, INTEGER) TO APPLICATION ROLE app_user;

-- List service containers as JSON
CREATE OR REPLACE PROCEDURE app_public.get_service_containers()
    RETURNS VARIANT
    LANGUAGE SQL
    EXECUTE AS OWNER
AS
$$
DECLARE
    service_name STRING DEFAULT 'app_public.st_spcs';
BEGIN
    EXECUTE IMMEDIATE 'SHOW SERVICE CONTAINERS IN SERVICE ' || :service_name;
    RETURN (
        SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
        FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
    );
END
$$;
GRANT USAGE ON PROCEDURE app_public.get_service_containers() TO APPLICATION ROLE app_admin;
GRANT USAGE ON PROCEDURE app_public.get_service_containers() TO APPLICATION ROLE app_user;

-- Sample data procedure for quick testing
CREATE OR REPLACE PROCEDURE app_public.load_sample_social_network()
    RETURNS STRING
    LANGUAGE SQL
    EXECUTE AS OWNER
AS
$$
BEGIN
    -- Create a small social network graph with 5 people
    LET result STRING;
    
    -- Create nodes using direct Cypher queries
    CALL app_public.graph_query('demo_social_network', 
        'CREATE (:Person {name: ''Alice'', age: 30, city: ''New York''}),
                (:Person {name: ''Bob'', age: 25, city: ''San Francisco''}),
                (:Person {name: ''Carol'', age: 35, city: ''Seattle''}),
                (:Person {name: ''David'', age: 28, city: ''Boston''}),
                (:Person {name: ''Eve'', age: 32, city: ''Chicago''})');
    
    -- Create relationships
    CALL app_public.graph_query('demo_social_network',
        'MATCH (a:Person {name: ''Alice''}), (b:Person {name: ''Bob''})
         CREATE (a)-[:KNOWS {since: 2020}]->(b)');
    
    CALL app_public.graph_query('demo_social_network',
        'MATCH (b:Person {name: ''Bob''}), (c:Person {name: ''Carol''})
         CREATE (b)-[:KNOWS {since: 2019}]->(c)');
    
    CALL app_public.graph_query('demo_social_network',
        'MATCH (a:Person {name: ''Alice''}), (d:Person {name: ''David''})
         CREATE (a)-[:KNOWS {since: 2021}]->(d)');
    
    CALL app_public.graph_query('demo_social_network',
        'MATCH (d:Person {name: ''David''}), (e:Person {name: ''Eve''})
         CREATE (d)-[:KNOWS {since: 2022}]->(e)');
    
    CALL app_public.graph_query('demo_social_network',
        'MATCH (c:Person {name: ''Carol''}), (e:Person {name: ''Eve''})
         CREATE (c)-[:KNOWS {since: 2018}]->(e)');
    
    RETURN 'Sample social network created successfully! Try: CALL app_public.graph_query(''demo_social_network'', ''MATCH (p:Person) RETURN p.name, p.city'')';
END
$$;
GRANT USAGE ON PROCEDURE app_public.load_sample_social_network() TO APPLICATION ROLE app_admin;
GRANT USAGE ON PROCEDURE app_public.load_sample_social_network() TO APPLICATION ROLE app_user;

