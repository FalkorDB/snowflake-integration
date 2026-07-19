# Air Routes Use Cases

Two graph algorithm use cases on the air routes demo, runnable straight from Snowflake.

## 1. Cheapest route: weighted shortest path

**Story:** A passenger flies Sydney (SYD) to New York (JFK). What is the route with the fewest total kilometers, including every stop along the way?

```sql
CALL <app_instance_name>.app_public.shortest_path(
  'airroutes',      -- graph name
  'Airport',        -- node label
  'iata_code',      -- node property
  'SYD',            -- source
  'JFK',            -- target
  'ROUTE',          -- relationship type
  'distance_km'     -- property to minimize
);
```

Returns the total distance (`pathWeight`) and the ordered list of airports on the cheapest path.

## 2. Route planning: PageRank

**Story:** An airline is planning a new route. Which airport gives the best connectivity for onward flights? PageRank scores airports by how well they connect to other well-connected hubs, so passengers landing there can reach anywhere in one hop. The same ranking works for risk analysis: whose closure would disrupt the network most?

```sql
CALL <app_instance_name>.app_public.page_rank(
  'airroutes',   -- graph name
  'Airport',     -- node label
  'ROUTE',       -- relationship type
  'iata_code',   -- property to show per node
  10             -- top N results
);
```

Returns the 10 highest-ranked airports with their scores, most important first.
