# vmspawn

Batch VM creation tool for OpenShift Virtualization.

Creates VirtualMachines at scale by importing a base disk image, snapshotting it, and cloning VMs from the snapshot. Each run is tagged with a unique **batch ID** so you can spawn additional VMs at any time without worrying about name or namespace conflicts.

## Prerequisites

- `oc` CLI logged into an OpenShift cluster
- OpenShift Virtualization (`openshift-cnv` namespace)
- OpenShift Data Foundation (`openshift-storage` namespace)
- A Ceph RBD storage class (default: `ocs-storagecluster-ceph-rbd-virtualization`)

## Quick start

```bash
# Create 10 VMs spread across 2 namespaces
./vmspawn --vms=10 --namespaces=2

# Add 5 more VMs later (no conflicts -- new batch ID is auto-generated)
./vmspawn --vms=5 --namespaces=1

# Dry-run to preview generated YAML without applying
./vmspawn -n --vms=10 --namespaces=2

# Delete all resources for a batch
./vmspawn --delete=a3f7b2
```

## How it works

Each invocation auto-generates a 6-character hex **batch ID** (e.g. `a3f7b2`). This ID is embedded in every resource name and applied as a Kubernetes label, making each run fully isolated.

The tool performs four steps in order:

1. **Create namespaces** -- `vm-{batch}-ns-1`, `vm-{batch}-ns-2`, ...
2. **Import base disk** -- creates a DataVolume per namespace that downloads the QCOW2 image
3. **Snapshot base disk** -- creates a VolumeSnapshot per namespace for fast cloning
4. **Create VMs** -- clones VMs from the snapshot: `{basename}-{batch}-1`, `{basename}-{batch}-2`, ...

VMs are distributed evenly across namespaces, with any remainder allocated to the first namespaces.

## Resource naming

| Resource | Name pattern | Example |
|---|---|---|
| Namespace | `vm-{batch}-ns-{N}` | `vm-a3f7b2-ns-1` |
| DataVolume (base) | `{basename}-base` | `rhel9-base` |
| VolumeSnapshot | `{basename}-vm-{batch}-ns-{N}` | `rhel9-vm-a3f7b2-ns-1` |
| VirtualMachine | `{basename}-{batch}-{ID}` | `rhel9-a3f7b2-3` |

## Labels

All resources are labeled for easy querying:

- `batch-id` -- the batch ID for this run
- `vm-basename` -- the base image name (on DataVolumes, VolumeSnapshots, and VMs)

## Deleting batches

Use `--delete` to remove all resources for a batch:

```bash
# Preview what would be deleted
./vmspawn -n --delete=a3f7b2

# Delete all resources for a batch
./vmspawn --delete=a3f7b2
```

This deletes the batch's namespaces, which cascades and removes all VMs, DataVolumes, VolumeSnapshots, and PVCs inside them. The batch manifest file is also cleaned up.

To delete all batches at once via `oc` directly:

```bash
oc delete ns -l batch-id
```

## Inspecting batches

After creation, the tool prints ready-to-use commands:

```bash
# List all VMs in a batch
oc get vm -A -l batch-id=a3f7b2

# List all namespaces in a batch
oc get ns -l batch-id=a3f7b2

# List all batch manifest files
ls logs/*.manifest
```

A manifest file (`logs/batch-{BATCH_ID}.manifest`) is written after each run with a summary of all created resources.

## Options

```
Usage: vmspawn [options] [number_of_vms [number_of_namespaces]]

    -n                          Dry-run (show YAML without applying)
    -q                          Quiet (show only log messages)
    -h                          Show help

    --batch-id=ID               Set batch ID (auto-generated if omitted)
    --basename=name             VM base name (default: rhel9)
    --vms=N                     Total number of VMs (default: 1)
    --namespaces=N              Number of namespaces (default: 1)
    --vms-per-namespace=N       VMs per namespace (overrides --vms)

    --dv-url=URL                Disk image URL
    --storage-size=N            Storage size (default: 22Gi)
    --storage-class=class       Storage class name
    --snapshot-class=class      Snapshot class name
    --pvc-base-name=name        Base PVC name (default: rhel9-base)

    --cores=N                   VM CPU cores (default: 1)
    --memory=N                  VM memory (default: 1Gi)
    --request-cpu=N             CPU request (defaults to cores)
    --request-memory=N          Memory request (defaults to memory)

    --run-strategy=strategy     Run strategy (default: Always)
    --start                     Start VMs (equivalent to --run-strategy=Always)
    --stop                      Don't start VMs (equivalent to --run-strategy=Halted)
    --wait                      Wait for all VMs to reach Running state
    --nowait                    Don't wait (default)

    --delete=BATCH_ID           Delete all resources for the given batch
```

## Project layout

```
vmspawn              # main script
templates/
  namespace.yaml     # namespace template
  dv.yaml            # DataVolume template (base disk import)
  volumesnap.yaml    # VolumeSnapshot template
  vm-snap.yaml       # VirtualMachine template (clone from snapshot)
tests/
  vmspawn.bats       # unit tests (run with: bats tests/)
logs/                # created at runtime -- logs and batch manifests
```
