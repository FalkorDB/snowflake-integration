SCRIPT_DIR="$(dirname "$0")"

# List files to be uploaded
echo "Files to upload:"
ls -la "$SCRIPT_DIR/../app/src/"

# Upload files
snow sql -q "use role falkordb_role; put file://$SCRIPT_DIR/../app/src/* @falkordb_app.napp.app_stage auto_compress=false overwrite=true;"

# Check if upload succeeded
if [ $? -ne 0 ]; then
	echo "❌ Error: File upload failed. Please check the output above."
	exit 1
fi

echo "✅ Application files uploaded!"

