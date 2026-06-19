#!/usr/bin/env bats

# Unit tests for vstorm UDN (User Defined Network) feature
# Run with: bats tests/14-udn.bats

load 'helpers'

VSTORM="./vstorm"

setup_file() {
    setup_oc_mock
}

# ===============================================================
# Category 14: Validation / error handling (ERR-UDN-1 through ERR-UDN-7)
# ===============================================================

# ---------------------------------------------------------------
# ERR-UDN-1: --udn-ssh without --udn-l2
# ---------------------------------------------------------------
@test "ERR: --udn-ssh requires --udn-l2" {
  run bash "$VSTORM" -n --batch-id=udnerr1 --udn-ssh --vms=1 --namespaces=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"--udn-ssh requires --udn-l2"* ]]
}

# ---------------------------------------------------------------
# ERR-UDN-2: invalid --udn-ssh value
# ---------------------------------------------------------------
@test "ERR: invalid --udn-ssh value rejected" {
  run bash "$VSTORM" -n --batch-id=udnerr2 --udn-l2 --udn-ssh=invalid \
    --vms=1 --namespaces=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid --udn-ssh value 'invalid'"* ]]
  [[ "$output" == *"use nodeport or clusterip"* ]]
}

# ---------------------------------------------------------------
# ERR-UDN-3: invalid --subnet format
# ---------------------------------------------------------------
@test "ERR: invalid --subnet format rejected" {
  run bash "$VSTORM" -n --batch-id=udnerr3 --udn-l2 --subnet=not-a-cidr \
    --vms=1 --namespaces=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid --subnet='not-a-cidr'"* ]]
}

# ---------------------------------------------------------------
# ERR-UDN-4: --subnet prefix out of range
# ---------------------------------------------------------------
@test "ERR: --subnet prefix out of range rejected" {
  run bash "$VSTORM" -n --batch-id=udnerr4 --udn-l2 --subnet=10.0.0.0/33 \
    --vms=1 --namespaces=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid --subnet='10.0.0.0/33'"* ]]
}

# ---------------------------------------------------------------
# ERR-UDN-5: missing udn-l2 template
# ---------------------------------------------------------------
@test "ERR: missing udn-l2 template fails with --udn-l2" {
  local tmpdir
  tmpdir=$(mktemp -d)
  cp "$BATS_TEST_DIRNAME/../vstorm" "$tmpdir/vstorm"
  chmod +x "$tmpdir/vstorm"
  mkdir "$tmpdir/templates"
  cp templates/namespace.yaml templates/vm-clone.yaml templates/dv.yaml \
    "$tmpdir/templates/"
  run bash "$tmpdir/vstorm" -n --batch-id=udnerr5 --udn-l2 \
    --vms=1 --namespaces=1 --dv-url=http://example.com/disk.qcow --no-snapshot
  [ "$status" -ne 0 ]
  [[ "$output" == *"No udn-l2 template found"* ]]
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------
# ERR-UDN-6: missing vm-udn template
# ---------------------------------------------------------------
@test "ERR: missing vm-udn template fails with --udn-l2" {
  local tmpdir
  tmpdir=$(mktemp -d)
  cp "$BATS_TEST_DIRNAME/../vstorm" "$tmpdir/vstorm"
  chmod +x "$tmpdir/vstorm"
  mkdir "$tmpdir/templates"
  cp templates/namespace.yaml templates/udn-l2.yaml templates/vm-clone.yaml \
    templates/dv.yaml "$tmpdir/templates/"
  run bash "$tmpdir/vstorm" -n --batch-id=udnerr6 --udn-l2 \
    --vms=1 --namespaces=1 --dv-url=http://example.com/disk.qcow --no-snapshot
  [ "$status" -ne 0 ]
  [[ "$output" == *"No vm-udn template found"* ]]
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------
# ERR-UDN-7: missing svc-ssh-udn template
# ---------------------------------------------------------------
@test "ERR: missing svc-ssh-udn template fails with --udn-ssh" {
  local tmpdir
  tmpdir=$(mktemp -d)
  cp "$BATS_TEST_DIRNAME/../vstorm" "$tmpdir/vstorm"
  chmod +x "$tmpdir/vstorm"
  mkdir "$tmpdir/templates"
  cp templates/namespace.yaml templates/udn-l2.yaml templates/vm-clone.yaml \
    templates/vm-clone-udn.yaml templates/dv.yaml "$tmpdir/templates/"
  run bash "$tmpdir/vstorm" -n --batch-id=udnerr7 --udn-l2 --udn-ssh \
    --vms=1 --namespaces=1 --dv-url=http://example.com/disk.qcow --no-snapshot
  [ "$status" -ne 0 ]
  [[ "$output" == *"No svc-ssh-udn template found"* ]]
  rm -rf "$tmpdir"
}

# ===============================================================
# Category 14: Core UDN L2 YAML (UDN-1 through UDN-6)
# ===============================================================

# ---------------------------------------------------------------
# UDN-1: --udn-l2 creates UserDefinedNetwork per namespace
# ---------------------------------------------------------------
@test "UDN: creates UserDefinedNetwork per namespace with default subnet" {
  run bash "$VSTORM" -n --batch-id=udn001 --udn-l2 --vms=2 --namespaces=2
  [ "$status" -eq 0 ]

  local udn_count
  udn_count=$(echo "$output" | grep -c "kind: UserDefinedNetwork")
  [ "$udn_count" -eq 2 ]

  [[ "$output" == *"topology: Layer2"* ]]
  [[ "$output" == *"role: Primary"* ]]
  [[ "$output" == *'subnets: ["10.132.10.0/16"]'* ]]
  [[ "$output" == *"k8s.ovn.org/primary-user-defined-network"* ]]
  [[ "$output" == *"name: l2-network-udn001"* ]]
  [[ "$output" == *"UDN L2: enabled (subnet: 10.132.10.0/16)"* ]]
}

# ---------------------------------------------------------------
# UDN-2: custom --subnet
# ---------------------------------------------------------------
@test "UDN: custom --subnet appears in UDN CR and summary" {
  run bash "$VSTORM" -n --batch-id=udn002 --udn-l2 --subnet=10.200.0.0/16 \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *'subnets: ["10.200.0.0/16"]'* ]]
  [[ "$output" == *"UDN L2: enabled (subnet: 10.200.0.0/16)"* ]]
}

