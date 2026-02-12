#!/usr/bin/env bats

# Unit tests for vmspawn
# Run with: bats tests/

VMSPAWN="./vmspawn"

# ===============================================================
# Quick start commands (README)
# ===============================================================

# ---------------------------------------------------------------
# QS-1: ./vmspawn --cores=4 --memory=8Gi --vms=10 --namespaces=2
#   Default DataSource (rhel9), 10 VMs with custom CPU/memory
# ---------------------------------------------------------------
@test "QS: default DataSource, 4 cores 8Gi, 10 VMs across 2 namespaces" {
  run bash "$VMSPAWN" -n --batch-id=qs0001 --cores=4 --memory=8Gi --vms=10 --namespaces=2
  [ "$status" -eq 0 ]

  # --- Namespaces ---
  [[ "$output" == *"name: vm-qs0001-ns-1"* ]]
  [[ "$output" == *"name: vm-qs0001-ns-2"* ]]
  [[ "$output" != *"vm-qs0001-ns-3"* ]]

  # --- DataVolume clones from rhel9 DataSource ---
  [[ "$output" == *"Creating DataVolumes"* ]]
  [[ "$output" == *"kind: DataVolume"* ]]
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"kind: DataSource"* ]]
  [[ "$output" == *"name: rhel9"* ]]
  [[ "$output" == *"namespace: openshift-virtualization-os-images"* ]]

  # --- DV has explicit storage size ---
  [[ "$output" == *"storage: 32Gi"* ]]

  # --- VolumeSnapshots ---
  [[ "$output" == *"Creating VolumeSnapshots"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]
  [[ "$output" == *"name: rhel9-vm-qs0001-ns-1"* ]]
  [[ "$output" == *"name: rhel9-vm-qs0001-ns-2"* ]]

  # --- VMs clone from snapshot ---
  [[ "$output" == *"Creating VirtualMachines"* ]]
  [[ "$output" == *"kind: VirtualMachine"* ]]
  [[ "$output" == *"smartCloneFromExistingSnapshot"* ]]

  # --- 10 VMs total: 5 per namespace ---
  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 10 ]

  # --- Default cloud-init auto-applied ---
  [[ "$output" == *"applying default cloud-init"* ]]
  [[ "$output" == *"kind: Secret"* ]]
  [[ "$output" == *"secretRef"* ]]
  [[ "$output" == *"cloudInitNoCloud"* ]]

  # --- VM spec: custom CPU and memory ---
  [[ "$output" == *"cores: 4"* ]]
  [[ "$output" == *"guest: 8Gi"* ]]

  # --- VM spec structure ---
  [[ "$output" == *"runStrategy: Always"* ]]
  [[ "$output" == *"bus: virtio"* ]]
  [[ "$output" == *"masquerade"* ]]
  [[ "$output" == *"evictionStrategy: LiveMigrate"* ]]

  # --- Log messages reflect custom CPU/memory ---
  [[ "$output" == *"VM CPU cores:  4"* ]]
  [[ "$output" == *"VM memory:     8Gi"* ]]

  # --- Labels on all resources ---
  [[ "$output" == *'batch-id: "qs0001"'* ]]
  [[ "$output" == *'vm-basename: "rhel9"'* ]]
}

# ---------------------------------------------------------------
# QS-2: ./vmspawn --datasource=fedora --vms=5 --namespaces=1
#   Different DataSource (fedora)
# ---------------------------------------------------------------
@test "QS: fedora DataSource, 5 VMs in 1 namespace" {
  run bash "$VMSPAWN" -n --batch-id=qs0002 --datasource=fedora --vms=5 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Single namespace ---
  [[ "$output" == *"name: vm-qs0002-ns-1"* ]]
  [[ "$output" != *"vm-qs0002-ns-2"* ]]

  # --- DV references fedora DataSource ---
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"kind: DataSource"* ]]
  [[ "$output" == *"name: fedora"* ]]
  [[ "$output" == *"namespace: openshift-virtualization-os-images"* ]]

  # --- VolumeSnapshot created ---
  [[ "$output" == *"kind: VolumeSnapshot"* ]]

  # --- 5 VMs ---
  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 5 ]

  # --- VMs clone from snapshot ---
  [[ "$output" == *"smartCloneFromExistingSnapshot"* ]]

  # --- Default cloud-init auto-applied ---
  [[ "$output" == *"applying default cloud-init"* ]]
  [[ "$output" == *"kind: Secret"* ]]
}

# ---------------------------------------------------------------
# QS-3: ./vmspawn --dv-url=http://myhost:8000/rhel9-disk.qcow2 --vms=10 --namespaces=2
#   URL import mode
# ---------------------------------------------------------------
@test "QS: URL import, 10 VMs across 2 namespaces" {
  run bash "$VMSPAWN" -n --batch-id=qs0003 --vms=10 --namespaces=2 \
    --dv-url=http://myhost:8000/rhel9-disk.qcow2
  [ "$status" -eq 0 ]

  # --- 2 namespaces ---
  [[ "$output" == *"name: vm-qs0003-ns-1"* ]]
  [[ "$output" == *"name: vm-qs0003-ns-2"* ]]

  # --- DV imports from URL (not DataSource) ---
  [[ "$output" == *"kind: DataVolume"* ]]
  [[ "$output" == *"http://myhost:8000/rhel9-disk.qcow2"* ]]
  [[ "$output" != *"sourceRef"* ]]
  [[ "$output" != *"kind: DataSource"* ]]

  # --- DV uses explicit storage size ---
  [[ "$output" == *"storage: 32Gi"* ]]

  # --- VolumeSnapshots ---
  [[ "$output" == *"Creating VolumeSnapshots"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]
  [[ "$output" == *"name: vm-vm-qs0003-ns-1"* ]]
  [[ "$output" == *"name: vm-vm-qs0003-ns-2"* ]]

  # --- 10 VMs ---
  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 10 ]

  # --- No auto cloud-init in URL mode ---
  [[ "$output" != *"applying default cloud-init"* ]]
  [[ "$output" != *"kind: Secret"* ]]
  [[ "$output" != *"cloudInitNoCloud"* ]]

  # --- VMs clone from snapshot ---
  [[ "$output" == *"smartCloneFromExistingSnapshot"* ]]
}

# ---------------------------------------------------------------
# QS-4: ./vmspawn --cloudinit=helpers/cloudinit-stress-workload.yaml --vms=10 --namespaces=2
#   Custom cloud-init workload
# ---------------------------------------------------------------
@test "QS: custom cloud-init stress workload, 10 VMs across 2 namespaces" {
  run bash "$VMSPAWN" -n --batch-id=qs0004 --vms=10 --namespaces=2 \
    --cloudinit=helpers/cloudinit-stress-workload.yaml
  [ "$status" -eq 0 ]

  # --- DataSource mode (default) ---
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"kind: DataSource"* ]]
  [[ "$output" == *"name: rhel9"* ]]

  # --- Cloud-init Secret created per namespace ---
  local secret_count
  secret_count=$(echo "$output" | grep -c "kind: Secret")
  [ "$secret_count" -eq 2 ]

  # --- Secret references correct name ---
  [[ "$output" == *"name: rhel9-cloudinit"* ]]

  # --- VM volumes use secretRef ---
  [[ "$output" == *"cloudInitNoCloud"* ]]
  [[ "$output" == *"secretRef"* ]]
  [[ "$output" != *"userDataBase64"* ]]

  # --- 10 VMs ---
  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 10 ]

  # --- Explicit cloud-init, not auto-applied ---
  [[ "$output" != *"applying default cloud-init"* ]]
}

# ---------------------------------------------------------------
# QS-5: ./vmspawn --datasource=centos-stream9 --vms=5 --namespaces=1
#   Different DataSource with default cloud-init auto-applied
# ---------------------------------------------------------------
@test "QS: centos-stream9 DataSource with default cloud-init" {
  run bash "$VMSPAWN" -n --batch-id=qs0005 --datasource=centos-stream9 --vms=5 --namespaces=1
  [ "$status" -eq 0 ]

  # --- DV references centos-stream9 DataSource ---
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"kind: DataSource"* ]]
  [[ "$output" == *"name: centos-stream9"* ]]
  [[ "$output" == *"namespace: openshift-virtualization-os-images"* ]]

  # --- DV + snapshot + clone flow ---
  [[ "$output" == *"Creating DataVolumes"* ]]
  [[ "$output" == *"Creating VolumeSnapshots"* ]]
  [[ "$output" == *"smartCloneFromExistingSnapshot"* ]]

  # --- 5 VMs ---
  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 5 ]

  # --- Default cloud-init auto-applied (not explicit) ---
  [[ "$output" == *"applying default cloud-init"* ]]
  [[ "$output" == *"kind: Secret"* ]]
  [[ "$output" == *"secretRef"* ]]
  [[ "$output" == *"cloudInitNoCloud"* ]]
}

# ---------------------------------------------------------------
# QS-6: ./vmspawn --storage-class=my-nfs-sc --vms=10 --namespaces=2
#   Non-OCS storage class (snapshots auto-disabled)
# ---------------------------------------------------------------
@test "QS: non-OCS storage class auto-disables snapshots, 10 VMs across 2 namespaces" {
  run bash "$VMSPAWN" -n --batch-id=qs0006 --storage-class=my-nfs-sc --vms=10 --namespaces=2
  [ "$status" -eq 0 ]

  # --- 2 namespaces ---
  [[ "$output" == *"name: vm-qs0006-ns-1"* ]]
  [[ "$output" == *"name: vm-qs0006-ns-2"* ]]

  # --- Snapshots auto-disabled ---
  [[ "$output" == *"Snapshot mode: disabled (direct DataSource clone)"* ]]
  [[ "$output" == *"Skipping VolumeSnapshots"* ]]
  [[ "$output" != *"kind: VolumeSnapshot"* ]]

  # --- No base DV (direct DataSource clone) ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]

  # --- Storage class applied ---
  [[ "$output" == *"storageClassName: my-nfs-sc"* ]]
  [[ "$output" == *"Storage Class: my-nfs-sc"* ]]

  # --- VMs clone directly from DataSource ---
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"kind: DataSource"* ]]
  [[ "$output" != *"smartCloneFromExistingSnapshot"* ]]

  # --- 10 VMs ---
  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 10 ]

  # --- Default cloud-init auto-applied ---
  [[ "$output" == *"applying default cloud-init"* ]]
  [[ "$output" == *"kind: Secret"* ]]
}

# ---------------------------------------------------------------
# QS-7: ./vmspawn --storage-class=my-rbd-sc --snapshot-class=my-rbd-snap --vms=10 --namespaces=2
#   Custom storage + snapshot class pair (snapshots enabled)
# ---------------------------------------------------------------
@test "QS: custom storage and snapshot class pair, 10 VMs across 2 namespaces" {
  run bash "$VMSPAWN" -n --batch-id=qs0007 --storage-class=my-rbd-sc \
    --snapshot-class=my-rbd-snap --vms=10 --namespaces=2
  [ "$status" -eq 0 ]

  # --- 2 namespaces ---
  [[ "$output" == *"name: vm-qs0007-ns-1"* ]]
  [[ "$output" == *"name: vm-qs0007-ns-2"* ]]

  # --- Snapshots enabled (both classes provided) ---
  [[ "$output" == *"Snapshot mode: enabled"* ]]
  [[ "$output" == *"Creating VolumeSnapshots"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]

  # --- Uses provided classes ---
  [[ "$output" == *"storageClassName: my-rbd-sc"* ]]
  [[ "$output" == *"volumeSnapshotClassName: my-rbd-snap"* ]]

  # --- VMs clone from snapshot ---
  [[ "$output" == *"smartCloneFromExistingSnapshot"* ]]

  # --- 10 VMs ---
  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 10 ]
}

# ---------------------------------------------------------------
# QS-8: ./vmspawn --no-snapshot --vms=10 --namespaces=2
#   Explicit no-snapshot mode
# ---------------------------------------------------------------
@test "QS: explicit no-snapshot, 10 VMs across 2 namespaces" {
  run bash "$VMSPAWN" -n --batch-id=qs0008 --no-snapshot --vms=10 --namespaces=2
  [ "$status" -eq 0 ]

  # --- 2 namespaces ---
  [[ "$output" == *"name: vm-qs0008-ns-1"* ]]
  [[ "$output" == *"name: vm-qs0008-ns-2"* ]]

  # --- Snapshots disabled (DataSource direct clone) ---
  [[ "$output" == *"Snapshot mode: disabled (direct DataSource clone)"* ]]
  [[ "$output" == *"Skipping VolumeSnapshots"* ]]
  [[ "$output" != *"kind: VolumeSnapshot"* ]]

  # --- No base DV, VMs clone directly from DataSource ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"kind: DataSource"* ]]
  [[ "$output" != *"smartCloneFromExistingSnapshot"* ]]

  # --- 10 VMs ---
  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 10 ]

  # --- Default cloud-init auto-applied ---
  [[ "$output" == *"applying default cloud-init"* ]]
  [[ "$output" == *"kind: Secret"* ]]
}

