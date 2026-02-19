#!/usr/bin/env bats

# Unit tests for vmspawn
# Run with: bats tests/

VMSPAWN="./vmspawn"

# ===============================================================
# Core functionality
# ===============================================================

# ---------------------------------------------------------------
# Batch ID auto-generation
# ---------------------------------------------------------------
@test "auto-generates a 6-character hex batch ID" {
  run bash "$VMSPAWN" -q --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  local batch_id
  batch_id=$(echo "$output" | grep "Batch ID:" | head -1 | awk '{print $NF}')
  [[ "$batch_id" =~ ^[0-9a-f]{6}$ ]]
}

# ---------------------------------------------------------------
# Namespace naming
# ---------------------------------------------------------------
@test "namespaces follow vm-{batch}-ns-{N} pattern" {
  run bash "$VMSPAWN" -q --batch-id=ff0011 --vms=4 --namespaces=3
  [ "$status" -eq 0 ]

  [[ "$output" == *"vm-ff0011-ns-1"* ]]
  [[ "$output" == *"vm-ff0011-ns-2"* ]]
  [[ "$output" == *"vm-ff0011-ns-3"* ]]
  [[ "$output" != *"vm-ff0011-ns-4"* ]]
}

# ---------------------------------------------------------------
# VM distribution
# ---------------------------------------------------------------
@test "VMs are distributed evenly with remainder in first namespaces" {
  run bash "$VMSPAWN" -q --batch-id=aabb11 --vms=5 --namespaces=2
  [ "$status" -eq 0 ]

  local ns1_count ns2_count
  ns1_count=$(echo "$output" | grep -c "Creating VirtualMachine.*for namespace: vm-aabb11-ns-1")
  ns2_count=$(echo "$output" | grep -c "Creating VirtualMachine.*for namespace: vm-aabb11-ns-2")

  [ "$ns1_count" -eq 3 ]
  [ "$ns2_count" -eq 2 ]
}

# ===============================================================
# Validation / error handling
# ===============================================================

@test "--delete without a value fails with helpful error" {
  run bash "$VMSPAWN" -n --delete
  [ "$status" -ne 0 ]
  [[ "$output" == *"--delete requires a batch ID"* ]]
}

@test "non-numeric first positional argument is rejected" {
  run bash "$VMSPAWN" -n abc123
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid argument"* ]]
  [[ "$output" == *"expected a number for total VMs"* ]]
}

@test "non-numeric second positional argument is rejected" {
  run bash "$VMSPAWN" -n 5 abc
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid argument"* ]]
  [[ "$output" == *"expected a number for namespaces"* ]]
}

@test "--cloudinit with missing file fails" {
  run bash "$VMSPAWN" -n --batch-id=err001 --vms=1 --namespaces=1 \
    --cloudinit=nonexistent-file.yaml
  [ "$status" -ne 0 ]
  [[ "$output" == *"Cloud-init file not found"* ]]
}

