#!/usr/bin/env bats

# Unit tests for vstorm
# Run with: bats tests/
#
# Regression coverage for incremental "progress" manifest POSTs
# (post_batch_result_metadata(), see wait_for_batch_datavolumes_for_timestamps
# and main()'s --ns-sequential-creation loop).
#
# Before this fix, --ns-sequential-creation staggered `oc apply` calls one
# namespace at a time, but never POSTed a progress manifest per namespace --
# the first progress POST only happened after *all* namespaces were already
# created. These tests use a mock curl (helpers.bash: setup_curl_mock) that
# records each POST's manifest_phase + url instead of hitting the network,
# so we can verify:
#   - default/parallel creation still POSTs exactly one progress manifest
#     (unchanged behavior)
#   - --ns-sequential-creation POSTs one additional progress manifest per
#     namespace, interleaved between namespaces (not just at the end)

load 'helpers'

VSTORM="./vstorm"

setup_file() {
    setup_oc_mock
    setup_curl_mock
}

teardown() {
    unset MOCK_VM_LINES MOCK_CURL_LOG
}

# Returns the (1-based) line number of the first line in $output matching
# the given fixed string, or empty if not found.
line_of() {
    printf '%s\n' "$output" | grep -n -F -m1 -- "$1" | cut -d: -f1
}

# Returns all (1-based) line numbers in $output matching the given fixed
# string, one per line.
lines_of() {
    printf '%s\n' "$output" | grep -n -F -- "$1" | cut -d: -f1
}

# True (0) if at least one of the given line numbers falls strictly between
# lo and hi. Usage: any_line_between LO HI LINE...
any_line_between() {
    local lo=$1 hi=$2 n
    shift 2
    for n in "$@"; do
	if (( n > lo && n < hi )); then return 0; fi
    done
    return 1
}

# ===============================================================
# Default (parallel) namespace creation: unchanged -- one progress POST
# after all namespaces are created, plus one final POST.
# ===============================================================

@test "PROG: parallel creation posts exactly one progress manifest and one final manifest" {
  local log; log=$(mktemp)
  MOCK_CURL_LOG="$log" run bash "$VSTORM" --batch-id=prog001 --containerdisk --basename=tvm \
    --env=RESULT_SERVER_URL=http://mock-result-server.invalid/v1/results \
    --vms=4 --namespaces=2
  [ "$status" -eq 0 ]
  [ -s "$log" ]

  local progress_count final_count total_count
  progress_count=$(grep -c '^progress ' "$log")
  final_count=$(grep -c '^final ' "$log")
  total_count=$(wc -l < "$log")

  [ "$progress_count" -eq 1 ]
  [ "$final_count" -eq 1 ]
  [ "$total_count" -eq 2 ]
}

@test "PROG: parallel creation's single progress POST happens after both namespaces exist" {
  local log; log=$(mktemp)
  MOCK_CURL_LOG="$log" run bash "$VSTORM" --batch-id=prog002 --containerdisk --basename=tvm \
    --env=RESULT_SERVER_URL=http://mock-result-server.invalid/v1/results \
    --vms=4 --namespaces=2
  [ "$status" -eq 0 ]

  local ns2_line post_line
  ns2_line=$(line_of "Creating namespace: prog002-ns-2")
  post_line=$(line_of "Posting batch prog002 progress manifest")

  [ -n "$ns2_line" ]; [ -n "$post_line" ]
  [ "$ns2_line" -lt "$post_line" ]
}

# ===============================================================
# --ns-sequential-creation: one incremental progress POST per namespace,
# interleaved between namespaces, in addition to the pre-existing
# post-loop progress POST and the final POST.
# ===============================================================

@test "PROG: ns-sequential-creation posts one progress manifest per namespace" {
  local log; log=$(mktemp)
  MOCK_VM_LINES=$'prog010-ns-1 tvm-prog010-1 5m Running True\nprog010-ns-1 tvm-prog010-2 5m Running True\nprog010-ns-2 tvm-prog010-3 5m Running True\nprog010-ns-2 tvm-prog010-4 5m Running True\nprog010-ns-3 tvm-prog010-5 5m Running True\nprog010-ns-3 tvm-prog010-6 5m Running True' \
    MOCK_CURL_LOG="$log" \
    run bash "$VSTORM" --batch-id=prog010 --containerdisk --basename=tvm \
    --env=RESULT_SERVER_URL=http://mock-result-server.invalid/v1/results \
    --ns-sequential-creation --vms=6 --namespaces=3
  [ "$status" -eq 0 ]
  [ -s "$log" ]

  local progress_count final_count total_count
  progress_count=$(grep -c '^progress ' "$log")
  final_count=$(grep -c '^final ' "$log")
  total_count=$(wc -l < "$log")

  # 3 namespaces -> 3 per-namespace progress POSTs (new) + 1 post-loop
  # progress POST (pre-existing, after all namespaces are done) + 1 final POST.
  [ "$progress_count" -eq 4 ]
  [ "$final_count" -eq 1 ]
  [ "$total_count" -eq 5 ]
}

