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
    echo "Probing ${url}…"
    if curl -fsS --connect-timeout 3 --max-time 5 "$url"; then
        echo
        echo "Health check OK."
    else
        echo
        echo "Health check failed — see: journalctl -u ${UNIT_NAME} -e" >&2
        exit 1
    fi
fi
