#!/usr/bin/env bats

# Unit tests for vstorm
# Run with: bats tests/
#
# Regression coverage for wait_for_all_vms() actually running (wet-run, not
# dry-run) end-to-end via create_virtualmachines(). All other test files
# only ever exercise vstorm with -n/-q (dry-run), so wait_for_all_vms() --
# and any function that calls it -- was never actually executed by the test
# suite. That's exactly how a bug slipped through: create_virtualmachines()
# declared its "vm" loop variable as "local -i" (integer), and because
# wait_for_all_vms() is called from within create_virtualmachines() and
# doesn't declare its own local "vm", bash's dynamic scoping made
# wait_for_all_vms()'s `read -r vm` write into that integer-typed local.
# Assigning a non-numeric string like "ns/vm-name" to an integer variable
# makes bash evaluate it as arithmetic, which fails under `set -u` on the
# first bare word (e.g. "vstorm: unbound variable"). --ns-sequential-creation
# triggers this via its forced inter-namespace wait even without --wait.

load 'helpers'

VSTORM="./vstorm"

setup_file() {
    setup_oc_mock
}

teardown() {
    unset MOCK_VM_LINES
}

@test "wet-run: --wait completes and reports all VMs ready (no unbound variable)" {
  MOCK_VM_LINES=$'wwr001-ns-1 tvm-wwr001-1 5m Running True\nwwr001-ns-1 tvm-wwr001-2 5m Running True' \
    run bash "$VSTORM" --batch-id=wwr001 --containerdisk --basename=tvm \
    --vms=2 --namespaces=1 --wait
  [ "$status" -eq 0 ]
  [[ "$output" != *"unbound variable"* ]]
  [[ "$output" == *"All VMs are ready"* ]]
}

@test "wet-run: --ns-sequential-creation forces an inter-namespace wait (no unbound variable)" {
  MOCK_VM_LINES=$'wwr002-ns-1 tvm-wwr002-1 5m Running True\nwwr002-ns-2 tvm-wwr002-2 5m Running True' \
    run bash "$VSTORM" --batch-id=wwr002 --containerdisk --basename=tvm \
    --vms=2 --namespaces=2 --ns-sequential-creation
  [ "$status" -eq 0 ]
  [[ "$output" != *"unbound variable"* ]]
  # Namespace 1 (not the last) must wait before namespace 2 starts.
  [[ "$output" == *"All VMs are ready"* ]]
}
