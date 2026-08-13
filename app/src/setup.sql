CREATE APPLICATION ROLE IF NOT EXISTS app_admin;
CREATE APPLICATION ROLE IF NOT EXISTS app_user;

-- Create schema for the application
CREATE SCHEMA IF NOT EXISTS app_public;
GRANT USAGE ON SCHEMA app_public TO APPLICATION ROLE app_admin;
GRANT USAGE ON SCHEMA app_public TO APPLICATION ROLE app_user;

-- Records the compute resources start_app() was given, so stop_app()/suspend_app()
-- can release them later. Without this the app creates a compute pool it can never
-- suspend, and the pool keeps billing per node-hour after the app is stopped.
CREATE TABLE IF NOT EXISTS app_public.app_config (
    config_key STRING PRIMARY KEY,
    config_value STRING,
    updated_on TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);
GRANT SELECT ON TABLE app_public.app_config TO APPLICATION ROLE app_admin;

-- Cortex Agent schemas. These mirror the Snowflake-native agent surface used by
-- graph analytics apps: GRAPH is the public API, AGENT_TOOLS contains callable
-- tools, and AGENT_ARTEFACTS stores per-agent configuration.
CREATE SCHEMA IF NOT EXISTS graph;
CREATE SCHEMA IF NOT EXISTS agent_tools;
CREATE SCHEMA IF NOT EXISTS agent_artefacts;
GRANT USAGE ON SCHEMA graph TO APPLICATION ROLE app_admin;
GRANT USAGE ON SCHEMA graph TO APPLICATION ROLE app_user;
GRANT USAGE ON SCHEMA agent_tools TO APPLICATION ROLE app_admin;
GRANT USAGE ON SCHEMA agent_tools TO APPLICATION ROLE app_user;
GRANT USAGE ON SCHEMA agent_artefacts TO APPLICATION ROLE app_admin;

CREATE TABLE IF NOT EXISTS agent_artefacts.agent_config (
    agent_name STRING PRIMARY KEY,
    source_schema STRING NOT NULL,
    working_schema STRING NOT NULL,
    warehouse_name STRING,
    created_on TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    updated_on TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);
ALTER TABLE IF EXISTS agent_artefacts.agent_config ALTER COLUMN warehouse_name DROP NOT NULL;
GRANT SELECT ON TABLE agent_artefacts.agent_config TO APPLICATION ROLE app_admin;

CREATE TABLE IF NOT EXISTS agent_artefacts.agent_context (
    agent_name STRING,
    context_key STRING,
    context_value VARIANT,
    updated_on TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (agent_name, context_key)
);
GRANT SELECT ON TABLE agent_artefacts.agent_context TO APPLICATION ROLE app_admin;

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

-- Store FalkorDB engine version (updated each release via docker_push.sh)
CREATE TABLE IF NOT EXISTS app_public.app_metadata (key STRING, value STRING);
MERGE INTO app_public.app_metadata t USING (SELECT 'falkordb_version' AS key, 'text-to-cypher:v0.2.6' AS value) s
  ON t.key = s.key WHEN MATCHED THEN UPDATE SET value = s.value WHEN NOT MATCHED THEN INSERT VALUES (s.key, s.value);
GRANT SELECT ON TABLE app_public.app_metadata TO APPLICATION ROLE app_admin;
GRANT SELECT ON TABLE app_public.app_metadata TO APPLICATION ROLE app_user;

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
    RUNTIME_VERSION = '3.10'
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


-- Internal helper: the current state of a compute pool, or NULL when the pool does
-- not exist or the app cannot see it (a consumer-owned pool). Used to word billing
-- messages from the pool's real state rather than from what was just requested.
CREATE OR REPLACE PROCEDURE app_public.compute_pool_state(poolname VARCHAR)
    RETURNS STRING
    LANGUAGE SQL
    EXECUTE AS OWNER
AS
$$
DECLARE
    pool_state STRING DEFAULT NULL;
