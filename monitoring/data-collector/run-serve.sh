#!/bin/bash
# Launch data-collector serve.py from env (used by the systemd unit).
# Expected env: VSTORM_HOME, LISTEN, DATA_DIR; optional TOKEN.
set -euo pipefail

VSTORM_HOME="${VSTORM_HOME:?set VSTORM_HOME to the vstorm repo root}"
LISTEN="${LISTEN:-0.0.0.0:8080}"
DATA_DIR="${DATA_DIR:-${VSTORM_HOME}/data-collector-data}"
SERVE="${VSTORM_HOME}/monitoring/data-collector/serve.py"

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
