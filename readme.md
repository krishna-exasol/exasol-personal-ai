# Exasol Personal AI

A one-command installer that brings up an AI-ready Exasol stack on your machine:

- **Exasol Personal** — the database, deployed on the host by the official `exasol` launcher (`exasol install local`)
- **Exasol JSON Tables** — ingest, wrap, and query JSON in Exasol
- **Exasol MCP Server** — an LLM-facing, read-only access layer

After install you have an **Exasol Personal database running on the host** plus **two companion containers** (`exasol-personal-ai-mcp`, `exasol-personal-ai-json-tables`) that connect to it.

> 📖 New here? Start with **[INSTALL.md](INSTALL.md)**.

---

## How this differs from a pure-Docker bundle

Exasol **Personal** is not a Docker image — it is a launcher CLI that provisions a real Exasol database (locally inside a managed VM on macOS, or on a cloud provider). So the database is **not** a service in this `compose.yaml`. Instead:

1. The installer ensures the `exasol` launcher is installed and a database is running.
2. It discovers the database's host/port/credentials via `exasol info --json`.
3. It starts the MCP Server and JSON Tables containers, wired to the host DB through `host.docker.internal`.

**Platform:** Exasol Personal's **local** database runs on **macOS Apple Silicon only**. On other platforms, deploy a cloud database with the launcher (`exasol install aws|azure|exoscale|stackit`) and point the bundle at it — see [INSTALL.md](INSTALL.md).

---

## Install (one command)

**macOS (Apple Silicon):**

```bash
curl -fsSL https://raw.githubusercontent.com/krishna-exasol/exasol-personal-ai/main/install.sh | sh
```

Prerequisites: **Docker Desktop** running. The installer will install the `exasol` launcher and run `exasol install local` if no database exists yet (that step can take 10–20 minutes the first time).

From a local clone instead: `./install.sh`.

---

## What you get

| Component | Address | Notes |
| --- | --- | --- |
| Exasol Personal (SQL) | `127.0.0.1:<dbPort>` | on the host; user `sys` / discovered password. Port is dynamic — see `exasol info`. |
| `exasol-personal-ai-mcp` | `http://127.0.0.1:4896/mcp` | MCP protocol endpoint |
| `exasol-personal-ai-json-tables` | _(no port)_ | CLI kept running; commands are `exec`'d in |

Why JSON Tables and MCP stay separate: JSON Tables needs `pyexasol>=2.2,<3` while MCP Server needs `pyexasol>=1,<2` — incompatible in one Python environment, so each runs isolated. See [DESIGN.md](DESIGN.md).

---

## Use the JSON Tables CLI

The installer generates a helper that injects the discovered DSN/credentials:

```bash
~/.exasol-personal-ai/run-json-tables.sh --help
```

Ingest a JSON file (place it in `~/.exasol-personal-ai/workspace/` first):

```bash
~/.exasol-personal-ai/run-json-tables.sh ingest-and-wrap --input data.json --name my_events
```

> **Ingest caveat:** Exasol's bulk-import (HTTP transport) has the database connect *back* to the client. With the DB on the host and JSON Tables in a container, that reverse path can fail. If it does, use the **host-mode fallback** in [DESIGN.md](DESIGN.md) (run the JSON Tables CLI directly on the Mac host). `wrap`, `describe`, and query operations are unaffected.

---

## Uninstall

```bash
~/.exasol-personal-ai/uninstall.sh                 # removes the two containers, KEEPS the DB
REMOVE_DB=1 ~/.exasol-personal-ai/uninstall.sh     # also destroys the Personal DB
```

---

## Before public release

Development-grade MVP. Pin floating defaults first:

- JSON Tables tag or commit, not `main`
- MCP Server exact package version (already `1.10.1`)
- Publish release assets + SHA256 checksums

## License

[MIT](LICENSE).
