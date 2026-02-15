#!/bin/bash

# FalkorDB Snowflake Native App - Release New Patch
# Usage: ./release_new_patch.sh [patch_number] "comment"
# Example: ./release_new_patch.sh 18 "Fix CSV loading bug"

PATCH_NUMBER=$1
PATCH_COMMENT="${2:-Release patch $1}"

echo "🚀 Releasing new patch: $PATCH_NUMBER"
echo "📝 Comment: $PATCH_COMMENT"
echo ""

# Step 1: Update manifest.yml with new patch number and comment
echo "Step 1: Update manifest.yml..."
sed -i.bak "s/^  patch: .*/  patch: $PATCH_NUMBER/" app/src/manifest.yml
sed -i.bak "s/^  comment: .*/  comment: \"$PATCH_COMMENT\"/" app/src/manifest.yml
rm -f app/src/manifest.yml.bak
echo "✅ Updated manifest.yml: patch=$PATCH_NUMBER, comment=\"$PATCH_COMMENT\""
echo ""

# Step 2: Upload files to stage (uncompressed)
echo "Step 2: Upload files to stage..."
snow sql -q "USE ROLE falkordb_role; PUT file://app/src/* @falkordb_app.napp.app_stage AUTO_COMPRESS=FALSE OVERWRITE=TRUE;"
echo ""

# Step 3: Create the new patch
echo "Step 3: Create new patch for version V2..."
snow sql -q "USE ROLE falkordb_role; ALTER APPLICATION PACKAGE falkordb_app_pkg ADD PATCH FOR VERSION V2 USING @falkordb_app.napp.app_stage;"
echo ""

# Step 4: Wait for security scan approval (15-30 seconds)
echo "Step 4: Wait for security scan approval..."
sleep 30
echo ""

# Step 5: Check approval status (look for "APPROVED")
echo "Step 5: Check approval status..."
snow sql -q "USE ROLE falkordb_role; SHOW VERSIONS IN APPLICATION PACKAGE falkordb_app_pkg;" | grep "V2.*$PATCH_NUMBER"
echo ""

# Step 6: Set as DEFAULT
echo "Step 6: Set patch $PATCH_NUMBER as DEFAULT..."
snow sql -q "USE ROLE falkordb_role; ALTER APPLICATION PACKAGE falkordb_app_pkg MODIFY RELEASE CHANNEL DEFAULT SET DEFAULT RELEASE DIRECTIVE VERSION=V2 PATCH=$PATCH_NUMBER;"
echo ""

# Step 7: Verify it's DEFAULT
echo "Step 7: Verify DEFAULT status..."
snow sql -q "USE ROLE falkordb_role; SHOW VERSIONS IN APPLICATION PACKAGE falkordb_app_pkg;"
echo ""

echo "✅ Done! Patch $PATCH_NUMBER is now DEFAULT in marketplace."