BEGIN
    IF (poolname IS NULL OR NOT REGEXP_LIKE(UPPER(poolname), '^[A-Z_][A-Z0-9_$]*$')) THEN
        RETURN NULL;
    END IF;

    BEGIN
        EXECUTE IMMEDIATE 'SHOW COMPUTE POOLS LIKE ''' || poolname || '''';
        -- The name is matched exactly rather than collapsed with MAX: LIKE treats '_'
        -- as a single-character wildcard, so this pattern can return several pools,
        -- and MAX over the state column would return 'SUSPENDED' in preference to
        -- 'ACTIVE' - reporting "not billing" for a pool that is. MAX over the
        -- filtered result is over at most one row.
        pool_state := (
            SELECT UPPER(MAX("state"))
            FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
            WHERE UPPER("name") = UPPER(:poolname)
        );
    EXCEPTION
        WHEN OTHER THEN
            pool_state := NULL;
    END;

    RETURN pool_state;
END
$$;

-- Internal helper: suspend or resume a compute pool.
-- Returns an empty string on success, or a warning when the app cannot control the
-- pool - for example when the consumer created it (scripts/instantiate.sql) and only
-- granted the app USAGE on it.
CREATE OR REPLACE PROCEDURE app_public.set_compute_pool_state(poolname VARCHAR, new_state VARCHAR)
    RETURNS STRING
    LANGUAGE SQL
    EXECUTE AS OWNER
AS
$$
DECLARE
    action STRING DEFAULT UPPER(new_state);
    alter_err STRING DEFAULT NULL;
    pool_state STRING DEFAULT NULL;
    invalid_pool_name EXCEPTION (-20020, 'Invalid compute pool name.');
    invalid_state EXCEPTION (-20021, 'Compute pool state must be SUSPEND or RESUME.');
BEGIN
    IF (poolname IS NULL OR NOT REGEXP_LIKE(UPPER(poolname), '^[A-Z_][A-Z0-9_$]*$')) THEN
        RAISE invalid_pool_name;
    END IF;
    IF (action <> 'SUSPEND' AND action <> 'RESUME') THEN
        RAISE invalid_state;
    END IF;

    BEGIN
        EXECUTE IMMEDIATE 'ALTER COMPUTE POOL ' || poolname || ' ' || action;
        RETURN '';
    EXCEPTION
        WHEN OTHER THEN
            alter_err := SQLERRM;
    END;

    -- The ALTER also fails when the pool is already in, or already moving to, the
    -- requested state - which is success as far as the caller is concerned. The
    -- state is re-read instead of pattern-matching Snowflake's error text, so a
    -- reworded error cannot turn a healthy call into a false failure, and a real
    -- failure (no ownership, no such pool) is still reported.
    CALL app_public.compute_pool_state(:poolname) INTO :pool_state;

    IF (action = 'SUSPEND' AND pool_state IN ('SUSPENDED', 'SUSPENDING', 'STOPPING')) THEN
        RETURN '';
    END IF;
    IF (action = 'RESUME' AND pool_state IN ('ACTIVE', 'IDLE', 'STARTING', 'RESUMING')) THEN
        RETURN '';
    END IF;

    RETURN 'Compute pool ' || poolname || ' could not be '
        || IFF(action = 'SUSPEND', 'suspended', 'resumed') || ' (' || alter_err || ').';
END
$$;

CREATE OR REPLACE PROCEDURE app_public.start_app(poolname VARCHAR, whname VARCHAR)
    RETURNS string
    LANGUAGE sql
    AS $$
BEGIN
        -- Refuse an unusable identifier before anything is created. IDENTIFIER()
        -- accepts a delimited name, so a quoted or hyphenated pool name creates a
        -- pool that set_compute_pool_state() then refuses to touch - and stop_app(),
        -- suspend_app() and resume_app() all CALL it without a handler, so that pool
        -- could never be suspended by the app. This can only refuse a call before it
        -- creates anything; every name that works today still works.
        IF (poolname IS NULL OR NOT RLIKE(poolname, '[A-Za-z_][A-Za-z0-9_$]*')) THEN
            RETURN 'Invalid compute pool name. Use an unquoted Snowflake identifier, '
                || 'such as FALKORDB_POOL. Nothing was created by this call.';
        END IF;
        IF (whname IS NULL OR NOT RLIKE(whname, '[A-Za-z_][A-Za-z0-9_$]*')) THEN
            RETURN 'Invalid warehouse name. Use an unquoted Snowflake identifier, '
                || 'such as FALKORDB_WH. Nothing was created by this call.';
        END IF;

        -- Create compute pool if it doesn't exist.
        -- AUTO_SUSPEND_SECS is a backstop only: it fires when the pool is idle
        -- (no running services or jobs). While st_spcs is up the pool is never idle,
        -- so stopping the demo still requires stop_app() or suspend_app().
        EXECUTE IMMEDIATE 'CREATE COMPUTE POOL IF NOT EXISTS IDENTIFIER(?) 
            MIN_NODES = 1 
            MAX_NODES = 1
            INSTANCE_FAMILY = CPU_X64_S
            AUTO_RESUME = TRUE
            AUTO_SUSPEND_SECS = 300'
            USING (poolname);

        -- CREATE ... IF NOT EXISTS leaves an existing pool untouched, so a pool
        -- from an earlier install keeps whatever AUTO_SUSPEND_SECS it had (the
        -- Snowflake default is 3600). Apply the backstop to those too. Best
        -- effort: the pool may be consumer-owned. The name is validated before
        -- interpolation because ALTER COMPUTE POOL takes a literal identifier.
        IF (REGEXP_LIKE(UPPER(poolname), '^[A-Z_][A-Z0-9_$]*$')) THEN
            BEGIN
                EXECUTE IMMEDIATE 'ALTER COMPUTE POOL ' || poolname || ' SET AUTO_SUSPEND_SECS = 300';
            EXCEPTION
                WHEN OTHER THEN
                    NULL;
            END;
        END IF;

        -- Remember which pool/warehouse this app was started with, so stop_app()
        -- and suspend_app() can release them.
        MERGE INTO app_public.app_config AS t
        USING (
            SELECT 'compute_pool' AS config_key, :poolname AS config_value
            UNION ALL
            SELECT 'warehouse' AS config_key, :whname AS config_value
        ) AS s
        ON t.config_key = s.config_key
        WHEN MATCHED THEN UPDATE SET config_value = s.config_value, updated_on = CURRENT_TIMESTAMP()
        WHEN NOT MATCHED THEN INSERT (config_key, config_value) VALUES (s.config_key, s.config_value);

        -- The pool may be suspended from a previous suspend_app()/stop_app().
        -- AUTO_RESUME does not cover an explicitly suspended pool, so resume it.
        CALL app_public.set_compute_pool_state(:poolname, 'RESUME');
        
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

    -- If the service already existed but was suspended by suspend_app(), the
    -- CREATE above is a no-op and the service stays suspended. Resume it.
    BEGIN
        ALTER SERVICE app_public.st_spcs RESUME;
    EXCEPTION
        WHEN OTHER THEN
            NULL; -- already running
    END;

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

    -- Create wrapper procedure for weighted shortest path (algo.SPpaths).
    -- Returns the single cheapest path between two nodes, minimizing the sum
    -- of weight_prop along the path instead of just counting hops. The search
    -- is unbounded in depth and pathCount is fixed at 1: this is the only
    -- combination where algo.SPpaths uses its fast Dijkstra strategy
    -- (requires FalkorDB >= 4.20); maxLen or pathCount > 1 fall back to a
    -- slow enumeration that can stall the service on dense graphs.
    EXECUTE IMMEDIATE 'CREATE OR REPLACE PROCEDURE app_public.shortest_path(graph_name VARCHAR, node_label VARCHAR, node_prop VARCHAR, source_value VARCHAR, target_value VARCHAR, rel_type VARCHAR, weight_prop VARCHAR)
        RETURNS STRING
        LANGUAGE SQL
        AS
        ''DECLARE
            cypher STRING;
        BEGIN
            cypher := ''''MATCH (src:'''' || :node_label || '''' {'''' || :node_prop || '''': "'''' || :source_value || ''''"}), (dst:'''' || :node_label || '''' {'''' || :node_prop || '''': "'''' || :target_value || ''''"}) '''' ||
                      ''''CALL algo.SPpaths({sourceNode: src, targetNode: dst, relTypes: ["'''' || :rel_type || ''''"], weightProp: "'''' || :weight_prop || ''''", pathCount: 1}) '''' ||
                      ''''YIELD path, pathWeight '''' ||
                      ''''RETURN pathWeight, [n IN nodes(path) | n.'''' || :node_prop || ''''] AS route'''';
            RETURN app_public.graph_query_raw({''''graph_name'''': :graph_name, ''''query'''': :cypher});
        END''';

    EXECUTE IMMEDIATE 'GRANT USAGE ON PROCEDURE app_public.shortest_path(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR) TO APPLICATION ROLE app_admin';
    EXECUTE IMMEDIATE 'GRANT USAGE ON PROCEDURE app_public.shortest_path(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR) TO APPLICATION ROLE app_user';

    -- Create wrapper procedure for PageRank (algo.pageRank). Scores every
    -- node by importance: a node ranks high when many other important nodes
    -- point to it. Returns the top limit_count nodes with their scores,
    -- highest first, showing node_prop for each node.
    EXECUTE IMMEDIATE 'CREATE OR REPLACE PROCEDURE app_public.page_rank(graph_name VARCHAR, node_label VARCHAR, rel_type VARCHAR, node_prop VARCHAR, limit_count INTEGER)
        RETURNS STRING
        LANGUAGE SQL
        AS
        ''DECLARE
            cypher STRING;
        BEGIN
            cypher := ''''CALL algo.pageRank("'''' || :node_label || ''''", "'''' || :rel_type || ''''") '''' ||
                      ''''YIELD node, score '''' ||
                      ''''RETURN node.'''' || :node_prop || '''' AS node, score '''' ||
                      ''''ORDER BY score DESC LIMIT '''' || :limit_count;
            RETURN app_public.graph_query_raw({''''graph_name'''': :graph_name, ''''query'''': :cypher});
        END''';

    EXECUTE IMMEDIATE 'GRANT USAGE ON PROCEDURE app_public.page_rank(VARCHAR, VARCHAR, VARCHAR, VARCHAR, INTEGER) TO APPLICATION ROLE app_admin';
    EXECUTE IMMEDIATE 'GRANT USAGE ON PROCEDURE app_public.page_rank(VARCHAR, VARCHAR, VARCHAR, VARCHAR, INTEGER) TO APPLICATION ROLE app_user';

    -- Cortex Agent tool functions. Cortex Agents call these as generic tools
    -- from Snowflake; the functions delegate to the app-owned SPCS service.
    EXECUTE IMMEDIATE 'CREATE OR REPLACE FUNCTION agent_tools.get_context(input_agent_name VARCHAR)
        RETURNS OBJECT
        LANGUAGE SQL
        AS
        ''(
            SELECT OBJECT_CONSTRUCT(
                ''''agent_name'''', cfg.agent_name,
                ''''source_schema'''', cfg.source_schema,
                ''''working_schema'''', cfg.working_schema,
                ''''guidance'''', ''''Use run_cypher for Cypher execution, inspect_graph to discover labels/relationships/properties, and list_graphs to discover loaded graphs. Generate read-only Cypher for exploratory questions unless the user explicitly asks to mutate graph data. For loading, the user/admin must bind consumer_data_table first; then generate LOAD CSV mapping Cypher, ask for confirmation, and call load_csv. Agent tools use the caller role default warehouse, like Snowflake Cortex Agent custom tools.''''
            )
            FROM agent_artefacts.agent_config cfg
            WHERE cfg.agent_name = UPPER(input_agent_name)
        )''';

    EXECUTE IMMEDIATE 'CREATE OR REPLACE FUNCTION agent_tools.list_graphs(input_agent_name VARCHAR)
        RETURNS STRING
        LANGUAGE SQL
        AS
        ''app_public.graph_list_raw({})''';

    EXECUTE IMMEDIATE 'CREATE OR REPLACE FUNCTION agent_tools.inspect_graph(input_agent_name VARCHAR, graph_name VARCHAR)
        RETURNS OBJECT
        LANGUAGE SQL
        AS
        ''OBJECT_CONSTRUCT(
            ''''labels'''', app_public.graph_query_raw(OBJECT_CONSTRUCT(''''graph_name'''', graph_name, ''''query'''', ''''CALL db.labels()'''')),
            ''''relationship_types'''', app_public.graph_query_raw(OBJECT_CONSTRUCT(''''graph_name'''', graph_name, ''''query'''', ''''CALL db.relationshipTypes()'''')),
            ''''property_keys'''', app_public.graph_query_raw(OBJECT_CONSTRUCT(''''graph_name'''', graph_name, ''''query'''', ''''CALL db.propertyKeys()''''))
        )''';

    EXECUTE IMMEDIATE 'CREATE OR REPLACE FUNCTION agent_tools.graph_stats(input_agent_name VARCHAR, graph_name VARCHAR)
        RETURNS OBJECT
        LANGUAGE SQL
        AS
        ''OBJECT_CONSTRUCT(
            ''''node_count'''', app_public.graph_query_raw(OBJECT_CONSTRUCT(''''graph_name'''', graph_name, ''''query'''', ''''MATCH (n) RETURN count(n) AS node_count'''')),
            ''''relationship_count'''', app_public.graph_query_raw(OBJECT_CONSTRUCT(''''graph_name'''', graph_name, ''''query'''', ''''MATCH ()-[r]->() RETURN count(r) AS relationship_count''''))
        )''';

    EXECUTE IMMEDIATE 'CREATE OR REPLACE FUNCTION agent_tools.load_csv_guidance(input_agent_name VARCHAR)
        RETURNS OBJECT
        LANGUAGE SQL
        AS
        ''(
            SELECT OBJECT_CONSTRUCT(
                ''''source_schema'''', cfg.source_schema,
                ''''working_schema'''', cfg.working_schema,
                ''''tool'''', CURRENT_DATABASE() || ''''.AGENT_TOOLS.LOAD_CSV(input_agent_name, graph_name, cypher_query)'''',
                ''''binding_required'''', ''''The user/admin must bind consumer_data_table before loading. If loading fails with a reference error, ask the user to bind a Snowflake table through the app reference flow before retrying.'''',
                ''''required_pattern'''', ''''Use LOAD CSV FROM ''''''''file://consumer_data.csv'''''''' AS row. Access columns by index: row[0], row[1], row[2]. Prefer MERGE for retry-safe loads.'''',
                ''''index_guidance'''', ''''Before large MERGE loads, create an index on the matched label/property, for example CREATE INDEX ON :Airport(id).''''
            )
            FROM agent_artefacts.agent_config cfg
            WHERE cfg.agent_name = UPPER(input_agent_name)
        )''';

    EXECUTE IMMEDIATE 'CREATE OR REPLACE FUNCTION agent_tools.run_cypher(input_agent_name VARCHAR, graph_name VARCHAR, cypher_query VARCHAR)
        RETURNS OBJECT
        LANGUAGE SQL
        AS
        ''OBJECT_CONSTRUCT(
            ''''graph_name'''', graph_name,
            ''''cypher_query'''', cypher_query,
            ''''result'''', app_public.graph_query_raw(OBJECT_CONSTRUCT(''''graph_name'''', graph_name, ''''query'''', cypher_query))
        )''';

    EXECUTE IMMEDIATE 'CREATE OR REPLACE PROCEDURE agent_tools.text_to_cypher(input_agent_name VARCHAR, graph_name VARCHAR, user_question VARCHAR, model_name VARCHAR)
        RETURNS VARIANT
        LANGUAGE JAVASCRIPT
        EXECUTE AS OWNER
        AS
        ''
        var defaultModel = "claude-4-sonnet";
        var model = MODEL_NAME === null || MODEL_NAME === undefined || String(MODEL_NAME).trim() === ""
            ? defaultModel
            : String(MODEL_NAME).trim();

        function scalar(sqlText, binds) {
            var statement = snowflake.execute({sqlText: sqlText, binds: binds || []});
            if (!statement.next()) {
                return null;
            }
            return statement.getColumnValue(1);
        }

        function cleanCypher(text) {
            if (text === null || text === undefined) {
                return "";
            }
            var cleaned = String(text).trim();
            cleaned = cleaned.replace(/^```[a-zA-Z]*\\\\s*/, "").replace(/```$/, "").trim();
            return cleaned;
        }

        if (!INPUT_AGENT_NAME || !GRAPH_NAME || !USER_QUESTION) {
            throw new Error("input_agent_name, graph_name, and user_question are required.");
        }
        if (model.length > 128 || !/^[A-Za-z0-9_.:-]+$/.test(model)) {
            throw new Error("model_name must contain only letters, digits, underscores, dots, colons, or hyphens.");
        }

        var labels = scalar(
            "SELECT app_public.graph_query_raw(OBJECT_CONSTRUCT(''''graph_name'''', ?, ''''query'''', ''''CALL db.labels()''''))",
            [GRAPH_NAME]
        );
        var relationshipTypes = scalar(
            "SELECT app_public.graph_query_raw(OBJECT_CONSTRUCT(''''graph_name'''', ?, ''''query'''', ''''CALL db.relationshipTypes()''''))",
            [GRAPH_NAME]
        );
        var propertyKeys = scalar(
            "SELECT app_public.graph_query_raw(OBJECT_CONSTRUCT(''''graph_name'''', ?, ''''query'''', ''''CALL db.propertyKeys()''''))",
            [GRAPH_NAME]
        );
        var stats = scalar(
            "SELECT OBJECT_CONSTRUCT(''''node_count'''', app_public.graph_query_raw(OBJECT_CONSTRUCT(''''graph_name'''', ?, ''''query'''', ''''MATCH (n) RETURN count(n) AS node_count'''')), ''''relationship_count'''', app_public.graph_query_raw(OBJECT_CONSTRUCT(''''graph_name'''', ?, ''''query'''', ''''MATCH ()-[r]->() RETURN count(r) AS relationship_count'''')))",
            [GRAPH_NAME, GRAPH_NAME]
        );

        var prompt = [
            "You generate FalkorDB Cypher for Snowflake Agent tools.",
            "Return only one Cypher query. Do not include markdown fences or explanations.",
            "Prefer read-only MATCH/RETURN queries unless the user explicitly asks to mutate data.",
            "Avoid unsupported subquery forms and avoid expensive all-graph anti-joins when a bounded approximation is safer.",
            "If the exact query is likely too expensive, generate a safer bounded query with LIMIT and selective filters.",
            "Graph name: " + GRAPH_NAME,
            "Labels: " + labels,
            "Relationship types: " + relationshipTypes,
            "Property keys: " + propertyKeys,
            "Graph stats: " + JSON.stringify(stats),
            "User question: " + USER_QUESTION
        ].join("\\\\n");

        var rawResponse = scalar(
            "SELECT SNOWFLAKE.CORTEX.COMPLETE(?, ?)",
            [model, prompt]
        );

        return {
            model: model,
            graph_name: GRAPH_NAME,
            question: USER_QUESTION,
            schema_context: {
                labels: labels,
                relationship_types: relationshipTypes,
                property_keys: propertyKeys,
                stats: stats
            },
            cypher: cleanCypher(rawResponse),
            raw_response: rawResponse,
            note: "Review the generated Cypher before calling run_cypher. Ask for confirmation before running mutating queries."
        };
        ''';

    EXECUTE IMMEDIATE 'CREATE OR REPLACE PROCEDURE agent_tools.text_to_cypher(input_agent_name VARCHAR, graph_name VARCHAR, user_question VARCHAR)
        RETURNS VARIANT
        LANGUAGE SQL
        EXECUTE AS OWNER
        AS
        ''DECLARE
            generated VARIANT;
        BEGIN
            CALL agent_tools.text_to_cypher(:input_agent_name, :graph_name, :user_question, NULL) INTO :generated;
            RETURN generated;
        END''';

    EXECUTE IMMEDIATE 'CREATE OR REPLACE PROCEDURE agent_tools.load_csv(input_agent_name VARCHAR, graph_name VARCHAR, cypher_query VARCHAR)
        RETURNS VARIANT
        LANGUAGE SQL
        AS
        ''DECLARE
            configured_agent_count NUMBER;
            load_result VARIANT;
            missing_agent EXCEPTION (-20020, ''''Unknown FalkorDB agent. Call graph.create_agent first.'''' );
        BEGIN
            SELECT COUNT(*) INTO :configured_agent_count
            FROM agent_artefacts.agent_config
            WHERE agent_name = UPPER(:input_agent_name);

            IF (configured_agent_count = 0) THEN
                RAISE missing_agent;
            END IF;

            CALL app_public.load_csv(:graph_name, :cypher_query) INTO :load_result;
            RETURN load_result;
        END''';

    EXECUTE IMMEDIATE 'GRANT USAGE ON FUNCTION agent_tools.get_context(VARCHAR) TO APPLICATION ROLE app_admin';
    EXECUTE IMMEDIATE 'GRANT USAGE ON FUNCTION agent_tools.get_context(VARCHAR) TO APPLICATION ROLE app_user';
    EXECUTE IMMEDIATE 'GRANT USAGE ON FUNCTION agent_tools.list_graphs(VARCHAR) TO APPLICATION ROLE app_admin';
    EXECUTE IMMEDIATE 'GRANT USAGE ON FUNCTION agent_tools.list_graphs(VARCHAR) TO APPLICATION ROLE app_user';
    EXECUTE IMMEDIATE 'GRANT USAGE ON FUNCTION agent_tools.inspect_graph(VARCHAR, VARCHAR) TO APPLICATION ROLE app_admin';
    EXECUTE IMMEDIATE 'GRANT USAGE ON FUNCTION agent_tools.inspect_graph(VARCHAR, VARCHAR) TO APPLICATION ROLE app_user';
    EXECUTE IMMEDIATE 'GRANT USAGE ON FUNCTION agent_tools.graph_stats(VARCHAR, VARCHAR) TO APPLICATION ROLE app_admin';
    EXECUTE IMMEDIATE 'GRANT USAGE ON FUNCTION agent_tools.graph_stats(VARCHAR, VARCHAR) TO APPLICATION ROLE app_user';
    EXECUTE IMMEDIATE 'GRANT USAGE ON FUNCTION agent_tools.load_csv_guidance(VARCHAR) TO APPLICATION ROLE app_admin';
    EXECUTE IMMEDIATE 'GRANT USAGE ON FUNCTION agent_tools.load_csv_guidance(VARCHAR) TO APPLICATION ROLE app_user';
    EXECUTE IMMEDIATE 'GRANT USAGE ON FUNCTION agent_tools.run_cypher(VARCHAR, VARCHAR, VARCHAR) TO APPLICATION ROLE app_admin';
    EXECUTE IMMEDIATE 'GRANT USAGE ON FUNCTION agent_tools.run_cypher(VARCHAR, VARCHAR, VARCHAR) TO APPLICATION ROLE app_user';
    EXECUTE IMMEDIATE 'GRANT USAGE ON PROCEDURE agent_tools.text_to_cypher(VARCHAR, VARCHAR, VARCHAR) TO APPLICATION ROLE app_admin';
    EXECUTE IMMEDIATE 'GRANT USAGE ON PROCEDURE agent_tools.text_to_cypher(VARCHAR, VARCHAR, VARCHAR) TO APPLICATION ROLE app_user';
    EXECUTE IMMEDIATE 'GRANT USAGE ON PROCEDURE agent_tools.text_to_cypher(VARCHAR, VARCHAR, VARCHAR, VARCHAR) TO APPLICATION ROLE app_admin';
    EXECUTE IMMEDIATE 'GRANT USAGE ON PROCEDURE agent_tools.text_to_cypher(VARCHAR, VARCHAR, VARCHAR, VARCHAR) TO APPLICATION ROLE app_user';
    EXECUTE IMMEDIATE 'GRANT USAGE ON PROCEDURE agent_tools.load_csv(VARCHAR, VARCHAR, VARCHAR) TO APPLICATION ROLE app_admin';
    EXECUTE IMMEDIATE 'GRANT USAGE ON PROCEDURE agent_tools.load_csv(VARCHAR, VARCHAR, VARCHAR) TO APPLICATION ROLE app_user';

RETURN 'Service started. Check status, and when ready, get URL';
END;
$$;
GRANT USAGE ON PROCEDURE app_public.start_app(VARCHAR, VARCHAR) TO APPLICATION ROLE app_admin;

CREATE OR REPLACE PROCEDURE app_public.start_app(poolname VARCHAR, whname VARCHAR, options OBJECT)
    RETURNS STRING
    LANGUAGE JAVASCRIPT
    EXECUTE AS OWNER
AS
$$
function getOption(options, names, defaultValue) {
    if (!options) {
        return defaultValue;
    }
    for (var i = 0; i < names.length; i++) {
        if (Object.prototype.hasOwnProperty.call(options, names[i])) {
            return options[names[i]];
        }
    }
    return defaultValue;
}

function validateCpu(value, name) {
    var str = String(value);
    if (!/^(?:[0-9]+(?:[.][0-9]+)?|[0-9]+m)$/.test(str)) {
        throw new Error("Invalid " + name + ". Use a numeric CPU value such as 1, 1.5, or 500m.");
    }
    return str;
}

function validateMemory(value, name) {
    var str = String(value);
    if (!/^[0-9]+(?:[.][0-9]+)?(?:M|Mi|G|Gi)$/.test(str)) {
        throw new Error("Invalid " + name + ". Use memory with units M, Mi, G, or Gi, such as 2G or 4Gi.");
    }
    return str;
}

// The same identifier rule set_compute_pool_state() enforces. It is checked here so
// an unusable name is rejected before anything is created or recorded: that
// procedure RAISEs on a bad name, and stop_app()/suspend_app() call it without a
// handler, so a bad name recorded in app_config would make them abort with a raw
// error instead of returning their guidance.
function validateIdentifier(value, name, example) {
    if (value === null || value === undefined) {
        throw new Error("Missing " + name + ". Pass an unquoted Snowflake identifier, " +
            "such as " + example + ". Nothing was created by this call.");
    }
    var str = String(value);
    if (!/^[A-Za-z_][A-Za-z0-9_$]*$/.test(str)) {
        throw new Error("Invalid " + name + ". Use an unquoted Snowflake identifier, " +
            "such as " + example + ". Nothing was created by this call.");
    }
    return str;
}

validateIdentifier(POOLNAME, "compute pool name", "FALKORDB_POOL");
validateIdentifier(WHNAME, "warehouse name", "FALKORDB_WH");

var cpuRequest = validateCpu(getOption(OPTIONS, ["cpuRequest", "cpu_request", "CPUREQUEST", "CPU_REQUEST"], 1), "cpuRequest");
var memoryRequest = validateMemory(getOption(OPTIONS, ["memoryRequest", "memory_request", "MEMORYREQUEST", "MEMORY_REQUEST"], "2G"), "memoryRequest");
var cpuLimit = validateCpu(getOption(OPTIONS, ["cpuLimit", "cpu_limit", "CPULIMIT", "CPU_LIMIT"], 2), "cpuLimit");
var memoryLimit = validateMemory(getOption(OPTIONS, ["memoryLimit", "memory_limit", "MEMORYLIMIT", "MEMORY_LIMIT"], "4G"), "memoryLimit");

var spec = `spec:
  containers:
    - name: falkordb-server
      image: /falkordb_app/napp/img_repo/falkordb_server:latest
      command:
        - /bin/bash
        - -lc
        - sed -i -e '/^ALLOWED_ORIGINS=/d' -e '/^AUTH_URL=/d' -e '/^NEXTAUTH_URL=/d' /var/lib/falkordb/browser/.env.local && exec /entrypoint.sh
      env:
        AUTH_TRUST_HOST: "true"
        TRUST_PROXY_HEADERS: "true"
        FALKORDB_ARGS: "MAX_QUEUED_QUERIES 25 TIMEOUT_DEFAULT 60000 TIMEOUT_MAX 120000 RESULTSET_SIZE 10000"
      volumeMounts:
        - name: shared-staging
          mountPath: /var/lib/FalkorDB/import
      resources:
        requests:
          cpu: ${cpuRequest}
          memory: ${memoryRequest}
        limits:
          cpu: ${cpuLimit}
          memory: ${memoryLimit}
  volumes:
    - name: shared-staging
      source: "@app_public.staging"
      uid: 1000
      gid: 1000
  endpoints:
    - name: api
      port: 8080
      public: false
    - name: falkordb
      port: 6379
      public: false
    - name: falkordb-browser
      port: 3000
      public: true
`;

var dollarQuote = String.fromCharCode(36) + String.fromCharCode(36);

// Establish whether the service already exists BEFORE any compute is created.
// ALTER SERVICE ... FROM SPECIFICATION cannot move a service to another compute
// pool, so if the service is already running on a different pool than the one
// requested, creating the requested pool would start a second pool that never runs
// anything. That is rejected up front, before the pool exists.
//
// DESCRIBE SERVICE is used rather than SHOW SERVICES because it fails loudly for a
// missing service instead of returning an empty result that cannot be told apart
// from "the lookup did not work" - the same false-negative service_exists() guards
// against. An unreadable lookup is treated as unknown and stops the call, so an
// unrecorded pool can never be created on a guess.
var existingPool = null;
var existingWarehouse = null;
try {
    snowflake.execute({ sqlText: "DESCRIBE SERVICE app_public.st_spcs" });
    var svcRs = snowflake.execute({
        sqlText: "SELECT \"compute_pool\", \"query_warehouse\" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))"
    });
    if (svcRs.next()) {
        existingPool = svcRs.getColumnValue(1);
        existingWarehouse = svcRs.getColumnValue(2);
    }
} catch (descErr) {
    if (String(descErr.message).indexOf("does not exist") < 0) {
        throw new Error("Could not determine whether the FalkorDB service already exists (" +
            descErr.message + "). No compute pool or warehouse was created. " +
            "Resolve that error and try again.");
    }
    // "does not exist or not authorized" is the definitive absent answer.
    existingPool = null;
    existingWarehouse = null;
}

if (existingPool !== null && String(existingPool).toUpperCase() !== String(POOLNAME).toUpperCase()) {
    throw new Error("The FalkorDB service already runs on compute pool " + existingPool +
        ", so it cannot be moved to " + POOLNAME + ". No compute pool or warehouse was " +
        "created by this call. Either call start_app with '" + existingPool +
        "', or call app_public.stop_app() first, which drops the service and suspends " +
        existingPool + ".");
}

// The pool and warehouse are recorded BEFORE any compute is created. If a later
// statement in this procedure fails, stop_app() and suspend_app() can still find
// the pool and suspend it; recording afterwards would leave a running, unrecorded
// pool billing with no way for the app to release it.
snowflake.execute({
    sqlText: "MERGE INTO app_public.app_config AS t " +
        "USING (SELECT 'compute_pool' AS config_key, ? AS config_value " +
        "UNION ALL SELECT 'warehouse', ?) AS s " +
        "ON t.config_key = s.config_key " +
        "WHEN MATCHED THEN UPDATE SET config_value = s.config_value, updated_on = CURRENT_TIMESTAMP() " +
        "WHEN NOT MATCHED THEN INSERT (config_key, config_value) VALUES (s.config_key, s.config_value)",
    binds: [POOLNAME, WHNAME]
});

snowflake.execute({
    sqlText: "CREATE COMPUTE POOL IF NOT EXISTS IDENTIFIER(?) MIN_NODES = 1 MAX_NODES = 1 INSTANCE_FAMILY = CPU_X64_S AUTO_RESUME = TRUE AUTO_SUSPEND_SECS = 300",
    binds: [POOLNAME]
});

// The pool may be suspended from a previous suspend_app()/stop_app().
snowflake.execute({
    sqlText: "CALL app_public.set_compute_pool_state(?, 'RESUME')",
    binds: [POOLNAME]
});

snowflake.execute({
    sqlText: "CREATE WAREHOUSE IF NOT EXISTS IDENTIFIER(?) WITH WAREHOUSE_SIZE = 'XSMALL' INITIALLY_SUSPENDED = TRUE AUTO_SUSPEND = 300 AUTO_RESUME = TRUE",
    binds: [WHNAME]
});


// A bare CREATE SERVICE fails when the service already exists, which made every
// repeat call of this procedure fail after it had already created and resumed the
// compute pool. An existing service is updated with ALTER SERVICE instead, so custom
// CPU and memory take effect rather than being silently ignored (which is what
// CREATE SERVICE IF NOT EXISTS would do). The branch is decided by the lookup above,
// which is authoritative, rather than by guessing from a failed CREATE.
var serviceUpdated = false;
try {
    if (existingPool !== null) {
        snowflake.execute({
            sqlText: "ALTER SERVICE app_public.st_spcs FROM SPECIFICATION " + dollarQuote + spec + dollarQuote,
            binds: []
        });
        // FROM SPECIFICATION does not change QUERY_WAREHOUSE, so it is set separately
        // when the caller asked for a warehouse the service is not already using.
        if (existingWarehouse !== null &&
            String(existingWarehouse).toUpperCase() !== String(WHNAME).toUpperCase()) {
            snowflake.execute({
                sqlText: "ALTER SERVICE app_public.st_spcs SET QUERY_WAREHOUSE = IDENTIFIER(?)",
                binds: [WHNAME]
            });
        }
        serviceUpdated = true;
    } else {
        snowflake.execute({
            sqlText: "CREATE SERVICE app_public.st_spcs IN COMPUTE POOL IDENTIFIER(?) FROM SPECIFICATION " + dollarQuote + spec + dollarQuote + " QUERY_WAREHOUSE = IDENTIFIER(?)",
            binds: [POOLNAME, WHNAME]
        });
    }
} catch (svcErr) {
    // The compute pool has already been created and resumed at this point, so the
    // error has to say so - the requested CPU or memory not fitting the pool's node
    // is the most likely reason to land here, and it is reached with compute running.
    throw new Error((existingPool !== null
            ? "Could not apply the requested resources to the existing service ("
            : "Could not create the service (") + svcErr.message +
        "). Compute pool " + POOLNAME + " is running and is recorded in app_config - " +
        "call app_public.stop_app() to drop the service and suspend it.");
}

var startResult = snowflake.execute({
    sqlText: "CALL app_public.start_app(?, ?)",
    binds: [POOLNAME, WHNAME]
});
startResult.next();

return "Service " + (serviceUpdated ? "updated" : "started") + " with custom resources: request " + cpuRequest + " CPU / " + memoryRequest + ", limit " + cpuLimit + " CPU / " + memoryLimit + ". Poll app_public.get_service_status() until serving is true, then get the URL.";
$$;
GRANT USAGE ON PROCEDURE app_public.start_app(VARCHAR, VARCHAR, OBJECT) TO APPLICATION ROLE app_admin;

CREATE OR REPLACE PROCEDURE app_public.graph_query(graph_name VARCHAR, cypher_query VARCHAR, options OBJECT)
    RETURNS VARIANT
    LANGUAGE JAVASCRIPT
    EXECUTE AS OWNER
AS
$$
function normalizeOptions(options) {
    if (!options) {
        return {};
    }
    if (typeof options === "string") {
        return JSON.parse(options);
    }
    return options;
}

function getProperty(obj, names) {
    for (var i = 0; i < names.length; i++) {
        if (obj && Object.prototype.hasOwnProperty.call(obj, names[i])) {
            return obj[names[i]];
        }
    }
    return undefined;
}

function validateOutputTable(name) {
    if (!name || !/^[A-Za-z_][A-Za-z0-9_$]*[.][A-Za-z_][A-Za-z0-9_$]*[.][A-Za-z_][A-Za-z0-9_$]*$/.test(name)) {
        throw new Error("Invalid write.outputTable. Use an unquoted fully qualified table name: DATABASE.SCHEMA.TABLE");
    }
}

function normalizeRows(parsed) {
    if (Array.isArray(parsed)) {
        return parsed;
    }
    if (parsed && Array.isArray(parsed.data)) {
        return parsed.data;
    }
    if (parsed && Array.isArray(parsed.records)) {
        return parsed.records;
    }
    if (parsed && Array.isArray(parsed.results)) {
        return parsed.results;
    }
    if (parsed === null || parsed === undefined || parsed === "") {
        return [];
    }
    return [parsed];
}

var normalizedOptions = normalizeOptions(OPTIONS);
var writeOptions = getProperty(normalizedOptions, ["write", "WRITE"]);
var outputTable = writeOptions ? getProperty(writeOptions, ["outputTable", "output_table", "OUTPUTTABLE", "OUTPUT_TABLE"]) : null;

if (writeOptions) {
    validateOutputTable(outputTable);
}

var queryResult = snowflake.execute({
    sqlText: "SELECT app_public.graph_query_raw(OBJECT_CONSTRUCT('graph_name', ?, 'query', ?))",
    binds: [GRAPH_NAME, CYPHER_QUERY]
});

if (!queryResult.next()) {
    throw new Error("FalkorDB query returned no result.");
}

var rawResult = queryResult.getColumnValue(1);
var parsedResult;
try {
    parsedResult = typeof rawResult === "string" ? JSON.parse(rawResult) : rawResult;
} catch (parseErr) {
    parsedResult = {"raw_result": rawResult};
}

if (!writeOptions) {
    return rawResult;
}

var rows = normalizeRows(parsedResult);

snowflake.execute({
    sqlText: "CREATE OR REPLACE TABLE " + outputTable + " (ROW_INDEX NUMBER, ROW_DATA VARIANT)"
});

for (var i = 0; i < rows.length; i++) {
    snowflake.execute({
        sqlText: "INSERT INTO " + outputTable + " (ROW_INDEX, ROW_DATA) SELECT ?, PARSE_JSON(?)",
        binds: [i, JSON.stringify(rows[i])]
    });
}

return {
    "output_table": outputTable,
    "row_count": rows.length,
    "note": "Rows are stored as VARIANT in ROW_DATA because Cypher result shapes can vary by query."
};
$$;
GRANT USAGE ON PROCEDURE app_public.graph_query(VARCHAR, VARCHAR, OBJECT) TO APPLICATION ROLE app_admin;
GRANT USAGE ON PROCEDURE app_public.graph_query(VARCHAR, VARCHAR, OBJECT) TO APPLICATION ROLE app_user;

CREATE OR REPLACE PROCEDURE graph.create_agent(agent_name VARCHAR, source_schema VARCHAR, working_schema VARCHAR)
    RETURNS STRING
    LANGUAGE SQL
    EXECUTE AS OWNER
AS
$$
DECLARE
    normalized_agent_name STRING DEFAULT UPPER(agent_name);
    app_name STRING DEFAULT CURRENT_DATABASE();
    agent_fqn STRING;
    spec STRING;
    invalid_agent_name EXCEPTION (-20010, 'Invalid agent name. Use letters, digits, underscores, or dollar signs; first character must be a letter or underscore.');
    invalid_schema_name EXCEPTION (-20011, 'Invalid schema name. Use a fully qualified database.schema identifier.');
BEGIN
    IF (normalized_agent_name IS NULL OR NOT REGEXP_LIKE(normalized_agent_name, '^[A-Z_][A-Z0-9_$]*$')) THEN
        RAISE invalid_agent_name;
    END IF;

    IF (source_schema IS NULL OR working_schema IS NULL
        OR NOT REGEXP_LIKE(source_schema, '^[A-Za-z0-9_.$"]+[.][A-Za-z0-9_.$"]+$')
        OR NOT REGEXP_LIKE(working_schema, '^[A-Za-z0-9_.$"]+[.][A-Za-z0-9_.$"]+$')) THEN
        RAISE invalid_schema_name;
    END IF;

    agent_fqn := app_name || '.GRAPH.' || normalized_agent_name;

    MERGE INTO agent_artefacts.agent_config t
    USING (
        SELECT
            :normalized_agent_name AS agent_name,
            :source_schema AS source_schema,
            :working_schema AS working_schema
    ) s
    ON t.agent_name = s.agent_name
    WHEN MATCHED THEN UPDATE SET
        source_schema = s.source_schema,
        working_schema = s.working_schema,
        warehouse_name = NULL,
        updated_on = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (agent_name, source_schema, working_schema, warehouse_name)
        VALUES (s.agent_name, s.source_schema, s.working_schema, NULL);

    EXECUTE IMMEDIATE 'CREATE TABLE IF NOT EXISTS agent_artefacts.agent_context__' || normalized_agent_name || ' (
        context_key STRING,
        context_value VARIANT,
        updated_on TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
    )';
    EXECUTE IMMEDIATE 'CREATE TABLE IF NOT EXISTS agent_artefacts.agent_config__' || normalized_agent_name || ' (
        config_key STRING,
        config_value VARIANT,
        updated_on TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
    )';

    MERGE INTO agent_artefacts.agent_context t
    USING (
        SELECT :normalized_agent_name AS agent_name, 'setup' AS context_key,
               OBJECT_CONSTRUCT(
                 'source_schema', :source_schema,
                 'working_schema', :working_schema
               ) AS context_value
    ) s
    ON t.agent_name = s.agent_name AND t.context_key = s.context_key
    WHEN MATCHED THEN UPDATE SET context_value = s.context_value, updated_on = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (agent_name, context_key, context_value)
        VALUES (s.agent_name, s.context_key, s.context_value);

    spec := 'orchestration:
  budget:
    seconds: 60
    tokens: 16000
