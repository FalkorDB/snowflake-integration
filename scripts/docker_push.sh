echo "Getting repository information using JSON format..."
json_output=$(snow sql --format JSON -q "use role falkordb_role; show image repositories in schema falkordb_app.napp;" 2>/dev/null)

if [ $? -ne 0 ] || [ -z "$json_output" ]; then
    echo "❌ Failed to get repository information from Snowflake"
    exit 1
fi

# Extract repository URL using jq - handle nested JSON structure
repository_url=$(echo "$json_output" | jq -r '.[1][0].repository_url // empty' 2>/dev/null)

if [ ! -z "$repository_url" ] && [[ "$repository_url" =~ .*registry\.snowflakecomputing\.com.* ]]; then
    echo "✅ Extracted repository URL: $repository_url"
else
    echo "❌ Failed to extract repository URL using JSON/jq method."
    echo "JSON output for debugging:"
    echo "$json_output"
    echo "Please ensure jq is installed: brew install jq"
    exit 1
fi

# Log in to Docker registry using local token file
echo "🔐 Logging into Docker registry using local token..."

# Extract registry host from repository URL
registry_host=$(echo "$repository_url" | sed 's|/.*||')

# Read token from local file
if [ ! -f "token" ]; then
    echo "❌ Token file not found. Please ensure 'token' file exists in the project root."
    exit 1
fi

token=$(head -n 1 token)

if [ -z "$token" ]; then
    echo "❌ Token file is empty or invalid."
    exit 1
fi

# Login with token from file
echo "$token" | docker login "$registry_host" -u barak --password-stdin || {
	echo "❌ Docker login failed with token from file. Please check your token and credentials."
	exit 1
}

echo "✅ Successfully logged into Docker registry!"

FALKORDB_IMAGE="text-to-cypher:v0.1.5-beta.20"   # source image to pull
TARGET_IMAGE_NAME="falkordb_server"              # image name expected by falkordb.yml
TARGET_TAG="latest"                              # falkordb.yml has no tag -> defaults to 'latest'

docker pull --platform linux/amd64 "falkordb/$FALKORDB_IMAGE" || {
	echo "❌ Failed to pull FalkorDB Docker image: \"falkordb/$FALKORDB_IMAGE"
	exit 1
}

docker tag "falkordb/$FALKORDB_IMAGE" "$repository_url/$TARGET_IMAGE_NAME:$TARGET_TAG"
docker push "$repository_url/$TARGET_IMAGE_NAME:$TARGET_TAG" || {
	echo "❌ Failed to push FalkorDB Docker image to Snowflake Container Services."
	exit 1
}

# List images currently present in the Snowflake image repository
echo "📦 Listing images in Snowflake repository..."
repo_fqn="falkordb_app.napp.img_repo"
images_json=$(snow sql --format JSON -q "use role falkordb_role; use database falkordb_app; show images in image repository ${repo_fqn};" 2>/dev/null)

if [ $? -ne 0 ] || [ -z "$images_json" ]; then
    echo "⚠️ Could not retrieve images list from repository $repo_fqn"
else
    # Try to render a compact table if expected fields exist, otherwise print raw JSON
    pretty_list=$(echo "$images_json" | jq -r '
        if (.[1] | length) == 0 then "(no images found)"
        else (.[1] | map([.repository_name // .repository // "",
                          .tag // .image_tag // "",
                          .digest // .image_digest // "",
                          .created_on // .last_modified // ""]) 
        | ( ["REPOSITORY","TAG","DIGEST","CREATED"], ["----------","---","------","-------"] ) + .
        | .[] | @tsv) end' 2>/dev/null)

    if [ -n "$pretty_list" ]; then
        echo "$pretty_list" | column -t
    else
        echo "$images_json"
    fi
fi

echo "✅ Pushed image reference to use in YAML: /falkordb_app/napp/img_repo/${TARGET_IMAGE_NAME}:${TARGET_TAG}"


