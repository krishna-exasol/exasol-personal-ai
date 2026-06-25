#!/usr/bin/env sh
set -eu

# ===========================================================================
# Exasol Personal AI installer
#   Exasol Personal (host DB)  +  JSON Tables  +  MCP Server
#
# Unlike a pure-Docker bundle, the DATABASE here is provided on the host by the
# Exasol Personal launcher (`exasol install local`, macOS Apple Silicon only).
# This script:
#   1. ensures the `exasol` launcher is installed,
#   2. ensures a local Personal database is deployed and running,
#   3. discovers its DSN / credentials via `exasol info --json`,
#   4. builds & starts the MCP Server and JSON Tables containers, wired to the
#      host database through host.docker.internal.
# ===========================================================================

INSTALL_DIR="${INSTALL_DIR:-"$HOME/.exasol-personal-ai"}"
JSON_TABLES_REF="${EXASOL_JSON_TABLES_REF:-main}"
MCP_SERVER_VERSION="${EXASOL_MCP_SERVER_VERSION:-1.10.1}"
MCP_PORT="${EXASOL_MCP_PORT:-4896}"
# DB host as seen from inside the containers. host.docker.internal -> the Mac host.
DB_HOST_FOR_CONTAINERS="${EXASOL_DB_HOST:-host.docker.internal}"
# Set EXASOL_SKIP_DB_DEPLOY=1 to manage the Personal DB yourself (skip auto-deploy).
SKIP_DB_DEPLOY="${EXASOL_SKIP_DB_DEPLOY:-0}"
PERSONAL_INSTALLER_URL="${EXASOL_PERSONAL_INSTALLER_URL:-https://downloads.exasol.com/exasol-personal/installer.sh}"
EXASOL_AI_REF="${EXASOL_AI_REF:-main}"
EXASOL_AI_BASE_URL="${EXASOL_AI_BASE_URL:-https://raw.githubusercontent.com/krishna-exasol/exasol-personal-ai/${EXASOL_AI_REF}}"

# ---------------------------------------------------------------------------
# Pretty output (colors only on an interactive terminal)
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_CYAN="$(printf '\033[36m')"; C_GREEN="$(printf '\033[32m')"
  C_YEL="$(printf '\033[33m')";  C_GRY="$(printf '\033[90m')"
  C_WHT="$(printf '\033[97m')";  C_RST="$(printf '\033[0m')"
else
  C_CYAN=""; C_GREEN=""; C_YEL=""; C_GRY=""; C_WHT=""; C_RST=""
fi

PHASE=0
TOTAL=6

banner() {
  printf '\n'
  printf '  %s=================================================%s\n' "$C_CYAN" "$C_RST"
  printf '  %s Exasol Personal AI Installer%s\n' "$C_WHT" "$C_RST"
  printf '  %s Personal (host DB) + JSON Tables + MCP Server%s\n' "$C_GRY" "$C_RST"
  printf '  %s=================================================%s\n' "$C_CYAN" "$C_RST"
}
phase() { PHASE=$((PHASE + 1)); printf '\n  %s[%d/%d]%s %s%s%s\n' "$C_CYAN" "$PHASE" "$TOTAL" "$C_RST" "$C_WHT" "$1" "$C_RST"; }
ok()    { printf '      %s\xe2\x9c\x93%s %s%s%s\n' "$C_GREEN" "$C_RST" "$C_GRY" "$1" "$C_RST"; }
info()  { printf '        %s%s%s\n' "$C_GRY" "$1" "$C_RST"; }
warn()  { printf '      %s! %s%s\n' "$C_YEL" "$1" "$C_RST"; }
die()   { printf '\n%sError:%s %s\n' "$C_YEL" "$C_RST" "$1" >&2; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required. $2"
}

# Line-based extraction from indented (pretty-printed) JSON on stdin.
json_num() { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p" | head -1; }
json_str() { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -1; }

# ---------------------------------------------------------------------------
# Locate this script's directory (so local assets are used when run from a clone)
# ---------------------------------------------------------------------------
SCRIPT_PATH="${0:-}"
case "$SCRIPT_PATH" in
  /*)  SCRIPT_DIR="$(dirname "$SCRIPT_PATH")" ;;
  */*) SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)" ;;
  *)   SCRIPT_DIR="" ;;