instructions:
  response: "You are FalkorDB Graph Agent. Be concise. Always show the Cypher query generated or executed when answering query requests. Explain generated Cypher before running mutating queries. Prefer read-only MATCH/RETURN queries unless the user explicitly asks to change graph data."
  orchestration: "Always pass input_agent_name=' || normalized_agent_name || ' when calling tools. Use get_context first for configured schemas. Use list_graphs to discover loaded graphs. Use inspect_graph and graph_stats before generating Cypher when schema or size is unknown. For difficult graph questions, call text_to_cypher before run_cypher so FalkorDB-specific Cypher is generated with graph schema context. Use the default text-to-Cypher model unless the user explicitly asks for a specific Snowflake Cortex model; when requested, pass that model as model_name. Show the cypher field returned by text_to_cypher before running it. When using run_cypher, include the executed cypher_query from the tool result in your answer. Explain generated Cypher before running it, and ask for confirmation before mutating queries. Use load_csv_guidance when the user asks how to load data. To load data, first explain that consumer_data_table must already be bound by a user/admin. Ask which graph name to use if missing. Generate LOAD CSV mapping Cypher using row indexes and MERGE for idempotency, then ask for explicit confirmation before calling load_csv. Use run_cypher to execute Cypher against FalkorDB. Source schema is ' || source_schema || ' and working schema is ' || working_schema || '. Agent tools use the caller role default warehouse."
  sample_questions:
    - question: "What graphs are available?"
    - question: "Inspect my graph schema and suggest useful Cypher queries."
    - question: "Find the top connected nodes in my graph."
    - question: "Generate a Cypher query for this question and run it."
    - question: "Help me load my bound Snowflake table into a FalkorDB graph."
