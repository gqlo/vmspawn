#!/bin/bash
# Launch data-collector serve.py from env (used by the systemd unit).
# Expected env: VSTORM_HOME, LISTEN; optional DATA_DIR, TOKEN.
# Default DATA_DIR: <checkout>/monitoring/data-collector/workload-result-data
set -euo pipefail

VSTORM_HOME="${VSTORM_HOME:?set VSTORM_HOME to the vstorm repo root}"
LISTEN="${LISTEN:-0.0.0.0:8080}"
COLLECTOR_DIR="${VSTORM_HOME}/monitoring/data-collector"
DATA_DIR="${DATA_DIR:-${COLLECTOR_DIR}/workload-result-data}"
SERVE="${COLLECTOR_DIR}/serve.py"

if [[ ! -f "$SERVE" ]]; then
    echo "serve.py not found: $SERVE" >&2
    exit 1
fi

mkdir -p "$DATA_DIR"
cd "$DATA_DIR"

args=(--listen "$LISTEN" --data-dir "$DATA_DIR")
if [[ -n "${TOKEN:-}" ]]; then
    args+=(--token "$TOKEN")
fi

exec /usr/bin/python3 "$SERVE" "${args[@]}"
