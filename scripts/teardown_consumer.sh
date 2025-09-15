#!/bin/bash

# Consumer Teardown Script for FalkorDB Native App
# This script removes the consumer database and related resources
# Usage: ./teardown_consumer.sh

set -e

echo "🧹 FalkorDB Consumer Teardown Script"
echo "🗑️  Removing consumer database and resources"
echo "============================================="
echo ""

# Step 1: Remove consumer database and resources
echo "🗑️  Step 1: Removing consumer database..."

snow sql -q "
-- Use ACCOUNTADMIN to ensure we have sufficient privileges
USE ROLE ACCOUNTADMIN;

-- Drop consumer databases (both possible names) and all their contents
DROP DATABASE IF EXISTS consumer_data CASCADE;
DROP DATABASE IF EXISTS consumer_db CASCADE;

-- Drop the warehouses
DROP WAREHOUSE IF EXISTS wh_consumer;

-- Drop the consumer role
DROP ROLE IF EXISTS consumer_role;

SELECT 'Consumer resources removed' AS status;
"

if [ $? -ne 0 ]; then
    echo "❌ Failed to remove consumer database"
    exit 1
fi

echo "✅ Consumer database removed successfully!"
echo ""

echo "🎉 Consumer teardown complete!"
echo ""
echo "📊 Summary:"
echo "   ✅ Consumer database dropped: consumer_data"
echo "   ✅ All schemas and tables removed"
echo "   ✅ Staging areas cleaned up"
echo ""