#!/usr/bin/env bats

# Regression coverage for --delete-all discovering and deleting non-vstorm
# VM namespaces (namespaces with VirtualMachines that are not vstorm batch
# namespaces and not openshift/kube system namespaces).

load 'helpers'

VSTORM="./vstorm"

setup_file() {
    setup_oc_mock
    setup_virtctl_mock
}

teardown() {
    unset MOCK_NS_LINES MOCK_VM_LINES MOCK_NS_CALLS_FILE MOCK_CLEANUP_TICKS_FILE
    unset MOCK_LEFTOVER_NS MOCK_VIRTCTL_STOP_LOG DELETE_POLL_INTERVAL
}

@test "delete-all: discovers and deletes non-vstorm VM namespace" {
  ns_calls_file=$(mktemp)
  ticks_file=$(mktemp)
  stop_log=$(mktemp)
  echo 1 > "$ticks_file"

  MOCK_VM_LINES=$'my-vm-ns tvm-manual-1 5m Stopped False' \
  MOCK_LEFTOVER_NS="my-vm-ns" \
  MOCK_CLEANUP_TICKS_FILE="$ticks_file" \
  MOCK_VIRTCTL_STOP_LOG="$stop_log" \
  DELETE_POLL_INTERVAL=0 \
    run bash "$VSTORM" --delete-all --yes
  [ "$status" -eq 0 ]

  [[ "$output" == *"Found non-vstorm VM namespaces:"* ]]
  [[ "$output" == *"my-vm-ns"* ]]
  [[ "$output" == *"Stopping 1 VM(s) in my-vm-ns"* ]]
  [[ "$output" == *"Deleting namespace 'my-vm-ns'"* ]]
  [[ "$output" == *"Monitoring cleanup for namespace 'my-vm-ns'"* ]]
  [[ "$output" == *"fully cleaned up"* ]]
  grep -qx 'my-vm-ns/tvm-manual-1' "$stop_log"

  rm -f "$ns_calls_file" "$ticks_file" "$stop_log"
}

@test "delete-all: skips openshift and kube system VM namespaces" {
  MOCK_VM_LINES=$'openshift-cnv virt-operator 5m Running True
kube-system test-vm 5m Running True
my-other-ns vm1 5m Stopped False' \
  MOCK_LEFTOVER_NS="my-other-ns" \
  MOCK_CLEANUP_TICKS_FILE="$(mktemp)" \
  DELETE_POLL_INTERVAL=0 \
    run bash "$VSTORM" --delete-all --yes
  [ "$status" -eq 0 ]

  [[ "$output" == *"Found non-vstorm VM namespaces:"* ]]
  [[ "$output" == *"my-other-ns"* ]]
  [[ "$output" != *"openshift-cnv"* ]]
  [[ "$output" != *"kube-system"* ]]

  rm -f "$MOCK_CLEANUP_TICKS_FILE"
}

@test "delete-all: vstorm batch namespaces are not listed as non-vstorm" {
  ns_calls_file=$(mktemp)
  ticks_file=$(mktemp)
  echo 1 > "$ticks_file"

  MOCK_NS_LINES="delall1-ns-1" \
  MOCK_VM_LINES=$'delall1-ns-1 tvm-delall1-1 5m Stopped False
other-ns tvm-other-1 5m Stopped False' \
  MOCK_NS_CALLS_FILE="$ns_calls_file" \
  MOCK_LEFTOVER_NS="delall1-ns-1" \
  MOCK_CLEANUP_TICKS_FILE="$ticks_file" \
  DELETE_POLL_INTERVAL=0 \
    run bash "$VSTORM" --delete-all --yes
  [ "$status" -eq 0 ]

  [[ "$output" == *"Found vstorm batches:"* ]]
  [[ "$output" == *"delall1"* ]]
  [[ "$output" == *"Found non-vstorm VM namespaces:"* ]]
  [[ "$output" == *"other-ns"* ]]
  [[ "$output" != *"delall1-ns-1  (1 VMs)"* ]]

  rm -f "$ns_calls_file" "$ticks_file"
}
