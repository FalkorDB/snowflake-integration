-- ============================================================================
-- Snowflake Marketplace Metrics: Service Account Setup
-- ============================================================================
-- Run this script once as ACCOUNTADMIN to create a dedicated, least-privilege
-- role and service user for the GitHub Actions metrics export workflow.
--
-- Prerequisites:
--   1. Generate an RSA key pair for key-pair authentication:
--      openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out metrics_bot_key.p8 -nocrypt
--      openssl rsa -in metrics_bot_key.p8 -pubout -out metrics_bot_key.pub
--   2. Replace <YOUR_RSA_PUBLIC_KEY> below with the contents of metrics_bot_key.pub
--      (without the BEGIN/END header/footer lines).
-- ============================================================================

USE ROLE ACCOUNTADMIN;

-- 1. Create a dedicated role for metrics extraction
CREATE ROLE IF NOT EXISTS sf_metrics_role
  COMMENT = 'Role for automated Snowflake Marketplace metrics extraction';

-- 2. Grant read access to the provider analytics views
--    IMPORTED PRIVILEGES on the SNOWFLAKE database gives access to
--    DATA_SHARING_USAGE, ORGANIZATION_USAGE, and ACCOUNT_USAGE schemas.
GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE sf_metrics_role;

-- 3. Create a small warehouse (auto-suspends after 60s to minimize cost)
CREATE WAREHOUSE IF NOT EXISTS WH_METRICS
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  COMMENT = 'XS warehouse for marketplace metrics queries';
GRANT USAGE ON WAREHOUSE WH_METRICS TO ROLE sf_metrics_role;

-- 4. Create service account user with key-pair authentication
CREATE USER IF NOT EXISTS sf_metrics_bot
  DEFAULT_ROLE = sf_metrics_role
  DEFAULT_WAREHOUSE = WH_METRICS
  RSA_PUBLIC_KEY = '<YOUR_RSA_PUBLIC_KEY>'
  COMMENT = 'Service account for GitHub Actions metrics export';
GRANT ROLE sf_metrics_role TO USER sf_metrics_bot;
