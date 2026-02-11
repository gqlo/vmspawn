# Testing

vmspawn uses [Bats](https://github.com/bats-core/bats-core) (Bash Automated Testing System) for unit tests and GitHub Actions for CI.

## How the tests work

All tests use **dry-run mode** (`-n` or `-q`) unless they need live-mode behavior (StorageProfile auto-detection, WFFC handling), in which case they use a **mock `oc`** script. No real cluster is required.

Each test:

1. Runs `vmspawn` with a fixed `--batch-id` and specific flags
2. Captures the full stdout/stderr via Bats `run`
3. Asserts on the generated YAML: resource kinds, names, namespaces, labels, template fields, and counts

This validates that the correct templates are selected, variables are substituted, and the creation flow (DV, snapshot/no-snapshot, VM, cloud-init Secret) matches expectations.

## Running tests locally

```bash
# Run all tests
bats tests/

# Run a single test by name
bats tests/vmspawn.bats --filter "QS: default DataSource"
```

Bats is available via most package managers (`apt install bats`, `brew install bats-core`).

## Test categories

### Quick Start (QS-1 through QS-10)

One test per README Quick Start example. Each validates the full YAML output end-to-end:

| Test | Command | What it validates |
|---|---|---|
| QS-1 | `--vms=10 --namespaces=2` | DataSource DV, snapshot, 10 VMs, auto cloud-init, labels, VM spec |
| QS-2 | `--datasource=fedora --vms=5` | Fedora DataSource in DV, snapshot path, auto cloud-init |
| QS-3 | `--dv-url=... --vms=10` | URL import DV with explicit size, snapshot, 10 VMs, no auto cloud-init |
| QS-4 | `--cloudinit=...stress... --vms=10` | Custom cloud-init Secret per namespace, secretRef, not auto-applied |
| QS-5 | `--datasource=centos-stream9 --vms=5` | Different DataSource with default cloud-init auto-applied |
| QS-6 | `--storage-class=my-nfs-sc --vms=10` | Non-OCS storage class auto-disables snapshots, direct DataSource clone (no base DV) |
| QS-7 | `--storage-class=X --snapshot-class=Y --vms=10` | Custom storage + snapshot class pair keeps snapshots enabled |
| QS-8 | `--no-snapshot --vms=10` | Explicit no-snapshot mode, direct DataSource clone, auto cloud-init |
| QS-9 | `-n --vms=10` | Dry-run outputs YAML, no `oc apply`, no completion message |
| QS-10 | `--delete=a3f7b2` | Delete dry-run shows correct `oc delete` command |

### Dry-run YAML file tests

| Test | What it validates |
|---|---|
| YAML file saved | Dry-run creates a file with all resource types and document separators |
| Batch ID and namespaces | Correct batch ID and namespace names in the saved YAML file |
| No-snapshot YAML | DataSource clone (no PVC clone, no snapshot) in saved file |
| Quiet mode | `-q` mode does not create a YAML file |

### Core functionality

- **Batch ID** -- auto-generated 6-character hex ID
- **Namespace naming** -- `vm-{batch}-ns-{N}` pattern
- **VM distribution** -- even spread with remainder in first namespaces

### Validation / error handling

- `--delete` without a value is rejected
- Non-numeric positional arguments are rejected
- `--cloudinit` with a missing file fails
- `--dv-url=` with no URL fails

### YAML structure

Each Kubernetes resource type has a dedicated structure test:

| Test | Validates |
|---|---|
| DataSource DV | `storage:` API, accessModes, volumeMode, explicit size for WFFC compatibility |
| URL DV | `source.http.url`, explicit `storage: 50Gi` |
| VirtualMachine | metadata, runStrategy, dataVolumeTemplates, CPU/memory, devices, firmware, scheduling, volumes |
| VolumeSnapshot | apiVersion, snapshotClassName, PVC source |
| Namespace | apiVersion, name, batch-id label |
| Cloud-init Secret | apiVersion, name, namespace, type, userdata, labels |
| `--stop` flag | `runStrategy: Halted` |

### No-snapshot mode (NS-1 through NS-8)

Tests for `--no-snapshot` which skips VolumeSnapshots. With a DataSource, each VM's inline DataVolumeTemplate clones directly from the DataSource (no intermediate base DV). With a URL import, VMs still clone from a base PVC:

| Test | Command | What it validates |
|---|---|---|
| NS-1 | `--no-snapshot --vms=3` | Skips VolumeSnapshot creation, skips base DV, uses inline DataVolumeTemplates |
| NS-2 | `--no-snapshot --vms=2` | VMs use `sourceRef` (DataSource) not `source.pvc`, no `rhel9-base` reference |
| NS-3 | `--no-snapshot --dv-url=...` | URL import mode still creates base DV and uses PVC clone |
| NS-4 | `--no-snapshot --cloudinit=...` | Cloud-init works with direct DataSource clone |
| NS-5 | `--no-snapshot --vms=10 --namespaces=3` | Multiple namespaces with direct DataSource clone |
| NS-6 | `--no-snapshot --storage-class=my-sc` | Custom storage class applied, no base DV |
| NS-7 | `--snapshot` | Explicit `--snapshot` produces snapshot-based flow |
| NS-8 | `--no-snapshot --cores=4 --memory=8Gi` | `vm-datasource.yaml` template is well-formed with all fields |

### Direct DataSource clone (DC-1 through DC-10)

Tests for the direct DataSource clone path (no-snapshot + DataSource), where each VM's inline DataVolumeTemplate clones directly from the DataSource. This eliminates the intermediate base DV/PVC, avoiding WaitForFirstConsumer deadlocks:

| Test | Command | What it validates |
|---|---|---|
| DC-1 | `--no-snapshot --datasource=fedora` | Custom DataSource name propagates into each VM's inline DV `sourceRef` |
| DC-2 | `--no-snapshot --datasource=win2k22 --basename=win2k22` | DataSource name and namespace appear correctly in inline DV |
| DC-3 | `--no-snapshot --storage-size=50Gi` | Custom storage size propagates into inline DV's storage request |
| DC-4 | `--no-snapshot --vms=3` | Each VM gets a uniquely named DV (`rhel9-{batch}-1`, `-2`, `-3`), no `rhel9-base` |
| DC-5 | `--no-snapshot --vms=4 --namespaces=2` | Multi-namespace: no per-namespace base DV, each VM references DataSource |
| DC-6 | `--no-snapshot --dv-url=...` | URL import still creates base DV and uses PVC clone (old path preserved) |
| DC-7 | `--snapshot` | Snapshot mode still creates base DV + VolumeSnapshot (old path preserved) |
| DC-8 | `--no-snapshot --rwo` | `--rwo` access mode correctly applied to inline DV in `vm-datasource.yaml` |
| DC-9 | *(live mode, mock oc)* | Completion message shows "direct DataSource clone, no base DVs" |
| DC-10 | `--no-snapshot --stop` | `runStrategy: Halted` works with direct DataSource clone path |

### Auto-detection (AD-1 through AD-4)

Tests for automatic snapshot mode detection based on `--storage-class` and `--snapshot-class`:

| Test | Command | What it validates |
|---|---|---|
| AD-1 | `--storage-class=my-nfs-sc` | Custom storage class without snapshot-class auto-disables snapshots, uses direct DataSource clone |
| AD-2 | `--storage-class=my-rbd-sc --snapshot-class=my-snap` | Both classes provided keeps snapshots enabled |
| AD-3 | `--storage-class=my-ceph-sc --snapshot` | Explicit `--snapshot` overrides auto-detection |
| AD-4 | *(no storage flags)* | Default OCS storage class keeps snapshots enabled |

### Access mode options (AM-1 through AM-6)

Tests for `--access-mode`, `--rwo`, and `--rwx` CLI options:

| Test | Command | What it validates |
|---|---|---|
| AM-1 | *(default)* | Default access mode is `ReadWriteMany` |
| AM-2 | `--rwo --no-snapshot` | `--rwo` sets `ReadWriteOnce` on all resources, no `ReadWriteMany` |
| AM-3 | `--access-mode=ReadWriteOnce --no-snapshot` | Long-form option works |
| AM-4 | `--rwx` | `--rwx` sets `ReadWriteMany` |
| AM-5 | `--rwo --snapshot` | `--rwo` applies to snapshot-based VMs too |
| AM-6 | `--rwo --no-snapshot --dv-url=...` | `--rwo` with URL import mode |

### StorageProfile auto-detection (SP-1 through SP-5)

Live-mode tests using a **mock `oc`** that returns configured `StorageProfile` access modes:

| Test | Mock returns | What it validates |
|---|---|---|
| SP-1 | `ReadWriteOnce` | Auto-detects RWO from StorageProfile (e.g. LVMS) |
| SP-2 | `ReadWriteMany` | Auto-detects RWX from StorageProfile (e.g. OCS/Ceph) |
| SP-3 | *(unavailable)* | Falls back to default `ReadWriteMany` with warning |
| SP-4 | `ReadWriteMany` + `--rwo` | Explicit `--rwo` overrides StorageProfile RWX |
| SP-5 | `ReadWriteOnce` + `--rwx` | Explicit `--rwx` overrides StorageProfile RWO |

### WaitForFirstConsumer handling (WFFC-1 through WFFC-4)

Live-mode tests using a mock `oc` that simulates WaitForFirstConsumer (WFFC) storage classes:

| Test | Scenario | What it validates |
|---|---|---|
| WFFC-1 | WFFC + DataSource + no-snapshot | Skips base DV entirely (direct DataSource clone avoids deadlock) |
| WFFC-2 | WFFC + URL import + no-snapshot | Skips DV wait, proceeds to VM creation (VMs trigger PVC binding) |
| WFFC-3 | Immediate binding + URL import | Normal DV wait (no skip), all DVs complete before VMs |
| WFFC-4 | WFFC in dry-run | WFFC warning shown when `oc` is available in dry-run |

## Three clone paths

vmspawn uses three different clone strategies depending on the mode:

```text
1. Snapshot mode (default for OCS storage):
   DataSource → base DV/PVC → VolumeSnapshot → VM DVs clone from snapshot

2. No-snapshot + DataSource (default for non-OCS storage):
   DataSource → VM DVs clone directly from DataSource (no base DV)

3. No-snapshot + URL import (--dv-url):
   URL → base DV/PVC → VM DVs clone from base PVC
```

Path 2 was introduced to eliminate the intermediate base DV, which caused WaitForFirstConsumer deadlocks with local storage (e.g. LVMS). Each VM's Pod directly acts as the WFFC consumer for its own DV.

## CI pipeline

GitHub Actions runs three jobs on every push and PR to `main`:

| Job | Tool | Scope |
|---|---|---|
| `test` | `bats` | All tests in `tests/` |
| `lint-yaml` | `yamllint` | `helpers/*.yaml` |
| `lint-markdown` | `markdownlint-cli2` | All `*.md` files |

Configuration files:

- `.yamllint` -- relaxes line length (200), disables document-start and truthy checks, allows `#cloud-config` comments
- `.markdownlint.yaml` -- increases line length (400), disables MD040 and MD060
