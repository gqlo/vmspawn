#!/bin/bash
# Serve the workload-result dashboard UI only (no SQLite / ingest).
# Point the header "API" field at a collector, e.g.:
#   http://127.0.0.1:8080
#   http://lab-host:8080
# Or open with ?api=http://lab-host:8080
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

if [[ ! -f "${STATIC}/index.html" ]]; then
    echo "Dashboard assets not found: ${STATIC}/index.html" >&2
    exit 1
fi

echo "Dashboard UI:  http://${BIND}:${PORT}/"
echo "Set API base to your collector (empty = same origin, which has no API here)."
echo "Example: http://127.0.0.1:8080   or   http://<lab-host>:8080"
echo "One-shot: http://${BIND}:${PORT}/?api=http://<collector-host>:8080"
echo "Ctrl-C to stop."
exec /usr/bin/python3 -m http.server "$PORT" --bind "$BIND" --directory "$STATIC"
