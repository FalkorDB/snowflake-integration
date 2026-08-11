# Demo Scripts

Two scripts that run the **Air Routes demo** end to end against a FalkorDB Native App
in your own Snowflake account, from your laptop.

```bash
./scripts/demo_up.sh      # start everything and load the demo graph
./scripts/demo_down.sh    # stop everything so nothing keeps billing
```

They run **locally** — they are just wrappers around the [Snowflake CLI](https://docs.snowflake.com/en/developer-guide/snowflake-cli/index)
(`snow`), which talks to your account over the network. Nothing runs inside Snowflake
except the SQL they send.

> ⚠️ **This costs money.** The demo starts a compute pool, which bills **per node-hour**
> for as long as it is running. Always finish with `./scripts/demo_down.sh`.
> See [Cost](#cost) below.

---

## Before you start

### 1. Install the Snowflake CLI

```bash
pip install snowflake-cli
snow --version
```

### 2. Create a connection

The scripts never create a connection — they use whatever `snow` is already configured
with. Create one once:

```bash
snow connection add
```

You will be prompted for your account identifier (e.g. `myorg-myaccount`), user,
password/authenticator, and optionally a default role and warehouse. Verify it:

```bash
snow connection test
```

This writes to `~/.snowflake/config.toml` (on macOS,
`~/Library/Application Support/snowflake/config.toml`).

If you keep several connections, pick one per run with `FALKORDB_SNOW_CONNECTION`;
otherwise your default connection is used.

### 3. Install the FalkorDB Native App

**The scripts assume the application already exists.** They call `start_app` on it, but
never create it. Install it first, either from the Snowflake Marketplace or, if you are
developing the app itself, with the setup scripts in this directory:

```bash
./scripts/setup_consumer.sh     # consumer database, schema, tables
./scripts/setup_app.sh          # build/push the image, publish the app package
./scripts/instansiate_app.sh    # create the application instance
```

Your role also needs the account-level privileges the app requires:
`CREATE COMPUTE POOL`, `CREATE WAREHOUSE`, `BIND SERVICE ENDPOINT`, and
`IMPORTED PRIVILEGES ON SNOWFLAKE DB`.

---

## The data

The demo builds a graph of the world's airports and the airline routes between them.
The CSVs live in [`examples/airroutes/`](../examples/airroutes/) — a different directory
from these scripts, but `demo_up.sh` resolves them relative to the repo root, so you do
not need to move or download anything.

| File | Size | Rows | What it is |
|---|---|---|---|
| `examples/airroutes/airports.csv` | ~7.9 MB | ~47.9k | One row per airport: IATA/ICAO codes, name, country, latitude/longitude |
| `examples/airroutes/routes.csv` | ~2.6 MB | ~67.2k | One row per airline route: airline, source airport, destination airport, stops |

These are the standard open aviation datasets: airports from
[OurAirports](https://ourairports.com/data/) (public domain) and routes from
[OpenFlights](https://openflights.org/data.html) (ODbL).

`demo_up.sh` uploads them into Snowflake tables it creates for you:

```
ROUTES_DEMO.PUBLIC.AIRPORTS
ROUTES_DEMO.PUBLIC.ROUTES
ROUTES_DEMO.PUBLIC.AIRROUTES_STAGE   -- internal stage used for the upload
```

Each table is then bound to the application with `register_callback` +
`SYSTEM$REFERENCE`, so you do **not** need to click through the Permissions UI.

For the same demo done by hand, query by query, see
[`examples/airroutes/README.md`](../examples/airroutes/README.md).

---

## Running it

```bash
./scripts/demo_up.sh
```

Six steps, roughly 5–10 minutes on a cold start:

1. Start the compute pool, warehouse and the FalkorDB service
2. Wait until the service is READY **and actually answering queries**
3. Upload the Air Routes CSVs into Snowflake tables
4. Create the graph indexes — *before* any data is loaded
5. Load airports, then routes, then compute route distances
6. Print the FalkorDB Browser URL

Then explore the graph in the Browser, or run the sample queries the script prints —
`shortest_path` (SYD→JFK) and `page_rank` (busiest hubs).

When you are done:

```bash
./scripts/demo_down.sh
```

Both scripts are safe to re-run. A cold start (nothing exists) and a warm start
(resuming what `demo_down.sh` suspended) take the same path.

### Flags

| Command | What it does |
|---|---|
| `./scripts/demo_up.sh` | Full run: start the service and load the demo graph |
| `./scripts/demo_up.sh --skip-upload` | Rebuild the graph, reuse tables from a previous run (skips ~11 MB of CSV) |
| `./scripts/demo_up.sh --no-data` | Start the service only, load nothing |
| `./scripts/demo_down.sh` | Suspend the service **and** the compute pool |
| `./scripts/demo_down.sh --drop` | Drop the service instead of suspending it |

Use `--drop` when you want to restart with different container resources. Otherwise the
default is faster: the service definition stays, so `demo_up.sh` restarts in seconds.

### Settings

Every default can be overridden with an environment variable. The defaults match the
names used in this repo's setup scripts — **if you installed the app from the
Marketplace, or under different names, you must override them.**

| Variable | Default | What it is |
|---|---|---|
| `FALKORDB_APP_NAME` | `falkordb_app_instance` | The application instance |
| `FALKORDB_ROLE` | `consumer_role` | Role passed to `snow --role` |
| `FALKORDB_POOL` | `POOL_CONSUMER` | Compute pool |
| `FALKORDB_WAREHOUSE` | `WH_CONSUMER` | Warehouse |
| `FALKORDB_DEMO_DB` | `ROUTES_DEMO` | Database holding the demo tables |
| `FALKORDB_SNOW_CONNECTION` | *(your default)* | Which `snow` connection to use |
| `FALKORDB_READY_TIMEOUT_SECS` | `900` | How long to wait for the service to report READY |
| `FALKORDB_QUERY_TIMEOUT_SECS` | `300` | How long to wait for it to accept a query |

Example:

```bash
FALKORDB_APP_NAME=my_falkordb_app \
FALKORDB_ROLE=ACCOUNTADMIN \
FALKORDB_POOL=MY_POOL \
FALKORDB_WAREHOUSE=MY_WH \
./scripts/demo_up.sh
```

---

## Cost

The compute pool is the expensive part. It bills per node-hour in the `ACTIVE`, `IDLE`,
`RESIZING` **and `STOPPING`** states — **only `SUSPENDED` is free.** A `CPU_X64_S` pool
runs about **0.11 credits/node-hour**, or roughly 79 credits a month if you forget it.

`AUTO_SUSPEND_SECS` will *not* save you. It only fires once the pool is idle, and the
FalkorDB service is a long-running container, so the pool is never idle.

This is why `demo_down.sh` exists and why it waits for the pool to actually report
`SUSPENDED` before telling you it is done. If a run fails partway through, `demo_up.sh`
prints the exact teardown command — run it.

To check at any time:

```bash
snow sql -q "CALL <app_name>.app_public.get_compute_status();"
snow sql -q "SHOW COMPUTE POOLS;"
```

---

## Troubleshooting

**`Insufficient privileges ... must have OPERATE granted`** when suspending a pool —
a pool created by the app is owned by the *application*, so even `ACCOUNTADMIN` cannot
touch it by default:

```sql
GRANT OPERATE ON COMPUTE POOL <pool> TO ROLE <your_role>;
ALTER COMPUTE POOL <pool> SUSPEND;
```

**`503 ... Connection refused`** — the service reports READY before FalkorDB is
listening. `demo_up.sh` handles this by polling a real query, but if you query manually
right after `start_app`, wait a few seconds.

**The service is READY but never answers** — a service resumed after a very long suspend
can wedge. Reset it:

```bash
./scripts/demo_down.sh --drop && ./scripts/demo_up.sh
```

**Data disappeared after a restart** — expected. Graph data is not persisted; the
service mounts a stage for CSV import only. `demo_up.sh` reloads it every time.

**Logs:**

```bash
snow sql -q "CALL <app_name>.app_public.get_service_logs('0', 'falkordb-server', 100);"
```
