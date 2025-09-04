#!/usr/bin/env bash
SCRIPT_DIR="$(dirname "$0")"
ARG="hello world"  

# Call the toUpper procedure exposed by the application instance
snow sql -q "use role consumer_role; use database FALKORDB_APP_INSTANCE; call app_public.toUpper('$ARG');"

snow sql -q "use role consumer_role; use database FALKORDB_APP_INSTANCE; call app_public.list_graphs();"

# directly call the service function 
snow sql -q "USE ROLE consumer_role; USE DATABASE FALKORDB_APP_INSTANCE;  SELECT app_public.list_graphs_raw({'test': 'direct_call'});"