tools:
  - tool_spec:
      type: "generic"
      name: "get_context"
      description: "Return this FalkorDB agent configuration, source schema, working schema, and usage guidance."
      input_schema:
        type: "object"
        properties:
          input_agent_name:
            type: "string"
            description: "The configured FalkorDB agent name."
        required:
          - "input_agent_name"
  - tool_spec:
      type: "generic"
      name: "list_graphs"
      description: "List graphs currently loaded in the FalkorDB service."
      input_schema:
        type: "object"
        properties:
          input_agent_name:
            type: "string"
            description: "The configured FalkorDB agent name."
        required:
          - "input_agent_name"
  - tool_spec:
      type: "generic"
      name: "inspect_graph"
      description: "Inspect labels, relationship types, and property keys for a FalkorDB graph."
      input_schema:
        type: "object"
        properties:
          input_agent_name:
            type: "string"
            description: "The configured FalkorDB agent name."
          graph_name:
            type: "string"
            description: "The FalkorDB graph name to inspect."
        required:
          - "input_agent_name"
          - "graph_name"
  - tool_spec:
      type: "generic"
      name: "run_cypher"
      description: "Run a Cypher query against a FalkorDB graph and return both the executed cypher_query and result."
      input_schema:
        type: "object"
        properties:
          input_agent_name:
            type: "string"
            description: "The configured FalkorDB agent name."
          graph_name:
            type: "string"
            description: "The FalkorDB graph name."
          cypher_query:
            type: "string"
            description: "The Cypher query to execute. Prefer read-only queries unless mutation was explicitly requested."
        required:
          - "input_agent_name"
          - "graph_name"
          - "cypher_query"
  - tool_spec:
      type: "generic"
      name: "text_to_cypher"
      description: "Generate FalkorDB Cypher from a natural-language graph question using Snowflake Cortex and FalkorDB graph schema context. Returns the generated cypher, selected model, and schema_context used. Use this before run_cypher for complex graph questions. Pass model_name only when the user explicitly requests a specific Cortex model."
      input_schema:
        type: "object"
        properties:
          input_agent_name:
            type: "string"
            description: "The configured FalkorDB agent name."
          graph_name:
            type: "string"
            description: "The FalkorDB graph name."
          user_question:
            type: "string"
            description: "The user question or task to translate into FalkorDB Cypher."
          model_name:
            type: "string"
            description: "Optional Snowflake Cortex model for Cypher generation. Defaults to claude-4-sonnet when omitted."
        required:
          - "input_agent_name"
          - "graph_name"
          - "user_question"
  - tool_spec:
      type: "generic"
      name: "graph_stats"
      description: "Return basic graph size statistics: node count and relationship count."
      input_schema:
        type: "object"
        properties:
          input_agent_name:
            type: "string"
            description: "The configured FalkorDB agent name."
          graph_name:
            type: "string"
            description: "The FalkorDB graph name."
        required:
          - "input_agent_name"
          - "graph_name"
  - tool_spec:
      type: "generic"
      name: "load_csv_guidance"
      description: "Return guidance for loading bound Snowflake table data into FalkorDB with LOAD CSV."
      input_schema:
        type: "object"
        properties:
          input_agent_name:
            type: "string"
            description: "The configured FalkorDB agent name."
        required:
          - "input_agent_name"
  - tool_spec:
      type: "generic"
      name: "load_csv"
      description: "Load data from the already-bound consumer_data_table reference into a FalkorDB graph using a confirmed LOAD CSV Cypher mapping."
      input_schema:
        type: "object"
        properties:
          input_agent_name:
            type: "string"
            description: "The configured FalkorDB agent name."
          graph_name:
            type: "string"
            description: "The FalkorDB graph name to load into."
          cypher_query:
            type: "string"
            description: "The LOAD CSV Cypher mapping to execute. It must use LOAD CSV FROM ''file://consumer_data.csv'' AS row and should use MERGE for retry-safe loads."
        required:
          - "input_agent_name"
          - "graph_name"
          - "cypher_query"