# ---------------------------------------------------------------
# QS-9: ./vmspawn -n --vms=10 --namespaces=2
#   Dry-run mode (same as QS-1 but verifying dry-run behavior)
# ---------------------------------------------------------------
@test "QS: dry-run does not emit oc apply commands" {
  run bash "$VMSPAWN" -n --batch-id=qs0009 --vms=10 --namespaces=2
  [ "$status" -eq 0 ]

  # --- Outputs YAML ---
  [[ "$output" == *"apiVersion:"* ]]
  [[ "$output" == *"kind: Namespace"* ]]
  [[ "$output" == *"kind: DataVolume"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]
  [[ "$output" == *"kind: VirtualMachine"* ]]

  # --- Does not print "oc apply" (dry-run skips actual commands) ---
  [[ "$output" != *"oc apply"* ]]

  # --- Does not print completion message (only printed when doit=1) ---
  [[ "$output" != *"Resource creation completed successfully"* ]]

  # --- Dry-run YAML file saved ---
  [[ "$output" == *"Dry-run YAML saved to: logs/qs0009-dryrun.yaml"* ]]

  # cleanup
  rm -f logs/qs0009-dryrun.yaml
}

# ---------------------------------------------------------------
# Dry-run YAML file tests
# ---------------------------------------------------------------
@test "dry-run: saves YAML file with all resources" {
  run bash "$VMSPAWN" -n --batch-id=dry001 --vms=3 --namespaces=1
  [ "$status" -eq 0 ]

  # --- File exists ---
  [ -f logs/dry001-dryrun.yaml ]

  # --- File contains all resource types ---
  local content
  content=$(cat logs/dry001-dryrun.yaml)
  [[ "$content" == *"kind: Namespace"* ]]
  [[ "$content" == *"kind: DataVolume"* ]]
  [[ "$content" == *"kind: VolumeSnapshot"* ]]
  [[ "$content" == *"kind: VirtualMachine"* ]]

  # --- File contains document separators ---
  local separator_count
  separator_count=$(grep -c "^---$" logs/dry001-dryrun.yaml)
  [ "$separator_count" -ge 4 ]

  # --- Message printed to stdout ---
  [[ "$output" == *"Dry-run YAML saved to: logs/dry001-dryrun.yaml"* ]]

  # cleanup
  rm -f logs/dry001-dryrun.yaml
}

@test "dry-run: YAML file has correct batch ID and namespaces" {
  run bash "$VMSPAWN" -n --batch-id=dry002 --vms=2 --namespaces=2
  [ "$status" -eq 0 ]

  [ -f logs/dry002-dryrun.yaml ]

  local content
  content=$(cat logs/dry002-dryrun.yaml)

  # --- Batch ID substituted ---
  [[ "$content" == *'batch-id: "dry002"'* ]]

  # --- Both namespaces present ---
  [[ "$content" == *"name: vm-dry002-ns-1"* ]]
  [[ "$content" == *"name: vm-dry002-ns-2"* ]]

  # --- VM names ---
  [[ "$content" == *"name: rhel9-dry002-1"* ]]
  [[ "$content" == *"name: rhel9-dry002-2"* ]]

  # cleanup
  rm -f logs/dry002-dryrun.yaml
}

@test "dry-run: no-snapshot mode saves DataSource clone YAML" {
  run bash "$VMSPAWN" -n --batch-id=dry003 --no-snapshot --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  [ -f logs/dry003-dryrun.yaml ]

  local content
  content=$(cat logs/dry003-dryrun.yaml)

  # --- DataSource clone, not PVC clone, not snapshot ---
  [[ "$content" == *"sourceRef"* ]]
  [[ "$content" == *"kind: DataSource"* ]]
  [[ "$content" != *"smartCloneFromExistingSnapshot"* ]]
  [[ "$content" != *"kind: VolumeSnapshot"* ]]
  # --- No standalone DataVolume (only in VM dataVolumeTemplates) ---
  [[ "$content" != *"name: rhel9-base"* ]]

  # cleanup
  rm -f logs/dry003-dryrun.yaml
}

@test "dry-run: quiet mode does not create YAML file" {
  run bash "$VMSPAWN" -q --batch-id=dry004 --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- No YAML file created ---
  [ ! -f logs/dry004-dryrun.yaml ]

  # --- No "saved to" message ---
  [[ "$output" != *"Dry-run YAML saved to"* ]]
}

# ---------------------------------------------------------------
# QS-10: ./vmspawn --delete=a3f7b2
#   Delete batch
# ---------------------------------------------------------------
@test "QS: delete batch dry-run shows correct oc delete command" {
  run bash "$VMSPAWN" -n --delete=a3f7b2
  [ "$status" -eq 0 ]

  [[ "$output" == *"dry-run"* ]]
  [[ "$output" == *"a3f7b2"* ]]
  [[ "$output" == *"oc delete ns -l batch-id=a3f7b2"* ]]
}

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
# ERR-4: too many positional arguments rejected
# ---------------------------------------------------------------
@test "ERR: three positional arguments rejected" {
  run bash "$VMSPAWN" -n --batch-id=err013 10 2 extra
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
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
  run bash "$VMSPAWN" -Z
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

# ===============================================================
# YAML structure validation
# ===============================================================

# ---------------------------------------------------------------
# DataSource DV template structure
# ---------------------------------------------------------------
@test "DataSource DV uses storage API with explicit size" {
  run bash "$VMSPAWN" -n --batch-id=yaml01 --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # Uses storage: (not pvc:)
  [[ "$output" == *"storage:"* ]]
  [[ "$output" == *"accessModes:"* ]]
  [[ "$output" == *"ReadWriteMany"* ]]
  [[ "$output" == *"volumeMode: Block"* ]]
  [[ "$output" == *"storageClassName:"* ]]
  # Explicit size included for WFFC compatibility
  [[ "$output" == *"storage: 32Gi"* ]]
}

# ---------------------------------------------------------------
# URL DV template structure
# ---------------------------------------------------------------
@test "URL DV uses source.http.url with explicit storage size" {
  run bash "$VMSPAWN" -n --batch-id=yaml02 --vms=1 --namespaces=1 \
    --dv-url=http://example.com/disk.qcow2 --storage-size=50Gi
  [ "$status" -eq 0 ]

  [[ "$output" == *"url: http://example.com/disk.qcow2"* ]]
  [[ "$output" == *"storage: 50Gi"* ]]
}

# ---------------------------------------------------------------
# VM YAML structure
# ---------------------------------------------------------------
@test "VM YAML contains all expected sections" {
  run bash "$VMSPAWN" -n --batch-id=yaml03 --vms=1 --namespaces=1 \
    --cores=4 --memory=8Gi
  [ "$status" -eq 0 ]

  # VM metadata
  [[ "$output" == *"kind: VirtualMachine"* ]]
  [[ "$output" == *"name: rhel9-yaml03-1"* ]]
  [[ "$output" == *"namespace: vm-yaml03-ns-1"* ]]

  # Spec
  [[ "$output" == *"runStrategy: Always"* ]]
  [[ "$output" == *"dataVolumeTemplates"* ]]

  # CPU and memory from flags
  [[ "$output" == *"cores: 4"* ]]
  [[ "$output" == *"guest: 8Gi"* ]]

  # Devices
  [[ "$output" == *"disk:"* ]]
  [[ "$output" == *"bus: virtio"* ]]
  [[ "$output" == *"masquerade"* ]]
  [[ "$output" == *"networkInterfaceMultiqueue: true"* ]]
  [[ "$output" == *"rng: {}"* ]]

  # Firmware
  [[ "$output" == *"efi:"* ]]
  [[ "$output" == *"secureBoot: false"* ]]

  # Scheduling
  [[ "$output" == *"evictionStrategy: LiveMigrate"* ]]

  # Volumes
  [[ "$output" == *"dataVolume:"* ]]
  [[ "$output" == *"name: vda"* ]]
}

# ---------------------------------------------------------------
# --stop sets run strategy to Halted
# ---------------------------------------------------------------
@test "--stop sets runStrategy to Halted" {
  run bash "$VMSPAWN" -n --batch-id=yaml04 --vms=1 --namespaces=1 --stop
  [ "$status" -eq 0 ]

  [[ "$output" == *"runStrategy: Halted"* ]]
}

# ---------------------------------------------------------------
# VolumeSnapshot YAML structure
# ---------------------------------------------------------------
@test "VolumeSnapshot YAML is well-formed" {
  run bash "$VMSPAWN" -n --batch-id=yaml05 --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"apiVersion: snapshot.storage.k8s.io/v1"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]
  [[ "$output" == *"name: rhel9-vm-yaml05-ns-1"* ]]
  [[ "$output" == *"namespace: vm-yaml05-ns-1"* ]]
  [[ "$output" == *"volumeSnapshotClassName:"* ]]
  [[ "$output" == *"persistentVolumeClaimName: rhel9-base"* ]]
}

# ---------------------------------------------------------------
# Namespace YAML structure
# ---------------------------------------------------------------
@test "Namespace YAML is well-formed" {
  run bash "$VMSPAWN" -n --batch-id=yaml06 --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"apiVersion: v1"* ]]
  [[ "$output" == *"kind: Namespace"* ]]
  [[ "$output" == *"name: vm-yaml06-ns-1"* ]]
  [[ "$output" == *'batch-id: "yaml06"'* ]]
}

# ---------------------------------------------------------------
# Cloud-init Secret YAML structure
# ---------------------------------------------------------------
@test "Cloud-init Secret YAML is well-formed" {
  run bash "$VMSPAWN" -n --batch-id=yaml07 --vms=1 --namespaces=1 \
    --cloudinit=helpers/cloudinit-stress-workload.yaml
  [ "$status" -eq 0 ]

  [[ "$output" == *"apiVersion: v1"* ]]
  [[ "$output" == *"kind: Secret"* ]]
  [[ "$output" == *"name: rhel9-cloudinit"* ]]
  [[ "$output" == *"namespace: vm-yaml07-ns-1"* ]]
  [[ "$output" == *"type: Opaque"* ]]
  [[ "$output" == *"userdata:"* ]]
  [[ "$output" == *'batch-id: "yaml07"'* ]]
  [[ "$output" == *'vm-basename: "rhel9"'* ]]
}

# ===============================================================
# --no-snapshot mode (direct PVC clone)
# ===============================================================

# ---------------------------------------------------------------
# NS-1: --no-snapshot skips VolumeSnapshots entirely
# ---------------------------------------------------------------
@test "no-snapshot: skips VolumeSnapshot creation" {
  run bash "$VMSPAWN" -n --batch-id=nosn01 --no-snapshot --vms=3 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Snapshot info ---
  [[ "$output" == *"Snapshot mode: disabled (direct DataSource clone)"* ]]
  [[ "$output" == *"Skipping VolumeSnapshots"* ]]

  # --- No VolumeSnapshot YAML emitted ---
  [[ "$output" != *"kind: VolumeSnapshot"* ]]
  [[ "$output" != *"volumeSnapshotClassName"* ]]

  # --- No base DataVolume (direct DataSource clone) ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]

  # --- VMs still created (with inline DataVolumeTemplates) ---
  [[ "$output" == *"Creating VirtualMachines"* ]]
  [[ "$output" == *"kind: VirtualMachine"* ]]
  [[ "$output" == *"dataVolumeTemplates"* ]]

  # --- 3 VMs ---
  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 3 ]
}

# ---------------------------------------------------------------
# NS-2: --no-snapshot VMs clone directly from DataSource
# ---------------------------------------------------------------
@test "no-snapshot: VMs clone from DataSource instead of snapshot" {
  run bash "$VMSPAWN" -n --batch-id=nosn02 --no-snapshot --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- VM uses DataSource sourceRef (not PVC, not snapshot) ---
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"kind: DataSource"* ]]
  [[ "$output" == *"name: rhel9"* ]]
  [[ "$output" == *"namespace: openshift-virtualization-os-images"* ]]

  # --- No base PVC reference ---
  [[ "$output" != *"name: rhel9-base"* ]]

  # --- No snapshot references ---
  [[ "$output" != *"smartCloneFromExistingSnapshot"* ]]
}

