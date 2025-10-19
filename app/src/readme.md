# FalkorDB Snowflake Native App

This repo contains a **Snowflake Native App** that lets you seamlessly integrate and query FalkorDB graph databases inside your Snowflake environment.

---

## Features

- **Import Snowflake tables to FalkorDB** using easy SQL procedures
- **Execute Cypher queries** on imported graph data
- **Secure, self-contained Snowflake-native deployment**
- **App code and dependencies** are shipped as part of the Snowflake application package (no remote code execution)
- **All code is human-readable** (not obfuscated or minified without source maps)

---

## Architecture

![Architecture Diagram](https://raw.githubusercontent.com/FalkorDB/snowflake-integration/main/falkor_snowflake_arch.png)

---

## Security Compliance

This app **fully conforms** to Snowflake's [security requirements for application code](https://docs.snowflake.com/en/developer-guide/native-apps/security-app-requirements#security-requirements-for-application-code):

- **No code loaded/executed** from outside the app package (except Snowflake-provided libraries)
- **No code obfuscation:** All code (including JavaScript) is shipped in human-readable form (or with source maps if minified).
- **All dependencies** are included and must not have unresolved critical/high CVEs.
- **No plain-text secrets** are stored or required anywhere.

For further technical details, see the [`app/src/setup.sql`](https://github.com/FalkorDB/snowflake-integration/blob/main/app/src/setup.sql) file.

---

## App Procedures

App logic and procedures are defined in [`app/src/setup.sql`](https://github.com/FalkorDB/snowflake-integration/blob/main/app/src/setup.sql). Key procedures include:

- `start_app(poolname, whname)` – Initializes the service and resources
- `load_csv(graph_name, table, cypher_query)` – Loads table data to FalkorDB and executes Cypher queries
- `graph_query(graph_name, query)` – Executes Cypher queries
- `graph_list()` – Lists all graphs
- `graph_delete(graph_name)` – Deletes a graph
- `get_service_status()`, `get_service_logs(...)`, `get_service_containers()` – Admin helpers

All logic is handled **inside the package** for full auditability.

---

## How It Works

1. **User runs a procedure** (e.g., `load_csv`, `graph_query`) from Snowflake SQL.
2. **App logic handles staging**: Loads table as CSV, manages roles/permissions, calls corresponding FalkorDB service endpoint.
3. **Results and responses** are returned to the user via Snowflake's native app framework.

---

## Installation & Usage

See [`readme.md`](https://github.com/FalkorDB/snowflake-integration/blob/main/readme.md) and included scripts for setup and usage instructions.

---