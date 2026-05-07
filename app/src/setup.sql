CREATE APPLICATION ROLE IF NOT EXISTS app_admin;
CREATE APPLICATION ROLE IF NOT EXISTS app_user;

-- Create schema for the application
CREATE SCHEMA IF NOT EXISTS app_public;
GRANT USAGE ON SCHEMA app_public TO APPLICATION ROLE app_admin;
GRANT USAGE ON SCHEMA app_public TO APPLICATION ROLE app_user;

-- Register callback for reference binding
CREATE OR REPLACE PROCEDURE app_public.register_callback(ref_name STRING, operation STRING, ref_or_alias STRING)
RETURNS STRING
LANGUAGE SQL
AS $$
BEGIN
  CASE (operation)
    WHEN 'ADD' THEN
      -- Bind the reference using SYSTEM$SET_REFERENCE
      CALL SYSTEM$SET_REFERENCE(:ref_name, :ref_or_alias);
    WHEN 'REMOVE' THEN
      -- Remove the reference binding
      CALL SYSTEM$REMOVE_REFERENCE(:ref_name, :ref_or_alias);
    WHEN 'CLEAR' THEN
      -- Clear all bindings for this reference
      CALL SYSTEM$REMOVE_ALL_REFERENCES(:ref_name);
    ELSE
      RETURN 'ERROR: Unknown operation: ' || operation;
  END CASE;
  RETURN 'Success';
EXCEPTION
  WHEN OTHER THEN
    RETURN 'ERROR: ' || SQLERRM;
END;
$$;
GRANT USAGE ON PROCEDURE app_public.register_callback(STRING, STRING, STRING) TO APPLICATION ROLE app_admin;

-- Helper procedure to check if table reference is bound
CREATE OR REPLACE PROCEDURE app_public.check_bound_table()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS $$
BEGIN
  -- Try to describe the reference to check if it's bound
  BEGIN
    DESCRIBE TABLE reference('consumer_data_table');
    RETURN 'Reference IS bound and accessible';
  EXCEPTION
    WHEN OTHER THEN
      RETURN 'Reference NOT bound or error: ' || SQLERRM;
  END;
END;
$$;
GRANT USAGE ON PROCEDURE app_public.check_bound_table() TO APPLICATION ROLE app_admin;
GRANT USAGE ON PROCEDURE app_public.check_bound_table() TO APPLICATION ROLE app_user;