# ---------------------------------------------------------------
# UDN-3: VM uses l2bridge interface, not masquerade
# ---------------------------------------------------------------
@test "UDN: VM uses l2bridge interface instead of masquerade" {
  run bash "$VSTORM" -n --batch-id=udn003 --udn-l2 --vms=2 --namespaces=2
  [ "$status" -eq 0 ]

  [[ "$output" == *"name: l2bridge"* ]]
  [[ "$output" == *"primary-udn-net"* ]]
  [[ "$output" != *"masquerade"* ]]
}

# ---------------------------------------------------------------
# UDN-4: --udn-l2 with containerdisk
# ---------------------------------------------------------------
@test "UDN: containerdisk mode uses UDN VM template" {
  run bash "$VSTORM" -n --batch-id=udn004 --udn-l2 --containerdisk \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"kind: UserDefinedNetwork"* ]]
  [[ "$output" == *"name: l2bridge"* ]]
  [[ "$output" == *"containerDisk:"* ]]
  [[ "$output" != *"kind: DataVolume"* ]]
}

# ---------------------------------------------------------------
# UDN-5: --udn-l2 with direct DataSource clone (no snapshot)
# ---------------------------------------------------------------
@test "UDN: no-snapshot DataSource clone uses UDN VM template" {
  run bash "$VSTORM" -n --batch-id=udn005 --udn-l2 --no-snapshot \
    --datasource=rhel9 --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"kind: UserDefinedNetwork"* ]]
  [[ "$output" == *"name: l2bridge"* ]]
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"kind: DataSource"* ]]
  [[ "$output" != *"kind: VolumeSnapshot"* ]]
}

# ---------------------------------------------------------------
# UDN-6: without UDN flags, default networking is unchanged
# ---------------------------------------------------------------
@test "UDN: without --udn-l2, default masquerade networking is used" {
  run bash "$VSTORM" -n --batch-id=udn006 --datasource=rhel9 \
    --vms=1 --namespaces=1 --no-snapshot
  [ "$status" -eq 0 ]

  [[ "$output" != *"kind: UserDefinedNetwork"* ]]
  [[ "$output" != *"l2bridge"* ]]
  [[ "$output" == *"masquerade"* ]]
  [[ "$output" == *"UDN L2: disabled"* ]]
}

# ===============================================================
# Category 14: Cloud-init networkData (UDN-7 through UDN-9)
# ===============================================================

