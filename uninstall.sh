#!/usr/bin/env sh
set -eu

# Removes the MCP Server + JSON Tables containers for this bundle.
# By default it LEAVES the Exasol Personal database untouched (it is a host
# deployment managed by the `exasol` launcher, not part of this compose stack).
#
#   uninstall.sh                 # stop & remove the two containers + images
#   REMOVE_DB=1 uninstall.sh     # ALSO destroy the Personal DB (exasol destroy --remove)

INSTALL_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$INSTALL_DIR"

if [ -f compose.yaml ]; then
  echo "Stopping and removing containers + built images..."
  docker compose --env-file .env -f compose.yaml down --rmi local --remove-orphans || true
fi

if [ "${REMOVE_DB:-0}" = "1" ]; then
  echo "Destroying the Exasol Personal database (REMOVE_DB=1)..."
  if command -v exasol >/dev/null 2>&1; then
    exasol destroy --remove || true
  elif [ -x "$HOME/.local/bin/exasol" ]; then
    "$HOME/.local/bin/exasol" destroy --remove || true
  else
    echo "  exasol launcher not found; skip. Remove manually with 'exasol destroy --remove'."
  fi
else
  echo "Left the Exasol Personal database in place. Use REMOVE_DB=1 to also destroy it."
fi

echo "Done. You can delete $INSTALL_DIR to remove staged files."