@test "PROG: ns-sequential-creation progress POSTs happen between namespaces, not only at the end" {
  local log; log=$(mktemp)
  MOCK_VM_LINES=$'prog011-ns-1 tvm-prog011-1 5m Running True\nprog011-ns-1 tvm-prog011-2 5m Running True\nprog011-ns-2 tvm-prog011-3 5m Running True\nprog011-ns-2 tvm-prog011-4 5m Running True\nprog011-ns-3 tvm-prog011-5 5m Running True\nprog011-ns-3 tvm-prog011-6 5m Running True' \
    MOCK_CURL_LOG="$log" \
    run bash "$VSTORM" --batch-id=prog011 --containerdisk --basename=tvm \
    --env=RESULT_SERVER_URL=http://mock-result-server.invalid/v1/results \
    --ns-sequential-creation --vms=6 --namespaces=3
  [ "$status" -eq 0 ]

  local ns1_line ns2_line ns3_line done_line
  ns1_line=$(line_of "Namespace 1 of 3")
  ns2_line=$(line_of "Namespace 2 of 3")
  ns3_line=$(line_of "Namespace 3 of 3")
  done_line=$(line_of "Resource creation completed successfully")

  [ -n "$ns1_line" ]; [ -n "$ns2_line" ]; [ -n "$ns3_line" ]; [ -n "$done_line" ]

  local -a post_lines
  mapfile -t post_lines < <(lines_of "Posting batch prog011 progress manifest")
  [ "${#post_lines[@]}" -ge 3 ]

  # A progress POST happens after namespace 1's resources but before namespace 2 starts.
  any_line_between "$ns1_line" "$ns2_line" "${post_lines[@]}"
  # A progress POST happens after namespace 2's resources but before namespace 3 starts.
  any_line_between "$ns2_line" "$ns3_line" "${post_lines[@]}"
  # A progress POST happens after namespace 3's resources, before the run reports done.
  any_line_between "$ns3_line" "$done_line" "${post_lines[@]}"
}

@test "PROG: ns-sequential-creation with a single namespace posts one incremental progress manifest" {
  local log; log=$(mktemp)
  MOCK_VM_LINES=$'prog012-ns-1 tvm-prog012-1 5m Running True\nprog012-ns-1 tvm-prog012-2 5m Running True\nprog012-ns-1 tvm-prog012-3 5m Running True' \
    MOCK_CURL_LOG="$log" \
    run bash "$VSTORM" --batch-id=prog012 --containerdisk --basename=tvm \
    --env=RESULT_SERVER_URL=http://mock-result-server.invalid/v1/results \
    --ns-sequential-creation --vms=3 --namespaces=1
  [ "$status" -eq 0 ]

  local progress_count final_count total_count
  progress_count=$(grep -c '^progress ' "$log")
  final_count=$(grep -c '^final ' "$log")
  total_count=$(wc -l < "$log")

  # 1 namespace -> 1 per-namespace progress POST (new) + 1 post-loop
  # progress POST (pre-existing) + 1 final POST.
  [ "$progress_count" -eq 2 ]
  [ "$final_count" -eq 1 ]
  [ "$total_count" -eq 3 ]
}

# ===============================================================
# No result server configured: no POSTs attempted either way.
# ===============================================================

@test "PROG: RESULT_SERVER_URL disabled means no progress/final POSTs in either mode" {
  local log; log=$(mktemp)
  MOCK_CURL_LOG="$log" run bash "$VSTORM" --batch-id=prog020 --containerdisk --basename=tvm \
    --env=RESULT_SERVER_URL= --vms=2 --namespaces=1
  [ "$status" -eq 0 ]
  [ ! -s "$log" ]

  MOCK_CURL_LOG="$log" run bash "$VSTORM" --batch-id=prog021 --containerdisk --basename=tvm \
    --env=RESULT_SERVER_URL= --ns-sequential-creation --vms=2 --namespaces=1
  [ "$status" -eq 0 ]
  [ ! -s "$log" ]
}
