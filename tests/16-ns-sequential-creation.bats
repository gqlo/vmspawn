#!/usr/bin/env bats

# Unit tests for vstorm
# Run with: bats tests/
#
# Covers --ns-sequential-creation: default false (all namespaces together)
# vs. --ns-sequential-creation=true (one namespace fully created before the next).

load 'helpers'

VSTORM="./vstorm"

setup_file() {
    setup_oc_mock
}

# Returns the (1-based) line number of the first line in $output matching
# the given fixed string, or empty if not found.
line_of() {
    printf '%s\n' "$output" | grep -n -F -m1 -- "$1" | cut -d: -f1
}

# ===============================================================
# Default behavior: all namespaces in parallel (unchanged)
# ===============================================================

@test "ns-sequential-creation default: all namespaces are created before any VM" {
  run bash "$VSTORM" -n --batch-id=nsc001 --datasource=rhel9 --no-snapshot \
    --vms=4 --namespaces=2
  [ "$status" -eq 0 ]

  # --- off by default; no staging message ---
  [[ "$output" != *"ns-sequential-creation enabled"* ]]

  local ns1_line ns2_line vm1_line
  ns1_line=$(line_of "Creating namespace: nsc001-ns-1")
  ns2_line=$(line_of "Creating namespace: nsc001-ns-2")
  vm1_line=$(line_of "Creating VirtualMachine 1 ")

  [ -n "$ns1_line" ]
  [ -n "$ns2_line" ]
  [ -n "$vm1_line" ]

  # --- Both namespaces are created before the first VM ---
  [ "$ns1_line" -lt "$vm1_line" ]
  [ "$ns2_line" -lt "$vm1_line" ]

  # --- 4 VMs total, 2 per namespace ---
  local vm_count
  vm_count=$(printf '%s\n' "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 4 ]
}

@test "ns-sequential-creation default: all base DataVolumes created before any VM" {
  run bash "$VSTORM" -n --batch-id=nsc002 --dv-url=http://example.com/disk.qcow2 --no-snapshot \
    --vms=4 --namespaces=2
  [ "$status" -eq 0 ]

  local dv1_line dv2_line vm1_line
  dv1_line=$(line_of "Creating DataVolume for namespace: nsc002-ns-1")
  dv2_line=$(line_of "Creating DataVolume for namespace: nsc002-ns-2")
  vm1_line=$(line_of "Creating VirtualMachine 1 ")

  [ -n "$dv1_line" ]
  [ -n "$dv2_line" ]
  [ "$dv1_line" -lt "$vm1_line" ]
  [ "$dv2_line" -lt "$vm1_line" ]
}

@test "ns-sequential-creation=false explicitly behaves like the default (parallel)" {
  run bash "$VSTORM" -n --batch-id=nsc003 --datasource=rhel9 --no-snapshot \
    --ns-sequential-creation=false --vms=4 --namespaces=2
  [ "$status" -eq 0 ]

  [[ "$output" != *"ns-sequential-creation enabled"* ]]

  local ns2_line vm1_line
  ns2_line=$(line_of "Creating namespace: nsc003-ns-2")
  vm1_line=$(line_of "Creating VirtualMachine 1 ")
  [ "$ns2_line" -lt "$vm1_line" ]
}

# ===============================================================
# --ns-sequential-creation: one namespace fully created before the next
# ===============================================================

@test "ns-sequential-creation (bare flag): staging message is logged" {
  run bash "$VSTORM" -n --batch-id=nsc010 --datasource=rhel9 --no-snapshot \
    --ns-sequential-creation --vms=4 --namespaces=2
  [ "$status" -eq 0 ]

  [[ "$output" == *"ns-sequential-creation enabled"* ]]
  [[ "$output" == *"Namespace 1 of 2"* ]]
  [[ "$output" == *"Namespace 2 of 2"* ]]
}

@test "ns-sequential-creation: namespace 1's VMs are created before namespace 2 exists" {
  run bash "$VSTORM" -n --batch-id=nsc011 --datasource=rhel9 --no-snapshot \
    --ns-sequential-creation=true --vms=4 --namespaces=2
  [ "$status" -eq 0 ]

  local ns1_line ns2_line vm1_line vm2_line vm3_line
  ns1_line=$(line_of "Creating namespace: nsc011-ns-1")
  ns2_line=$(line_of "Creating namespace: nsc011-ns-2")
  vm1_line=$(line_of "Creating VirtualMachine 1 ")
  vm2_line=$(line_of "Creating VirtualMachine 2 ")
  vm3_line=$(line_of "Creating VirtualMachine 3 ")

  [ -n "$ns1_line" ]; [ -n "$ns2_line" ]
  [ -n "$vm1_line" ]; [ -n "$vm2_line" ]; [ -n "$vm3_line" ]

  # --- ns-1's VMs (1,2) both happen before ns-2 is created ---
  [ "$ns1_line" -lt "$vm1_line" ]
  [ "$vm1_line" -lt "$ns2_line" ]
  [ "$vm2_line" -lt "$ns2_line" ]

  # --- ns-2's VM (3) happens after ns-2 is created ---
  [ "$ns2_line" -lt "$vm3_line" ]

  # --- VM numbering is still continuous across namespaces ---
  local vm_count
  vm_count=$(printf '%s\n' "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 4 ]
  [[ "$output" == *"Creating VirtualMachine 4 "* ]]
}

@test "ns-sequential-creation: per-namespace DataVolume + VolumeSnapshot + VM ordering" {
  run bash "$VSTORM" -n --batch-id=nsc012 --datasource=rhel9 \
    --snapshot-class=ocs-storagecluster-rbdplugin-snapclass \
    --ns-sequential-creation --vms=4 --namespaces=2
  [ "$status" -eq 0 ]

  local dv1_line snap1_line vm1_line dv2_line vm3_line
  dv1_line=$(line_of "Creating DataVolume for namespace: nsc012-ns-1")
  snap1_line=$(line_of "Creating VolumeSnapshot for namespace: nsc012-ns-1")
  vm1_line=$(line_of "Creating VirtualMachine 1 ")
  dv2_line=$(line_of "Creating DataVolume for namespace: nsc012-ns-2")
  vm3_line=$(line_of "Creating VirtualMachine 3 ")

  [ -n "$dv1_line" ]; [ -n "$snap1_line" ]; [ -n "$vm1_line" ]; [ -n "$dv2_line" ]

  # --- namespace 1: DV -> Snapshot -> VMs, all before namespace 2's DV ---
  [ "$dv1_line" -lt "$snap1_line" ]
  [ "$snap1_line" -lt "$vm1_line" ]
  [ "$vm1_line" -lt "$dv2_line" ]
  [ "$dv2_line" -lt "$vm3_line" ]

  # --- 2 base DataVolumes, 2 VolumeSnapshots, 4 VMs ---
  local dv_count snap_count vm_count
  dv_count=$(printf '%s\n' "$output" | grep -c "^Creating DataVolume for namespace")
  snap_count=$(printf '%s\n' "$output" | grep -c "^Creating VolumeSnapshot for namespace")
  vm_count=$(printf '%s\n' "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$dv_count" -eq 2 ]
  [ "$snap_count" -eq 2 ]
  [ "$vm_count" -eq 4 ]
}

@test "ns-sequential-creation: NodePort service allocation continues across namespaces" {
  run bash "$VSTORM" -n --batch-id=nsc013 --datasource=rhel9 --no-snapshot \
    --ns-sequential-creation --service --vms=4 --namespaces=2
  [ "$status" -eq 0 ]

  # --- Ports still increment per namespace, same as parallel mode ---
  [[ "$output" == *"nodePort: 32222"* ]]
  [[ "$output" == *"nodePort: 32223"* ]]

  local svc_count
  svc_count=$(printf '%s\n' "$output" | grep -c "kind: Service")
  [ "$svc_count" -eq 2 ]
}

@test "ns-sequential-creation: works with a single namespace (no staging needed)" {
  run bash "$VSTORM" -n --batch-id=nsc014 --datasource=rhel9 --no-snapshot \
    --ns-sequential-creation --vms=3 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"Namespace 1 of 1"* ]]
  local vm_count
  vm_count=$(printf '%s\n' "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 3 ]
}

@test "ns-sequential-creation: total VM/namespace counts match parallel mode for the same input" {
  run bash "$VSTORM" -n --batch-id=nsc015a --datasource=rhel9 --no-snapshot \
    --vms=9 --namespaces=3
  [ "$status" -eq 0 ]
  local vm_count_parallel
  vm_count_parallel=$(printf '%s\n' "$output" | grep -c "Creating VirtualMachine [0-9]")

  run bash "$VSTORM" -n --batch-id=nsc015b --datasource=rhel9 --no-snapshot \
    --ns-sequential-creation --vms=9 --namespaces=3
  [ "$status" -eq 0 ]
  local vm_count_sequential
  vm_count_sequential=$(printf '%s\n' "$output" | grep -c "Creating VirtualMachine [0-9]")

  [ "$vm_count_parallel" -eq 9 ]
  [ "$vm_count_sequential" -eq 9 ]
  [[ "$output" == *"name: nsc015b-ns-1"* ]]
  [[ "$output" == *"name: nsc015b-ns-2"* ]]
  [[ "$output" == *"name: nsc015b-ns-3"* ]]
}

# ===============================================================
# Validation
# ===============================================================

@test "ERR: invalid --ns-sequential-creation value is rejected" {
  run bash "$VSTORM" -n --batch-id=nsc020 --datasource=rhel9 --ns-sequential-creation=bogus \
    --vms=1 --namespaces=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid --ns-sequential-creation value"* ]]
}

@test "OPT: --ns-sequential-creation accepted with 0/1/yes/no/on/off synonyms" {
  run bash "$VSTORM" -n --batch-id=nsc021 --datasource=rhel9 --no-snapshot \
    --ns-sequential-creation=1 --vms=2 --namespaces=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"ns-sequential-creation enabled"* ]]

  run bash "$VSTORM" -n --batch-id=nsc022 --datasource=rhel9 --no-snapshot \
    --ns-sequential-creation=0 --vms=2 --namespaces=1
  [ "$status" -eq 0 ]
  [[ "$output" != *"ns-sequential-creation enabled"* ]]
}
