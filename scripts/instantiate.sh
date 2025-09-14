#!/bin/bash

# FalkorDB Application Instantiation Script
# This script creates the FalkorDB app instance and uploads consumer data

set -e

SCRIPT_DIR="$(dirname "$0")"

echo "🚀 FalkorDB Application Instantiation"
echo "======================================"
echo ""

# Step 1: Create the application instance
echo "📱 Step 1: Creating FalkorDB application instance..."
snow sql -f "$SCRIPT_DIR/instantiate.sql"

if [ $? -ne 0 ]; then
    echo "❌ Failed to create application instance"
    exit 1
fi

echo "✅ Application instance created successfully!"
echo ""

# Step 2: Upload consumer data
echo "📊 Step 2: Uploading consumer data..."
cd "$(dirname "$SCRIPT_DIR")" # Go to project root
./upload_consumer_data.sh

if [ $? -ne 0 ]; then
    echo "❌ Failed to upload consumer data"
    echo "⚠️  Application instance was created but consumer data upload failed"
    exit 1
fi

echo ""
echo "🎉 FalkorDB application instantiation complete!"
echo "✅ Application instance created"
echo "✅ Consumer data uploaded and permissions granted"
echo ""


