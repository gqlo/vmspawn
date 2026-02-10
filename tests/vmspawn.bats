#!/usr/bin/env bats

# Unit tests for vmspawn
# Run with: bats tests/

VMSPAWN="./vmspawn"

# ===============================================================
# Quick start commands (README)
# ===============================================================

# ---------------------------------------------------------------
# QS-1: ./vmspawn --vms=10 --namespaces=2
#   Default DataSource (rhel9), 10 VMs across 2 namespaces
# ---------------------------------------------------------------
@test "QS: default DataSource, 10 VMs across 2 namespaces" {
  run bash "$VMSPAWN" -n --batch-id=qs0001 --vms=10 --namespaces=2
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

  # --- DV has no explicit storage size (auto-sized from DataSource) ---
  # The dv-datasource.yaml template uses storage: without resources.requests.storage
  local dv_yaml
  dv_yaml=$(echo "$output" | sed -n '/kind: DataVolume/,/^---/p' | head -20)
  [[ "$dv_yaml" != *"storage: 22Gi"* ]]

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

  # --- VM spec structure ---
  [[ "$output" == *"runStrategy: Always"* ]]
  [[ "$output" == *"cores: 1"* ]]
  [[ "$output" == *"guest: 1Gi"* ]]
  [[ "$output" == *"bus: virtio"* ]]
  [[ "$output" == *"masquerade"* ]]
  [[ "$output" == *"evictionStrategy: LiveMigrate"* ]]

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
# QS-5: ./vmspawn -n --vms=10 --namespaces=2
#   Dry-run mode (same as QS-1 but verifying dry-run behavior)
# ---------------------------------------------------------------
@test "QS: dry-run does not emit oc apply commands" {
  run bash "$VMSPAWN" -n --batch-id=qs0005 --vms=10 --namespaces=2
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
}

# ---------------------------------------------------------------
# QS-6: ./vmspawn --delete=a3f7b2
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
@test "DataSource DV uses storage API without explicit size" {
  run bash "$VMSPAWN" -n --batch-id=yaml01 --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # Uses storage: (not pvc:)
  [[ "$output" == *"storage:"* ]]
  [[ "$output" == *"accessModes:"* ]]
  [[ "$output" == *"ReadWriteMany"* ]]
  [[ "$output" == *"volumeMode: Block"* ]]
  [[ "$output" == *"storageClassName:"* ]]
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
