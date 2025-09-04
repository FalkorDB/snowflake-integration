SCRIPT_DIR="$(dirname "$0")"

snow sql -f $SCRIPT_DIR/uninstantiate.sql