tool_resources:
  get_context:
    type: "function"
    execution_environment:
      type: "warehouse"
      query_timeout: 60
    identifier: "' || app_name || '.AGENT_TOOLS.GET_CONTEXT"
  list_graphs:
    type: "function"
    execution_environment:
      type: "warehouse"
      query_timeout: 60
    identifier: "' || app_name || '.AGENT_TOOLS.LIST_GRAPHS"
  inspect_graph:
    type: "function"
    execution_environment:
      type: "warehouse"
      query_timeout: 120
    identifier: "' || app_name || '.AGENT_TOOLS.INSPECT_GRAPH"
  graph_stats:
    type: "function"
    execution_environment:
      type: "warehouse"
      query_timeout: 120
    identifier: "' || app_name || '.AGENT_TOOLS.GRAPH_STATS"
  load_csv_guidance:
    type: "function"
    execution_environment:
      type: "warehouse"
      query_timeout: 60
    identifier: "' || app_name || '.AGENT_TOOLS.LOAD_CSV_GUIDANCE"
  run_cypher:
    type: "function"
    execution_environment:
      type: "warehouse"
      query_timeout: 120
    identifier: "' || app_name || '.AGENT_TOOLS.RUN_CYPHER"
  text_to_cypher:
    type: "procedure"
    execution_environment:
      type: "warehouse"
      query_timeout: 120
    identifier: "' || app_name || '.AGENT_TOOLS.TEXT_TO_CYPHER"
  load_csv:
    type: "procedure"
    execution_environment:
      type: "warehouse"
      query_timeout: 600
    identifier: "' || app_name || '.AGENT_TOOLS.LOAD_CSV"