# ---------------------------------------------------------------
# NS-3: --no-snapshot with URL import
# ---------------------------------------------------------------
@test "no-snapshot: works with --dv-url" {
  run bash "$VMSPAWN" -n --batch-id=nosn03 --no-snapshot --vms=2 --namespaces=1 \
    --dv-url=http://example.com/disk.qcow2
  [ "$status" -eq 0 ]

  # --- DV imports from URL ---
  [[ "$output" == *"http://example.com/disk.qcow2"* ]]

  # --- No snapshots ---
  [[ "$output" != *"kind: VolumeSnapshot"* ]]
  [[ "$output" == *"Skipping VolumeSnapshots"* ]]

  # --- VMs clone from PVC ---
  [[ "$output" == *"pvc:"* ]]
  [[ "$output" != *"smartCloneFromExistingSnapshot"* ]]
}

# ---------------------------------------------------------------
# NS-4: --no-snapshot with custom cloud-init
# ---------------------------------------------------------------
@test "no-snapshot: works with custom cloud-init" {
  run bash "$VMSPAWN" -n --batch-id=nosn04 --no-snapshot --vms=2 --namespaces=1 \
    --cloudinit=helpers/cloudinit-stress-workload.yaml
  [ "$status" -eq 0 ]

  # --- Cloud-init Secret created ---
  [[ "$output" == *"kind: Secret"* ]]
  [[ "$output" == *"cloudInitNoCloud"* ]]
  [[ "$output" == *"secretRef"* ]]

  # --- No snapshots ---
  [[ "$output" != *"kind: VolumeSnapshot"* ]]
  [[ "$output" == *"Skipping VolumeSnapshots"* ]]

  # --- Direct DataSource clone ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
  [[ "$output" == *"sourceRef"* ]]
}

# ---------------------------------------------------------------
# NS-5: --no-snapshot across multiple namespaces
# ---------------------------------------------------------------
@test "no-snapshot: multiple namespaces, 10 VMs" {
  run bash "$VMSPAWN" -n --batch-id=nosn05 --no-snapshot --vms=10 --namespaces=3
  [ "$status" -eq 0 ]

  # --- 3 namespaces ---
  [[ "$output" == *"name: vm-nosn05-ns-1"* ]]
  [[ "$output" == *"name: vm-nosn05-ns-2"* ]]
  [[ "$output" == *"name: vm-nosn05-ns-3"* ]]

  # --- 10 VMs ---
  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 10 ]

  # --- No snapshots ---
  [[ "$output" != *"kind: VolumeSnapshot"* ]]
}

# ---------------------------------------------------------------
# NS-6: --storage-class option works
# ---------------------------------------------------------------
@test "storage-class option sets storage class on all resources" {
  run bash "$VMSPAWN" -n --batch-id=nosn06 --no-snapshot --vms=1 --namespaces=1 \
    --storage-class=my-custom-sc
  [ "$status" -eq 0 ]

  # --- Storage class appears in VM ---
  [[ "$output" == *"storageClassName: my-custom-sc"* ]]
  [[ "$output" == *"Storage Class: my-custom-sc"* ]]

  # --- No base DV (DataSource direct clone) ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
}

# ---------------------------------------------------------------
# NS-7: --snapshot (default) still works as before
# ---------------------------------------------------------------
@test "explicit --snapshot produces snapshot-based flow" {
  run bash "$VMSPAWN" -n --batch-id=nosn07 --snapshot --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Snapshot mode enabled ---
  [[ "$output" == *"Snapshot mode: enabled"* ]]

  # --- VolumeSnapshot created ---
  [[ "$output" == *"Creating VolumeSnapshots"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]

  # --- VMs clone from snapshot ---
  [[ "$output" == *"smartCloneFromExistingSnapshot"* ]]
}

# ---------------------------------------------------------------
# NS-8: vm-datasource.yaml template is well-formed
# ---------------------------------------------------------------
@test "no-snapshot: VM DataSource clone YAML is well-formed" {
  run bash "$VMSPAWN" -n --batch-id=nosn08 --no-snapshot --vms=1 --namespaces=1 \
    --cores=4 --memory=8Gi
  [ "$status" -eq 0 ]

  # VM metadata
  [[ "$output" == *"kind: VirtualMachine"* ]]
  [[ "$output" == *"name: rhel9-nosn08-1"* ]]
  [[ "$output" == *"namespace: vm-nosn08-ns-1"* ]]

  # Spec
  [[ "$output" == *"runStrategy: Always"* ]]
  [[ "$output" == *"dataVolumeTemplates"* ]]

  # DataSource sourceRef (not PVC clone)
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"kind: DataSource"* ]]
  [[ "$output" == *"name: rhel9"* ]]
  [[ "$output" == *"namespace: openshift-virtualization-os-images"* ]]
  [[ "$output" != *"name: rhel9-base"* ]]

  # Storage spec on inline DV
  [[ "$output" == *"storage:"* ]]
  [[ "$output" == *"accessModes:"* ]]
  [[ "$output" == *"volumeMode: Block"* ]]
  [[ "$output" == *"storage: 32Gi"* ]]

  # CPU and memory from flags
  [[ "$output" == *"cores: 4"* ]]
  [[ "$output" == *"guest: 8Gi"* ]]

  # Standard VM features
  [[ "$output" == *"bus: virtio"* ]]
  [[ "$output" == *"masquerade"* ]]
  [[ "$output" == *"evictionStrategy: LiveMigrate"* ]]
  [[ "$output" == *"efi:"* ]]

  # Labels
  [[ "$output" == *'batch-id: "nosn08"'* ]]
  [[ "$output" == *'vm-basename: "rhel9"'* ]]
}

# ===============================================================
# Direct DataSource clone (no-snapshot + DataSource)
# ===============================================================

# ---------------------------------------------------------------
# DC-1: Custom DataSource name propagates into each VM's inline DV
# ---------------------------------------------------------------
@test "datasource-clone: custom DataSource name in inline DV" {
  run bash "$VMSPAWN" -n --batch-id=dc0001 --no-snapshot --datasource=fedora \
    --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Skips base DV ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]

  # --- Each VM's DV references fedora DataSource ---
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"kind: DataSource"* ]]
  [[ "$output" == *"name: fedora"* ]]
  [[ "$output" == *"namespace: openshift-virtualization-os-images"* ]]

  # --- No fedora-base PVC ---
  [[ "$output" != *"name: fedora-base"* ]]
}

# ---------------------------------------------------------------
# DC-2: Default DataSource namespace appears in each VM's inline DV
# ---------------------------------------------------------------
@test "datasource-clone: DataSource namespace in inline DV" {
  run bash "$VMSPAWN" -n --batch-id=dc0002 --no-snapshot --datasource=win2k22 \
    --basename=win2k22 --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- DataSource references correct name and default namespace ---
  [[ "$output" == *"name: win2k22"* ]]
  [[ "$output" == *"namespace: openshift-virtualization-os-images"* ]]

  # --- VM basename set to match DataSource ---
  [[ "$output" == *'vm-basename: "win2k22"'* ]]
  [[ "$output" == *"name: win2k22-dc0002-1"* ]]

  # --- No base DV ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
}

# ---------------------------------------------------------------
# DC-3: Custom storage size propagates into inline DV
# ---------------------------------------------------------------
@test "datasource-clone: --storage-size in inline DV" {
  run bash "$VMSPAWN" -n --batch-id=dc0003 --no-snapshot \
    --storage-size=50Gi --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Inline DV has the custom storage size ---
  [[ "$output" == *"storage: 50Gi"* ]]

  # --- Still direct DataSource clone ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
  [[ "$output" == *"sourceRef"* ]]
}

# ---------------------------------------------------------------
# DC-4: Each VM gets a uniquely named DV (not rhel9-base)
# ---------------------------------------------------------------
@test "datasource-clone: per-VM unique DV names" {
  run bash "$VMSPAWN" -n --batch-id=dc0004 --no-snapshot --vms=3 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Each VM's DV has a unique name ---
  [[ "$output" == *"name: rhel9-dc0004-1"* ]]
  [[ "$output" == *"name: rhel9-dc0004-2"* ]]
  [[ "$output" == *"name: rhel9-dc0004-3"* ]]

  # --- No base DV name ---
  [[ "$output" != *"name: rhel9-base"* ]]
}

# ---------------------------------------------------------------
# DC-5: Multiple namespaces — no base PVC per namespace
# ---------------------------------------------------------------
@test "datasource-clone: multi-namespace has no per-namespace base DV" {
  run bash "$VMSPAWN" -n --batch-id=dc0005 --no-snapshot --vms=4 --namespaces=2
  [ "$status" -eq 0 ]

  # --- 2 namespaces ---
  [[ "$output" == *"name: vm-dc0005-ns-1"* ]]
  [[ "$output" == *"name: vm-dc0005-ns-2"* ]]

  # --- No base DV for any namespace ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
  [[ "$output" != *"name: rhel9-base"* ]]

  # --- All 4 VMs created ---
  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 4 ]

  # --- Each VM references the DataSource ---
  # Count sourceRef occurrences (one per VM)
  local ds_count
  ds_count=$(echo "$output" | grep -c "kind: DataSource")
  [ "$ds_count" -eq 4 ]
}

# ---------------------------------------------------------------
# DC-6: URL import + no-snapshot still creates base DV
# ---------------------------------------------------------------
@test "datasource-clone: URL import still creates base DV (not direct clone)" {
  run bash "$VMSPAWN" -n --batch-id=dc0006 --no-snapshot \
    --dv-url=http://example.com/disk.qcow2 --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Base DV IS created (URL import path) ---
  [[ "$output" == *"Creating DataVolumes"* ]]
  [[ "$output" == *"kind: DataVolume"* ]]
  [[ "$output" == *"name: vm-base"* ]]
  [[ "$output" != *"Skipping base DataVolume creation"* ]]

  # --- Snapshot mode shows PVC clone (not DataSource clone) ---
  [[ "$output" == *"Snapshot mode: disabled (direct PVC clone)"* ]]

  # --- VMs clone from base PVC ---
  [[ "$output" == *"pvc:"* ]]
  [[ "$output" == *"name: vm-base"* ]]
}

# ---------------------------------------------------------------
# DC-7: Snapshot mode + DataSource still creates base DV
# ---------------------------------------------------------------
@test "datasource-clone: snapshot mode still creates base DV" {
  run bash "$VMSPAWN" -n --batch-id=dc0007 --snapshot --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Base DV IS created ---
  [[ "$output" == *"Creating DataVolumes"* ]]
  [[ "$output" == *"name: rhel9-base"* ]]
  [[ "$output" != *"Skipping base DataVolume creation"* ]]

  # --- VolumeSnapshot from base DV ---
  [[ "$output" == *"kind: VolumeSnapshot"* ]]
  [[ "$output" == *"persistentVolumeClaimName: rhel9-base"* ]]

  # --- VMs clone from snapshot ---
  [[ "$output" == *"smartCloneFromExistingSnapshot"* ]]
}

# ---------------------------------------------------------------
# DC-8: Access mode applies to inline DV in vm-datasource.yaml
# ---------------------------------------------------------------
@test "datasource-clone: --rwo access mode on inline DV" {
  run bash "$VMSPAWN" -n --batch-id=dc0008 --no-snapshot --rwo --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Access mode in summary ---
  [[ "$output" == *"Access Mode: ReadWriteOnce"* ]]

  # --- RWO in inline DV (no RWX anywhere) ---
  [[ "$output" == *"ReadWriteOnce"* ]]
  [[ "$output" != *"ReadWriteMany"* ]]

  # --- Still direct DataSource clone ---
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"kind: DataSource"* ]]
}

# ---------------------------------------------------------------
# DC-9: Live-mode completion message (mock oc)
# ---------------------------------------------------------------
@test "datasource-clone: live-mode summary says no base DVs" {
  local mock_dir
  mock_dir=$(mktemp -d)
  _create_mock_oc "$mock_dir"

  export MOCK_ACCESS_MODE=ReadWriteOnce
  export PATH="$mock_dir:$PATH"

  run bash "$VMSPAWN" --batch-id=dc0009 --storage-class=lvms-nvme-sc \
    --no-snapshot --vms=2 --namespaces=1

  rm -rf "$mock_dir"
  rm -f logs/dc0009-*.log logs/batch-dc0009.manifest

  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
  [[ "$output" == *"direct DataSource clone, no base DVs"* ]]
  [[ "$output" == *"Resource creation completed successfully"* ]]
}

