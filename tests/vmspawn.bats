#!/usr/bin/env bats

# Unit tests for vmspawn
# Run with: bats tests/

VMSPAWN="./vmspawn"

# ---------------------------------------------------------------
# 1. Batch ID auto-generation
# ---------------------------------------------------------------
@test "auto-generates a 6-character hex batch ID" {
  run bash "$VMSPAWN" -q --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # Extract the batch ID from the "Batch ID: <id>" line
  local batch_id
  batch_id=$(echo "$output" | grep "Batch ID:" | head -1 | awk '{print $NF}')

  # Must be exactly 6 hex characters
  [[ "$batch_id" =~ ^[0-9a-f]{6}$ ]]
}

# ---------------------------------------------------------------
# 2. Batch ID override
# ---------------------------------------------------------------
@test "batch ID override appears in all resource names" {
  run bash "$VMSPAWN" -n --batch-id=aabbcc --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # Namespace uses the batch ID
  [[ "$output" == *"vm-aabbcc-ns-1"* ]]

  # VM names use the batch ID
  [[ "$output" == *"rhel9-aabbcc-1"* ]]
  [[ "$output" == *"rhel9-aabbcc-2"* ]]

  # Snapshot uses the batch ID
  [[ "$output" == *"rhel9-vm-aabbcc-ns-1"* ]]

  # Label is present
  [[ "$output" == *'batch-id: "aabbcc"'* ]]
}

# ---------------------------------------------------------------
# 3. Namespace naming pattern
# ---------------------------------------------------------------
@test "namespaces follow vm-{batch}-ns-{N} pattern" {
  run bash "$VMSPAWN" -q --batch-id=ff0011 --vms=4 --namespaces=3
  [ "$status" -eq 0 ]

  [[ "$output" == *"vm-ff0011-ns-1"* ]]
  [[ "$output" == *"vm-ff0011-ns-2"* ]]
  [[ "$output" == *"vm-ff0011-ns-3"* ]]

  # Should NOT have a 4th namespace
  [[ "$output" != *"vm-ff0011-ns-4"* ]]
}

# ---------------------------------------------------------------
# 4. VM naming pattern
# ---------------------------------------------------------------
@test "VMs follow {basename}-{batch}-{ID} pattern" {
  run bash "$VMSPAWN" -n --batch-id=112233 --vms=3 --namespaces=1
  [ "$status" -eq 0 ]

  # Check each VM name appears in the YAML output
  [[ "$output" == *"name: rhel9-112233-1"* ]]
  [[ "$output" == *"name: rhel9-112233-2"* ]]
  [[ "$output" == *"name: rhel9-112233-3"* ]]
}

# ---------------------------------------------------------------
# 5. Custom basename
# ---------------------------------------------------------------
@test "custom basename is reflected in VM and resource names" {
  run bash "$VMSPAWN" -n --batch-id=ccddee --basename=win11 --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # VM names use custom basename
  [[ "$output" == *"name: win11-ccddee-1"* ]]
  [[ "$output" == *"name: win11-ccddee-2"* ]]

  # DataVolume base uses custom basename
  [[ "$output" == *"name: win11-base"* ]]

  # VolumeSnapshot uses custom basename
  [[ "$output" == *"name: win11-vm-ccddee-ns-1"* ]]

  # Label uses custom basename
  [[ "$output" == *'vm-basename: "win11"'* ]]
}

# ---------------------------------------------------------------
# 6. VM distribution across namespaces
# ---------------------------------------------------------------
@test "VMs are distributed evenly with remainder in first namespaces" {
  run bash "$VMSPAWN" -q --batch-id=aabb11 --vms=5 --namespaces=2
  [ "$status" -eq 0 ]

  # 5 VMs / 2 NS = 2 per NS + 1 remainder in ns-1
  # ns-1 should get VMs 1, 2, 3  (3 VMs)
  # ns-2 should get VMs 4, 5     (2 VMs)
  local ns1_count ns2_count
  ns1_count=$(echo "$output" | grep -c "Creating VirtualMachine.*for namespace: vm-aabb11-ns-1")
  ns2_count=$(echo "$output" | grep -c "Creating VirtualMachine.*for namespace: vm-aabb11-ns-2")

  [ "$ns1_count" -eq 3 ]
  [ "$ns2_count" -eq 2 ]
}

# ---------------------------------------------------------------
# 7. Labels in YAML output
# ---------------------------------------------------------------
@test "batch-id and vm-basename labels appear in all resource YAML" {
  run bash "$VMSPAWN" -n --batch-id=labels --basename=rhel9 --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # Count batch-id label occurrences:
  # Expected in: namespace, datavolume, volumesnapshot, VM metadata, VM pod template
  local label_count
  label_count=$(echo "$output" | grep -c 'batch-id: "labels"')
  [ "$label_count" -ge 5 ]

  # vm-basename label should appear on DV, VolumeSnapshot, VM metadata, VM pod template
  local basename_count
  basename_count=$(echo "$output" | grep -c 'vm-basename: "rhel9"')
  [ "$basename_count" -ge 4 ]
}
