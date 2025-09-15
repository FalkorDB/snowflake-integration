#!/bin/bash

# FalkorDB Application Uninstantiation Script
# This script removes the FalkorDB app instance
# Usage: ./uninstansiate_app.sh

set -e

SCRIPT_DIR="$(dirname "$0")"

echo "🗑️  FalkorDB Application Uninstantiation"
echo "📱 Removing app instance"
echo "======================================="
echo ""

# Step 1: Remove the application instance
echo "📱 Step 1: Removing FalkorDB application instance..."
snow sql -f "$SCRIPT_DIR/uninstantiate.sql"

if [ $? -ne 0 ]; then
    echo "❌ Failed to remove application instance"
    exit 1
fi

echo "✅ Application instance removed successfully!"
echo ""

echo "🎉 FalkorDB application uninstantiation complete!"
echo ""
echo "📊 Summary:"
echo "   ✅ Application instance removed: falkordb_app_instance"
echo "   ✅ Instance-specific resources cleaned up"
echo ""
echo "📍 Note: Consumer data remains intact"
echo "📍 Use teardown_consumer.sh if you want to remove consumer data"
echo ""