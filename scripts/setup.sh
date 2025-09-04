SCRIPT_DIR="$(dirname "$0")"

snow sql -f "$SCRIPT_DIR/setup.sql"

$SCRIPT_DIR/docker_push.sh

$SCRIPT_DIR/upload_files.sh

snow sql -f "$SCRIPT_DIR/create_application.sql"


