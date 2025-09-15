CREATE APPLICATION ROLE app_admin;
CREATE APPLICATION ROLE app_user;
CREATE SCHEMA IF NOT EXISTS app_public;
GRANT USAGE ON SCHEMA app_public TO APPLICATION ROLE app_admin;
GRANT USAGE ON SCHEMA app_public TO APPLICATION ROLE app_user;

-- Create staging area for CSV exports
CREATE STAGE IF NOT EXISTS app_public.staging;
GRANT READ, WRITE ON STAGE app_public.staging TO APPLICATION ROLE app_admin;
GRANT READ, WRITE ON STAGE app_public.staging TO APPLICATION ROLE app_user;

CREATE OR ALTER VERSIONED SCHEMA v1;
GRANT USAGE ON SCHEMA v1 TO APPLICATION ROLE app_admin;


CREATE OR REPLACE PROCEDURE app_public.start_app(poolname VARCHAR, whname VARCHAR)
    RETURNS string
    LANGUAGE sql
    AS $$
BEGIN
        EXECUTE IMMEDIATE 'CREATE SERVICE IF NOT EXISTS app_public.st_spcs
            IN COMPUTE POOL Identifier(''' || poolname || ''')
            FROM SPECIFICATION_FILE=''' || '/falkordb.yaml' || '''
            QUERY_WAREHOUSE=''' || whname || '''';
    GRANT USAGE ON SERVICE app_public.st_spcs TO APPLICATION ROLE app_user;
    GRANT SERVICE ROLE app_public.st_spcs!ALL_ENDPOINTS_USAGE TO APPLICATION ROLE app_user;
    -- Also grant to app_admin for operational tasks
    GRANT USAGE ON SERVICE app_public.st_spcs TO APPLICATION ROLE app_admin;
    GRANT SERVICE ROLE app_public.st_spcs!ALL_ENDPOINTS_USAGE TO APPLICATION ROLE app_admin;
    -- Create service function after service exists with specific path
    EXECUTE IMMEDIATE 'CREATE OR REPLACE FUNCTION app_public.list_graphs_raw(request OBJECT)
        RETURNS VARIANT
        SERVICE=app_public.st_spcs
        ENDPOINT=''api''
        MAX_BATCH_ROWS=1
        AS ''/echo''';
    
    -- Create wrapper procedure for easier calling
    EXECUTE IMMEDIATE 'CREATE OR REPLACE PROCEDURE app_public.list_graphs()
        RETURNS VARIANT
        LANGUAGE SQL
        AS
        ''BEGIN
            RETURN app_public.list_graphs_raw({''''test'''': ''''snowflake_service_function''''});
        END''';
    
    EXECUTE IMMEDIATE 'GRANT USAGE ON FUNCTION app_public.list_graphs_raw(OBJECT) TO APPLICATION ROLE app_admin';
    EXECUTE IMMEDIATE 'GRANT USAGE ON FUNCTION app_public.list_graphs_raw(OBJECT) TO APPLICATION ROLE app_user';
    EXECUTE IMMEDIATE 'GRANT USAGE ON PROCEDURE app_public.list_graphs() TO APPLICATION ROLE app_admin';
    EXECUTE IMMEDIATE 'GRANT USAGE ON PROCEDURE app_public.list_graphs() TO APPLICATION ROLE app_user';

    -- Create load_csv service function 
    EXECUTE IMMEDIATE 'CREATE OR REPLACE FUNCTION app_public.load_csv_raw(request OBJECT)
        RETURNS VARIANT
        SERVICE=app_public.st_spcs
        ENDPOINT=''api''
        AS ''/load_csv''';
    
    -- Create wrapper procedure for load_csv, load the data from consumer_table as csv file named consumer_table.csv to in the staging area and then call load_csv_raw  
    EXECUTE IMMEDIATE 'CREATE OR REPLACE PROCEDURE app_public.load_csv(graph_name VARCHAR, consumer_table VARCHAR, cypher_query VARCHAR)
        RETURNS VARIANT
        LANGUAGE SQL
        AS
        ''BEGIN
            -- Export data from consumer_table to CSV file in staging area
            EXECUTE IMMEDIATE ''''COPY INTO @app_public.staging/'''' || :consumer_table || ''''.csv 
                FROM (SELECT * FROM '''' || :consumer_table || '''') 
                FILE_FORMAT = (TYPE = CSV)'''';
            
            -- Call load_csv_raw with the CSV file path
            RETURN app_public.load_csv_raw({''''graph_name'''': :graph_name, ''''csv_file'''': :consumer_table || ''''.csv'''', ''''cypher_query'''': :cypher_query});
        END''';
    
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


-- Simple utility procedure as part of the app
CREATE OR REPLACE PROCEDURE app_public.toUpper(s STRING)
        RETURNS STRING
        LANGUAGE JAVASCRIPT
AS
$$
    var sArg = arguments[0];
    if (sArg === null || sArg === undefined) return null;
    return String(sArg).toUpperCase();
$$;

GRANT USAGE ON PROCEDURE app_public.toUpper(STRING) TO APPLICATION ROLE app_user;
GRANT USAGE ON PROCEDURE app_public.toUpper(STRING) TO APPLICATION ROLE app_admin;

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