esac

copy_or_download_asset() {
  name="$1"; destination="$2"
  if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/$name" ]; then
    cp "$SCRIPT_DIR/$name" "$destination"; ok "$name (local)"; return
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$EXASOL_AI_BASE_URL/$name" -o "$destination"
  elif command -v wget >/dev/null 2>&1; then
    wget -q "$EXASOL_AI_BASE_URL/$name" -O "$destination"
  else
    die "curl or wget is required to download installer assets."
  fi
  ok "$name"
}

EXASOL_BIN=""
resolve_exasol() {
  if command -v exasol >/dev/null 2>&1; then EXASOL_BIN="exasol"; return 0; fi
  if [ -x "$HOME/.local/bin/exasol" ]; then EXASOL_BIN="$HOME/.local/bin/exasol"; return 0; fi
  return 1
}

# ===========================================================================
banner

# --- 1. Prerequisites ------------------------------------------------------
phase "Checking prerequisites"
need docker "Install Docker Desktop and start it."
ok "docker found"
docker info >/dev/null 2>&1 || die "Docker is installed but the engine is not running. Start Docker and re-run."
ok "Docker engine is running"

OS="$(uname -s 2>/dev/null || echo unknown)"
ARCH="$(uname -m 2>/dev/null || echo unknown)"
if [ "$OS" = "Darwin" ] && { [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ]; }; then
  ok "Host is macOS Apple Silicon ($ARCH)"
else
  warn "Host is $OS/$ARCH. Exasol Personal's LOCAL database only runs on macOS Apple Silicon."
  warn "Either run this on an Apple-Silicon Mac, or deploy a cloud DB (exasol install aws|azure|...)"
  warn "and re-run with EXASOL_SKIP_DB_DEPLOY=1 plus EXASOL_DB_HOST/EXASOL_DB_PORT set."
fi

# --- 2. Exasol Personal launcher ------------------------------------------
phase "Ensuring the Exasol Personal launcher is installed"
if resolve_exasol; then
  ok "exasol launcher found ($EXASOL_BIN)"
else
  info "Installing the Exasol Personal launcher from downloads.exasol.com ..."
  need curl "Needed to download the Exasol Personal installer."
  curl -fsSL "$PERSONAL_INSTALLER_URL" | sh
  resolve_exasol || die "exasol launcher still not found after install. Add \$HOME/.local/bin to your PATH and re-run."
  ok "exasol launcher installed ($EXASOL_BIN)"
fi

# --- 3. Local Personal database -------------------------------------------
phase "Ensuring an Exasol Personal database is running"
if "$EXASOL_BIN" info --json >/dev/null 2>&1; then
  ok "an Exasol Personal deployment already exists"
  # Best-effort start in case it is stopped (ignore errors / already-running).
  "$EXASOL_BIN" start >/dev/null 2>&1 || true
elif [ "$SKIP_DB_DEPLOY" = "1" ]; then
  die "No Personal deployment found and EXASOL_SKIP_DB_DEPLOY=1. Deploy one (exasol install local) or set EXASOL_DB_HOST/EXASOL_DB_PORT."
else
  warn "No deployment found. Running 'exasol install local' (this can take 10-20 minutes)..."
  "$EXASOL_BIN" install local || die "'exasol install local' failed. See the launcher output above."
  ok "local Exasol Personal database deployed"
fi

# --- 4. Discover connection details ---------------------------------------
phase "Discovering database connection"
INFO_JSON="$("$EXASOL_BIN" info --json 2>/dev/null || true)"
[ -n "$INFO_JSON" ] || die "Could not read 'exasol info --json'. Is the deployment healthy? Try 'exasol info'."

DB_PORT="${EXASOL_DB_PORT:-$(printf '%s\n' "$INFO_JSON" | json_num dbPort)}"
DB_USER="$(printf '%s\n' "$INFO_JSON" | json_str username)"; DB_USER="${DB_USER:-sys}"
DEPLOY_DIR="$(printf '%s\n' "$INFO_JSON" | json_str deploymentDir)"
SECRETS_FILE="${DEPLOY_DIR:+$DEPLOY_DIR/secrets.json}"
[ -n "$SECRETS_FILE" ] && [ -f "$SECRETS_FILE" ] || SECRETS_FILE="$HOME/.exasol/personal/deployments/default/secrets.json"

