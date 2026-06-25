# Exasol Personal AI

A **one-command installer** that stands up an AI-ready Exasol stack on your machine by bundling three official Exasol components:

| Component | Role | Source |
| --- | --- | --- |
| **Exasol Personal** | The database | [exasol/exasol-personal](https://github.com/exasol/exasol-personal) |
| **Exasol JSON Tables** | Ingest, wrap, and query JSON as SQL | [exasol-labs/exasol-json-tables](https://github.com/exasol-labs/exasol-json-tables) |
| **Exasol MCP Server** | LLM-facing, read-only access layer (Model Context Protocol) | [exasol/mcp-server](https://github.com/exasol/mcp-server) |

After install you have an **Exasol Personal database running on the host** plus **two companion containers** that connect to it:

```
exasol-personal-ai-mcp           → http://127.0.0.1:4896/mcp
exasol-personal-ai-json-tables   → CLI, commands exec'd on demand
```

> 🗺️ Prefer a visual? Open **[architecture.html](architecture.html)** for a diagrammed walkthrough of how the pieces fit together.

---

## Table of contents

- [Quick start](#quick-start)
- [Why this isn't a single docker-compose](#why-this-isnt-a-single-docker-compose)
- [Architecture](#architecture)
- [What the installer does, step by step](#what-the-installer-does-step-by-step)
- [Connection discovery](#connection-discovery)
- [Using the stack](#using-the-stack)
- [The JSON Tables ingest caveat](#the-json-tables-ingest-caveat-important)
- [Cloud / remote database (non-Mac)](#cloud--remote-database-non-mac)
- [Configuration reference](#configuration-reference)
- [Files the installer creates](#files-the-installer-creates)
- [Verify & troubleshoot](#verify--troubleshoot)
- [Uninstall](#uninstall)
- [Security notes](#security-notes)
- [Before public release](#before-public-release)
- [License](#license)

---

## Quick start

**Requirements:** macOS on **Apple Silicon** (for the local database), at least 8 GB RAM, and **Docker Desktop running**.

```bash
curl -fsSL https://raw.githubusercontent.com/krishna-exasol/exasol-personal-ai/main/install.sh | sh
```

Or from a local clone:

```bash
git clone https://github.com/krishna-exasol/exasol-personal-ai.git
cd exasol-personal-ai
./install.sh
```

The first run installs the `exasol` launcher and (if no database exists yet) runs `exasol install local`, which downloads a managed VM runtime and starts the database — **this can take 10–20 minutes**. Subsequent runs reuse the existing database and finish in seconds.

> Not on an Apple-Silicon Mac? The local database won't run, but you can point the bundle at a cloud database — see [Cloud / remote database](#cloud--remote-database-non-mac).

---

## Why this isn't a single docker-compose

The previous bundle (`exasol-ai`) put Exasol **Nano** — a real Docker image — into a `docker compose` alongside MCP and JSON Tables. All three were containers on one network.

Exasol **Personal** is different: it is **not a Docker image**. It's a launcher CLI (`exasol`) that *provisions* a full Exasol database — locally inside a managed VM on macOS, or on a cloud provider (AWS/Azure/Exoscale/STACKIT) via OpenTofu. There is nothing to drop into a compose file, and the local mode is **macOS Apple-Silicon only** (a hard-coded `darwin/arm64` check in the launcher).

So the database is **not** a service in this `compose.yaml`. Instead the installer treats the launcher as the source of truth for the database and wires the two companion containers to whatever endpoint it produces.

---

## Architecture

```
            ┌─────────────────────────── macOS host ───────────────────────────┐
            │                                                                   │
            │   exasol launcher  ──►  Exasol Personal DB                        │
            │   (~/.local/bin)        (managed VM, 127.0.0.1:<dbPort>, sys/…)   │
            │                                  ▲                                │
            │                                  │ host.docker.internal:<dbPort>  │
            │        ┌─────────────────────────┼─────────────────────────┐     │
            │        │ Docker Desktop          │                         │     │
            │        │   ┌──────────────────┐  │  ┌────────────────────┐ │     │
            │        │   │ mcp-server       │──┘  │ json-tables        │─┘     │
            │        │   │ :4896  (HTTP/MCP)│     │ (CLI, exec on demand)│     │
            │        │   └──────────────────┘     └────────────────────┘ │     │
            │        └──────────────────────────────────────────────────┘     │
            └───────────────────────────────────────────────────────────────────┘
```

**Why MCP and JSON Tables are separate containers:** their `pyexasol` requirements conflict —

- MCP Server: `pyexasol>=1,<2`
- JSON Tables: `pyexasol>=2.2,<3`

They cannot share one Python environment, and they don't need to talk to each other — both only talk to the database. So each runs isolated.

**Why JSON Tables needs a heavy image:** its Python CLI shells out to a **Rust** (`cargo`) ingest engine at runtime, so the image carries the repo checkout plus a Rust toolchain (pre-built so the first ingest isn't a cold compile).

---

## What the installer does, step by step

`install.sh` runs six phases:

1. **Check prerequisites** — Docker engine running; warns if the host isn't macOS/arm64.
2. **Ensure the Exasol Personal launcher** — if `exasol` isn't found (on `PATH` or in `~/.local/bin`), install it from `downloads.exasol.com/exasol-personal/installer.sh`.
3. **Ensure a database** — if `exasol info --json` shows no deployment, run `exasol install local` (10–20 min first time). If a deployment exists but is stopped, `exasol start` it. Set `EXASOL_SKIP_DB_DEPLOY=1` to manage the DB yourself.
4. **Discover the connection** — read host/port/user/password (see [below](#connection-discovery)).
5. **Stage files & write `.env`** into `~/.exasol-personal-ai/`.
6. **Build & start the containers** — `docker compose up -d --build`, then generate the `run-json-tables.sh` helper.

---

## Connection discovery

The installer never hardcodes a DSN — the local database port is **dynamic**. It reads:

- `exasol info --json` → `connection.host`, `connection.dbPort`, `connection.username`
- `<deploymentDir>/secrets.json` → `dbPassword` (default `~/.exasol/personal/deployments/default/secrets.json`)

Local Personal deployments default to `sys` / `exasol`, but the password is read from `secrets.json` rather than assumed. Discovered values are written to `~/.exasol-personal-ai/.env`, which `compose.yaml` consumes:

```env
EXA_DB_HOST=host.docker.internal
EXA_DB_PORT=<discovered>
EXA_USER=sys
EXA_PASSWORD=<discovered>
```

From inside the containers the host DB is reached as `host.docker.internal:<dbPort>` (resolved natively on Docker Desktop; `extra_hosts: host-gateway` covers Linux engines). TLS certificate validation is disabled for both tools because the local DB uses a self-signed certificate.

> Redeployed the database and the port changed? Just re-run `./install.sh` — it re-discovers the port and rewrites `.env`.

---

## Using the stack

### Connect an LLM client to MCP

Point any MCP-capable client at:

```
http://127.0.0.1:4896/mcp
```

It is **read-only by default** (`mcp-settings.json`: `enable_read_query: true`, writes disabled). Health probe: `curl -s http://127.0.0.1:4896/health`.

### Query the database directly

```bash
exasol connect                 # interactive SQL shell
exasol connect -c "SELECT 1"   # one-off statement
```

### Ingest & query JSON with JSON Tables

The installer generates a helper that injects the discovered DSN/credentials, so you only pass the JSON-Tables arguments:

```bash
# place your file in the workspace first
cp data.json ~/.exasol-personal-ai/workspace/

# ingest a JSON file and generate SQL wrappers over it
~/.exasol-personal-ai/run-json-tables.sh ingest-and-wrap --input data.json --name my_events

# other subcommands
~/.exasol-personal-ai/run-json-tables.sh --help
~/.exasol-personal-ai/run-json-tables.sh describe wrappers
```

Equivalent raw call (the helper just wraps this and appends `--dsn/--user/--password`):

```bash
docker compose --env-file ~/.exasol-personal-ai/.env \
  -f ~/.exasol-personal-ai/compose.yaml \
  exec json-tables exasol-json-tables --help
```

---

## The JSON Tables ingest caveat (important)

Exasol's **bulk import** uses **HTTP transport**: the client opens a local HTTP endpoint and the **database connects back to it** to pull the data. This is trivial when the DB and client share a network (as in an all-container stack).

Here the database lives on the host (inside Personal's managed VM) and JSON Tables runs in a container. The DB→client (reverse) direction is **not guaranteed** across that boundary, so **`ingest` may fail** even though `wrap`, `describe`, `validate`, and all query operations (client→DB only) work fine.

**Host-mode fallback for ingest** — run the JSON Tables CLI directly on the Mac host, where it shares `127.0.0.1` with the database and the reverse connection is local:

```bash
git clone https://github.com/exasol-labs/exasol-json-tables.git
cd exasol-json-tables
python3 -m pip install -e .        # needs Python 3.10+ and a Rust toolchain (rustup)

# read the live port from: exasol info
exasol-json-tables ingest-and-wrap \
  --input data.json --name my_events \
  --dsn 127.0.0.1:<dbPort> --user sys --password <password>
```

A cleaner long-term fix is to teach JSON Tables to advertise a reachable callback address (so a containerized CLI can publish a fixed transport port the host DB can reach), or to ship JSON Tables as a self-contained wheel the installer runs on the host.

---

## Cloud / remote database (non-Mac)

Exasol Personal's *local* mode is macOS-only, but the `exasol` launcher itself runs anywhere for **cloud** targets:

```bash
# install the launcher (see https://github.com/exasol/exasol-personal), then:
exasol install aws        # or: azure | exoscale | stackit
exasol info               # note the host and dbPort
```

Start just the containers against that endpoint (skip the local auto-deploy):

```bash
EXASOL_SKIP_DB_DEPLOY=1 \
EXASOL_DB_HOST=<public-host> \
EXASOL_DB_PORT=<dbPort> \
./install.sh
```

Supply the matching credentials via the launcher's `secrets.json`, or edit `~/.exasol-personal-ai/.env` afterward and run `docker compose up -d`.

---

## Configuration reference

Environment variables honored by `install.sh`:

| Variable | Default | Purpose |
| --- | --- | --- |
| `INSTALL_DIR` | `~/.exasol-personal-ai` | Where stack files and `.env` are staged |
| `EXASOL_MCP_SERVER_VERSION` | `1.10.1` | MCP Server pip version |
| `EXASOL_JSON_TABLES_REF` | `main` | JSON Tables git ref to build |
| `EXASOL_MCP_PORT` | `4896` | Host port published for MCP (on `127.0.0.1`) |
| `EXASOL_DB_HOST` | `host.docker.internal` | DB host as seen from inside the containers |
| `EXASOL_DB_PORT` | _(discovered)_ | Override the auto-discovered DB port |
| `EXASOL_SKIP_DB_DEPLOY` | `0` | `1` = don't auto-run `exasol install local` |
| `EXASOL_PERSONAL_INSTALLER_URL` | downloads.exasol.com/… | Override the launcher installer URL |

MCP behavior is controlled by `mcp-settings.json` (read-only query enabled, writes/profiling/BucketFS disabled by default).

---

## Files the installer creates

```text
~/.exasol-personal-ai/
  compose.yaml             # mcp-server + json-tables (no DB service)
  Dockerfile.mcp
  Dockerfile.json-tables
  mcp-settings.json        # MCP read-only policy
  manifest.json            # component versions / provenance
  .env                     # discovered DSN + credentials (keep private)
  run-json-tables.sh       # CLI helper that injects the DSN
  uninstall.sh
  workspace/               # drop JSON files here; mounted into the json-tables container
```

The Exasol Personal database itself lives under `~/.exasol/personal/deployments/default/` and is managed by the `exasol` launcher (not by this stack).

---

## Verify & troubleshoot

```bash
# containers up?
docker compose --env-file ~/.exasol-personal-ai/.env -f ~/.exasol-personal-ai/compose.yaml ps

# database info (host)
exasol info

# MCP health
curl -s http://127.0.0.1:4896/health

# JSON Tables CLI
~/.exasol-personal-ai/run-json-tables.sh --help
```

| Symptom | Fix |
| --- | --- |
| `exasol: command not found` after install | Add `~/.local/bin` to `PATH` (`export PATH="$HOME/.local/bin:$PATH"`), re-run. |
| `Docker engine is not running` | Start Docker Desktop, wait until ready, re-run. |
| Containers can't reach the DB | Confirm `exasol info` shows a running deployment with a `dbPort`; check `EXA_DB_PORT` in `~/.exasol-personal-ai/.env`. |
| `ingest` fails but queries work | Reverse HTTP-transport limitation — use the [host-mode fallback](#the-json-tables-ingest-caveat-important). |
| Wrong port after a redeploy | Re-run `./install.sh`; it re-discovers the port and rewrites `.env`. |
| Not on Apple-Silicon Mac | Use a [cloud database](#cloud--remote-database-non-mac). |

---

## Uninstall

```bash
~/.exasol-personal-ai/uninstall.sh                 # remove the two containers + images, KEEP the DB
REMOVE_DB=1 ~/.exasol-personal-ai/uninstall.sh     # ALSO destroy the Personal DB (exasol destroy --remove)
```

By default the database is left in place (it is a host deployment, not part of this stack).

---

## Security notes

- MCP runs **read-only** and is published only on `127.0.0.1:4896`. Do not expose that port beyond localhost — it runs with `--no-auth` for local LLM clients.
- Credentials live only in `~/.exasol-personal-ai/.env`; keep the directory private.
- `.gitattributes` pins shell scripts to LF so they keep working on macOS even when edited on Windows.

---

## Before public release

This is a development-grade MVP. Pin floating defaults first:

- JSON Tables → a tested tag or commit (not `main`)
- MCP Server → keep pinned (`1.10.1`)
- Publish `install.sh` + assets as release artifacts with SHA256 checksums
- Validate end-to-end on a clean Apple-Silicon Mac, **including the ingest path**

---

## License

[MIT](LICENSE).