# ---------------------------------------------------------------
# DC-10: --stop with direct DataSource clone
# ---------------------------------------------------------------
@test "datasource-clone: --stop sets Halted runStrategy" {
  run bash "$VMSPAWN" -n --batch-id=dc0010 --no-snapshot --stop --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"runStrategy: Halted"* ]]
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"kind: DataSource"* ]]
}

# ===============================================================
# Auto-detection: --storage-class without --snapshot-class
# ===============================================================

# ---------------------------------------------------------------
# AD-1: custom storage class auto-disables snapshots
# ---------------------------------------------------------------
@test "auto-detect: custom storage-class without snapshot-class disables snapshots" {
  run bash "$VMSPAWN" -n --batch-id=auto01 --storage-class=my-nfs-sc --vms=3 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Auto-detected no-snapshot mode ---
  [[ "$output" == *"Snapshot mode: disabled (direct DataSource clone)"* ]]
  [[ "$output" == *"Skipping VolumeSnapshots"* ]]

  # --- No VolumeSnapshot YAML emitted ---
  [[ "$output" != *"kind: VolumeSnapshot"* ]]
  [[ "$output" != *"volumeSnapshotClassName"* ]]

  # --- No base DV (direct DataSource clone) ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]

  # --- Storage class applied to resources ---
  [[ "$output" == *"storageClassName: my-nfs-sc"* ]]
  [[ "$output" == *"Storage Class: my-nfs-sc"* ]]

  # --- VMs use DataSource clone ---
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"kind: DataSource"* ]]
  [[ "$output" != *"smartCloneFromExistingSnapshot"* ]]

  # --- 3 VMs still created ---
  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 3 ]
}

# ---------------------------------------------------------------
# AD-2: custom storage-class + snapshot-class keeps snapshots
# ---------------------------------------------------------------
@test "auto-detect: custom storage-class with snapshot-class keeps snapshots enabled" {
  run bash "$VMSPAWN" -n --batch-id=auto02 --storage-class=my-rbd-sc \
    --snapshot-class=my-rbd-snap --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Snapshot mode enabled ---
  [[ "$output" == *"Snapshot mode: enabled"* ]]
  [[ "$output" == *"Creating VolumeSnapshots"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]

  # --- Uses the provided snapshot class ---
  [[ "$output" == *"volumeSnapshotClassName: my-rbd-snap"* ]]

  # --- Uses the provided storage class ---
  [[ "$output" == *"storageClassName: my-rbd-sc"* ]]

  # --- VMs clone from snapshot ---
  [[ "$output" == *"smartCloneFromExistingSnapshot"* ]]
}

# ---------------------------------------------------------------
# AD-3: custom storage-class + explicit --snapshot overrides
# ---------------------------------------------------------------
@test "auto-detect: custom storage-class with explicit --snapshot keeps snapshots" {
  run bash "$VMSPAWN" -n --batch-id=auto03 --storage-class=my-ceph-sc \
    --snapshot --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Snapshot mode enabled (explicit override) ---
  [[ "$output" == *"Snapshot mode: enabled"* ]]
  [[ "$output" == *"Creating VolumeSnapshots"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]

  # --- Storage class applied ---
  [[ "$output" == *"storageClassName: my-ceph-sc"* ]]
}

# ---------------------------------------------------------------
# AD-4: default storage class (no --storage-class flag) keeps snapshots
# ---------------------------------------------------------------
@test "auto-detect: default storage class keeps snapshots enabled" {
  run bash "$VMSPAWN" -n --batch-id=auto04 --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Snapshot mode enabled (default) ---
  [[ "$output" == *"Snapshot mode: enabled"* ]]
  [[ "$output" == *"Creating VolumeSnapshots"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]
  [[ "$output" == *"smartCloneFromExistingSnapshot"* ]]
}

# ===============================================================
# Access mode options (--access-mode, --rwo, --rwx)
# ===============================================================

# ---------------------------------------------------------------
# AM-1: default access mode is ReadWriteMany
# ---------------------------------------------------------------
@test "access-mode: default is ReadWriteMany" {
  run bash "$VMSPAWN" -n --batch-id=am0001 --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"Access Mode: ReadWriteMany"* ]]
  [[ "$output" == *"ReadWriteMany"* ]]
}

# ---------------------------------------------------------------
# AM-2: --rwo shortcut sets ReadWriteOnce on all resources
# ---------------------------------------------------------------
@test "access-mode: --rwo sets ReadWriteOnce on DV and VM" {
  run bash "$VMSPAWN" -n --batch-id=am0002 --rwo --no-snapshot --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"Access Mode: ReadWriteOnce"* ]]
  [[ "$output" == *"ReadWriteOnce"* ]]
  [[ "$output" != *"ReadWriteMany"* ]]
}

# ---------------------------------------------------------------
# AM-3: --access-mode=ReadWriteOnce
# ---------------------------------------------------------------
@test "access-mode: --access-mode=ReadWriteOnce" {
  run bash "$VMSPAWN" -n --batch-id=am0003 --access-mode=ReadWriteOnce --no-snapshot --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"Access Mode: ReadWriteOnce"* ]]
  [[ "$output" == *"ReadWriteOnce"* ]]
  [[ "$output" != *"ReadWriteMany"* ]]
}

# ---------------------------------------------------------------
# AM-4: --rwx shortcut sets ReadWriteMany
# ---------------------------------------------------------------
@test "access-mode: --rwx sets ReadWriteMany" {
  run bash "$VMSPAWN" -n --batch-id=am0004 --rwx --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"Access Mode: ReadWriteMany"* ]]
  [[ "$output" == *"ReadWriteMany"* ]]
}

# ---------------------------------------------------------------
# AM-5: --rwo with snapshot mode (VMs also get RWO)
# ---------------------------------------------------------------
@test "access-mode: --rwo applies to snapshot-based VMs too" {
  run bash "$VMSPAWN" -n --batch-id=am0005 --rwo --snapshot --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"Access Mode: ReadWriteOnce"* ]]
  [[ "$output" == *"ReadWriteOnce"* ]]
  [[ "$output" != *"ReadWriteMany"* ]]
}

# ---------------------------------------------------------------
# AM-6: --rwo with URL import mode
# ---------------------------------------------------------------
@test "access-mode: --rwo with URL import" {
  run bash "$VMSPAWN" -n --batch-id=am0006 --rwo --no-snapshot --vms=1 --namespaces=1 \
    --dv-url=http://example.com/disk.qcow2
  [ "$status" -eq 0 ]

  [[ "$output" == *"Access Mode: ReadWriteOnce"* ]]
  [[ "$output" == *"ReadWriteOnce"* ]]
  [[ "$output" != *"ReadWriteMany"* ]]
}

# ===============================================================
# StorageProfile auto-detection (live mode with mock oc)
# ===============================================================

# Helper: create a mock oc script that satisfies all prerequisite
# checks and returns MOCK_ACCESS_MODE for StorageProfile queries.
# Usage: _create_mock_oc <directory>
_create_mock_oc() {
    local dir=$1
    mkdir -p "$dir"
    cat > "$dir/oc" << 'MOCKEOF'
#!/bin/bash
case "$1" in
    whoami) echo "test-user" ;;
    get)
        case "$2" in
            storageprofile)
                if [[ -n "${MOCK_ACCESS_MODE:-}" ]]; then
                    echo "$MOCK_ACCESS_MODE"
                else
                    exit 1
                fi
                ;;
            storageclass)
                # Return binding mode when -o jsonpath is used
                if [[ "$*" == *"volumeBindingMode"* && -n "${MOCK_BIND_MODE:-}" ]]; then
                    echo "$MOCK_BIND_MODE"
                fi
                ;;
            datavolume) echo "Succeeded" ;;
            volumesnapshot) echo "true" ;;
            *) ;;
        esac
        ;;
    apply) cat > /dev/null ;;
    *) ;;
esac
MOCKEOF
    chmod +x "$dir/oc"
}

# ---------------------------------------------------------------
# SP-1: StorageProfile returns RWO (e.g. LVMS)
# ---------------------------------------------------------------
@test "auto-detect: StorageProfile returns RWO for LVMS-like storage" {
  local mock_dir
  mock_dir=$(mktemp -d)
  _create_mock_oc "$mock_dir"

  export MOCK_ACCESS_MODE=ReadWriteOnce
  export PATH="$mock_dir:$PATH"

  run bash "$VMSPAWN" --batch-id=sp0001 --storage-class=lvms-nvme-sc \
    --no-snapshot --vms=1 --namespaces=1

  rm -rf "$mock_dir"
  rm -f logs/sp0001-*.log logs/batch-sp0001.manifest

  [ "$status" -eq 0 ]
  [[ "$output" == *"Auto-detected access mode 'ReadWriteOnce' from StorageProfile for 'lvms-nvme-sc'"* ]]
  [[ "$output" == *"Access Mode: ReadWriteOnce"* ]]
}

# ---------------------------------------------------------------
# SP-2: StorageProfile returns RWX (e.g. OCS/Ceph)
# ---------------------------------------------------------------
@test "auto-detect: StorageProfile returns RWX for OCS-like storage" {
  local mock_dir
  mock_dir=$(mktemp -d)
  _create_mock_oc "$mock_dir"

  export MOCK_ACCESS_MODE=ReadWriteMany
  export PATH="$mock_dir:$PATH"

  run bash "$VMSPAWN" --batch-id=sp0002 --storage-class=ocs-rbd-virt \
    --no-snapshot --vms=1 --namespaces=1

  rm -rf "$mock_dir"
  rm -f logs/sp0002-*.log logs/batch-sp0002.manifest

  [ "$status" -eq 0 ]
  [[ "$output" == *"Auto-detected access mode 'ReadWriteMany' from StorageProfile for 'ocs-rbd-virt'"* ]]
  [[ "$output" == *"Access Mode: ReadWriteMany"* ]]
}

# ---------------------------------------------------------------
# SP-3: StorageProfile unavailable → falls back to default RWX
# ---------------------------------------------------------------
@test "auto-detect: StorageProfile unavailable falls back to default RWX" {
  local mock_dir
  mock_dir=$(mktemp -d)
  _create_mock_oc "$mock_dir"

  # Do NOT export MOCK_ACCESS_MODE → mock exits 1 for storageprofile
  unset MOCK_ACCESS_MODE
  export PATH="$mock_dir:$PATH"

  run bash "$VMSPAWN" --batch-id=sp0003 --storage-class=unknown-sc \
    --no-snapshot --vms=1 --namespaces=1

  rm -rf "$mock_dir"
  rm -f logs/sp0003-*.log logs/batch-sp0003.manifest

  [ "$status" -eq 0 ]
  [[ "$output" == *"Could not detect access mode from StorageProfile"* ]]
  [[ "$output" == *"using default: ReadWriteMany"* ]]
  [[ "$output" == *"Access Mode: ReadWriteMany"* ]]
}

# ---------------------------------------------------------------
# SP-4: explicit --rwo overrides StorageProfile that says RWX
# ---------------------------------------------------------------
@test "auto-detect: explicit --rwo overrides StorageProfile RWX" {
  local mock_dir
  mock_dir=$(mktemp -d)
  _create_mock_oc "$mock_dir"

  export MOCK_ACCESS_MODE=ReadWriteMany
  export PATH="$mock_dir:$PATH"

  run bash "$VMSPAWN" --batch-id=sp0004 --rwo --storage-class=ocs-rbd-virt \
    --no-snapshot --vms=1 --namespaces=1

  rm -rf "$mock_dir"
  rm -f logs/sp0004-*.log logs/batch-sp0004.manifest

  [ "$status" -eq 0 ]
  [[ "$output" == *"Access mode explicitly set to: ReadWriteOnce"* ]]
  [[ "$output" == *"Access Mode: ReadWriteOnce"* ]]
  [[ "$output" != *"Auto-detected"* ]]
}

