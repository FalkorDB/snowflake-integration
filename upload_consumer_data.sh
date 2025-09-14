#!/bin/bash

# Consumer Data Upload Script for FalkorDB Native App
# This script uploads social network CSV data for the FalkorDB app
# Usage: ./upload_consumer_data.sh

set -e

echo "🚀 FalkorDB Consumer Data Upload Script"
echo "📊 Uploading CSV data for FalkorDB app"
echo "=============================================="
echo ""

# Step 1: Create Consumer Database and Upload Data
echo "📋 Step 1: Setting up consumer database and uploading data..."

snow sql -q "
USE ROLE consumer_role;

-- Create consumer database if it doesn't exist
CREATE DATABASE IF NOT EXISTS consumer_data;
USE DATABASE consumer_data;

-- Create schema for social network data
CREATE SCHEMA IF NOT EXISTS social_network;
USE SCHEMA social_network;

-- Create stage for file uploads
CREATE STAGE IF NOT EXISTS csv_stage;

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

SELECT 'Database setup complete' AS status;
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

# Step 3: Grant permissions to FalkorDB app
echo "🔑 Step 3: Granting permissions to FalkorDB app..."

snow sql -q "
USE ROLE consumer_role;

-- Grant permissions to the FalkorDB application
GRANT USAGE ON DATABASE consumer_data TO APPLICATION falkordb_app_instance;
GRANT USAGE ON SCHEMA consumer_data.social_network TO APPLICATION falkordb_app_instance;
GRANT SELECT ON TABLE consumer_data.social_network.social_nodes TO APPLICATION falkordb_app_instance;
GRANT SELECT ON TABLE consumer_data.social_network.social_relationships TO APPLICATION falkordb_app_instance;

SELECT 'Permissions granted to FalkorDB app' AS status;
"

if [ $? -ne 0 ]; then
    echo "❌ Failed to grant permissions to FalkorDB app"
    exit 1
fi

echo "✅ Permissions granted successfully!"
echo ""

echo "🎉 Consumer data upload complete!"
echo ""
echo "📊 Summary:"
echo "   ✅ Consumer database created: consumer_data"
echo "   ✅ Social network schema created: social_network"
echo "   ✅ Tables created: social_nodes, social_relationships"
echo "   ✅ CSV data uploaded and loaded"
echo "   ✅ Permissions granted to FalkorDB app"
echo ""
echo "� Check your data with:"
echo "   snow sql -q \"USE ROLE consumer_role; SELECT COUNT(*) FROM consumer_data.social_network.social_nodes;\""
echo "   snow sql -q \"USE ROLE consumer_role; SELECT COUNT(*) FROM consumer_data.social_network.social_relationships;\""
echo ""
