# Air Routes Demo · End to End

Load two CSVs into Snowflake, build a graph with the FalkorDB Native App, and answer a multi-hop question. This is the exact flow shown in the FalkorDB Snowflake webinar.

## Files

| File | Size | Contents |
|------|------|----------|
| `airports.csv` | ~8 MB | One row per airport (id, ident, type, name, lat/lon, country, iata_code, ...) |
| `routes.csv` | ~2.7 MB | One row per airline route (airline, source_airport, destination_airport, stops, ...) |

The `row[n]` indexes in the Cypher below match the column order of these files.

## 1. Load the CSVs into Snowflake (UI, no SQL)

1. Snowflake sidebar → **Ingestion** → **Add Data** → **Load data into a table**
2. Browse to `airports.csv` → create database `ROUTES_DEMO` → create table `AIRPORTS` → **Load**
3. Repeat for `routes.csv` → select existing `ROUTES_DEMO` → create table `ROUTES` → **Load**

Best practices for CSV uploads:
- Let Snowflake auto-detect columns, then review types before loading (lat/lon should be FLOAT, ids NUMBER)
- Keep file names and table names aligned (`airports.csv` → `AIRPORTS`) so the mapping stays obvious
- For files over ~250 MB, use a stage + `COPY INTO` instead of the UI

## 2. Install and start the FalkorDB Native App

1. **Marketplace** → search **FalkorDB** → **Get**, grant the requested privileges
2. Start the service and wait for READY:

```sql
CALL <app_instance_name>.app_public.start_app('FALKORDB_POOL', 'FALKORDB_WH');
CALL <app_instance_name>.app_public.get_service_status();
```

An empty result `[]` means still starting; re-run until you see `"status":"READY"`.

## 3. Create indexes (before loading)

```sql
CALL <app_instance_name>.app_public.graph_query('airroutes',
  'CREATE INDEX FOR (a:Airport) ON (a.id)');
CALL <app_instance_name>.app_public.graph_query('airroutes',
  'CREATE INDEX FOR (a:Airport) ON (a.iata_code)');
```

## 4. Load airports

Bind `ROUTES_DEMO.PUBLIC.AIRPORTS` to the app's `consumer_data_table` reference, then:

```sql
CALL <app_instance_name>.app_public.load_csv('airroutes',
  'LOAD CSV FROM ''file://consumer_data.csv'' AS row
   MERGE (a:Airport {id: toInteger(row[0])})
   SET a.ident = row[1], a.type = row[2], a.name = row[3],
       a.latitude = toFloat(row[4]), a.longitude = toFloat(row[5]),
       a.elevation_ft = toInteger(row[6]), a.continent = row[7],
       a.iso_country = row[8], a.iso_region = row[9],
       a.municipality = row[10], a.scheduled_service = row[11],
       a.icao_code = row[12], a.iata_code = row[13]');
```

Note: the staged file is always named `consumer_data.csv`, regardless of the bound table.

## 5. Load routes

Rebind `consumer_data_table` to `ROUTES_DEMO.PUBLIC.ROUTES`, then:

```sql
CALL <app_instance_name>.app_public.load_csv('airroutes',
  'LOAD CSV FROM ''file://consumer_data.csv'' AS row
   MATCH (src:Airport {iata_code: row[2]})
   MATCH (dst:Airport {iata_code: row[4]})
   CREATE (src)-[r:ROUTE]->(dst)
   SET r.airline = row[0], r.airline_id = row[1],
       r.source_airport = row[2], r.destination_airport = row[4],
       r.stops = toInteger(row[7]), r.equipment = row[8]');
```

## 6. Ask a multi-hop question

Flight paths from Sydney to New York JFK in up to 5 hops:

```sql
CALL <app_instance_name>.app_public.graph_query('airroutes',
  'MATCH path = (:Airport {iata_code:"SYD"})-[:ROUTE*1..5]->(:Airport {iata_code:"JFK"})
   RETURN length(path) AS hops,
          [airport IN nodes(path) | airport.iata_code] AS route_path
   LIMIT 20');
```

For the full walkthrough (including the SQL comparison and Cortex Agent setup), see the
[Snowflake integration guide](https://docs.falkordb.com/integration/snowflake.html).