# ---------------------------------------------------------------
# SP-5: explicit --rwx overrides StorageProfile that says RWO
# ---------------------------------------------------------------
@test "auto-detect: explicit --rwx overrides StorageProfile RWO" {
  local mock_dir
  mock_dir=$(mktemp -d)
  _create_mock_oc "$mock_dir"

  export MOCK_ACCESS_MODE=ReadWriteOnce
  export PATH="$mock_dir:$PATH"

  run bash "$VMSPAWN" --batch-id=sp0005 --rwx --storage-class=lvms-nvme-sc \
    --no-snapshot --vms=1 --namespaces=1

  rm -rf "$mock_dir"
  rm -f logs/sp0005-*.log logs/batch-sp0005.manifest

  [ "$status" -eq 0 ]
  [[ "$output" == *"Access mode explicitly set to: ReadWriteMany"* ]]
  [[ "$output" == *"Access Mode: ReadWriteMany"* ]]
  [[ "$output" != *"Auto-detected"* ]]
}

# ===============================================================
# WaitForFirstConsumer handling
# ===============================================================

# ---------------------------------------------------------------
# WFFC-1: WFFC + DataSource + no-snapshot → no base DV at all
# ---------------------------------------------------------------
@test "wffc: DataSource no-snapshot skips base DV entirely for WFFC" {
  local mock_dir
  mock_dir=$(mktemp -d)
  _create_mock_oc "$mock_dir"

  export MOCK_ACCESS_MODE=ReadWriteOnce
  export MOCK_BIND_MODE=WaitForFirstConsumer
  export PATH="$mock_dir:$PATH"

  run bash "$VMSPAWN" --batch-id=wf0001 --storage-class=lvms-nvme-sc \
    --no-snapshot --vms=2 --namespaces=1

  rm -rf "$mock_dir"
  rm -f logs/wf0001-*.log logs/batch-wf0001.manifest

  [ "$status" -eq 0 ]
  [[ "$output" == *"WaitForFirstConsumer"* ]]
  # No base DV created — each VM clones directly from DataSource
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
  [[ "$output" == *"Creating VirtualMachines"* ]]
  [[ "$output" == *"Resource creation completed successfully"* ]]
}

# ---------------------------------------------------------------
# WFFC-2: WFFC + URL import → skip DV wait, proceed to VM creation
# ---------------------------------------------------------------
@test "wffc: skips DataVolume wait for WaitForFirstConsumer with URL import" {
  local mock_dir
  mock_dir=$(mktemp -d)
  _create_mock_oc "$mock_dir"

  export MOCK_ACCESS_MODE=ReadWriteOnce
  export MOCK_BIND_MODE=WaitForFirstConsumer
  export PATH="$mock_dir:$PATH"

  run bash "$VMSPAWN" --batch-id=wf0002 --storage-class=lvms-nvme-sc \
    --no-snapshot --vms=2 --namespaces=1 \
    --dv-url=http://example.com/disk.qcow2

  rm -rf "$mock_dir"
  rm -f logs/wf0002-*.log logs/batch-wf0002.manifest

  [ "$status" -eq 0 ]
  [[ "$output" == *"WaitForFirstConsumer"* ]]
  [[ "$output" == *"Skipping DataVolume wait"* ]]
  [[ "$output" == *"VMs will trigger PVC binding"* ]]
  # VMs were still created despite DV wait being skipped
  [[ "$output" == *"Creating VirtualMachines"* ]]
  [[ "$output" == *"Resource creation completed successfully"* ]]
}

# ---------------------------------------------------------------
# WFFC-3: Immediate binding + URL import → normal DV wait (no skip)
# ---------------------------------------------------------------
@test "wffc: normal DV wait for Immediate binding with URL import" {
  local mock_dir
  mock_dir=$(mktemp -d)
  _create_mock_oc "$mock_dir"

  export MOCK_ACCESS_MODE=ReadWriteOnce
  export MOCK_BIND_MODE=Immediate
  export PATH="$mock_dir:$PATH"

  run bash "$VMSPAWN" --batch-id=wf0003 --storage-class=lvms-nvme-sc-imm \
    --no-snapshot --vms=1 --namespaces=1 \
    --dv-url=http://example.com/disk.qcow2

  rm -rf "$mock_dir"
  rm -f logs/wf0003-*.log logs/batch-wf0003.manifest

  [ "$status" -eq 0 ]
  [[ "$output" != *"Skipping DataVolume wait"* ]]
  [[ "$output" == *"All DataVolumes are completed successfully"* ]]
  [[ "$output" == *"Creating VirtualMachines"* ]]
}

# ---------------------------------------------------------------
# WFFC-4: WFFC + explicit --snapshot → auto-disables snapshots
# ---------------------------------------------------------------
@test "wffc: snapshot mode auto-disabled for WFFC storage" {
  local mock_dir
  mock_dir=$(mktemp -d)
  _create_mock_oc "$mock_dir"

  export MOCK_ACCESS_MODE=ReadWriteOnce
  export MOCK_BIND_MODE=WaitForFirstConsumer
  export PATH="$mock_dir:$PATH"

  run bash "$VMSPAWN" --batch-id=wf0004 --storage-class=lvms-nvme-sc \
    --snapshot --vms=2 --namespaces=1

  rm -rf "$mock_dir"
  rm -f logs/wf0004-*.log logs/batch-wf0004.manifest

  [ "$status" -eq 0 ]
  # Snapshot mode was auto-disabled
  [[ "$output" == *"Disabling snapshot mode"* ]]
  [[ "$output" == *"WFFC storage won't bind"* ]]
  [[ "$output" == *"Falling back to direct DataSource clone"* ]]
  # No VolumeSnapshot created
  [[ "$output" != *"Creating VolumeSnapshots"* ]]
  # Direct DataSource clone used instead
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
  [[ "$output" == *"Creating VirtualMachines"* ]]
  [[ "$output" == *"Resource creation completed successfully"* ]]
}

# ---------------------------------------------------------------
# WFFC-5: WFFC detection works in dry-run
# ---------------------------------------------------------------
@test "wffc: dry-run shows WFFC warning when oc is available" {
  local mock_dir
  mock_dir=$(mktemp -d)
  _create_mock_oc "$mock_dir"

  export MOCK_ACCESS_MODE=ReadWriteOnce
  export MOCK_BIND_MODE=WaitForFirstConsumer
  export PATH="$mock_dir:$PATH"

  run bash "$VMSPAWN" -n --batch-id=wf0004 --storage-class=lvms-nvme-sc \
    --no-snapshot --vms=1 --namespaces=1

  rm -rf "$mock_dir"
  rm -f logs/wf0004-dryrun.yaml

  [ "$status" -eq 0 ]
  [[ "$output" == *"WaitForFirstConsumer"* ]]
  [[ "$output" == *"Access Mode: ReadWriteOnce"* ]]
}

# ===============================================================
# Missing option coverage
# ===============================================================

# ---------------------------------------------------------------
# OPT-1: --pvc-base-name sets the VolumeSnapshot PVC source name
# ---------------------------------------------------------------
@test "option: --pvc-base-name changes VolumeSnapshot PVC source" {
  run bash "$VMSPAWN" -n --batch-id=opt001 --pvc-base-name=custom-base \
    --snapshot --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- VolumeSnapshot references the custom PVC name ---
  [[ "$output" == *"persistentVolumeClaimName: custom-base"* ]]

  # --- Default name should not appear ---
  [[ "$output" != *"persistentVolumeClaimName: rhel9-base"* ]]
}

# ---------------------------------------------------------------
# OPT-2: --request-cpu sets CPU request in VM spec
# ---------------------------------------------------------------
@test "option: --request-cpu adds CPU request to VM spec" {
  run bash "$VMSPAWN" -n --batch-id=opt002 --request-cpu=500m --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- resources.requests.cpu appears in VM spec ---
  [[ "$output" == *"resources:"* ]]
  [[ "$output" == *"requests:"* ]]
  [[ "$output" == *"cpu: 500m"* ]]
}

# ---------------------------------------------------------------
# OPT-3: --request-memory sets memory request in VM spec
# ---------------------------------------------------------------
@test "option: --request-memory adds memory request to VM spec" {
  run bash "$VMSPAWN" -n --batch-id=opt003 --request-memory=512Mi --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- resources.requests.memory appears in VM spec ---
  [[ "$output" == *"resources:"* ]]
  [[ "$output" == *"requests:"* ]]
  [[ "$output" == *"memory: 512Mi"* ]]
}

# ---------------------------------------------------------------
# OPT-4: --request-cpu and --request-memory together
# ---------------------------------------------------------------
@test "option: --request-cpu and --request-memory together" {
  run bash "$VMSPAWN" -n --batch-id=opt004 --request-cpu=2 --request-memory=4Gi \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Both CPU and memory requests present ---
  [[ "$output" == *"resources:"* ]]
  [[ "$output" == *"requests:"* ]]
  [[ "$output" == *"cpu: 2"* ]]
  [[ "$output" == *"memory: 4Gi"* ]]
}

# ---------------------------------------------------------------
# OPT-5: --vms-per-namespace calculates total VMs correctly
# ---------------------------------------------------------------
@test "option: --vms-per-namespace calculates total VMs" {
  run bash "$VMSPAWN" -n --batch-id=opt005 --vms-per-namespace=3 --namespaces=2
  [ "$status" -eq 0 ]

  # --- Total VMs = 3 * 2 = 6 ---
  [[ "$output" == *"Total VMs: 6"* ]]

  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 6 ]

  # --- 3 per namespace ---
  local ns1_count ns2_count
  ns1_count=$(echo "$output" | grep -c "Creating VirtualMachine.*for namespace: vm-opt005-ns-1")
  ns2_count=$(echo "$output" | grep -c "Creating VirtualMachine.*for namespace: vm-opt005-ns-2")
  [ "$ns1_count" -eq 3 ]
  [ "$ns2_count" -eq 3 ]
}

# ---------------------------------------------------------------
# OPT-6: --run-strategy sets custom run strategy
# ---------------------------------------------------------------
@test "option: --run-strategy sets custom run strategy" {
  run bash "$VMSPAWN" -n --batch-id=opt006 --run-strategy=RerunOnFailure \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"runStrategy: RerunOnFailure"* ]]
}

# ---------------------------------------------------------------
# OPT-7: --start sets runStrategy to Always
# ---------------------------------------------------------------
@test "option: --start sets runStrategy to Always" {
  run bash "$VMSPAWN" -n --batch-id=opt007 --start --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"runStrategy: Always"* ]]
}

# ---------------------------------------------------------------
# OPT-8: --wait is accepted (dry-run does not actually wait)
# ---------------------------------------------------------------
@test "option: --wait is accepted without error" {
  run bash "$VMSPAWN" -n --batch-id=opt008 --wait --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Dry-run succeeds; --wait doesn't affect YAML output ---
  [[ "$output" == *"kind: VirtualMachine"* ]]
}

# ---------------------------------------------------------------
# OPT-9: --nowait is accepted (dry-run does not wait by default)
# ---------------------------------------------------------------
@test "option: --nowait is accepted without error" {
  run bash "$VMSPAWN" -n --batch-id=opt009 --nowait --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"kind: VirtualMachine"* ]]
}

# ---------------------------------------------------------------
# OPT-10: --create-existing-vm is accepted
# ---------------------------------------------------------------
@test "option: --create-existing-vm is accepted without error" {
  run bash "$VMSPAWN" -n --batch-id=opt010 --create-existing-vm --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"kind: VirtualMachine"* ]]
}

# ---------------------------------------------------------------
# OPT-11: --no-create-existing-vm is accepted
# ---------------------------------------------------------------
@test "option: --no-create-existing-vm is accepted without error" {
  run bash "$VMSPAWN" -n --batch-id=opt011 --no-create-existing-vm --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"kind: VirtualMachine"* ]]
}

# ---------------------------------------------------------------
# OPT-12: -h shows usage/help text
# ---------------------------------------------------------------
@test "option: -h displays help text" {
  run bash "$VMSPAWN" -h
  [ "$status" -eq 1 ]

  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"options:"* ]]
  [[ "$output" == *"--vms=N"* ]]
  [[ "$output" == *"--namespaces=N"* ]]
}

# ---------------------------------------------------------------
# OPT-13: positional arguments set VMs and namespaces
# ---------------------------------------------------------------
@test "option: positional arguments set VMs and namespaces" {
  run bash "$VMSPAWN" -n --batch-id=opt013 8 3
  [ "$status" -eq 0 ]

  # --- 8 VMs across 3 namespaces ---
  [[ "$output" == *"Total VMs: 8"* ]]
  [[ "$output" == *"Namespaces: 3"* ]]

  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 8 ]

  # --- 3 namespaces created ---
  [[ "$output" == *"name: vm-opt013-ns-1"* ]]
  [[ "$output" == *"name: vm-opt013-ns-2"* ]]
  [[ "$output" == *"name: vm-opt013-ns-3"* ]]
  [[ "$output" != *"vm-opt013-ns-4"* ]]
}

