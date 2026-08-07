#!/bin/bash
# Launch data-collector serve.py from env (used by the systemd unit).
# Expected env: VSTORM_HOME, LISTEN; optional DATA_DIR, TOKEN, PYTHON.
# Default DATA_DIR: <checkout>/monitoring/data-collector/workload-result-data
# Default PYTHON: /usr/bin/python3 (needs >= 3.7; set PYTHON= on older platforms).
set -euo pipefail

VSTORM_HOME="${VSTORM_HOME:?set VSTORM_HOME to the vstorm repo root}"
LISTEN="${LISTEN:-0.0.0.0:8080}"
PYTHON="${PYTHON:-/usr/bin/python3}"
COLLECTOR_DIR="${VSTORM_HOME}/monitoring/data-collector"
DATA_DIR="${DATA_DIR:-${COLLECTOR_DIR}/workload-result-data}"
SERVE="${COLLECTOR_DIR}/serve.py"

if [[ ! -f "$SERVE" ]]; then
    echo "serve.py not found: $SERVE" >&2
    exit 1
fi

if [[ ! -x "$PYTHON" ]] && ! command -v "$PYTHON" >/dev/null 2>&1; then
    echo "Python interpreter not found: $PYTHON" >&2
    echo "Set PYTHON in /etc/vstorm/data-collector.env (e.g. PYTHON=/usr/bin/python3.11)" >&2
    exit 1
fi

# serve.py needs 3.7+ (from __future__ import annotations, ThreadingHTTPServer).
if ! "$PYTHON" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 7) else 1)'; then
    ver="$("$PYTHON" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo unknown)"
    echo "Python $ver at $PYTHON is too old; serve.py requires >= 3.7" >&2
    echo "Set PYTHON=/usr/bin/python3.11 (or similar) in /etc/vstorm/data-collector.env" >&2
    exit 1
fi

mkdir -p "$DATA_DIR"
cd "$DATA_DIR"

args=(--listen "$LISTEN" --data-dir "$DATA_DIR")
if [[ -n "${TOKEN:-}" ]]; then
    args+=(--token "$TOKEN")
fi

exec "$PYTHON" "$SERVE" "${args[@]}"
