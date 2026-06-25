# Install guide

## Prerequisites

- **macOS on Apple Silicon** (for the local database) with at least 8 GB RAM
- **Docker Desktop**, installed and running
- Internet access (to download the launcher, base images, and JSON Tables source)

> Not on an Apple-Silicon Mac? See [Cloud / remote database](#cloud--remote-database) below.

## One-command install

```bash
curl -fsSL https://raw.githubusercontent.com/krishna-exasol/exasol-personal-ai/main/install.sh | sh
```

Or from a local clone:

```bash
git clone https://github.com/krishna-exasol/exasol-personal-ai.git
cd exasol-personal-ai
./install.sh
```

### What the installer does

1. **Checks prerequisites** — Docker engine running; warns if not macOS/arm64.
2. **Installs the Exasol Personal launcher** (`exasol`) if missing, from `downloads.exasol.com`. It lands in `~/.local/bin` — make sure that is on your `PATH`.
3. **Ensures a database** — if none exists, runs `exasol install local` (**10–20 min** the first time; downloads a managed VM runtime and starts the DB).
4. **Discovers the connection** via `exasol info --json` (+ `secrets.json` for the password).
5. **Builds & starts** the MCP Server and JSON Tables containers, wired to the host DB.

## Verify

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

## Connect an LLM client to MCP

Point any MCP-capable client at:

```
http://127.0.0.1:4896/mcp
```

It is read-only by default (`mcp-settings.json`).

## Ingest JSON

Place your file in the workspace, then run the helper:

```bash
cp data.json ~/.exasol-personal-ai/workspace/
~/.exasol-personal-ai/run-json-tables.sh ingest-and-wrap --input data.json --name my_events
```

If ingest fails with a connection/transport error, the database could not connect back to the containerized client — use the **host-mode fallback** in [DESIGN.md](DESIGN.md#json-tables-ingest-connectivity-known-caveat).

## Cloud / remote database

Exasol Personal's *local* mode is macOS-only, but the launcher runs anywhere for cloud targets:

```bash
# install the launcher (see https://github.com/exasol/exasol-personal)
exasol install aws        # or azure | exoscale | stackit
exasol info               # note the host and dbPort
```

Then start just the containers against that endpoint:

```bash
EXASOL_SKIP_DB_DEPLOY=1 \
EXASOL_DB_HOST=<public-host> \
EXASOL_DB_PORT=<dbPort> \
./install.sh
```

(Supply the matching `EXA_USER` / `EXA_PASSWORD` via the launcher's `secrets.json`, or edit `~/.exasol-personal-ai/.env` afterward and `docker compose up -d`.)

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `exasol: command not found` after install | Add `~/.local/bin` to `PATH` (`export PATH="$HOME/.local/bin:$PATH"`), re-run. |
| `Docker engine is not running` | Start Docker Desktop, wait for it to be ready, re-run. |
| Containers can't reach the DB | Confirm `exasol info` shows a running deployment and a `dbPort`; check `~/.exasol-personal-ai/.env` has the right `EXA_DB_PORT`. |
| Ingest fails, queries work | Reverse HTTP-transport limitation — use the host-mode fallback (DESIGN.md). |
| Wrong port after a redeploy | Re-run `./install.sh`; it re-discovers the port and rewrites `.env`. |

## Uninstall

```bash
~/.exasol-personal-ai/uninstall.sh                 # remove containers, keep the DB
REMOVE_DB=1 ~/.exasol-personal-ai/uninstall.sh     # also destroy the Personal DB
```