@test "--dv-url with empty DATASOURCE requires URL" {
  # --dv-url clears DATASOURCE; omitting URL value should fail
  run bash "$VMSPAWN" -n --batch-id=err002 --vms=1 --namespaces=1 --dv-url=
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------
# ERR-1: --vms=0 rejected as non-positive
# ---------------------------------------------------------------
@test "ERR: --vms=0 rejected as non-positive" {
  run bash "$VMSPAWN" -n --batch-id=err010 --vms=0 --namespaces=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Number of VMs must be a positive integer"* ]]
}

# ---------------------------------------------------------------
# ERR-2: --namespaces=0 rejected as non-positive
# ---------------------------------------------------------------
@test "ERR: --namespaces=0 rejected as non-positive" {
  run bash "$VMSPAWN" -n --batch-id=err011 --vms=1 --namespaces=0
  [ "$status" -ne 0 ]
  [[ "$output" == *"Number of namespaces must be a positive integer"* ]]
}

# ---------------------------------------------------------------
# ERR-3: VMs fewer than namespaces is rejected
# ---------------------------------------------------------------
@test "ERR: --vms=2 --namespaces=5 fails (VMs < namespaces)" {
  run bash "$VMSPAWN" -n --batch-id=err012 --vms=2 --namespaces=5
  [ "$status" -ne 0 ]
  [[ "$output" == *"Number of VMs must be greater than or equal to number of namespaces"* ]]
}

# ---------------------------------------------------------------
# ERR-4: too many positional arguments rejected with diagnostic
# ---------------------------------------------------------------
@test "ERR: three positional arguments rejected with count" {
  run bash "$VMSPAWN" -n --batch-id=err013 10 2 3
  [ "$status" -ne 0 ]
  [[ "$output" == *"too many positional arguments"* ]]
  [[ "$output" == *"got 3"* ]]
}

# ---------------------------------------------------------------
# ERR-5: negative number as positional arg rejected
# ---------------------------------------------------------------
@test "ERR: negative positional arg rejected as non-numeric" {
  run bash "$VMSPAWN" -n --batch-id=err014 -- -5
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid argument"* ]]
}

# ---------------------------------------------------------------
# ERR-6: unknown long option shows error with option name
# ---------------------------------------------------------------
@test "ERR: unknown long option rejected with name" {
  run bash "$VMSPAWN" -n --batch-id=err015 --nonexistent-option
  [ "$status" -ne 0 ]
  [[ "$output" == *"unrecognized option"* ]]
  [[ "$output" == *"--nonexistent-option"* ]]
  [[ "$output" == *"-h"* ]]
}

# ---------------------------------------------------------------
# ERR-7: unknown short option shows error with option name
# ---------------------------------------------------------------
@test "ERR: unknown short option rejected with name" {
  run bash "$VMSPAWN" -nZ
  [ "$status" -ne 0 ]
  [[ "$output" == *"unrecognized option"* ]]
  [[ "$output" == *"-Z"* ]]
  [[ "$output" == *"-h"* ]]
}

# ---------------------------------------------------------------
# ERR-8: --delete= with empty string fails
# ---------------------------------------------------------------
@test "ERR: --delete with empty value fails" {
  run bash "$VMSPAWN" -n "--delete="
  [ "$status" -ne 0 ]
  [[ "$output" == *"--delete requires a batch ID"* ]]
}

# ---------------------------------------------------------------
# ERR-9: --cloudinit pointing to a directory instead of a file
# ---------------------------------------------------------------
@test "ERR: --cloudinit with directory instead of file fails" {
  run bash "$VMSPAWN" -n --batch-id=err016 --vms=1 --namespaces=1 \
    --cloudinit=/tmp
  [ "$status" -ne 0 ]
  [[ "$output" == *"Cloud-init file not found"* ]]
}

# ---------------------------------------------------------------
# ERR-10: missing namespace.yaml template
# ---------------------------------------------------------------
@test "ERR: missing namespace.yaml template fails" {
  local tmpdir
  tmpdir=$(mktemp -d)
  run env CREATE_VM_PATH="$tmpdir" bash "$VMSPAWN" -n --batch-id=err017 --vms=1 --namespaces=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found on"* ]]
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------
# ERR-11: missing dv-datasource.yaml in snapshot+datasource mode
# ---------------------------------------------------------------
@test "ERR: missing dv-datasource.yaml template fails" {
  local tmpdir
  tmpdir=$(mktemp -d)
  # Provide namespace.yaml and volumesnap.yaml and vm-snap.yaml so it
  # gets past those checks and fails on dv-datasource.yaml
  cp templates/namespace.yaml "$tmpdir/"
  cp templates/volumesnap.yaml "$tmpdir/"
  cp templates/vm-snap.yaml "$tmpdir/"
  run env CREATE_VM_PATH="$tmpdir" bash "$VMSPAWN" -n --batch-id=err018 \
    --vms=1 --namespaces=1 --snapshot
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found on"* ]]
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------
# ERR-12: missing dv.yaml in URL mode
# ---------------------------------------------------------------
@test "ERR: missing dv.yaml template fails in URL mode" {
  local tmpdir
  tmpdir=$(mktemp -d)
  cp templates/namespace.yaml "$tmpdir/"
  cp templates/vm-clone.yaml "$tmpdir/"
  run env CREATE_VM_PATH="$tmpdir" bash "$VMSPAWN" -n --batch-id=err019 \
    --vms=1 --namespaces=1 --dv-url=http://example.com/disk.qcow2 --no-snapshot
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found on"* ]]
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------
# ERR-13: missing vm-snap.yaml in snapshot mode
# ---------------------------------------------------------------
@test "ERR: missing vm-snap.yaml template fails in snapshot mode" {
  local tmpdir
  tmpdir=$(mktemp -d)
  cp templates/namespace.yaml "$tmpdir/"
  cp templates/volumesnap.yaml "$tmpdir/"
  run env CREATE_VM_PATH="$tmpdir" bash "$VMSPAWN" -n --batch-id=err020 \
    --vms=1 --namespaces=1 --snapshot
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found on"* ]]
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------
# ERR-14: missing vm-datasource.yaml in no-snapshot datasource mode
# ---------------------------------------------------------------
@test "ERR: missing vm-datasource.yaml template fails" {
  local tmpdir
  tmpdir=$(mktemp -d)
  cp templates/namespace.yaml "$tmpdir/"
  run env CREATE_VM_PATH="$tmpdir" bash "$VMSPAWN" -n --batch-id=err021 \
    --vms=1 --namespaces=1 --no-snapshot
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found on"* ]]
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------
# ERR-15: missing vm-clone.yaml in URL no-snapshot mode
# ---------------------------------------------------------------
@test "ERR: missing vm-clone.yaml template fails in URL mode" {
  local tmpdir
  tmpdir=$(mktemp -d)
  cp templates/namespace.yaml "$tmpdir/"
  cp templates/dv.yaml "$tmpdir/"
  run env CREATE_VM_PATH="$tmpdir" bash "$VMSPAWN" -n --batch-id=err022 \
    --vms=1 --namespaces=1 --dv-url=http://example.com/disk.qcow2 --no-snapshot
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found on"* ]]
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------
# ERR-16: --snapshot then --no-snapshot (last wins = no-snapshot)
# ---------------------------------------------------------------
@test "ERR: --snapshot then --no-snapshot uses no-snapshot mode" {
  run bash "$VMSPAWN" -n --batch-id=err023 --vms=2 --namespaces=1 \
    --snapshot --no-snapshot
  [ "$status" -eq 0 ]
  [[ "$output" != *"Creating VolumeSnapshots"* ]]
  [[ "$output" != *"kind: VolumeSnapshot"* ]]
}

# ---------------------------------------------------------------
# ERR-17: --no-snapshot then --snapshot (last wins = snapshot)
# ---------------------------------------------------------------
@test "ERR: --no-snapshot then --snapshot uses snapshot mode" {
  run bash "$VMSPAWN" -n --batch-id=err024 --vms=2 --namespaces=1 \
    --no-snapshot --snapshot
  [ "$status" -eq 0 ]
  [[ "$output" == *"Creating VolumeSnapshots"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]
}

# ---------------------------------------------------------------
# ERR-18: --rwo then --rwx (last wins = ReadWriteMany)
# ---------------------------------------------------------------
@test "ERR: --rwo then --rwx uses ReadWriteMany" {
  run bash "$VMSPAWN" -n --batch-id=err025 --vms=1 --namespaces=1 \
    --rwo --rwx
  [ "$status" -eq 0 ]
  [[ "$output" == *"ReadWriteMany"* ]]
  [[ "$output" != *"ReadWriteOnce"* ]]
}

# ---------------------------------------------------------------
# ERR-19: --rwx then --rwo (last wins = ReadWriteOnce)
# ---------------------------------------------------------------
@test "ERR: --rwx then --rwo uses ReadWriteOnce" {
  run bash "$VMSPAWN" -n --batch-id=err026 --vms=1 --namespaces=1 \
    --rwx --rwo
  [ "$status" -eq 0 ]
  [[ "$output" == *"ReadWriteOnce"* ]]
}

# ---------------------------------------------------------------
# ERR-20: --dv-url overrides --datasource
# ---------------------------------------------------------------
@test "ERR: --dv-url overrides --datasource" {
  run bash "$VMSPAWN" -n --batch-id=err027 --vms=1 --namespaces=1 \
    --datasource=fedora --dv-url=http://example.com/disk.qcow2 --no-snapshot
  [ "$status" -eq 0 ]
  [[ "$output" == *"http://example.com/disk.qcow2"* ]]
  # DataSource should not be referenced
  [[ "$output" != *"sourceRef"* ]]
}

# ---------------------------------------------------------------
# ERR-21: --vms=-1 rejected as non-positive
# ---------------------------------------------------------------
@test "ERR: --vms=-1 rejected as non-positive" {
  run bash "$VMSPAWN" -n --batch-id=err028 --vms=-1 --namespaces=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Number of VMs must be a positive integer"* ]]
}

# ---------------------------------------------------------------
# ERR-22: --namespaces=-1 rejected as non-positive
# ---------------------------------------------------------------
@test "ERR: --namespaces=-1 rejected as non-positive" {
  run bash "$VMSPAWN" -n --batch-id=err029 --namespaces=-1 --vms=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Number of namespaces must be a positive integer"* ]]
}

# ---------------------------------------------------------------
# ERR-23: option placed after positional arg is detected
# ---------------------------------------------------------------
@test "ERR: option after positional arg detected" {
  run bash "$VMSPAWN" -n 10 --cores=4
  [ "$status" -ne 0 ]
  [[ "$output" == *"Misplaced option '--cores=4'"* ]]
  [[ "$output" == *"before positional arguments"* ]]
}

# ---------------------------------------------------------------
# ERR-24: option sandwiched between valid option and positional
# ---------------------------------------------------------------
@test "ERR: trailing option after positional arg detected" {
  run bash "$VMSPAWN" -n --cores=4 10 --memory=2Gi
  [ "$status" -ne 0 ]
  [[ "$output" == *"Misplaced option '--memory=2Gi'"* ]]
}

# ---------------------------------------------------------------
# ERR-25: multiple misplaced options (first one is reported)
# ---------------------------------------------------------------
@test "ERR: first misplaced option is reported" {
  run bash "$VMSPAWN" -n 10 --cores=4 --memory=2Gi
  [ "$status" -ne 0 ]
  [[ "$output" == *"Misplaced option '--cores=4'"* ]]
}

# ---------------------------------------------------------------
# ERR-26: misplaced --delete after positional arg
# ---------------------------------------------------------------
@test "ERR: misplaced --delete after positional arg detected" {
  run bash "$VMSPAWN" -n 5 --delete=abc123
  [ "$status" -ne 0 ]
  [[ "$output" == *"Misplaced option '--delete=abc123'"* ]]
}

# ---------------------------------------------------------------
# ERR-27: -- end-of-options marker still works (not a false positive)
# ---------------------------------------------------------------
@test "ERR: -- end-of-options does not trigger misplaced option check" {
  run bash "$VMSPAWN" -n --batch-id=err030 --vms=1 --namespaces=1 -- 5
  [ "$status" -eq 0 ]
}