# ===============================================================
# Category 1: Clone Path x Storage Options (combos 1-9)
# ===============================================================

# ---------------------------------------------------------------
# COMBO-1: --storage-class + --rwo + --no-snapshot
# ---------------------------------------------------------------
@test "combo: storage-class + rwo + no-snapshot on DataSource clone" {
  run bash "$VMSPAWN" -n --batch-id=cmb001 --storage-class=my-sc --rwo \
    --no-snapshot --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Custom storage class applied ---
  [[ "$output" == *"storageClassName: my-sc"* ]]
  [[ "$output" == *"Storage Class: my-sc"* ]]

  # --- RWO access mode ---
  [[ "$output" == *"Access Mode: ReadWriteOnce"* ]]
  [[ "$output" == *"ReadWriteOnce"* ]]
  [[ "$output" != *"ReadWriteMany"* ]]

  # --- No-snapshot DataSource clone ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"kind: DataSource"* ]]
  [[ "$output" != *"kind: VolumeSnapshot"* ]]
}

# ---------------------------------------------------------------
# COMBO-2: --storage-class + --snapshot-class + --rwo
# ---------------------------------------------------------------
@test "combo: storage-class + snapshot-class + rwo in snapshot path" {
  run bash "$VMSPAWN" -n --batch-id=cmb002 --storage-class=my-rbd \
    --snapshot-class=my-snap --rwo --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Custom storage class ---
  [[ "$output" == *"storageClassName: my-rbd"* ]]

  # --- Custom snapshot class ---
  [[ "$output" == *"volumeSnapshotClassName: my-snap"* ]]

  # --- RWO access mode ---
  [[ "$output" == *"Access Mode: ReadWriteOnce"* ]]
  [[ "$output" == *"ReadWriteOnce"* ]]
  [[ "$output" != *"ReadWriteMany"* ]]

  # --- Snapshot mode enabled ---
  [[ "$output" == *"Snapshot mode: enabled"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]
  [[ "$output" == *"smartCloneFromExistingSnapshot"* ]]
}

# ---------------------------------------------------------------
# COMBO-3: --storage-class + --rwo + --dv-url
# ---------------------------------------------------------------
@test "combo: storage-class + rwo + dv-url on URL import path" {
  run bash "$VMSPAWN" -n --batch-id=cmb003 --storage-class=my-sc --rwo \
    --dv-url=http://example.com/disk.qcow2 --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Custom storage class on base DV and VM ---
  [[ "$output" == *"storageClassName: my-sc"* ]]

  # --- RWO access mode ---
  [[ "$output" == *"Access Mode: ReadWriteOnce"* ]]
  [[ "$output" == *"ReadWriteOnce"* ]]
  [[ "$output" != *"ReadWriteMany"* ]]

  # --- URL import DV ---
  [[ "$output" == *"http://example.com/disk.qcow2"* ]]
  [[ "$output" == *"kind: DataVolume"* ]]
}

# ---------------------------------------------------------------
# COMBO-4: --storage-class + --storage-size + --dv-url
# ---------------------------------------------------------------
@test "combo: storage-class + storage-size + dv-url" {
  run bash "$VMSPAWN" -n --batch-id=cmb004 --storage-class=my-sc \
    --storage-size=50Gi --dv-url=http://example.com/disk.qcow2 \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Custom storage class ---
  [[ "$output" == *"storageClassName: my-sc"* ]]

  # --- Custom size on base DV ---
  [[ "$output" == *"storage: 50Gi"* ]]

  # --- URL import ---
  [[ "$output" == *"http://example.com/disk.qcow2"* ]]
}

# ---------------------------------------------------------------
# COMBO-5: --storage-size + --no-snapshot
# ---------------------------------------------------------------
@test "combo: storage-size + no-snapshot on DataSource inline DV" {
  run bash "$VMSPAWN" -n --batch-id=cmb005 --storage-size=50Gi \
    --no-snapshot --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Custom size in inline DV ---
  [[ "$output" == *"storage: 50Gi"* ]]

  # --- No base DV ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]

  # --- DataSource clone ---
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"kind: DataSource"* ]]
}

# ---------------------------------------------------------------
# COMBO-6: --storage-size + --snapshot
# ---------------------------------------------------------------
@test "combo: storage-size + snapshot on base DV and snapshot flow" {
  run bash "$VMSPAWN" -n --batch-id=cmb006 --storage-size=50Gi \
    --snapshot --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Custom size on base DV ---
  [[ "$output" == *"storage: 50Gi"* ]]

  # --- Snapshot flow ---
  [[ "$output" == *"Snapshot mode: enabled"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]
  [[ "$output" == *"Creating DataVolumes"* ]]
}

# ---------------------------------------------------------------
# COMBO-7: --rwx + --dv-url + --snapshot
# ---------------------------------------------------------------
@test "combo: rwx + dv-url + snapshot" {
  run bash "$VMSPAWN" -n --batch-id=cmb007 --rwx \
    --dv-url=http://example.com/disk.qcow2 --snapshot --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- RWX access mode ---
  [[ "$output" == *"Access Mode: ReadWriteMany"* ]]
  [[ "$output" == *"ReadWriteMany"* ]]

  # --- URL import with snapshots ---
  [[ "$output" == *"http://example.com/disk.qcow2"* ]]
  [[ "$output" == *"Snapshot mode: enabled"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]
  [[ "$output" == *"smartCloneFromExistingSnapshot"* ]]
}

# ---------------------------------------------------------------
# COMBO-8: --rwo + --storage-class + --no-snapshot + --storage-size
# ---------------------------------------------------------------
@test "combo: all storage options on DataSource clone path" {
  run bash "$VMSPAWN" -n --batch-id=cmb008 --rwo --storage-class=my-sc \
    --no-snapshot --storage-size=50Gi --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- All storage options applied ---
  [[ "$output" == *"storageClassName: my-sc"* ]]
  [[ "$output" == *"ReadWriteOnce"* ]]
  [[ "$output" == *"storage: 50Gi"* ]]
  [[ "$output" != *"ReadWriteMany"* ]]

  # --- DataSource direct clone ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
  [[ "$output" == *"sourceRef"* ]]
}

# ---------------------------------------------------------------
# COMBO-9: --access-mode=ReadWriteOnce + --storage-class + --snapshot-class
# ---------------------------------------------------------------
@test "combo: long-form access-mode + storage-class + snapshot-class" {
  run bash "$VMSPAWN" -n --batch-id=cmb009 --access-mode=ReadWriteOnce \
    --storage-class=my-rbd --snapshot-class=my-snap --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Long-form access mode ---
  [[ "$output" == *"Access Mode: ReadWriteOnce"* ]]
  [[ "$output" == *"ReadWriteOnce"* ]]
  [[ "$output" != *"ReadWriteMany"* ]]

  # --- Custom classes ---
  [[ "$output" == *"storageClassName: my-rbd"* ]]
  [[ "$output" == *"volumeSnapshotClassName: my-snap"* ]]

  # --- Snapshot mode enabled ---
  [[ "$output" == *"Snapshot mode: enabled"* ]]
}

# ===============================================================
# Category 2: Clone Path x Cloud-init (combos 10-14)
# ===============================================================

# ---------------------------------------------------------------
# COMBO-10: --dv-url + --snapshot + --cloudinit
# ---------------------------------------------------------------
@test "combo: dv-url + snapshot + custom cloudinit" {
  run bash "$VMSPAWN" -n --batch-id=cmb010 \
    --dv-url=http://example.com/disk.qcow2 --snapshot \
    --cloudinit=helpers/cloudinit-stress-workload.yaml --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- URL import ---
  [[ "$output" == *"http://example.com/disk.qcow2"* ]]

  # --- Snapshot mode ---
  [[ "$output" == *"kind: VolumeSnapshot"* ]]
  [[ "$output" == *"smartCloneFromExistingSnapshot"* ]]

  # --- Custom cloud-init Secret ---
  [[ "$output" == *"kind: Secret"* ]]
  [[ "$output" == *"cloudInitNoCloud"* ]]
  [[ "$output" == *"secretRef"* ]]

  # --- NOT auto-applied ---
  [[ "$output" != *"applying default cloud-init"* ]]
}

# ---------------------------------------------------------------
# COMBO-11: --dv-url + --no-snapshot + --cloudinit
# ---------------------------------------------------------------
@test "combo: dv-url + no-snapshot + custom cloudinit" {
  run bash "$VMSPAWN" -n --batch-id=cmb011 \
    --dv-url=http://example.com/disk.qcow2 --no-snapshot \
    --cloudinit=helpers/cloudinit-stress-workload.yaml --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- URL import with PVC clone ---
  [[ "$output" == *"http://example.com/disk.qcow2"* ]]
  [[ "$output" == *"pvc:"* ]]
  [[ "$output" != *"kind: VolumeSnapshot"* ]]

  # --- Cloud-init Secret ---
  [[ "$output" == *"kind: Secret"* ]]
  [[ "$output" == *"cloudInitNoCloud"* ]]
  [[ "$output" == *"secretRef"* ]]

  # --- NOT auto-applied (URL mode) ---
  [[ "$output" != *"applying default cloud-init"* ]]
}

# ---------------------------------------------------------------
# COMBO-12: --no-snapshot + --cloudinit + --namespaces=3
# ---------------------------------------------------------------
@test "combo: no-snapshot + cloudinit + 3 namespaces (Secret per ns)" {
  run bash "$VMSPAWN" -n --batch-id=cmb012 --no-snapshot \
    --cloudinit=helpers/cloudinit-stress-workload.yaml \
    --vms=6 --namespaces=3
  [ "$status" -eq 0 ]

  # --- 3 namespaces ---
  [[ "$output" == *"name: vm-cmb012-ns-1"* ]]
  [[ "$output" == *"name: vm-cmb012-ns-2"* ]]
  [[ "$output" == *"name: vm-cmb012-ns-3"* ]]

  # --- 3 Secrets (one per namespace) ---
  local secret_count
  secret_count=$(echo "$output" | grep -c "kind: Secret")
  [ "$secret_count" -eq 3 ]

  # --- DataSource clone ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
  [[ "$output" == *"sourceRef"* ]]
}

# ---------------------------------------------------------------
# COMBO-13: --dv-url + --snapshot (no --cloudinit) → no auto cloud-init
# ---------------------------------------------------------------
@test "combo: dv-url + snapshot without cloudinit has no auto cloud-init" {
  run bash "$VMSPAWN" -n --batch-id=cmb013 \
    --dv-url=http://example.com/disk.qcow2 --snapshot \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- URL + snapshot mode ---
  [[ "$output" == *"http://example.com/disk.qcow2"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]

  # --- No cloud-init ---
  [[ "$output" != *"applying default cloud-init"* ]]
  [[ "$output" != *"kind: Secret"* ]]
  [[ "$output" != *"cloudInitNoCloud"* ]]
}

# ---------------------------------------------------------------
# COMBO-14: --no-snapshot + --basename=fedora + --cloudinit
# ---------------------------------------------------------------
@test "combo: no-snapshot + custom basename + cloudinit" {
  run bash "$VMSPAWN" -n --batch-id=cmb014 --no-snapshot --basename=fedora \
    --cloudinit=helpers/cloudinit-stress-workload.yaml --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Custom basename in Secret name ---
  [[ "$output" == *"name: fedora-cloudinit"* ]]

  # --- Custom basename in VM name ---
  [[ "$output" == *"name: fedora-cmb014-1"* ]]

  # --- DataSource clone ---
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"kind: DataSource"* ]]

  # --- Cloud-init ---
  [[ "$output" == *"kind: Secret"* ]]
  [[ "$output" == *"cloudInitNoCloud"* ]]
  [[ "$output" == *"secretRef"* ]]
}

# ===============================================================
# Category 3: Clone Path x VM Resource Requests (combos 15-18)
# ===============================================================

# ---------------------------------------------------------------
# COMBO-15: --request-cpu + --request-memory + --snapshot
# ---------------------------------------------------------------
@test "combo: request-cpu + request-memory in snapshot path" {
  run bash "$VMSPAWN" -n --batch-id=cmb015 --request-cpu=2 --request-memory=4Gi \
    --snapshot --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Resource requests in vm-snap.yaml output ---
  [[ "$output" == *"resources:"* ]]
  [[ "$output" == *"requests:"* ]]
  [[ "$output" == *"cpu: 2"* ]]
  [[ "$output" == *"memory: 4Gi"* ]]

  # --- Snapshot mode ---
  [[ "$output" == *"smartCloneFromExistingSnapshot"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]
}

# ---------------------------------------------------------------
# COMBO-16: --request-cpu + --request-memory + --dv-url + --no-snapshot
# ---------------------------------------------------------------
@test "combo: request-cpu + request-memory in URL PVC clone path" {
  run bash "$VMSPAWN" -n --batch-id=cmb016 --request-cpu=2 --request-memory=4Gi \
    --dv-url=http://example.com/disk.qcow2 --no-snapshot --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Resource requests in vm-clone.yaml output ---
  [[ "$output" == *"resources:"* ]]
  [[ "$output" == *"requests:"* ]]
  [[ "$output" == *"cpu: 2"* ]]
  [[ "$output" == *"memory: 4Gi"* ]]

  # --- URL PVC clone ---
  [[ "$output" == *"http://example.com/disk.qcow2"* ]]
  [[ "$output" == *"pvc:"* ]]
}

# ---------------------------------------------------------------
# COMBO-17: --cores + --memory + --request-cpu + --request-memory (snapshot)
# ---------------------------------------------------------------
@test "combo: cores + memory + request-cpu + request-memory in snapshot path" {
  run bash "$VMSPAWN" -n --batch-id=cmb017 --cores=4 --memory=8Gi \
    --request-cpu=2 --request-memory=4Gi --snapshot --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- CPU/memory limits ---
  [[ "$output" == *"cores: 4"* ]]
  [[ "$output" == *"guest: 8Gi"* ]]

  # --- CPU/memory requests ---
  [[ "$output" == *"resources:"* ]]
  [[ "$output" == *"requests:"* ]]
  [[ "$output" == *"cpu: 2"* ]]
  [[ "$output" == *"memory: 4Gi"* ]]
}

# ---------------------------------------------------------------
# COMBO-18: --cores + --memory + --request-cpu + --request-memory (no-snapshot)
# ---------------------------------------------------------------
@test "combo: cores + memory + request-cpu + request-memory in DataSource clone" {
  run bash "$VMSPAWN" -n --batch-id=cmb018 --cores=4 --memory=8Gi \
    --request-cpu=2 --request-memory=4Gi --no-snapshot --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- CPU/memory limits ---
  [[ "$output" == *"cores: 4"* ]]
  [[ "$output" == *"guest: 8Gi"* ]]

  # --- CPU/memory requests ---
  [[ "$output" == *"resources:"* ]]
  [[ "$output" == *"requests:"* ]]
  [[ "$output" == *"cpu: 2"* ]]
  [[ "$output" == *"memory: 4Gi"* ]]

  # --- DataSource clone ---
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"kind: DataSource"* ]]
}

