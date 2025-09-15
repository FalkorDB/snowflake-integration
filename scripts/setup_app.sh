#!/bin/bash

# App Setup Script for FalkorDB Native App  
# This script sets up the application infrastructure, builds Docker image, and publishes the app
# Usage: ./setup_app.sh

set -e

SCRIPT_DIR="$(dirname "$0")"

echo "🚀 FalkorDB App Setup Script"
echo "🔧 Setting up application infrastructure and publishing app"
echo "======================================================="
echo ""

# Step 1: Setup application infrastructure
echo "📋 Step 1: Setting up application infrastructure..."
snow sql -f "$SCRIPT_DIR/setup.sql"

if [ $? -ne 0 ]; then
    echo "❌ Failed to setup application infrastructure"
    exit 1
fi

echo "✅ Application infrastructure ready!"
echo ""

# Step 2: Build and push Docker image
echo "🐳 Step 2: Building and pushing Docker image..."
$SCRIPT_DIR/docker_push.sh

if [ $? -ne 0 ]; then
    echo "❌ Failed to build and push Docker image"
    exit 1
fi

echo "✅ Docker image built and pushed!"
echo ""

# Step 3: Upload application files
echo "📤 Step 3: Uploading application files..."
$SCRIPT_DIR/upload_files.sh

if [ $? -ne 0 ]; then
    echo "❌ Failed to upload application files"
    exit 1
fi

echo "✅ Application files uploaded!"
echo ""

# Step 4: Create and publish application
echo "📦 Step 4: Creating and publishing application..."
snow sql -f "$SCRIPT_DIR/create_application.sql"

if [ $? -ne 0 ]; then
    echo "❌ Failed to create and publish application"
    exit 1
fi

echo "✅ Application created and published!"
echo ""

echo "🎉 FalkorDB app setup complete!"
echo ""
echo "📊 Summary:"
echo "   ✅ Application infrastructure setup"
echo "   ✅ Docker image built and pushed"
echo "   ✅ Application files uploaded"
echo "   ✅ Application package created and published"
echo ""
echo "📍 Next step: Run ./instansiate_app.sh to create an app instance"
echo ""