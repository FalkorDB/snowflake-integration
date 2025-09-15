#!/bin/bash

# App Teardown Script for FalkorDB Native App
# This script removes the application package and infrastructure
# Usage: ./teardown_app.sh

set -e

SCRIPT_DIR="$(dirname "$0")"

echo "🧹 FalkorDB App Teardown Script"
echo "🗑️  Removing application package and infrastructure"
echo "=================================================="
echo ""

# Step 1: Clean up application package and infrastructure
echo "🗑️  Step 1: Removing application package and infrastructure..."

snow sql -q "
--Step 1 - Clean Up Provider Objects
-- Use ACCOUNTADMIN to ensure we have sufficient privileges
USE ROLE ACCOUNTADMIN;

-- Drop application package if it exists
DROP APPLICATION PACKAGE IF EXISTS falkordb_app_pkg;

-- Drop database objects in correct order (if they exist)
DROP DATABASE IF EXISTS falkordb_app CASCADE;
DROP WAREHOUSE IF EXISTS wh_falkordb;

-- Drop the role if it exists
DROP ROLE IF EXISTS falkordb_role;

SELECT 'Application infrastructure removed' AS status;
"

if [ $? -ne 0 ]; then
    echo "❌ Failed to remove application infrastructure"
    exit 1
fi

echo "✅ Application infrastructure removed successfully!"
echo ""

# Step 2: Clean up roles
echo "🗑️  Step 2: Removing roles..."

snow sql -q "
--Step 2 - Clean Up Roles (as admin)
USE ROLE accountadmin;
DROP ROLE IF EXISTS falkordb_role;

SELECT 'Application roles removed' AS status;
"

if [ $? -ne 0 ]; then
    echo "❌ Failed to remove application roles"
    exit 1
fi

echo "✅ Application roles removed successfully!"
echo ""

echo "🎉 App teardown complete!"
echo ""
echo "📊 Summary:"
echo "   ✅ Application package removed: falkordb_app_pkg"
echo "   ✅ Application database removed: falkordb_app"
echo "   ✅ Image repository and stage removed"
echo "   ✅ Application warehouse removed: wh_falkordb"
echo "   ✅ Application role removed: falkordb_role"
echo ""