# ===============================================================
# Category 4: Clone Path x VM Lifecycle (combos 19-24)
# ===============================================================

# ---------------------------------------------------------------
# COMBO-19: --stop + --snapshot
# ---------------------------------------------------------------
@test "combo: stop + snapshot sets Halted in snapshot path" {
  run bash "$VMSPAWN" -n --batch-id=cmb019 --stop --snapshot \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"runStrategy: Halted"* ]]
  [[ "$output" == *"Snapshot mode: enabled"* ]]
  [[ "$output" == *"smartCloneFromExistingSnapshot"* ]]
}

# ---------------------------------------------------------------
# COMBO-20: --stop + --dv-url + --no-snapshot
# ---------------------------------------------------------------
@test "combo: stop + dv-url + no-snapshot sets Halted in URL clone" {
  run bash "$VMSPAWN" -n --batch-id=cmb020 --stop \
    --dv-url=http://example.com/disk.qcow2 --no-snapshot \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"runStrategy: Halted"* ]]
  [[ "$output" == *"http://example.com/disk.qcow2"* ]]
  [[ "$output" == *"pvc:"* ]]
}

# ---------------------------------------------------------------
# COMBO-21: --start + --no-snapshot
# ---------------------------------------------------------------
@test "combo: start + no-snapshot sets Always in DataSource clone" {
  run bash "$VMSPAWN" -n --batch-id=cmb021 --start --no-snapshot \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"runStrategy: Always"* ]]
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
  [[ "$output" == *"sourceRef"* ]]
}

# ---------------------------------------------------------------
# COMBO-22: --run-strategy=Manual + --snapshot
# ---------------------------------------------------------------
@test "combo: run-strategy Manual + snapshot" {
  run bash "$VMSPAWN" -n --batch-id=cmb022 --run-strategy=Manual --snapshot \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"runStrategy: Manual"* ]]
  [[ "$output" == *"Snapshot mode: enabled"* ]]
  [[ "$output" == *"smartCloneFromExistingSnapshot"* ]]
}

# ---------------------------------------------------------------
# COMBO-23: --run-strategy=Manual + --no-snapshot
# ---------------------------------------------------------------
@test "combo: run-strategy Manual + no-snapshot DataSource clone" {
  run bash "$VMSPAWN" -n --batch-id=cmb023 --run-strategy=Manual --no-snapshot \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"runStrategy: Manual"* ]]
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
  [[ "$output" == *"sourceRef"* ]]
}

# ---------------------------------------------------------------
# COMBO-24: --run-strategy=Manual + --dv-url + --no-snapshot
# ---------------------------------------------------------------
@test "combo: run-strategy Manual + dv-url + no-snapshot" {
  run bash "$VMSPAWN" -n --batch-id=cmb024 --run-strategy=Manual \
    --dv-url=http://example.com/disk.qcow2 --no-snapshot \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"runStrategy: Manual"* ]]
  [[ "$output" == *"http://example.com/disk.qcow2"* ]]
  [[ "$output" == *"pvc:"* ]]
}

# ===============================================================
# Category 5: Scale x Clone Path (combos 25-29)
# ===============================================================

# ---------------------------------------------------------------
# COMBO-25: --vms-per-namespace + --namespaces + --no-snapshot
# ---------------------------------------------------------------
@test "combo: vms-per-namespace + namespaces + no-snapshot DataSource clone" {
  run bash "$VMSPAWN" -n --batch-id=cmb025 --vms-per-namespace=3 --namespaces=2 \
    --no-snapshot
  [ "$status" -eq 0 ]

  # --- Total VMs = 3 * 2 = 6 ---
  [[ "$output" == *"Total VMs: 6"* ]]

  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 6 ]

  # --- DataSource direct clone ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
  [[ "$output" == *"sourceRef"* ]]

  # --- 2 namespaces ---
  [[ "$output" == *"name: vm-cmb025-ns-1"* ]]
  [[ "$output" == *"name: vm-cmb025-ns-2"* ]]
}

# ---------------------------------------------------------------
# COMBO-26: --vms-per-namespace + --namespaces + --snapshot
# ---------------------------------------------------------------
@test "combo: vms-per-namespace + namespaces + snapshot" {
  run bash "$VMSPAWN" -n --batch-id=cmb026 --vms-per-namespace=3 --namespaces=2 \
    --snapshot
  [ "$status" -eq 0 ]

  # --- Total VMs = 3 * 2 = 6 ---
  [[ "$output" == *"Total VMs: 6"* ]]

  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 6 ]

  # --- Snapshot flow ---
  [[ "$output" == *"Snapshot mode: enabled"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]
  [[ "$output" == *"smartCloneFromExistingSnapshot"* ]]

  # --- 2 VolumeSnapshots (one per namespace) ---
  local snap_count
  snap_count=$(echo "$output" | grep -c "kind: VolumeSnapshot")
  [ "$snap_count" -eq 2 ]
}

# ---------------------------------------------------------------
# COMBO-27: --vms-per-namespace + --namespaces + --cloudinit
# ---------------------------------------------------------------
@test "combo: vms-per-namespace + namespaces + cloudinit (Secret per ns)" {
  run bash "$VMSPAWN" -n --batch-id=cmb027 --vms-per-namespace=4 --namespaces=3 \
    --cloudinit=helpers/cloudinit-stress-workload.yaml
  [ "$status" -eq 0 ]

  # --- Total VMs = 4 * 3 = 12 ---
  [[ "$output" == *"Total VMs: 12"* ]]

  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 12 ]

  # --- 3 cloud-init Secrets (one per namespace) ---
  local secret_count
  secret_count=$(echo "$output" | grep -c "kind: Secret")
  [ "$secret_count" -eq 3 ]
}

# ---------------------------------------------------------------
# COMBO-28: positional 7 3 + --no-snapshot + --cloudinit
# ---------------------------------------------------------------
@test "combo: positional args + no-snapshot + cloudinit" {
  run bash "$VMSPAWN" -n --batch-id=cmb028 --no-snapshot \
    --cloudinit=helpers/cloudinit-stress-workload.yaml 7 3
  [ "$status" -eq 0 ]

  # --- 7 VMs across 3 namespaces ---
  [[ "$output" == *"Total VMs: 7"* ]]
  [[ "$output" == *"Namespaces: 3"* ]]

  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 7 ]

  # --- DataSource clone ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]

  # --- 3 Secrets ---
  local secret_count
  secret_count=$(echo "$output" | grep -c "kind: Secret")
  [ "$secret_count" -eq 3 ]
}

# ---------------------------------------------------------------
# COMBO-29: positional 5 2 + --cores + --memory
# ---------------------------------------------------------------
@test "combo: positional args + cores + memory" {
  run bash "$VMSPAWN" -n --batch-id=cmb029 --cores=4 --memory=8Gi 5 2
  [ "$status" -eq 0 ]

  # --- 5 VMs across 2 namespaces ---
  [[ "$output" == *"Total VMs: 5"* ]]
  [[ "$output" == *"Namespaces: 2"* ]]

  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 5 ]

  # --- Custom CPU/memory ---
  [[ "$output" == *"cores: 4"* ]]
  [[ "$output" == *"guest: 8Gi"* ]]
}

# ===============================================================
# Category 6: Naming x Clone Path (combos 30-34)
# ===============================================================

# ---------------------------------------------------------------
# COMBO-30: --basename + --pvc-base-name + --snapshot
# ---------------------------------------------------------------
@test "combo: basename + pvc-base-name + snapshot (both naming options)" {
  run bash "$VMSPAWN" -n --batch-id=cmb030 --basename=myvm \
    --pvc-base-name=myvm-base --snapshot --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- VM name uses basename ---
  [[ "$output" == *"name: myvm-cmb030-1"* ]]

  # --- VolumeSnapshot references pvc-base-name ---
  [[ "$output" == *"persistentVolumeClaimName: myvm-base"* ]]

  # --- DV base name uses VM_BASENAME pattern ---
  [[ "$output" == *"name: myvm-base"* ]]

  # --- Labels use basename ---
  [[ "$output" == *'vm-basename: "myvm"'* ]]
}

# ---------------------------------------------------------------
# COMBO-31: --basename=myvm + --snapshot (default pvc-base-name)
# ---------------------------------------------------------------
@test "combo: basename + snapshot with default pvc-base-name" {
  run bash "$VMSPAWN" -n --batch-id=cmb031 --basename=myvm --snapshot \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- VM name uses custom basename ---
  [[ "$output" == *"name: myvm-cmb031-1"* ]]

  # --- VolumeSnapshot PVC references the auto-derived pvc-base-name (myvm-base) ---
  [[ "$output" == *"persistentVolumeClaimName: myvm-base"* ]]

  # --- DV base name also uses VM_BASENAME ---
  # The DV is named {VM_BASENAME}-base = myvm-base
  [[ "$output" == *"name: myvm-base"* ]]

  # --- Labels ---
  [[ "$output" == *'vm-basename: "myvm"'* ]]
}

# ---------------------------------------------------------------
# COMBO-32: --datasource=fedora + --basename=custom-vm + --no-snapshot
# ---------------------------------------------------------------
@test "combo: datasource + different basename + no-snapshot" {
  run bash "$VMSPAWN" -n --batch-id=cmb032 --datasource=fedora \
    --basename=custom-vm --no-snapshot --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Uses fedora DataSource ---
  [[ "$output" == *"name: fedora"* ]]
  [[ "$output" == *"kind: DataSource"* ]]

  # --- VM uses custom basename ---
  [[ "$output" == *"name: custom-vm-cmb032-1"* ]]
  [[ "$output" == *"name: custom-vm-cmb032-2"* ]]

  # --- Labels use custom basename ---
  [[ "$output" == *'vm-basename: "custom-vm"'* ]]
}