if [ -f "$SECRETS_FILE" ]; then
  DB_PASSWORD="$(json_str dbPassword < "$SECRETS_FILE")"
fi
DB_PASSWORD="${DB_PASSWORD:-exasol}"

[ -n "$DB_PORT" ] || die "Could not determine the database port from 'exasol info --json'. Set EXASOL_DB_PORT explicitly."
ok "DB port:  $DB_PORT (host) -> ${DB_HOST_FOR_CONTAINERS}:${DB_PORT} (from containers)"
ok "DB user:  $DB_USER"
ok "DB password: discovered from secrets.json"

# --- 5. Stage stack files & config ----------------------------------------
phase "Staging stack files"
info "into $INSTALL_DIR"
mkdir -p "$INSTALL_DIR/workspace"
for asset in compose.yaml Dockerfile.mcp Dockerfile.json-tables mcp-settings.json manifest.json uninstall.sh; do
  copy_or_download_asset "$asset" "$INSTALL_DIR/$asset"
done

cat > "$INSTALL_DIR/.env" <<EOF
EXASOL_JSON_TABLES_REF=$JSON_TABLES_REF
EXASOL_MCP_SERVER_VERSION=$MCP_SERVER_VERSION
EXASOL_MCP_PORT=$MCP_PORT
EXA_DB_HOST=$DB_HOST_FOR_CONTAINERS
EXA_DB_PORT=$DB_PORT
EXA_USER=$DB_USER
EXA_PASSWORD=$DB_PASSWORD
EOF
ok ".env written"
if [ "$JSON_TABLES_REF" = "main" ]; then
  warn "JSON Tables ref is 'main'. For a release, pin a tested tag or commit."
fi

cd "$INSTALL_DIR"

# --- 6. Build & start containers ------------------------------------------
phase "Building & starting containers"
info "First run pulls images and compiles the JSON Tables engine - this can take a few minutes."
docker compose --env-file .env -f compose.yaml up -d --build
ok "containers started"

# JSON Tables CLI helper: injects the discovered DSN/credentials.
cat > "$INSTALL_DIR/run-json-tables.sh" <<'EOF'
#!/usr/bin/env sh
set -eu
install_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$install_dir"
# shellcheck disable=SC1091
. ./.env
exec docker compose --env-file .env -f compose.yaml exec json-tables \
  exasol-json-tables "$@" \
  --dsn "${EXA_DB_HOST}:${EXA_DB_PORT}" --user "${EXA_USER}" --password "${EXA_PASSWORD}"
EOF
chmod +x "$INSTALL_DIR/run-json-tables.sh"
ok "created run-json-tables.sh helper"
docker compose --env-file .env -f compose.yaml ps || true

# ---------------------------------------------------------------------------
printf '\n'
printf '  %s===================================================%s\n' "$C_GREEN" "$C_RST"
printf '   %s\xe2\x9c\x93%s %sExasol Personal AI is installed and running%s\n' "$C_GREEN" "$C_RST" "$C_WHT" "$C_RST"
printf '  %s===================================================%s\n' "$C_GREEN" "$C_RST"
printf '\n'
printf '   %sInstall dir%s %s\n' "$C_GRY" "$C_RST" "$INSTALL_DIR"
printf '   %sDatabase   %s 127.0.0.1:%s  (Exasol Personal, on host)\n' "$C_GRY" "$C_RST" "$DB_PORT"
printf '   %sMCP        %s http://127.0.0.1:%s/mcp\n' "$C_GRY" "$C_RST" "$MCP_PORT"
printf '\n'
printf '   %sNext steps%s\n' "$C_CYAN" "$C_RST"
printf '     - JSON Tables CLI : %s/run-json-tables.sh --help\n' "$INSTALL_DIR"
printf '     - Connect an MCP client to the MCP URL above\n'
printf '     - Uninstall       : %s/uninstall.sh\n' "$INSTALL_DIR"
printf '\n'
printf '   %sNote%s ingest (bulk import) uses Exasol HTTP transport where the DB\n' "$C_YEL" "$C_RST"
printf '   connects back to the client. If ingest from the container fails, see\n'
printf '   DESIGN.md "JSON Tables ingest connectivity" for the host-mode fallback.\n'
printf '\n'
