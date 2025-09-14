#!/bin/bash

# FalkorDB Application Uninstantiation Script
# This script removes the FalkorDB app instance and cleans up consumer data

set -e

SCRIPT_DIR="$(dirname "$0")"

echo "🗑️  FalkorDB Application Uninstantiation"
echo "======================================="
echo ""

# Step 1: Clean up consumer data
echo "🧹 Step 1: Cleaning up consumer data..."
snow sql -q "
USE ROLE consumer_role;

-- Drop consumer database and all its contents
DROP DATABASE IF EXISTS consumer_data;

SELECT 'Consumer data cleaned up' AS status;
"

if [ $? -eq 0 ]; then
    echo "✅ Consumer data cleaned up successfully!"
else
    echo "⚠️  Warning: Consumer data cleanup may have failed (this is okay if it didn't exist)"
fi

echo ""

# Step 2: Remove the application instance
echo "📱 Step 2: Removing FalkorDB application instance..."
snow sql -f "$SCRIPT_DIR/uninstantiate.sql"

if [ $? -ne 0 ]; then
    echo "❌ Failed to remove application instance"
    exit 1
fi

echo "✅ Application instance removed successfully!"
echo ""
echo "🎉 FalkorDB application uninstantiation complete!"
echo "✅ Consumer data cleaned up"
echo "✅ Application instance removed"
echo ""
