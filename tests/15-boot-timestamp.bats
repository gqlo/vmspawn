#!/usr/bin/env bats
# Shared vstorm-boot-timestamp.sh (standalone source; also embedded in cloud-inits).

load 'helpers'

SCRIPT="workload/vstorm-boot-timestamp.sh"

setup() {
    _BT_DIR=$(mktemp -d)
    export RESULT_TIMESTAMP_FILE="$_BT_DIR/timestamp.txt"
    unset RESULT_SERVER_URL VSTORM_BATCH_ID
}

teardown() {
    [[ -n "${_BT_DIR:-}" ]] && rm -rf "$_BT_DIR"
}

@test "boot-ts: script has valid bash syntax" {
    bash -n "$SCRIPT"
}

@test "boot-ts: creates timestamp file with numeric unix" {
    run bash "$SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ -f "$RESULT_TIMESTAMP_FILE" ]]
    grep -qE '^[0-9]+,' "$RESULT_TIMESTAMP_FILE"
}

@test "boot-ts: appends on second run and keeps first boot unix" {
    run bash "$SCRIPT"
    [[ "$status" -eq 0 ]]
    first=$(grep -E '^[0-9]+,' "$RESULT_TIMESTAMP_FILE" | head -1 | cut -d, -f1 | tr -d ' ')
    sleep 1
    run bash "$SCRIPT"
    [[ "$status" -eq 0 ]]
    lines=$(grep -cE '^[0-9]+,' "$RESULT_TIMESTAMP_FILE" || true)
    [[ "$lines" -ge 2 ]]
    again=$(grep -E '^[0-9]+,' "$RESULT_TIMESTAMP_FILE" | head -1 | cut -d, -f1 | tr -d ' ')
    [[ "$first" == "$again" ]]
}

@test "boot-ts: skips non-numeric header when resolving boot" {
    printf '%s\n' 'unix-timestamp, YYYY-MM-DDTHH:MM:SSZ' > "$RESULT_TIMESTAMP_FILE"
    run bash "$SCRIPT"
    [[ "$status" -eq 0 ]]
    grep -qE '^[0-9]+,' "$RESULT_TIMESTAMP_FILE"
}

@test "boot-ts: embedded in all workload cloud-inits" {
    for y in workload/cloudinit-fio-workload.yaml \
             workload/cloudinit-stress-ng-workload.yaml \
             workload/cloudinit-dirty-mem-pages.yaml \
             workload/cloudinit-default.yaml; do
        grep -q 'path: /opt/vstorm-boot-timestamp.sh' "$y"
        grep -q 'vstorm-boot-timestamp.service' "$y"
    done
}

@test "boot-ts: unreachable RESULT_SERVER_URL still writes file and exits 0" {
    export RESULT_SERVER_URL="http://127.0.0.1:1/v1/results"
    export VSTORM_BATCH_ID="btunreachable"
    export RESULT_RETRY=1
    export RESULT_TIMEOUT=1
    run bash "$SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ -f "$RESULT_TIMESTAMP_FILE" ]]
    grep -qE '^[0-9]+,' "$RESULT_TIMESTAMP_FILE"
    [[ "$output" == *"Boot heartbeat POST failed"* ]]
}

@test "boot-ts: RESULT_SERVER_URL without VSTORM_BATCH_ID skips POST" {
    export RESULT_SERVER_URL="http://127.0.0.1:1/v1/results"
    unset VSTORM_BATCH_ID
    export RESULT_RETRY=1
    export RESULT_TIMEOUT=1
    run bash "$SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ -f "$RESULT_TIMESTAMP_FILE" ]]
    [[ "$output" == *"VSTORM_BATCH_ID unset"* ]]
    [[ "$output" != *"Boot heartbeat posted"* ]]
}