-- Helper procedure to copy bound table data to stage
-- The caller owns the stage folder lifecycle. This helper only writes the
-- bound-table export into the supplied folder so direct callers cannot
-- accidentally delete pre-existing staged files.
CREATE OR REPLACE PROCEDURE app_public.copy_bound_table_to_stage(stage_folder VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  invalid_stage_folder EXCEPTION (-20001, 'Invalid stage folder name');
BEGIN
  IF (stage_folder IS NULL OR NOT REGEXP_LIKE(stage_folder, '^[A-Za-z0-9_-]+$')) THEN
    RAISE invalid_stage_folder;
  END IF;

  -- Copy data directly from the reference (no need to query alias)
  EXECUTE IMMEDIATE 'COPY INTO @app_public.staging/' || :stage_folder || '/' ||
                    ' FROM reference(''consumer_data_table'')' ||
                    ' FILE_FORMAT = (TYPE = CSV COMPRESSION = NONE)' ||
                    ' INCLUDE_QUERY_ID = TRUE';
  RETURN 'Success';
EXCEPTION
  WHEN OTHER THEN
    RETURN 'ERROR: Failed to copy data - ' || SQLERRM || '. Ensure table is bound via Apps → Permissions → Consumer Data Table';
END;
$$;
GRANT USAGE ON PROCEDURE app_public.copy_bound_table_to_stage(VARCHAR) TO APPLICATION ROLE app_admin;
GRANT USAGE ON PROCEDURE app_public.copy_bound_table_to_stage(VARCHAR) TO APPLICATION ROLE app_user;

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
    
    -- Create wrapper procedure for load_csv, load the data from bound consumer_table reference as csv files to staging area and then call load_csv_raw
    EXECUTE IMMEDIATE 'CREATE OR REPLACE PROCEDURE app_public.load_csv(graph_name VARCHAR, cypher_query VARCHAR)
        RETURNS VARIANT
        LANGUAGE JAVASCRIPT
        AS
        ''
        /*
         * Multi-part staging flow:
         * 1. Export the bound table into a UUID-named folder under app_public.staging.
         *    COPY INTO may create multiple CSV part files for large tables.
         * 2. LIST the folder, validate each generated basename, and sort the names
         *    for deterministic retry behavior.
         * 3. COPY FILES each part back to the stage root before calling load_csv_raw.
         *    The FalkorDB service already expects csv_file to be a flat filename in
         *    /var/lib/FalkorDB/import, so nested stage paths are intentionally hidden.
         *    INCLUDE_QUERY_ID in COPY INTO keeps these root filenames unique across
         *    concurrent load_csv calls.
         * 4. Remove both the temporary folder and root copies. Cleanup failures are
         *    surfaced to the caller so leaked stage files are visible.
         */
        var uuidResult = snowflake.execute({sqlText: "SELECT REPLACE(UUID_STRING(), ''''-'''', ''''_'''')"});
        uuidResult.next();
        var stageFolder = "consumer_data_" + uuidResult.getColumnValue(1);
        var rootCsvFiles = [];

        function removeStagePath(path) {
            snowflake.execute({sqlText: "REMOVE " + path});
        }

        function cleanupTemporaryFiles() {
            var cleanupErrors = [];
            try {
                removeStagePath("@app_public.staging/" + stageFolder + "/");
            } catch (folderErr) {
                cleanupErrors.push("folder cleanup failed: " + folderErr.message);
            }

            for (var i = 0; i < rootCsvFiles.length; i++) {
                try {
                    removeStagePath("@app_public.staging/" + rootCsvFiles[i]);
                } catch (fileErr) {
                    cleanupErrors.push("file cleanup failed for " + rootCsvFiles[i] + ": " + fileErr.message);
                }
            }

            return cleanupErrors;
        }

        // Export bound table data to CSV part files using helper procedure
        try {
            var exportResult = snowflake.execute({
                sqlText: "CALL app_public.copy_bound_table_to_stage(?)",
                binds: [stageFolder]
            });
            if (!exportResult.next()) {
                throw new Error("Export helper returned no result.");
            }
            var exportStatus = exportResult.getColumnValue(1);
            if (typeof exportStatus === "string" && exportStatus.indexOf("ERROR:") === 0) {
                throw new Error(exportStatus);
            }
        } catch (err) {
            var exportCleanupErrors = cleanupTemporaryFiles();
            var exportMessage = "Failed to export data from bound table. Ensure a table is bound in the app configuration. Error: " + err.message;
            if (exportCleanupErrors.length > 0) {
                exportMessage += " Cleanup also failed: " + exportCleanupErrors.join("; ");
            }
            throw new Error(exportMessage);
        }
        
        try {
            var listResult = snowflake.execute({
                sqlText: "LIST @app_public.staging/" + stageFolder + "/"
            });

            var stagedFiles = [];
            var loadResults = [];
            while (listResult.next()) {
                var stagedName = listResult.getColumnValue(1);
                var folderPrefix = stageFolder + "/";
                var folderIndex = stagedName.lastIndexOf(folderPrefix);
                if (folderIndex < 0) {
                    throw new Error("Unexpected staged file path: " + stagedName);
                }
                var csvFilename = stagedName.substring(folderIndex + folderPrefix.length);
                if (!/^[A-Za-z0-9_.-]+$/.test(csvFilename)) {
                    throw new Error("Unexpected staged file name: " + csvFilename);
                }
                stagedFiles.push(csvFilename);
            }

            if (stagedFiles.length === 0) {
                var emptyCleanupErrors = cleanupTemporaryFiles();
                if (emptyCleanupErrors.length > 0) {
                    throw new Error("No rows were exported, and cleanup failed: " + emptyCleanupErrors.join("; "));
                }
                return [];
            }

            stagedFiles.sort();

            // Root filenames stay invocation-unique because COPY INTO uses INCLUDE_QUERY_ID.
            for (var copyIndex = 0; copyIndex < stagedFiles.length; copyIndex++) {
                var rootCsvFilename = stagedFiles[copyIndex];
                rootCsvFiles.push(rootCsvFilename);
                snowflake.execute({
                    sqlText: "COPY FILES INTO @app_public.staging FROM @app_public.staging/" + stageFolder + "/ FILES = (''''" + rootCsvFilename + "'''')"
                });
            }

            for (var loadIndex = 0; loadIndex < rootCsvFiles.length; loadIndex++) {
                var result = snowflake.execute({
                    sqlText: "SELECT app_public.load_csv_raw({''''graph_name'''': ?, ''''csv_file'''': ?, ''''cypher_query'''': ?})",
                    binds: [GRAPH_NAME, rootCsvFiles[loadIndex], CYPHER_QUERY]
                });
                loadResults.push(result.next() ? result.getColumnValue(1) : null);
            }

            var cleanupErrors = cleanupTemporaryFiles();
            if (cleanupErrors.length > 0) {
                throw new Error("Loaded CSV data but failed to clean up temporary stage files: " + cleanupErrors.join("; "));
            }
            
            return loadResults.length === 1 ? loadResults[0] : loadResults;
        } catch (err) {
            var errorCleanupErrors = cleanupTemporaryFiles();
            if (errorCleanupErrors.length > 0) {
                throw new Error(err.message + " Cleanup also failed: " + errorCleanupErrors.join("; "));
            }
            throw err;
        }
        ''';

    
    EXECUTE IMMEDIATE 'GRANT USAGE ON FUNCTION app_public.load_csv_raw(OBJECT) TO APPLICATION ROLE app_admin';
    EXECUTE IMMEDIATE 'GRANT USAGE ON FUNCTION app_public.load_csv_raw(OBJECT) TO APPLICATION ROLE app_user';
    EXECUTE IMMEDIATE 'GRANT USAGE ON PROCEDURE app_public.load_csv(VARCHAR, VARCHAR) TO APPLICATION ROLE app_admin';
    EXECUTE IMMEDIATE 'GRANT USAGE ON PROCEDURE app_public.load_csv(VARCHAR, VARCHAR) TO APPLICATION ROLE app_user';

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
    
    -- Create nodes using MERGE (prevents duplicates if run multiple times)
    CALL app_public.graph_query('demo_social_network',
        'MERGE (:Person {name: ''Alice'', age: 30, city: ''New York''})');
    CALL app_public.graph_query('demo_social_network',
        'MERGE (:Person {name: ''Bob'', age: 25, city: ''San Francisco''})');
    CALL app_public.graph_query('demo_social_network',
        'MERGE (:Person {name: ''Carol'', age: 35, city: ''Seattle''})');
    CALL app_public.graph_query('demo_social_network',
        'MERGE (:Person {name: ''David'', age: 28, city: ''Boston''})');
    CALL app_public.graph_query('demo_social_network',
        'MERGE (:Person {name: ''Eve'', age: 32, city: ''Chicago''})');

    -- Create relationships using MERGE (prevents duplicates if run multiple times)
    CALL app_public.graph_query('demo_social_network',
        'MATCH (a:Person {name: ''Alice''}), (b:Person {name: ''Bob''})
         MERGE (a)-[:KNOWS {since: 2020}]->(b)');

    CALL app_public.graph_query('demo_social_network',
        'MATCH (b:Person {name: ''Bob''}), (c:Person {name: ''Carol''})
         MERGE (b)-[:KNOWS {since: 2019}]->(c)');

    CALL app_public.graph_query('demo_social_network',
        'MATCH (a:Person {name: ''Alice''}), (d:Person {name: ''David''})
         MERGE (a)-[:KNOWS {since: 2021}]->(d)');

    CALL app_public.graph_query('demo_social_network',
        'MATCH (d:Person {name: ''David''}), (e:Person {name: ''Eve''})
         MERGE (d)-[:KNOWS {since: 2022}]->(e)');

    CALL app_public.graph_query('demo_social_network',
        'MATCH (c:Person {name: ''Carol''}), (e:Person {name: ''Eve''})
         MERGE (c)-[:KNOWS {since: 2018}]->(e)');
    
    RETURN 'Sample social network created successfully! Try: CALL app_public.graph_query(''demo_social_network'', ''MATCH (p:Person) RETURN p.name, p.city'')';
END
$$;
GRANT USAGE ON PROCEDURE app_public.load_sample_social_network() TO APPLICATION ROLE app_admin;
GRANT USAGE ON PROCEDURE app_public.load_sample_social_network() TO APPLICATION ROLE app_user;
