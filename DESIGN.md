# Design

## Goal

Make "Exasol Personal database + MCP server (LLM/NL access) + JSON Tables (JSON-native SQL)" come up with a **single command**, on top of the official Exasol Personal launcher.

## Components and why they are arranged this way

| Component | What it is | Where it runs | Why |
| --- | --- | --- | --- |
| Exasol Personal | Go launcher (`exasol`) that provisions a real Exasol DB | **Host** (local VM on macOS, or cloud) | Personal is not a container image; it manages its own DB lifecycle. We consume the endpoint it produces. |
| MCP Server | `exasol-mcp-server` pip package, HTTP mode on `:4896` | Container | Clean pip install. Needs only client→DB connectivity, which works fine to a host DB. |
| JSON Tables | Python CLI that shells out to a Rust (`cargo`) ingest engine | Container (standing, CLI `exec`'d) | Needs the full repo + Rust toolchain at runtime; isolated because of a conflicting `pyexasol` pin. |

### Dependency isolation

- MCP Server: `pyexasol>=1,<2`
- JSON Tables: `pyexasol>=2.2,<3`

These cannot coexist in one Python environment, so the two tools run in separate containers. They are independent of each other; both only talk to the database.

## Connection discovery

The installer does not hardcode a DSN. After ensuring a database is running it reads:

- `exasol info --json` → `connection.host`, `connection.dbPort`, `connection.username`, `connection.insecureSkipCertValidation`
- `<deploymentDir>/secrets.json` → `dbPassword` (defaults to `~/.exasol/personal/deployments/default/secrets.json`)

Local Personal deployments default to user `sys` / password `exasol`, but the password is read from `secrets.json` rather than assumed. The discovered values are written to `~/.exasol-personal-ai/.env`, which `compose.yaml` consumes.

From inside the containers the host DB is reached as `host.docker.internal:<dbPort>` (resolved natively on Docker Desktop; `extra_hosts: host-gateway` covers Linux engines). TLS certificate validation is disabled for both tools because the local DB uses a self-signed certificate (`insecureSkipCertValidation` is true for local deployments).

## JSON Tables ingest connectivity (known caveat)

Exasol's bulk import uses **HTTP transport**: the CLI opens a local HTTP endpoint and the **database connects back to it** to pull the data. This works trivially when the DB and the client share a network (as in an all-container compose stack).

Here the DB lives on the host (inside Personal's managed VM) and JSON Tables runs in a container. The DB→client (reverse) direction is not guaranteed across that boundary, so **ingest may fail** even though `wrap`, `describe`, `validate`, and query operations (client→DB only) work.

**Host-mode fallback for ingest** — run the JSON Tables CLI directly on the Mac host, where it shares `127.0.0.1` with the Personal DB and the reverse connection is local:

```bash
# one-time, on the host
git clone https://github.com/exasol-labs/exasol-json-tables.git
cd exasol-json-tables
python3 -m pip install -e .          # needs Python 3.10+ and a Rust toolchain (rustup)

# read the live port: exasol info
exasol-json-tables ingest-and-wrap \
  --input data.json --name my_events \
  --dsn 127.0.0.1:<dbPort> --user sys --password <password>
```

A cleaner long-term fix is to teach JSON Tables to advertise a reachable callback address (so the containerized CLI can publish a fixed transport port the host DB can reach), or to ship JSON Tables as a self-contained wheel that the installer runs on the host.

## Platform

Personal's `install local` is macOS Apple Silicon only (enforced by the launcher). On other platforms, provision a cloud DB with the launcher and run this installer with `EXASOL_SKIP_DB_DEPLOY=1`, supplying `EXASOL_DB_HOST` / `EXASOL_DB_PORT` (and credentials via the launcher's secrets) so the containers target the remote endpoint.

## Security defaults

- MCP runs read-only (`enable_write_query: false`) and is published only on `127.0.0.1:4896`.
- The MCP `--no-auth` flag keeps the local endpoint open for local LLM clients; do not expose the port beyond localhost.
- Credentials live only in `~/.exasol-personal-ai/.env` (chmod it / keep the dir private).

## Release checklist

- Pin JSON Tables to a tested tag/commit (not `main`).
- Keep MCP Server pinned (`1.10.1`).
- Publish `install.sh` + assets as release artifacts with SHA256 checksums.
- Validate end-to-end on a clean Apple-Silicon Mac, including the ingest path.