';

    EXECUTE IMMEDIATE 'CREATE OR REPLACE AGENT IDENTIFIER(?)
        COMMENT = ''FalkorDB Cortex Agent for natural-language graph workflows''
        PROFILE = ''{"display_name":"FalkorDB Graph Agent","color":"purple"}''
        FROM SPECIFICATION ' || CHR(36) || CHR(36) || spec || CHR(36) || CHR(36)
        USING (agent_fqn);

    EXECUTE IMMEDIATE 'GRANT USAGE ON AGENT IDENTIFIER(?) TO APPLICATION ROLE app_admin' USING (agent_fqn);
    EXECUTE IMMEDIATE 'GRANT USAGE ON AGENT IDENTIFIER(?) TO APPLICATION ROLE app_user' USING (agent_fqn);

    RETURN 'Created FalkorDB Cortex Agent ' || agent_fqn || '. Grant SNOWFLAKE.CORTEX_AGENT_USER to the consumer role, grant SNOWFLAKE.CORTEX_USER and imported privileges on database SNOWFLAKE to the application, then open AI & ML > Agents or Snowflake Intelligence.';
END
$$;
GRANT USAGE ON PROCEDURE graph.create_agent(VARCHAR, VARCHAR, VARCHAR) TO APPLICATION ROLE app_admin;

CREATE OR REPLACE PROCEDURE graph.get_agent_caller_grants(agent_name VARCHAR)
    RETURNS STRING
    LANGUAGE SQL
    EXECUTE AS OWNER
