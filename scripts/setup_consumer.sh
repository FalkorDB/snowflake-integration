#!/bin/bash

# Consumer Setup Script for FalkorDB Native App
# This script sets up the consumer database, schema, tables, and loads initial data
# Usage: ./setup_consumer.sh

set -e

echo "🚀 FalkorDB Consumer Setup Script"
echo "📊 Setting up consumer database and loading CSV data"
echo "=================================================="
echo ""

# Step 0: Create Consumer Role
echo "👤 Step 0: Creating consumer role..."

snow sql -q "
USE ROLE ACCOUNTADMIN;

-- Create consumer role if it doesn't exist
CREATE ROLE IF NOT EXISTS consumer_role;
GRANT ROLE consumer_role TO ROLE SYSADMIN;
GRANT CREATE DATABASE ON ACCOUNT TO ROLE consumer_role;
GRANT CREATE WAREHOUSE ON ACCOUNT TO ROLE consumer_role;
GRANT CREATE COMPUTE POOL ON ACCOUNT TO ROLE consumer_role;
GRANT CREATE APPLICATION ON ACCOUNT TO ROLE consumer_role;
GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE consumer_role;
GRANT BIND SERVICE ENDPOINT ON ACCOUNT TO ROLE consumer_role WITH GRANT OPTION;

-- Create consumer warehouse
CREATE WAREHOUSE IF NOT EXISTS wh_consumer WITH warehouse_size='xsmall';
GRANT USAGE ON WAREHOUSE wh_consumer TO ROLE consumer_role WITH GRANT OPTION;

-- Grant access to the application package (this needs to be done after the package is created)
-- We'll add a step to grant this later in the setup process

-- Create consumer database and grant permissions
CREATE DATABASE IF NOT EXISTS consumer_data;
GRANT ALL PRIVILEGES ON DATABASE consumer_data TO ROLE consumer_role;
GRANT ALL PRIVILEGES ON ALL SCHEMAS IN DATABASE consumer_data TO ROLE consumer_role;
GRANT ALL PRIVILEGES ON FUTURE SCHEMAS IN DATABASE consumer_data TO ROLE consumer_role;

-- Switch to the database to grant additional permissions
USE DATABASE consumer_data;
GRANT ALL PRIVILEGES ON ALL TABLES IN DATABASE consumer_data TO ROLE consumer_role;
GRANT ALL PRIVILEGES ON ALL STAGES IN DATABASE consumer_data TO ROLE consumer_role;
GRANT ALL PRIVILEGES ON FUTURE TABLES IN DATABASE consumer_data TO ROLE consumer_role;
GRANT ALL PRIVILEGES ON FUTURE STAGES IN DATABASE consumer_data TO ROLE consumer_role;

SELECT 'Consumer role and database created successfully' AS status;
"

if [ $? -ne 0 ]; then
    echo "❌ Failed to create consumer role"
    exit 1
fi

echo "✅ Consumer role and database created successfully"
echo ""

# Step 1: Create Schema and Tables
echo "📋 Step 1: Setting up consumer schema and tables..."

snow sql -q "
USE ROLE consumer_role;
USE DATABASE consumer_data;

-- Create schema for social network data
CREATE SCHEMA IF NOT EXISTS social_network;
USE SCHEMA social_network;

-- Create stage for file uploads
CREATE STAGE IF NOT EXISTS csv_stage;

-- Create shared staging area for app exports
CREATE STAGE IF NOT EXISTS app_shared_stage;

-- Create tables for social network data
CREATE OR REPLACE TABLE social_nodes (
    name VARCHAR(100),
    node_label VARCHAR(50)
);

CREATE OR REPLACE TABLE social_relationships (
    from_name VARCHAR(100),
    to_name VARCHAR(100),
    relationship_type VARCHAR(50)
);

SELECT 'Consumer database setup complete' AS status;
"

if [ $? -ne 0 ]; then
    echo "❌ Failed to create consumer database and schema"
    exit 1
fi

echo "✅ Consumer database and schema ready!"
echo ""

# Step 2: Upload CSV files
echo "📤 Step 2: Uploading CSV files..."

# Check if CSV files exist
if [ ! -f "consumer/src/social_nodes_data.csv" ]; then
    echo "❌ Error: consumer/src/social_nodes_data.csv not found"
    exit 1
fi

if [ ! -f "consumer/src/social_relationships.csv" ]; then
    echo "❌ Error: consumer/src/social_relationships.csv not found"
    exit 1
fi

echo "📁 Found CSV files:"
echo "   - social_nodes_data.csv ($(wc -l < consumer/src/social_nodes_data.csv) lines)"
echo "   - social_relationships.csv ($(wc -l < consumer/src/social_relationships.csv) lines)"
echo ""

snow sql -q "
USE ROLE consumer_role;
USE DATABASE consumer_data;
USE SCHEMA social_network;

-- Upload CSV files
PUT file://consumer/src/social_nodes_data.csv @csv_stage auto_compress=false overwrite=true;
PUT file://consumer/src/social_relationships.csv @csv_stage auto_compress=false overwrite=true;

-- Load data into tables
COPY INTO social_nodes
FROM @csv_stage/social_nodes_data.csv
FILE_FORMAT = (TYPE = CSV FIELD_OPTIONALLY_ENCLOSED_BY = '\"' SKIP_HEADER = 1);

COPY INTO social_relationships  
FROM @csv_stage/social_relationships.csv
FILE_FORMAT = (TYPE = CSV FIELD_OPTIONALLY_ENCLOSED_BY = '\"' SKIP_HEADER = 1);

-- Check loaded data
SELECT 'Nodes loaded: ' || COUNT(*) AS nodes_status FROM social_nodes;
SELECT 'Relationships loaded: ' || COUNT(*) AS relationships_status FROM social_relationships;
"

if [ $? -ne 0 ]; then
    echo "❌ Failed to upload CSV data"
    exit 1
fi

echo "✅ CSV data uploaded successfully!"
echo ""

echo "🎉 Consumer setup complete!"
echo ""
echo "📊 Summary:"
echo "   ✅ Consumer database created: consumer_data"
echo "   ✅ Social network schema created: social_network"
echo "   ✅ Tables created: social_nodes, social_relationships"
echo "   ✅ CSV data uploaded and loaded"
echo ""
echo "📍 Check your data with:"
echo "   snow sql -q \"USE ROLE consumer_role; SELECT COUNT(*) FROM consumer_data.social_network.social_nodes;\""
echo "   snow sql -q \"USE ROLE consumer_role; SELECT COUNT(*) FROM consumer_data.social_network.social_relationships;\""
echo ""