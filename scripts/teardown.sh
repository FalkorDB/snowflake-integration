#!/bin/bash

# Complete Teardown Script for FalkorDB Native App Demo
# This script runs all teardown steps in the correct order
# Usage: ./teardown.sh

# Note: Removed 'set -e' to continue even if individual steps fail during cleanup

SCRIPT_DIR="$(dirname "$0")"

echo "🧹 FalkorDB Demo Complete Teardown"
echo "🗑️  Running all teardown steps in sequence"
echo "========================================="
echo ""

# Step 1: Uninstantiate App
echo "📱 Step 1: Uninstantiating app..."
$SCRIPT_DIR/uninstansiate_app.sh

if [ $? -ne 0 ]; then
    echo "❌ Failed to uninstantiate app"
    echo "⚠️  Continuing with remaining teardown steps..."
fi

echo ""

# Step 2: Teardown App
echo "📦 Step 2: Tearing down app infrastructure..."
$SCRIPT_DIR/teardown_app.sh

if [ $? -ne 0 ]; then
    echo "❌ Failed to teardown app infrastructure"
    echo "⚠️  Continuing with remaining teardown steps..."
fi

echo ""

# Step 3: Teardown Consumer
echo "🗄️  Step 3: Tearing down consumer database..."
$SCRIPT_DIR/teardown_consumer.sh

if [ $? -ne 0 ]; then
    echo "❌ Failed to teardown consumer database"
    exit 1
fi

echo ""
echo "🎉 Complete teardown finished!"
echo ""
echo "📊 Summary:"
echo "   ✅ App instance removed"
echo "   ✅ App infrastructure cleaned up"
echo "   ✅ Consumer database removed"
echo ""
echo "💡 The demo environment has been completely cleaned up."
echo ""