# ---------------------------------------------------------------
# UDN-7: auto cloud-init with containerdisk includes networkData
# ---------------------------------------------------------------
@test "UDN: auto cloud-init includes DHCP networkData" {
  run bash "$VSTORM" -n --batch-id=udn007 --udn-l2 --containerdisk \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"networkData:"* ]]
  [[ "$output" == *"dhcp4: true"* ]]
  [[ "$output" == *"name: e* # Matches eth0"* ]]
}

# ---------------------------------------------------------------
# UDN-8: explicit cloud-init with UDN includes networkData
# ---------------------------------------------------------------
@test "UDN: explicit cloud-init includes DHCP networkData" {
  run bash "$VSTORM" -n --batch-id=udn008 --udn-l2 \
    --cloudinit=workload/cloudinit-stress-ng-workload.yaml \
    --datasource=rhel9 --no-snapshot --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"networkData:"* ]]
  [[ "$output" == *"dhcp4: true"* ]]
  [[ "$output" == *"stress-ng"* ]]
}

# ---------------------------------------------------------------
# UDN-9: dv-url without cloud-init has no networkData
# ---------------------------------------------------------------
@test "UDN: dv-url without cloud-init omits networkData" {
  run bash "$VSTORM" -n --batch-id=udn009 --udn-l2 \
    --dv-url=http://example.com/disk.qcow --no-snapshot \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"name: l2bridge"* ]]
  [[ "$output" != *"networkData:"* ]]
}

# ===============================================================
# Category 14: SSH services (UDN-10 through UDN-14)
# ===============================================================

# ---------------------------------------------------------------
# UDN-10: NodePort SSH services per namespace
# ---------------------------------------------------------------
@test "UDN: NodePort SSH service created per namespace" {
  run bash "$VSTORM" -n --batch-id=udn010 --udn-l2 --udn-ssh \
    --vms=2 --namespaces=2
  [ "$status" -eq 0 ]

  local svc_count
  svc_count=$(echo "$output" | grep -c "kind: Service")
  [ "$svc_count" -eq 2 ]

  [[ "$output" == *"type: NodePort"* ]]
  [[ "$output" == *"nodePort: 32222"* ]]
  [[ "$output" == *"nodePort: 32223"* ]]
  [[ "$output" == *"kubevirt.io/domain: vm"* ]]
  [[ "$output" == *"Creating SSH NodePort Service"* ]]
  [[ "$output" == *"UDN SSH: enabled (NodePort from 32222"* ]]
}

# ---------------------------------------------------------------
# UDN-11: ClusterIP SSH service
# ---------------------------------------------------------------
@test "UDN: ClusterIP SSH service has no nodePort" {
  run bash "$VSTORM" -n --batch-id=udn011 --udn-l2 --udn-ssh=clusterip \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"type: ClusterIP"* ]]
  [[ "$output" == *"name: ssh-clusterip-vm-udn011"* ]]
  [[ "$output" == *"Creating SSH ClusterIP Service"* ]]
  [[ "$output" == *"UDN SSH: enabled (ClusterIP)"* ]]
  [[ "$output" != *"nodePort:"* ]]
}

# ---------------------------------------------------------------
# UDN-12: NodePort allocation logged per namespace
# ---------------------------------------------------------------
@test "UDN: NodePort SSH ports auto-increment per namespace" {
  run bash "$VSTORM" -n --batch-id=udn012 --udn-l2 --udn-ssh \
    --vms=2 --namespaces=2
  [ "$status" -eq 0 ]

  [[ "$output" == *"Creating SSH NodePort Service ssh-nodeport-vm-udn012 on port 32222"* ]]
  [[ "$output" == *"Creating SSH NodePort Service ssh-nodeport-vm-udn012 on port 32223"* ]]
}

# ---------------------------------------------------------------
# UDN-13: ClusterIP service naming matches in-cluster hostname pattern
# ---------------------------------------------------------------
@test "UDN: ClusterIP service name matches in-cluster hostname pattern" {
  run bash "$VSTORM" -n --batch-id=udn013 --udn-l2 --udn-ssh=clusterip \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"name: ssh-clusterip-vm-udn013"* ]]
  [[ "$output" == *"namespace: vm-udn013-ns-1"* ]]
  [[ "$output" == *"Creating SSH ClusterIP Service ssh-clusterip-vm-udn013"* ]]
}

# ---------------------------------------------------------------
# UDN-14: without --udn-ssh, no Service resources
# ---------------------------------------------------------------
@test "UDN: without --udn-ssh, no SSH Service is created" {
  run bash "$VSTORM" -n --batch-id=udn014 --udn-l2 --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" != *"kind: Service"* ]]
  [[ "$output" == *"UDN SSH: disabled"* ]]
}
