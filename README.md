# vmspawn

Batch VM creation tool for OpenShift Virtualization.

Creates VirtualMachines at scale with **cloud-init injection** to customize VMs at boot (e.g. install packages, start services, configure SSH). Includes ready-to-use workload scripts (in `helpers/`) that can be injected at boot via `--cloudinit` -- for example, `cloudinit-stress-workload.yaml` installs and runs **stress-ng** to generate CPU, memory load on each VM. More workload scripts will be added over time.
By default it clones from OCP's built-in **DataSources** (e.g. `rhel9`, `fedora`) -- no disk URL needed. Pass `--dv-url` to import a custom QCOW2 instead.
Each run is tagged with a unique **batch ID** for easy management -- list, inspect, or delete an entire batch with a single command, and spawn additional VMs at any time without worrying about name or namespace conflicts.

## Prerequisites

- `oc` CLI logged into an OpenShift cluster
- OpenShift Virtualization operator installed (`openshift-cnv` namespace)
- A storage class that supports `ReadWriteMany` block volumes
- **With snapshots (default for OCS):** OpenShift Data Foundation with Ceph RBD storage class and a matching VolumeSnapshotClass
- **Without snapshots:** any compatible storage class -- pass `--storage-class=CLASS` and snapshots are auto-disabled

## Quick start

```bash
# Create 10 RHEL9 VMs (4 cores, 8Gi memory) using default OCS storage class
./vmspawn --cores=4 --memory=8Gi --vms=10 --namespaces=2

# Use a different DataSource (e.g. Fedora) with default OCS storage
./vmspawn --datasource=fedora --vms=5 --namespaces=1

# Import a custom QCOW2 instead of using a DataSource (default OCS storage)
./vmspawn --dv-url=http://myhost:8000/rhel9-disk.qcow2 --vms=10 --namespaces=2

# Create VMs with a cloud-init workload injected at boot (default OCS storage)
./vmspawn --cloudinit=helpers/cloudinit-stress-workload.yaml --vms=10 --namespaces=2

# Use a different DataSource with default OCS storage (root password: password)
./vmspawn --datasource=centos-stream9 --vms=5 --namespaces=1

# Use a non-OCS storage class (snapshots auto-disabled)
./vmspawn --storage-class=my-nfs-sc --vms=10 --namespaces=2

# Use a custom storage class with snapshots (provide both classes)
./vmspawn --storage-class=my-rbd-sc --snapshot-class=my-rbd-snap --vms=10 --namespaces=2

# Explicitly disable snapshots on default OCS storage
./vmspawn --no-snapshot --vms=10 --namespaces=2

# Dry-run to preview generated YAML without applying (default OCS storage)
./vmspawn -n --vms=10 --namespaces=2

# Delete all resources for a batch
./vmspawn --delete=a3f7b2
```

## How it works

Each invocation auto-generates a 6-character hex **batch ID** (e.g. `a3f7b2`). This ID is embedded in every resource name and applied as a Kubernetes label, making each run fully isolated.

The tool performs these steps in order:

1. **Create namespaces** -- `vm-{batch}-ns-1`, `vm-{batch}-ns-2`, ...
2. **Create base disk** -- one DataVolume per namespace, either cloned from an OCP DataSource (default) or imported from a URL (`--dv-url`)
3. **Snapshot base disk** *(snapshot mode only)* -- creates a VolumeSnapshot per namespace for fast cloning
4. **Create VMs** -- clones VMs from the snapshot (snapshot mode) or directly from the base PVC (no-snapshot mode)

### Snapshot vs. no-snapshot mode

By default, vmspawn uses VolumeSnapshots for efficient cloning (each VM clones from a snapshot of the base disk). This requires a storage class that supports snapshots, such as OCS/ODF with Ceph RBD.

For storage classes without snapshot support, vmspawn clones each VM directly from the base PVC. This is auto-detected based on the options you provide:

| Options | Snapshot mode |
|---|---|
| *(defaults -- OCS storage)* | Enabled |
| `--storage-class=X` *(no snapshot-class)* | **Auto-disabled** |
| `--storage-class=X --snapshot-class=Y` | Enabled (matching pair) |
| `--no-snapshot` | Disabled (explicit) |
| `--snapshot` | Enabled (explicit override) |

In DataSource mode (default), a cloud-init is auto-injected to enable root SSH with password `password`.

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

A manifest file (`logs/batch-{BATCH_ID}.manifest`) is written after each run with a summary of all created resources. See [docs/logging.md](docs/logging.md) for details on log files, manifests, and the `logs/` directory structure.

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
    --storage-class=class       Storage class name (auto-disables snapshots
                                unless --snapshot-class is also provided)
    --snapshot-class=class      Snapshot class name (implies --snapshot)
    --snapshot                  Use VolumeSnapshots for cloning (default for OCS)
    --no-snapshot               Clone VMs directly from PVC (no snapshot needed)
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

- **Root password**: `password`
- **PasswordAuthentication**: enabled in sshd
- **PermitRootLogin**: enabled in sshd

```bash
# VMs are reachable via: ssh root@<vm-ip>  (password: password)
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
  logging.md         # logging, manifests, and logs/ directory structure
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
  vm-clone.yaml      # VirtualMachine template (clone from PVC, no-snapshot mode)
  cloudinit-secret.yaml  # cloud-init userdata Secret template
tests/
  vmspawn.bats       # unit tests (run with: bats tests/)
logs/                # created at runtime -- logs and batch manifests
```
