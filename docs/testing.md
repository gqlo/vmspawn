# Testing

vmspawn uses [Bats](https://github.com/bats-core/bats-core) (Bash Automated Testing System) for unit tests and GitHub Actions for CI.

## How the tests work

All tests use **dry-run mode** (`-n` or `-q`). The script generates YAML to stdout instead of calling `oc apply`, so tests run instantly with no cluster required.

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
| QS-1 | `--vms=10 --namespaces=2` | DataSource DV (no explicit size), snapshot, 10 VMs, auto cloud-init, labels, VM spec |
| QS-2 | `--datasource=fedora --vms=5` | Fedora DataSource in DV, snapshot path, auto cloud-init |
| QS-3 | `--dv-url=... --vms=10` | URL import DV with explicit size, snapshot, 10 VMs, no auto cloud-init |
| QS-4 | `--cloudinit=...stress... --vms=10` | Custom cloud-init Secret per namespace, secretRef, not auto-applied |
| QS-5 | `--datasource=centos-stream9 --vms=5` | Different DataSource with default cloud-init auto-applied |
| QS-6 | `--storage-class=my-nfs-sc --vms=10` | Non-OCS storage class auto-disables snapshots, PVC clone |
| QS-7 | `--storage-class=X --snapshot-class=Y --vms=10` | Custom storage + snapshot class pair keeps snapshots enabled |
| QS-8 | `--no-snapshot --vms=10` | Explicit no-snapshot mode, PVC clone, auto cloud-init |
| QS-9 | `-n --vms=10` | Dry-run outputs YAML, no `oc apply`, no completion message |
| QS-10 | `--delete=a3f7b2` | Delete dry-run shows correct `oc delete` command |

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
| DataSource DV | `storage:` API without explicit size, accessModes, volumeMode |
| URL DV | `source.http.url`, explicit `storage: 50Gi` |
| VirtualMachine | metadata, runStrategy, dataVolumeTemplates, CPU/memory, devices, firmware, scheduling, volumes |
| VolumeSnapshot | apiVersion, snapshotClassName, PVC source |
| Namespace | apiVersion, name, batch-id label |
| Cloud-init Secret | apiVersion, name, namespace, type, userdata, labels |
| `--stop` flag | `runStrategy: Halted` |

### No-snapshot mode (NS-1 through NS-8)

Tests for `--no-snapshot` which skips VolumeSnapshots and clones VMs directly from PVC:

| Test | Command | What it validates |
|---|---|---|
| NS-1 | `--no-snapshot --vms=3` | Skips VolumeSnapshot creation, uses PVC clone template |
| NS-2 | `--no-snapshot --vms=2` | VMs use `source.pvc` instead of `source.snapshot`, no `smartCloneFromExistingSnapshot` |
| NS-3 | `--no-snapshot --dv-url=...` | URL import mode works with no-snapshot |
| NS-4 | `--no-snapshot --cloudinit=...` | Cloud-init works with no-snapshot |
| NS-5 | `--no-snapshot --vms=10 --namespaces=3` | Multiple namespaces with no-snapshot |
| NS-6 | `--no-snapshot --storage-class=my-sc` | Custom storage class applied to all resources |
| NS-7 | `--snapshot` | Explicit `--snapshot` produces snapshot-based flow |
| NS-8 | `--no-snapshot --cores=4 --memory=8Gi` | `vm-clone.yaml` template is well-formed |

### Auto-detection (AD-1 through AD-4)

Tests for automatic snapshot mode detection based on `--storage-class` and `--snapshot-class`:

| Test | Command | What it validates |
|---|---|---|
| AD-1 | `--storage-class=my-nfs-sc` | Custom storage class without snapshot-class auto-disables snapshots |
| AD-2 | `--storage-class=my-rbd-sc --snapshot-class=my-snap` | Both classes provided keeps snapshots enabled |
| AD-3 | `--storage-class=my-ceph-sc --snapshot` | Explicit `--snapshot` overrides auto-detection |
| AD-4 | *(no storage flags)* | Default OCS storage class keeps snapshots enabled |

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
