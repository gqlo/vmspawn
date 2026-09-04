#!/usr/bin/env bats

# Unit tests for vstorm
# Run with: bats tests/
#
# Regression coverage for watch_batch_delete_cleanup() (see delete_batch()):
# after `oc delete ns -l batch-id=... --wait=false` returns, vstorm polls
# leftover namespaces/PVCs/PVs/VolumeAttachments for the batch, refreshing
# counts every DELETE_POLL_INTERVAL (default 2s; set to 0 here so tests run
# instantly) until everything reaches zero, or failing loudly (non-zero exit)
# if DELETE_POLL_TIMEOUT is hit first.
#
# The mock oc (helpers.bash) simulates namespaces/PVCs/PVs/VolumeAttachments
# disappearing over a few poll iterations via MOCK_CLEANUP_TICKS_FILE, so we
# can assert the loop actually re-polls (shows a nonzero count at least once)
# before converging, rather than only checking the final "cleaned up" line.

load 'helpers'

VSTORM="./vstorm"

setup_file() {
    setup_oc_mock
}

teardown() {
    unset MOCK_NS_LINES MOCK_LEFTOVER_NS MOCK_NS_CALLS_FILE MOCK_CLEANUP_TICKS_FILE
    unset DELETE_POLL_INTERVAL DELETE_POLL_TIMEOUT
}

# ---------------------------------------------------------------
# Dry-run mentions the post-delete monitoring step
# ---------------------------------------------------------------
@test "delete: dry-run mentions leftover monitoring" {
  run bash "$VSTORM" -n --delete=delw00
  [ "$status" -eq 0 ]
  [[ "$output" == *"--wait=false"* ]]
  [[ "$output" == *"monitor leftover namespaces/PVCs/PVs/VolumeAttachments"* ]]
}

# ---------------------------------------------------------------
# Wet-run: watch loop refreshes leftover counts, then converges to zero
# ---------------------------------------------------------------
@test "delete: wet-run watch loop refreshes leftover counts and reports fully cleaned up" {
  ns_calls_file=$(mktemp)
  ticks_file=$(mktemp)
  echo 2 > "$ticks_file"

  MOCK_NS_LINES="delw01-ns-1" \
  MOCK_LEFTOVER_NS="delw01-ns-1" \
  MOCK_NS_CALLS_FILE="$ns_calls_file" \
  MOCK_CLEANUP_TICKS_FILE="$ticks_file" \
  DELETE_POLL_INTERVAL=0 \
    run bash "$VSTORM" --delete=delw01 --yes
  [ "$status" -eq 0 ]

  [[ "$output" == *"Monitoring cleanup for batch 'delw01'"* ]]
  # At least one poll iteration must observe leftovers before converging.
  [[ "$output" == *"PVCs=1"* ]]
  [[ "$output" == *"PVs=1"* ]]
  [[ "$output" == *"VolumeAttachments=1"* ]]
  # Final iteration converges to zero across all four counters.
  [[ "$output" == *"namespaces=0"* ]]
  [[ "$output" == *"PVCs=0"* ]]
  [[ "$output" == *"PVs=0"* ]]
  [[ "$output" == *"VolumeAttachments=0"* ]]
  [[ "$output" == *"fully cleaned up"* ]]

  rm -f "$ns_calls_file" "$ticks_file"
}

# ---------------------------------------------------------------
# Wet-run: watch loop times out and reports remaining leftovers
# ---------------------------------------------------------------
@test "delete: wet-run watch loop times out and reports remaining leftovers" {
  ticks_file=$(mktemp)
  echo 1000000 > "$ticks_file"

  MOCK_NS_LINES="delw02-ns-1" \
  MOCK_LEFTOVER_NS="delw02-ns-1" \
  MOCK_CLEANUP_TICKS_FILE="$ticks_file" \
  DELETE_POLL_INTERVAL=0 \
  DELETE_POLL_TIMEOUT=0 \
    run bash "$VSTORM" --delete=delw02 --yes
  [ "$status" -ne 0 ]

  [[ "$output" == *"Timed out after 0s waiting for batch 'delw02' cleanup"* ]]
  [[ "$output" == *"leftovers remain: namespaces=1 PVCs=1 PVs=1 VolumeAttachments=1"* ]]

  rm -f "$ticks_file"
}
