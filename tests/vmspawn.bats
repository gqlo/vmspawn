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
  [[ "$output" == *"storage: 22Gi"* ]]

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
  [[ "$output" == *"storage: 22Gi"* ]]

  # --- VolumeSnapshots ---
  [[ "$output" == *"Creating VolumeSnapshots"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]
  [[ "$output" == *"name: rhel9-vm-qs0003-ns-1"* ]]
  [[ "$output" == *"name: rhel9-vm-qs0003-ns-2"* ]]

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
  [[ "$output" == *"Snapshot mode: disabled (direct PVC clone)"* ]]
  [[ "$output" == *"Skipping VolumeSnapshots"* ]]
  [[ "$output" != *"kind: VolumeSnapshot"* ]]

  # --- Storage class applied ---
  [[ "$output" == *"storageClassName: my-nfs-sc"* ]]
  [[ "$output" == *"Storage Class: my-nfs-sc"* ]]

  # --- VMs clone from PVC ---
  [[ "$output" == *"pvc:"* ]]
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

  # --- Snapshots disabled ---
  [[ "$output" == *"Snapshot mode: disabled (direct PVC clone)"* ]]
  [[ "$output" == *"Skipping VolumeSnapshots"* ]]
  [[ "$output" != *"kind: VolumeSnapshot"* ]]

  # --- VMs clone from PVC ---
  [[ "$output" == *"pvc:"* ]]
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

@test "dry-run: no-snapshot mode saves PVC clone YAML" {
  run bash "$VMSPAWN" -n --batch-id=dry003 --no-snapshot --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  [ -f logs/dry003-dryrun.yaml ]

  local content
  content=$(cat logs/dry003-dryrun.yaml)

  # --- PVC clone, not snapshot ---
  [[ "$content" == *"pvc:"* ]]
  [[ "$content" != *"smartCloneFromExistingSnapshot"* ]]
  [[ "$content" != *"kind: VolumeSnapshot"* ]]

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
  [[ "$output" == *"storage: 22Gi"* ]]
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
  [[ "$output" == *"Snapshot mode: disabled (direct PVC clone)"* ]]
  [[ "$output" == *"Skipping VolumeSnapshots"* ]]

  # --- No VolumeSnapshot YAML emitted ---
  [[ "$output" != *"kind: VolumeSnapshot"* ]]
  [[ "$output" != *"volumeSnapshotClassName"* ]]

  # --- DataVolume still created ---
  [[ "$output" == *"Creating DataVolumes"* ]]
  [[ "$output" == *"kind: DataVolume"* ]]

  # --- VMs still created ---
  [[ "$output" == *"Creating VirtualMachines"* ]]
  [[ "$output" == *"kind: VirtualMachine"* ]]

  # --- 3 VMs ---
  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 3 ]
}

# ---------------------------------------------------------------
# NS-2: --no-snapshot VMs clone from PVC (not snapshot)
# ---------------------------------------------------------------
@test "no-snapshot: VMs clone from PVC source instead of snapshot" {
  run bash "$VMSPAWN" -n --batch-id=nosn02 --no-snapshot --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- VM uses PVC source (not snapshot source) ---
  [[ "$output" == *"source:"* ]]
  [[ "$output" == *"pvc:"* ]]
  [[ "$output" == *"name: rhel9-base"* ]]

  # --- No snapshot references ---
  [[ "$output" != *"smartCloneFromExistingSnapshot"* ]]
  [[ "$output" != *"source:"*"snapshot:"* ]]
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

  # --- Storage class appears in DV and VM ---
  [[ "$output" == *"storageClassName: my-custom-sc"* ]]
  [[ "$output" == *"Storage Class: my-custom-sc"* ]]
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
# NS-8: vm-clone.yaml template is well-formed
# ---------------------------------------------------------------
@test "no-snapshot: VM clone YAML is well-formed" {
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

  # PVC clone source
  [[ "$output" == *"pvc:"* ]]
  [[ "$output" == *"name: rhel9-base"* ]]

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
# Auto-detection: --storage-class without --snapshot-class
# ===============================================================

# ---------------------------------------------------------------
# AD-1: custom storage class auto-disables snapshots
# ---------------------------------------------------------------
@test "auto-detect: custom storage-class without snapshot-class disables snapshots" {
  run bash "$VMSPAWN" -n --batch-id=auto01 --storage-class=my-nfs-sc --vms=3 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Auto-detected no-snapshot mode ---
  [[ "$output" == *"Snapshot mode: disabled (direct PVC clone)"* ]]
  [[ "$output" == *"Skipping VolumeSnapshots"* ]]

  # --- No VolumeSnapshot YAML emitted ---
  [[ "$output" != *"kind: VolumeSnapshot"* ]]
  [[ "$output" != *"volumeSnapshotClassName"* ]]

  # --- Storage class applied to resources ---
  [[ "$output" == *"storageClassName: my-nfs-sc"* ]]
  [[ "$output" == *"Storage Class: my-nfs-sc"* ]]

  # --- VMs use PVC clone ---
  [[ "$output" == *"pvc:"* ]]
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
# WFFC-1: WFFC detected → skip DV wait, proceed to VM creation
# ---------------------------------------------------------------
@test "wffc: skips DataVolume wait for WaitForFirstConsumer storage" {
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
  [[ "$output" == *"Skipping DataVolume wait"* ]]
  [[ "$output" == *"VMs will trigger PVC binding"* ]]
  # VMs were still created despite DV wait being skipped
  [[ "$output" == *"Creating VirtualMachines"* ]]
  [[ "$output" == *"Resource creation completed successfully"* ]]
}

# ---------------------------------------------------------------
# WFFC-2: Immediate binding → normal DV wait (no skip)
# ---------------------------------------------------------------
@test "wffc: normal DV wait for Immediate binding storage" {
  local mock_dir
  mock_dir=$(mktemp -d)
  _create_mock_oc "$mock_dir"

  export MOCK_ACCESS_MODE=ReadWriteOnce
  export MOCK_BIND_MODE=Immediate
  export PATH="$mock_dir:$PATH"

  run bash "$VMSPAWN" --batch-id=wf0002 --storage-class=lvms-nvme-sc-imm \
    --no-snapshot --vms=1 --namespaces=1

  rm -rf "$mock_dir"
  rm -f logs/wf0002-*.log logs/batch-wf0002.manifest

  [ "$status" -eq 0 ]
  [[ "$output" != *"Skipping DataVolume wait"* ]]
  [[ "$output" == *"All DataVolumes are completed successfully"* ]]
  [[ "$output" == *"Creating VirtualMachines"* ]]
}

# ---------------------------------------------------------------
# WFFC-3: WFFC detection also works in dry-run
# ---------------------------------------------------------------
@test "wffc: dry-run shows WFFC warning when oc is available" {
  local mock_dir
  mock_dir=$(mktemp -d)
  _create_mock_oc "$mock_dir"

  export MOCK_ACCESS_MODE=ReadWriteOnce
  export MOCK_BIND_MODE=WaitForFirstConsumer
  export PATH="$mock_dir:$PATH"

  run bash "$VMSPAWN" -n --batch-id=wf0003 --storage-class=lvms-nvme-sc \
    --no-snapshot --vms=1 --namespaces=1

  rm -rf "$mock_dir"
  rm -f logs/wf0003-dryrun.yaml

  [ "$status" -eq 0 ]
  [[ "$output" == *"WaitForFirstConsumer"* ]]
  [[ "$output" == *"Access Mode: ReadWriteOnce"* ]]
}
