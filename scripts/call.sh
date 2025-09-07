#!/usr/bin/env bash
SCRIPT_DIR="$(dirname "$0")"
ARG="hello world"  

# Call the toUpper procedure exposed by the application instance
snow sql -q "use role consumer_role; use database FALKORDB_APP_INSTANCE; call app_public.toUpper('$ARG');"

snow sql -q "use role consumer_role; use database FALKORDB_APP_INSTANCE; call app_public.list_graphs();"

# directly call the service function 
snow sql -q "USE ROLE consumer_role; USE DATABASE FALKORDB_APP_INSTANCE;  SELECT app_public.list_graphs_raw({'test': 'direct_call'});"




# call the procedure to load CSV data using wrapper
snow sql -q "use role consumer_role; use database FALKORDB_APP_INSTANCE;  CALL app_public.load_csv('Lee Pace,1979\nVin Diesel,1967\nChris Pratt,1979\nZoe Saldana,1978','LOAD CSV FROM ''file://actors.csv'' AS row MERGE (a:Actor {name: row[0], birth_year: toInteger(row[1])}) RETURN a.name, a.birth_year','social');"

# directly call the service function to load CSV data
snow sql -q "USE ROLE consumer_role; USE DATABASE FALKORDB_APP_INSTANCE;  SELECT app_public.load_csv_raw({'csv_data': 'Lee Pace,1979\nVin Diesel,1967\nChris Pratt,1979\nZoe Saldana,1978',  'cypher_query': 'LOAD CSV FROM ''file://actors.csv'' AS row MERGE (a:Actor {name: row[0], birth_year: toInteger(row[1])}) RETURN a.name, a.birth_year', 'graph_name': 'social'});"



curl -X POST \
  -H "Content-Type: application/json" \
  -H "User-Agent: Snowflake" \
  -d '{
    "data": [
      [
        0,
        {
          "csv_data": "Lee Pace,1979\nVin Diesel,1967\nChris Pratt,1979\nZoe Saldana,1978",
          "cypher_query": "LOAD CSV FROM 'file://actors.csv' AS row MERGE (a:Actor {name: row[0], birth_year: toInteger(row[1])}) RETURN a.name, a.birth_year",
          "graph_name": "social"
        }
      ]
    ]
  }' \
  http://localhost:8080/load_csv


"GRAPH.QUERY" "social" "LOAD CSV FROM file://d3df13f8-da49-45dc-aba6-3990beb77b35.csv AS row MERGE (a:Actor {name: row[0], birth_year: toInteger(row[1])}) RETURN a.name, a.birth_year" "--compact"
"GRAPH.QUERY" "social" "LOAD CSV FROM file://actors.csv                               AS row MERGE (a:Actor {name: row[0], birth_year: toInteger(row[1])}) RETURN a.name, a.birth_year"