# ---------------------------------------------------------------
# COMBO-33: --basename=myvm + --no-snapshot + --namespaces=2
# ---------------------------------------------------------------
@test "combo: basename + no-snapshot + multiple namespaces" {
  run bash "$VMSPAWN" -n --batch-id=cmb033 --basename=myvm --no-snapshot \
    --vms=4 --namespaces=2
  [ "$status" -eq 0 ]

  # --- VM names use custom basename ---
  [[ "$output" == *"name: myvm-cmb033-1"* ]]
  [[ "$output" == *"name: myvm-cmb033-2"* ]]
  [[ "$output" == *"name: myvm-cmb033-3"* ]]
  [[ "$output" == *"name: myvm-cmb033-4"* ]]

  # --- 2 namespaces ---
  [[ "$output" == *"name: vm-cmb033-ns-1"* ]]
  [[ "$output" == *"name: vm-cmb033-ns-2"* ]]

  # --- DataSource clone ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
}

# ---------------------------------------------------------------
# COMBO-34: --basename=myvm + --dv-url + --no-snapshot
# ---------------------------------------------------------------
@test "combo: basename + dv-url + no-snapshot" {
  run bash "$VMSPAWN" -n --batch-id=cmb034 --basename=myvm \
    --dv-url=http://example.com/disk.qcow2 --no-snapshot \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- VM name uses custom basename ---
  [[ "$output" == *"name: myvm-cmb034-1"* ]]

  # --- Base DV uses custom basename ---
  [[ "$output" == *"name: myvm-base"* ]]

  # --- URL import ---
  [[ "$output" == *"http://example.com/disk.qcow2"* ]]

  # --- PVC clone ---
  [[ "$output" == *"pvc:"* ]]
}

# ===============================================================
# Category 7: Option Precedence and Conflicts (combos 35-42)
# ===============================================================

# ---------------------------------------------------------------
# COMBO-35: --vms-per-namespace overrides --vms
# ---------------------------------------------------------------
@test "combo: vms-per-namespace overrides vms flag" {
  run bash "$VMSPAWN" -n --batch-id=cmb035 --vms-per-namespace=3 --vms=10 \
    --namespaces=2
  [ "$status" -eq 0 ]

  # --- vms-per-namespace wins: total = 3 * 2 = 6, not 10 ---
  [[ "$output" == *"Total VMs: 6"* ]]

  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 6 ]
}

# ---------------------------------------------------------------
# COMBO-36: --vms=10 + positional arg 5 → positional overrides
# ---------------------------------------------------------------
@test "combo: positional arg overrides --vms flag" {
  run bash "$VMSPAWN" -n --batch-id=cmb036 --vms=10 5
  [ "$status" -eq 0 ]

  # --- Positional arg 5 overrides --vms=10 ---
  [[ "$output" == *"Total VMs: 5"* ]]

  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 5 ]
}

# ---------------------------------------------------------------
# COMBO-37: --snapshot-class + --no-snapshot
# ---------------------------------------------------------------
@test "combo: snapshot-class + no-snapshot (explicit no-snapshot wins)" {
  run bash "$VMSPAWN" -n --batch-id=cmb037 --snapshot-class=my-snap \
    --no-snapshot --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Explicit --no-snapshot wins over --snapshot-class ---
  [[ "$output" == *"Snapshot mode: disabled"* ]]
  [[ "$output" != *"kind: VolumeSnapshot"* ]]
}

# ---------------------------------------------------------------
# COMBO-38: --snapshot-class alone (no --storage-class)
# ---------------------------------------------------------------
@test "combo: snapshot-class alone keeps snapshot mode on" {
  run bash "$VMSPAWN" -n --batch-id=cmb038 --snapshot-class=my-snap \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Snapshot mode stays enabled ---
  [[ "$output" == *"Snapshot mode: enabled"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]
  [[ "$output" == *"volumeSnapshotClassName: my-snap"* ]]
}

# ---------------------------------------------------------------
# COMBO-39: --stop + --wait (dry-run; Halted VMs won't run)
# ---------------------------------------------------------------
@test "combo: stop + wait accepted without error in dry-run" {
  run bash "$VMSPAWN" -n --batch-id=cmb039 --stop --wait \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Both flags accepted ---
  [[ "$output" == *"runStrategy: Halted"* ]]
  [[ "$output" == *"kind: VirtualMachine"* ]]
}

# ---------------------------------------------------------------
# COMBO-40: --dv-url + --datasource (dv-url clears datasource)
# ---------------------------------------------------------------
@test "combo: dv-url overrides datasource" {
  run bash "$VMSPAWN" -n --batch-id=cmb040 \
    --datasource=fedora --dv-url=http://example.com/disk.qcow2 \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- URL import used, not DataSource ---
  [[ "$output" == *"http://example.com/disk.qcow2"* ]]
  [[ "$output" != *"sourceRef"* ]]
  [[ "$output" != *"kind: DataSource"* ]]

  # --- DV source is URL, not DataSource ---
  [[ "$output" == *"Disk source: URL"* ]]
}

# ---------------------------------------------------------------
# COMBO-41: --start + --stop (last one wins)
# ---------------------------------------------------------------
@test "combo: start then stop — last flag wins" {
  run bash "$VMSPAWN" -n --batch-id=cmb041 --start --stop \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- --stop is last, so Halted ---
  [[ "$output" == *"runStrategy: Halted"* ]]
}

# ---------------------------------------------------------------
# COMBO-42: --run-strategy=Halted + --start (start overrides)
# ---------------------------------------------------------------
@test "combo: run-strategy Halted then start — start overrides" {
  run bash "$VMSPAWN" -n --batch-id=cmb042 --run-strategy=Halted --start \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- --start is last, so Always ---
  [[ "$output" == *"runStrategy: Always"* ]]
}

# ===============================================================
# Category 8: WFFC x Other Options (combos 43-46, mock oc)
# ===============================================================

# ---------------------------------------------------------------
# COMBO-43: WFFC + --cloudinit + --no-snapshot
# ---------------------------------------------------------------
@test "combo-wffc: cloudinit + no-snapshot with WFFC storage" {
  local mock_dir
  mock_dir=$(mktemp -d)
  _create_mock_oc "$mock_dir"

  export MOCK_ACCESS_MODE=ReadWriteOnce
  export MOCK_BIND_MODE=WaitForFirstConsumer
  export PATH="$mock_dir:$PATH"

  run bash "$VMSPAWN" --batch-id=cmb043 --storage-class=lvms-nvme-sc \
    --no-snapshot --cloudinit=helpers/cloudinit-stress-workload.yaml \
    --vms=2 --namespaces=1

  rm -rf "$mock_dir"
  rm -f logs/cmb043-*.log logs/batch-cmb043.manifest

  [ "$status" -eq 0 ]
  [[ "$output" == *"WaitForFirstConsumer"* ]]
  [[ "$output" == *"Skipping base DataVolume creation"* ]]

  # --- Cloud-init Secret still created ---
  [[ "$output" == *"Creating cloud-init Secret"* ]]
  [[ "$output" == *"Resource creation completed successfully"* ]]
}

# ---------------------------------------------------------------
# COMBO-44: WFFC + --dv-url (auto-detected RWO)
# Note: explicit --rwo would skip detect_access_mode() entirely,
#       bypassing WFFC detection. So we let the mock auto-detect.
# ---------------------------------------------------------------
@test "combo-wffc: dv-url with WFFC storage (auto-detected RWO)" {
  local mock_dir
  mock_dir=$(mktemp -d)
  _create_mock_oc "$mock_dir"

  export MOCK_ACCESS_MODE=ReadWriteOnce
  export MOCK_BIND_MODE=WaitForFirstConsumer
  export PATH="$mock_dir:$PATH"

  run bash "$VMSPAWN" --batch-id=cmb044 --storage-class=lvms-nvme-sc \
    --no-snapshot --dv-url=http://example.com/disk.qcow2 \
    --vms=1 --namespaces=1

  rm -rf "$mock_dir"
  rm -f logs/cmb044-*.log logs/batch-cmb044.manifest

  [ "$status" -eq 0 ]
  [[ "$output" == *"WaitForFirstConsumer"* ]]
  [[ "$output" == *"Auto-detected access mode 'ReadWriteOnce'"* ]]
  [[ "$output" == *"Skipping DataVolume wait"* ]]
  [[ "$output" == *"Resource creation completed successfully"* ]]
}

# ---------------------------------------------------------------
# COMBO-45: WFFC + --vms-per-namespace + --namespaces
# ---------------------------------------------------------------
@test "combo-wffc: vms-per-namespace + namespaces with WFFC storage" {
  local mock_dir
  mock_dir=$(mktemp -d)
  _create_mock_oc "$mock_dir"

  export MOCK_ACCESS_MODE=ReadWriteOnce
  export MOCK_BIND_MODE=WaitForFirstConsumer
  export PATH="$mock_dir:$PATH"

  run bash "$VMSPAWN" --batch-id=cmb045 --storage-class=lvms-nvme-sc \
    --no-snapshot --vms-per-namespace=3 --namespaces=2

  rm -rf "$mock_dir"
  rm -f logs/cmb045-*.log logs/batch-cmb045.manifest

  [ "$status" -eq 0 ]
  [[ "$output" == *"WaitForFirstConsumer"* ]]
  [[ "$output" == *"Skipping base DataVolume creation"* ]]

  # --- 6 VMs total ---
  [[ "$output" == *"6 VMs"* ]]
  [[ "$output" == *"Resource creation completed successfully"* ]]
}

# ---------------------------------------------------------------
# COMBO-46: WFFC + --snapshot + --cloudinit (auto-disables snapshot)
# ---------------------------------------------------------------
@test "combo-wffc: snapshot + cloudinit — WFFC auto-disables snapshot" {
  local mock_dir
  mock_dir=$(mktemp -d)
  _create_mock_oc "$mock_dir"

  export MOCK_ACCESS_MODE=ReadWriteOnce
  export MOCK_BIND_MODE=WaitForFirstConsumer
  export PATH="$mock_dir:$PATH"

  run bash "$VMSPAWN" --batch-id=cmb046 --storage-class=lvms-nvme-sc \
    --snapshot --cloudinit=helpers/cloudinit-stress-workload.yaml \
    --vms=2 --namespaces=1

  rm -rf "$mock_dir"
  rm -f logs/cmb046-*.log logs/batch-cmb046.manifest

  [ "$status" -eq 0 ]

  # --- Snapshot auto-disabled ---
  [[ "$output" == *"Disabling snapshot mode"* ]]
  [[ "$output" == *"Falling back to direct DataSource clone"* ]]

  # --- Cloud-init still works ---
  [[ "$output" == *"Creating cloud-init Secret"* ]]
  [[ "$output" == *"Resource creation completed successfully"* ]]
}

# ===============================================================
# Category 9: Dry-run / Quiet x Clone Path (combos 47-49)
# ===============================================================

# ---------------------------------------------------------------
# COMBO-47: -q + --no-snapshot
# ---------------------------------------------------------------
@test "combo: quiet mode + no-snapshot DataSource clone" {
  run bash "$VMSPAWN" -q --batch-id=cmb047 --no-snapshot --vms=3 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Quiet mode: no YAML output ---
  [[ "$output" != *"apiVersion:"* ]]
  [[ "$output" != *"kind: VirtualMachine"* ]]

  # --- Log messages still appear ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
  [[ "$output" == *"Skipping VolumeSnapshots"* ]]

  # --- No YAML file created ---
  [ ! -f logs/cmb047-dryrun.yaml ]
}

# ---------------------------------------------------------------
# COMBO-48: -q + --dv-url
# ---------------------------------------------------------------
@test "combo: quiet mode + dv-url URL import" {
  run bash "$VMSPAWN" -q --batch-id=cmb048 \
    --dv-url=http://example.com/disk.qcow2 --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Quiet mode: no YAML output ---
  [[ "$output" != *"apiVersion:"* ]]
  [[ "$output" != *"kind: VirtualMachine"* ]]

  # --- Log messages still appear ---
  [[ "$output" == *"Creating DataVolumes"* ]]
  [[ "$output" == *"Creating VirtualMachines"* ]]

  # --- No YAML file ---
  [ ! -f logs/cmb048-dryrun.yaml ]
}

# ---------------------------------------------------------------
# COMBO-49: -q + --delete
# ---------------------------------------------------------------
@test "combo: quiet mode + delete" {
  run bash "$VMSPAWN" -q --delete=abc123
  [ "$status" -eq 0 ]

  # --- Delete dry-run still shows info ---
  [[ "$output" == *"dry-run"* ]]
  [[ "$output" == *"abc123"* ]]
}
