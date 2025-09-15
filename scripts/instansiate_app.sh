#!/bin/bash

# FalkorDB Application Instantiation Script
# This script creates the FalkorDB app instance and sets up staging connections
# Usage: ./instansiate_app.sh

set -e

SCRIPT_DIR="$(dirname "$0")"

echo "🚀 FalkorDB Application Instantiation"
echo "📱 Creating app instance and setting up staging"
echo "=============================================="
echo ""

# Step 1: Grant application package access to consumer role
echo "🔑 Step 1: Granting application package access to consumer role..."

snow sql -q "
USE ROLE ACCOUNTADMIN;
-- Grant access to the application package to consumer_role
GRANT INSTALL, DEVELOP ON APPLICATION PACKAGE falkordb_app_pkg TO ROLE consumer_role;

SELECT 'Application package access granted to consumer_role' AS status;
"

if [ $? -ne 0 ]; then
    echo "❌ Failed to grant application package access"
    exit 1
fi

echo "✅ Application package access granted!"
echo ""

# Step 2: Create the application instance
echo "📱 Step 2: Creating FalkorDB application instance..."
snow sql -f "$SCRIPT_DIR/instantiate.sql"

if [ $? -ne 0 ]; then
    echo "❌ Failed to create application instance"
    exit 1
fi

echo "✅ Application instance created successfully!"
echo ""

# Step 3: Grant permissions to the app for consumer data access
echo "🔑 Step 3: Granting permissions to FalkorDB app..."

snow sql -q "
USE ROLE consumer_role;

-- Grant permissions to the FalkorDB application
GRANT USAGE ON DATABASE consumer_data TO APPLICATION falkordb_app_instance;
GRANT USAGE ON SCHEMA consumer_data.social_network TO APPLICATION falkordb_app_instance;
GRANT SELECT ON TABLE consumer_data.social_network.social_nodes TO APPLICATION falkordb_app_instance;
GRANT SELECT ON TABLE consumer_data.social_network.social_relationships TO APPLICATION falkordb_app_instance;

-- Grant access to staging areas for volume mounts
GRANT READ, WRITE ON STAGE consumer_data.social_network.app_shared_stage TO APPLICATION falkordb_app_instance;
GRANT READ ON STAGE consumer_data.social_network.csv_stage TO APPLICATION falkordb_app_instance;

-- Grant additional database privileges needed for the service
GRANT ALL PRIVILEGES ON DATABASE consumer_data TO APPLICATION falkordb_app_instance;
GRANT ALL PRIVILEGES ON SCHEMA consumer_data.social_network TO APPLICATION falkordb_app_instance;

SELECT 'Permissions granted to FalkorDB app' AS status;
"

if [ $? -ne 0 ]; then
    echo "❌ Failed to grant permissions to FalkorDB app"
    exit 1
fi

echo "✅ Permissions granted successfully!"
echo ""

# Step 4: Start the FalkorDB application
echo "🚀 Step 4: Starting FalkorDB application..."

snow sql -q "
USE ROLE consumer_role;
-- Start the FalkorDB app with the consumer compute pool and warehouse
CALL falkordb_app_instance.app_public.start_app('POOL_CONSUMER', 'WH_CONSUMER');
"

if [ $? -ne 0 ]; then
    echo "❌ Failed to start FalkorDB application"
    exit 1
fi

echo "✅ FalkorDB application started successfully!"
echo ""

echo "🎉 FalkorDB application instantiation complete!"
echo ""
echo "📊 Summary:"
echo "   ✅ Application package access granted to consumer role"
echo "   ✅ Application instance created: falkordb_app_instance"
echo "   ✅ Permissions granted for consumer data access"
echo "   ✅ FalkorDB application service started"
echo ""
echo "📍 You can now call app procedures to load CSV data:"
echo "   load_csv(graph, table, cypher_query)"
echo ""