AS
$$
DECLARE
    normalized_agent_name STRING DEFAULT UPPER(agent_name);
    source_schema STRING;
    working_schema STRING;
    app_name STRING DEFAULT CURRENT_DATABASE();
BEGIN
    SELECT cfg.source_schema, cfg.working_schema
      INTO :source_schema, :working_schema
      FROM agent_artefacts.agent_config cfg
     WHERE cfg.agent_name = :normalized_agent_name;

    RETURN '-- Run as ACCOUNTADMIN or a role with MANAGE CALLER GRANTS' || CHAR(10) ||
           'GRANT INHERITED CALLER SELECT ON ALL TABLES IN SCHEMA ' || source_schema || ' TO APPLICATION ' || app_name || ';' || CHAR(10) ||
           'GRANT INHERITED CALLER SELECT ON ALL VIEWS IN SCHEMA ' || source_schema || ' TO APPLICATION ' || app_name || ';' || CHAR(10) ||
           'GRANT INHERITED CALLER SELECT ON ALL TABLES IN SCHEMA ' || working_schema || ' TO APPLICATION ' || app_name || ';' || CHAR(10) ||
           'GRANT INHERITED CALLER SELECT ON ALL VIEWS IN SCHEMA ' || working_schema || ' TO APPLICATION ' || app_name || ';' || CHAR(10) ||
           'GRANT INHERITED CALLER INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA ' || working_schema || ' TO APPLICATION ' || app_name || ';';
END
$$;
GRANT USAGE ON PROCEDURE graph.get_agent_caller_grants(VARCHAR) TO APPLICATION ROLE app_admin;

CREATE OR REPLACE PROCEDURE graph.drop_agent(agent_name VARCHAR)
    RETURNS STRING
    LANGUAGE SQL
    EXECUTE AS OWNER
AS
$$
DECLARE
    normalized_agent_name STRING DEFAULT UPPER(agent_name);
    app_name STRING DEFAULT CURRENT_DATABASE();
    agent_fqn STRING;
    invalid_agent_name EXCEPTION (-20010, 'Invalid agent name.');
BEGIN
    IF (normalized_agent_name IS NULL OR NOT REGEXP_LIKE(normalized_agent_name, '^[A-Z_][A-Z0-9_$]*$')) THEN
        RAISE invalid_agent_name;
    END IF;

    agent_fqn := app_name || '.GRAPH.' || normalized_agent_name;
    EXECUTE IMMEDIATE 'DROP AGENT IF EXISTS IDENTIFIER(?)' USING (agent_fqn);
    EXECUTE IMMEDIATE 'DROP TABLE IF EXISTS agent_artefacts.agent_context__' || normalized_agent_name;
    EXECUTE IMMEDIATE 'DROP TABLE IF EXISTS agent_artefacts.agent_config__' || normalized_agent_name;
    DELETE FROM agent_artefacts.agent_context WHERE agent_context.agent_name = :normalized_agent_name;
    DELETE FROM agent_artefacts.agent_config WHERE agent_config.agent_name = :normalized_agent_name;
    RETURN 'Dropped FalkorDB Cortex Agent ' || agent_fqn;
END
$$;
GRANT USAGE ON PROCEDURE graph.drop_agent(VARCHAR) TO APPLICATION ROLE app_admin;

-- TRUE when the SPCS service object exists.
--
-- SHOW is used rather than SYSTEM$GET_SERVICE_STATUS because SHOW returns an empty
-- result for a missing service, while SYSTEM$GET_SERVICE_STATUS raises EXPRESSION_ERROR.
-- Not granted to any application role: this is an internal helper.
CREATE OR REPLACE PROCEDURE app_public.service_exists()
    RETURNS BOOLEAN
    LANGUAGE SQL
    EXECUTE AS OWNER
AS
$$
DECLARE
    found INTEGER DEFAULT 0;
    probe STRING;
BEGIN
    BEGIN
        SHOW SERVICES LIKE 'ST_SPCS' IN SCHEMA app_public;
        found := (SELECT COUNT(*) FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));
    EXCEPTION
        WHEN OTHER THEN
            found := 0;
    END;

    IF (found > 0) THEN
        RETURN TRUE;
    END IF;

    -- Confirm before reporting absence. A false negative here would make
    -- resume_app() refuse to resume a service that really is there, so an empty
    -- or failed SHOW is checked against the status function, which raises only
    -- when the service is genuinely missing.
    BEGIN
        probe := SYSTEM$GET_SERVICE_STATUS('app_public.st_spcs');
        RETURN TRUE;
    EXCEPTION
        WHEN OTHER THEN
            RETURN FALSE;
    END;
END
$$;

-- Same as stop_app(), with an explicit pool name for apps that were started before
-- the pool name was recorded, or when the pool is not the one start_app() used.
CREATE OR REPLACE PROCEDURE app_public.stop_app(poolname VARCHAR)
    RETURNS string
    LANGUAGE sql
    EXECUTE AS OWNER
    AS
$$
DECLARE
    pool_msg STRING;
    pool_state STRING;
BEGIN
    DROP SERVICE IF EXISTS app_public.st_spcs;

    CALL app_public.set_compute_pool_state(:poolname, 'SUSPEND') INTO :pool_msg;

    IF (pool_msg IS NULL OR pool_msg = '') THEN
        -- A pool bills until it actually reaches SUSPENDED: STOPPING and SUSPENDING
        -- are still charged, so the message is worded from the state, not from the
        -- fact that the SUSPEND was accepted.
        CALL app_public.compute_pool_state(:poolname) INTO :pool_state;

        IF (pool_state = 'SUSPENDED') THEN
            RETURN 'Service dropped and compute pool ' || poolname || ' suspended. No compute is running.';
        END IF;

        RETURN 'Service dropped and compute pool ' || poolname || ' is suspending (state: '
            || COALESCE(pool_state, 'UNKNOWN') || '). It is not fully stopped until it reaches '
            || 'SUSPENDED - confirm with app_public.get_compute_status().';
    END IF;

    RETURN 'Service dropped, but the compute pool was not suspended. ' || pool_msg
        || ' If the pool was created by the consumer rather than by the app, suspend it yourself, '
        || 'otherwise it stays running: ALTER COMPUTE POOL ' || poolname || ' SUSPEND;';
END
$$;
GRANT USAGE ON PROCEDURE app_public.stop_app(VARCHAR) TO APPLICATION ROLE app_admin;

-- Stop the app and release the compute it is billing for.
--
-- Dropping the service is not enough: the compute pool created by start_app()
-- keeps billing per node-hour while it is active, and AUTO_SUSPEND_SECS only fires
-- once the pool is idle, so the pool must be suspended explicitly.
CREATE OR REPLACE PROCEDURE app_public.stop_app()
    RETURNS string
    LANGUAGE sql
    EXECUTE AS OWNER
    AS
$$
DECLARE
    pool_name STRING;
    result_msg STRING;
BEGIN
    pool_name := (SELECT MAX(config_value) FROM app_public.app_config WHERE config_key = 'compute_pool');

    IF (pool_name IS NULL) THEN
        DROP SERVICE IF EXISTS app_public.st_spcs;
        RETURN 'Any service was dropped. No compute pool is recorded for this app, so no pool '
            || 'was suspended. If the app was started before this version, its pool may still be '
            || 'running: call app_public.stop_app(''<POOL_NAME>'') with the pool name, '
            || 'or suspend it yourself: ALTER COMPUTE POOL <POOL_NAME> SUSPEND;';
    END IF;

    CALL app_public.stop_app(:pool_name) INTO :result_msg;
    RETURN result_msg;
END
$$;
GRANT USAGE ON PROCEDURE app_public.stop_app() TO APPLICATION ROLE app_admin;

-- Cheap stop for repeat demos: suspends the service and the compute pool but keeps
-- the service definition, so resume_app() does not have to recreate it the way a
-- full start_app() would. Billing stops the same way it does with stop_app().
CREATE OR REPLACE PROCEDURE app_public.suspend_app()
    RETURNS string
    LANGUAGE sql
    EXECUTE AS OWNER
    AS
$$
DECLARE
    pool_name STRING;
    pool_msg STRING;
    pool_state STRING;
    has_service BOOLEAN DEFAULT FALSE;
    svc_err STRING DEFAULT NULL;
    svc_note STRING;
