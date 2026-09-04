#!/bin/bash
# Serve the workload-result dashboard UI only (no SQLite / ingest).
# Default API base (in the UI): the PerfScale lab collector
#   http://n42-h01-b02-mx750c.rdu3.labs.perfscale.redhat.com:8080
# Override in the header "API" field, or open with ?api=http://other:8080
#
# Usage:
#   ./monitoring/data-collector/run-dashboard.sh
#   PORT=5500 ./monitoring/data-collector/run-dashboard.sh
#   BIND=0.0.0.0 PORT=5500 ./monitoring/data-collector/run-dashboard.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STATIC="${HERE}/static"
PORT="${PORT:-5500}"
BIND="${BIND:-127.0.0.1}"
DEFAULT_API="${DEFAULT_API:-http://n42-h01-b02-mx750c.rdu3.labs.perfscale.redhat.com:8080}"

if [[ ! -f "${STATIC}/index.html" ]]; then
    echo "Dashboard assets not found: ${STATIC}/index.html" >&2
    exit 1
fi

echo "Dashboard UI:  http://${BIND}:${PORT}/"
echo "Default API:   ${DEFAULT_API}"
echo "Override via the header API field, or:"
echo "  http://${BIND}:${PORT}/?api=http://127.0.0.1:8080"
echo "Ctrl-C to stop."
exec /usr/bin/python3 -m http.server "$PORT" --bind "$BIND" --directory "$STATIC"
