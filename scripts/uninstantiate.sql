-- Teardown of resources created by instantiate.sql
-- Idempotent: safe to run multiple times

-- Use ACCOUNTADMIN to ensure we have sufficient privileges for cleanup
use role accountadmin;

-- Drop the application instance (stops services and removes app-scoped grants)
drop application if exists falkordb_app_instance;

-- Drop the compute pool used by the application
-- Note: If the pool is still in use, re-run after the app is dropped
DROP COMPUTE POOL IF EXISTS pool_consumer;
