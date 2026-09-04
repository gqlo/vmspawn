#!/bin/bash
# After git pull: reload systemd (if the unit file changed) and restart the
# data-collector so serve.py picks up new code. Static dashboard JS/CSS is
# read from disk per request; restart still refreshes the Python process.
#
# Usage (from anywhere):
#   ./monitoring/data-collector/restart-service.sh
#   ./monitoring/data-collector/restart-service.sh --no-sync-unit
#   ./monitoring/data-collector/restart-service.sh --no-health
#
# Needs sudo for systemctl (and to refresh /etc/systemd/system/ when syncing).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
UNIT_NAME="vstorm-data-collector.service"
UNIT_SRC="${HERE}/${UNIT_NAME}"
UNIT_DST="/etc/systemd/system/${UNIT_NAME}"
ENV_FILE="/etc/vstorm/data-collector.env"

# Health probe: serve.py often needs a moment after restart to bind.
HEALTH_ATTEMPTS="${HEALTH_ATTEMPTS:-20}"
HEALTH_INTERVAL_SEC="${HEALTH_INTERVAL_SEC:-0.25}"

SYNC_UNIT=1
CHECK_HEALTH=1
for arg in "$@"; do
    case "$arg" in
        --no-sync-unit) SYNC_UNIT=0 ;;
        --no-health) CHECK_HEALTH=0 ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown option: $arg (try --help)" >&2
            exit 2
            ;;
    esac
done

if [[ ! -f "$UNIT_SRC" ]]; then
    echo "Unit file missing in checkout: $UNIT_SRC" >&2
    exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Missing $ENV_FILE — install steps: ${HERE}/data-collector.md" >&2
    exit 1
fi

if (( SYNC_UNIT )); then
    if [[ ! -f "$UNIT_DST" ]] || ! cmp -s "$UNIT_SRC" "$UNIT_DST"; then
        echo "Installing/updating ${UNIT_DST} from checkout…"
        sudo cp "$UNIT_SRC" "$UNIT_DST"
        echo "Reloading systemd daemon…"
        sudo systemctl daemon-reload
    else
        echo "Installed unit matches checkout; skipping daemon-reload."
    fi
else
    echo "Skipping unit sync (--no-sync-unit)."
fi

echo "Restarting ${UNIT_NAME}…"
sudo systemctl restart "$UNIT_NAME"

# Give systemd a beat to flip to active (or fail) before we print status.
for _ in $(seq 1 20); do
    state="$(systemctl is-active "$UNIT_NAME" 2>/dev/null || true)"
    case "$state" in
        active|activating) break ;;
        failed|inactive)
            echo "Unit is ${state} after restart." >&2
            systemctl --no-pager --full status "$UNIT_NAME" || true
            journalctl -u "$UNIT_NAME" -n 30 --no-pager >&2 || true
            exit 1
            ;;
    esac
    sleep 0.1
done

echo "Status:"
systemctl --no-pager --full status "$UNIT_NAME" || true

if (( CHECK_HEALTH )); then
    listen="$(grep -E '^LISTEN=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    listen="${listen:-0.0.0.0:8080}"
    # Strip optional quotes
    listen="${listen%\"}"
    listen="${listen#\"}"
    listen="${listen%\'}"
    listen="${listen#\'}"
    host="${listen%:*}"
    port="${listen##*:}"
    [[ "$host" == "0.0.0.0" || "$host" == "::" || -z "$host" ]] && host="127.0.0.1"
    url="http://${host}:${port}/healthz"

    echo "Probing ${url} (up to ${HEALTH_ATTEMPTS} tries)…"
    body=""
    ok=0
    for i in $(seq 1 "$HEALTH_ATTEMPTS"); do
        if ! systemctl is-active --quiet "$UNIT_NAME"; then
            echo "Unit left active state during health wait." >&2
            break
        fi
        if body="$(curl -fsS --connect-timeout 1 --max-time 2 "$url" 2>/dev/null)"; then
            ok=1
            break
        fi
        sleep "$HEALTH_INTERVAL_SEC"
    done

    if (( ok )); then
        printf '%s\n' "$body"
        echo "Health check OK (attempt ${i}/${HEALTH_ATTEMPTS})."
    else
        echo "Health check failed after ${HEALTH_ATTEMPTS} attempts — see journal:" >&2
        journalctl -u "$UNIT_NAME" -n 40 --no-pager >&2 || true
        exit 1
    fi
fi
