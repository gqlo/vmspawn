# vmspawn

Batch VM creation tool for OpenShift Virtualization.

Creates VirtualMachines at scale with **cloud-init injection** to customize VMs at boot (e.g. install packages, start services, configure SSH). By default it clones from OCP's built-in **DataSources** (e.g. `rhel9`, `fedora`) -- no disk URL needed. Pass `--dv-url` to import a custom QCOW2 instead. Each run is tagged with a unique **batch ID** so you can spawn additional VMs at any time without worrying about name or namespace conflicts.

## Prerequisites

- `oc` CLI logged into an OpenShift cluster
- OpenShift Virtualization operator installed (`openshift-cnv` namespace)
- OpenShift Data Foundation operator installed (`openshift-storage` namespace)
- Ceph RBD storage class available (default: `ocs-storagecluster-ceph-rbd-virtualization`)

## Quick start

```bash
# Create 10 RHEL9 VMs from the built-in DataSource (default)
./vmspawn --vms=10 --namespaces=2

# Use a different DataSource (e.g. Fedora)
./vmspawn --datasource=fedora --vms=5 --namespaces=1

# Import a custom QCOW2 instead of using a DataSource
./vmspawn --dv-url=http://myhost:8000/rhel9-disk.qcow2 --vms=10 --namespaces=2

# Create VMs with a cloud-init workload injected at boot
./vmspawn --cloudinit=helpers/cloudinit-stress-workload.yaml --vms=10 --namespaces=2

# Use a different DataSource with the default cloud-init (root password: 100yard-)
./vmspawn --datasource=centos-stream9 --vms=5 --namespaces=1

# Dry-run to preview generated YAML without applying
./vmspawn -n --vms=10 --namespaces=2

# Delete all resources for a batch
./vmspawn --delete=a3f7b2
```

## How it works

Each invocation auto-generates a 6-character hex **batch ID** (e.g. `a3f7b2`). This ID is embedded in every resource name and applied as a Kubernetes label, making each run fully isolated.

The tool performs four steps in order:

1. **Create namespaces** -- `vm-{batch}-ns-1`, `vm-{batch}-ns-2`, ...
2. **Create base disk** -- one DataVolume per namespace, either cloned from an OCP DataSource (default) or imported from a URL (`--dv-url`)
3. **Snapshot base disk** -- creates a VolumeSnapshot per namespace for fast cloning
4. **Create VMs** -- clones VMs from the local snapshot: `{basename}-{batch}-1`, `{basename}-{batch}-2`, ...

In DataSource mode (default), a cloud-init is auto-injected to enable root SSH with password `100yard-`.

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

    --datasource=NAME           Clone from OCP DataSource (default: rhel9)
    --dv-url=URL                Import disk from URL (overrides --datasource)
    --storage-size=N            Storage size for --dv-url mode (default: 22Gi)
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

    --cloudinit=FILE            Inject cloud-init user-data from FILE into each VM
    --delete=BATCH_ID           Delete all resources for the given batch
```

## Cloud-init

Cloud-init user-data is stored in a per-namespace Kubernetes Secret and referenced via `cloudInitNoCloud.secretRef`, so there is no size limit and nothing needs to be baked into the disk image.

### Default cloud-init (DataSource mode)

When using a DataSource (the default), a built-in cloud-init (`helpers/cloudinit-default.yaml`) is automatically injected if no `--cloudinit` is specified. It configures:

- **Root password**: `100yard-`
- **PasswordAuthentication**: enabled in sshd
- **PermitRootLogin**: enabled in sshd

```bash
# VMs are reachable via: ssh root@<vm-ip>  (password: 100yard-)
./vmspawn --vms=10 --namespaces=2
```

To override, pass your own file with `--cloudinit=FILE`. In URL mode (`--dv-url`), no cloud-init is injected unless explicitly requested.

### Custom cloud-init

Use `--cloudinit=FILE` to inject any cloud-init user-data file:

```bash
./vmspawn --cloudinit=helpers/cloudinit-stress-workload.yaml --vms=10 --namespaces=2
```

The `cloudinit-stress-workload.yaml` config installs `stress-ng` and runs a bursty workload simulator as a systemd service. See [docs/stress-workload.md](docs/stress-workload.md) for details.

## Project layout

```
vmspawn              # main script
docs/
  stress-workload.md # stress-ng workload simulator documentation
  testing.md         # how tests work, categories, and CI pipeline
helpers/
  install-virtctl    # download and install virtctl from the cluster
  vm-ssh             # quick virtctl SSH wrapper
  vm-export          # export a VM disk as a qcow2 image
  stress_ng_random_vm.sh            # standalone stress-ng workload script
  cloudinit-default.yaml            # default cloud-init (root password SSH)
  cloudinit-stress-workload.yaml    # cloud-init user-data for stress workload
templates/
  namespace.yaml     # namespace template
  dv.yaml            # DataVolume template (import from URL)
  dv-datasource.yaml # DataVolume template (clone from DataSource)
  volumesnap.yaml    # VolumeSnapshot template
  vm-snap.yaml       # VirtualMachine template (clone from snapshot)
  cloudinit-secret.yaml  # cloud-init userdata Secret template
tests/
  vmspawn.bats       # unit tests (run with: bats tests/)
logs/                # created at runtime -- logs and batch manifests
```