BEGIN
    CALL app_public.service_exists() INTO :has_service;

    BEGIN
        ALTER SERVICE IF EXISTS app_public.st_spcs SUSPEND;
    EXCEPTION
        WHEN OTHER THEN
            svc_err := SQLERRM;
    END;

    -- The failure is reported rather than swallowed: claiming "Service suspended."
    -- after a failed ALTER would hide a service that is still running and billing.
    -- An already-suspended service also lands here, so the wording covers both.
    IF (NOT has_service) THEN
        svc_note := 'No service was running.';
    ELSEIF (svc_err IS NOT NULL) THEN
        svc_note := 'The service may not have been suspended (' || svc_err
            || ') - it is often already suspended. Confirm with app_public.get_service_status().';
    ELSE
        svc_note := 'Service suspended.';
    END IF;

    pool_name := (SELECT MAX(config_value) FROM app_public.app_config WHERE config_key = 'compute_pool');

    IF (pool_name IS NULL) THEN
        RETURN svc_note || IFF(has_service,
            ' No compute pool is recorded for this app, so no pool was suspended and it may '
                || 'still be running: ALTER COMPUTE POOL <POOL_NAME> SUSPEND;',
            ' No compute pool is recorded for this app either, so there is nothing to suspend.');
    END IF;

    CALL app_public.set_compute_pool_state(:pool_name, 'SUSPEND') INTO :pool_msg;

    IF (pool_msg IS NULL OR pool_msg = '') THEN
        -- STOPPING and SUSPENDING still bill, so only SUSPENDED is reported as free.
        CALL app_public.compute_pool_state(:pool_name) INTO :pool_state;

        RETURN svc_note || ' Compute pool ' || pool_name
            || IFF(pool_state = 'SUSPENDED',
                   ' suspended. No compute is running. ',
                   ' is suspending (state: ' || COALESCE(pool_state, 'UNKNOWN')
                       || '). It is not fully stopped until it reaches SUSPENDED - confirm '
                       || 'with app_public.get_compute_status(). ')
            || IFF(has_service, 'Call app_public.resume_app() to restart. ',
                                'Call app_public.start_app(''<POOL_NAME>'', ''<WAREHOUSE_NAME>'') to start it. ')
            || 'Graph data is held in memory only, so it does not survive the suspend - reload it once the service is serving.';
    END IF;

    RETURN svc_note || ' The compute pool was not suspended. ' || pool_msg
        || ' Suspend it yourself or it stays running: ALTER COMPUTE POOL ' || pool_name || ' SUSPEND;';
END
$$;
GRANT USAGE ON PROCEDURE app_public.suspend_app() TO APPLICATION ROLE app_admin;

-- Restart after suspend_app(). AUTO_RESUME does not cover an explicitly suspended
-- pool or service, so both are resumed here.
CREATE OR REPLACE PROCEDURE app_public.resume_app()
    RETURNS string
    LANGUAGE sql
    EXECUTE AS OWNER
    AS
$$
DECLARE
    pool_name STRING;
    pool_msg STRING DEFAULT '';
    has_service BOOLEAN DEFAULT FALSE;
    resume_err STRING;
BEGIN
    -- The service is checked before the compute pool is touched. Resuming the pool
    -- first would start billing for a service that stop_app() dropped and that
    -- resume_app() cannot recreate, leaving a pool billing with nothing running.
    CALL app_public.service_exists() INTO :has_service;

    IF (NOT has_service) THEN
        RETURN 'No service to resume: it was either dropped by stop_app() or never started. '
            || 'Call app_public.start_app(''<POOL_NAME>'', ''<WAREHOUSE_NAME>'') to create it. '
            || 'The compute pool was left untouched, so this call started no compute.';
    END IF;

    pool_name := (SELECT MAX(config_value) FROM app_public.app_config WHERE config_key = 'compute_pool');

    IF (pool_name IS NOT NULL) THEN
        CALL app_public.set_compute_pool_state(:pool_name, 'RESUME') INTO :pool_msg;
    END IF;

    BEGIN
        ALTER SERVICE IF EXISTS app_public.st_spcs RESUME;
    EXCEPTION
        WHEN OTHER THEN
            -- Usually "already running". The pool is deliberately left alone here:
            -- the service exists, so the pool is meant to be running, and suspending
            -- it on this path would stop a healthy service.
            resume_err := SQLERRM;
    END;

    -- Surface a failed pool resume: the service can report READY only once the
    -- pool is running, so hiding this would leave the caller polling forever.
    IF (pool_msg IS NOT NULL AND pool_msg <> '') THEN
        RETURN pool_msg || ' The service was asked to resume, but it cannot start '
            || 'until the compute pool is running. Resume the pool yourself: '
            || 'ALTER COMPUTE POOL ' || pool_name || ' RESUME;';
    END IF;

    IF (resume_err IS NOT NULL) THEN
        RETURN IFF(pool_name IS NULL,
                   'No compute pool is recorded for this app, so no pool was resumed. ',
                   'Compute pool ' || pool_name || ' resumed. ')
            || 'The service was not resumed (' || resume_err
            || '), which usually means it is already running. '
            || 'Poll app_public.get_service_status() until serving is true. '
            || 'If you did not intend to start compute, call app_public.stop_app().';
    END IF;

    RETURN IFF(pool_name IS NULL,
               'Service resuming. No compute pool is recorded for this app, so none was resumed. ',
               'Compute pool and service resuming. ')
        || 'Poll app_public.get_service_status() until serving is true - a container can '
        || 'report READY before FalkorDB accepts connections. '
        || 'Graph data is not persisted across a stop, so reload your data once the service is serving.';
END
$$;
GRANT USAGE ON PROCEDURE app_public.resume_app() TO APPLICATION ROLE app_admin;

-- Whether anything is still billing: the recorded compute resources and the pool state.
CREATE OR REPLACE PROCEDURE app_public.get_compute_status()
    RETURNS VARIANT
    LANGUAGE SQL
    EXECUTE AS OWNER
AS
$$
DECLARE
    pool_name STRING;
    wh_name STRING;
    pool_state VARIANT DEFAULT NULL;
BEGIN
    pool_name := (SELECT MAX(config_value) FROM app_public.app_config WHERE config_key = 'compute_pool');
    wh_name := (SELECT MAX(config_value) FROM app_public.app_config WHERE config_key = 'warehouse');

    IF (pool_name IS NOT NULL AND REGEXP_LIKE(UPPER(pool_name), '^[A-Z_][A-Z0-9_$]*$')) THEN
        BEGIN
            EXECUTE IMMEDIATE 'SHOW COMPUTE POOLS LIKE ''' || pool_name || '''';
            pool_state := (
                SELECT ARRAY_AGG(OBJECT_CONSTRUCT('name', "name", 'state', "state", 'num_services', "num_services"))
                FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
            );
        EXCEPTION
            WHEN OTHER THEN
                pool_state := NULL; -- the app cannot see a consumer-owned pool
        END;
    END IF;

    RETURN OBJECT_CONSTRUCT_KEEP_NULL(
        'compute_pool', pool_name,
        'warehouse', wh_name,
        'compute_pool_state', pool_state
    );
END
$$;
GRANT USAGE ON PROCEDURE app_public.get_compute_status() TO APPLICATION ROLE app_admin;
GRANT USAGE ON PROCEDURE app_public.get_compute_status() TO APPLICATION ROLE app_user;

-- Helpers to fetch service status and logs without requiring external application role switching
--
-- SPCS reports a container READY as soon as its process is running, which is before
-- FalkorDB is listening on its port, so a READY service can still answer
-- "503 ... Connection refused". The 'serving' flag closes that gap by asking the
-- service itself. It is only probed once the service claims to be READY, so the
-- usual startup polling loop stays a cheap metadata call.
CREATE OR REPLACE PROCEDURE app_public.get_service_status()
    RETURNS VARIANT
    LANGUAGE SQL
    EXECUTE AS OWNER
AS
$$
DECLARE
    service_name STRING DEFAULT 'app_public.st_spcs';
    raw_status STRING;
    serving BOOLEAN DEFAULT FALSE;
BEGIN
    -- SYSTEM$GET_SERVICE_STATUS raises EXPRESSION_ERROR when the service does not
    -- exist, which is exactly the state after stop_app(), so it is guarded here.
    BEGIN
        raw_status := SYSTEM$GET_SERVICE_STATUS(:service_name);
    EXCEPTION
        WHEN OTHER THEN
            RETURN OBJECT_CONSTRUCT_KEEP_NULL('containers', NULL, 'serving', FALSE);
    END;

    IF (raw_status ILIKE '%READY%') THEN
        BEGIN
            -- graph_list is used rather than a Cypher query because it takes no
            -- graph name and creates nothing; querying a graph would leave an
            -- empty health-check graph behind.
            EXECUTE IMMEDIATE 'SELECT app_public.graph_list_raw({})';
            serving := TRUE;
        EXCEPTION
            WHEN OTHER THEN
                -- Not listening yet, or the app has never been started, so the
                -- service functions do not exist.
                serving := FALSE;
        END;
    END IF;

    -- KEEP_NULL so the 'containers' key is always present: plain OBJECT_CONSTRUCT
    -- silently drops keys whose value is NULL.
    RETURN OBJECT_CONSTRUCT_KEEP_NULL(
        'containers', TRY_PARSE_JSON(raw_status),
        'serving', serving
    );
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
EXCEPTION
    WHEN OTHER THEN
        -- No service means no logs. Returning the reason keeps this usable while
        -- debugging a service that failed to start, instead of raising.
        RETURN 'No logs available (' || SQLERRM || '). '
            || 'If the service was dropped by stop_app(), start it with app_public.start_app().';
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
EXCEPTION
    WHEN OTHER THEN
        -- No service, so no containers. An empty array keeps the return type stable
        -- for callers that iterate it, rather than raising.
        RETURN ARRAY_CONSTRUCT();
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
