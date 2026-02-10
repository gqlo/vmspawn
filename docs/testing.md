# Testing

vmspawn uses [Bats](https://github.com/bats-core/bats-core) (Bash Automated Testing System) for unit tests and GitHub Actions for CI.

## How the tests work

All tests use **dry-run mode** (`-n` or `-q`). The script generates YAML to stdout instead of calling `oc apply`, so tests run instantly with no cluster required.

Each test:

1. Runs `vmspawn` with a fixed `--batch-id` and specific flags
2. Captures the full stdout/stderr via Bats `run`
3. Asserts on the generated YAML: resource kinds, names, namespaces, labels, template fields, and counts

This validates that the correct templates are selected, variables are substituted, and the creation flow (DV, snapshot, VM, cloud-init Secret) matches expectations.

## Running tests locally

```bash
# Run all tests
bats tests/

# Run a single test by name
bats tests/vmspawn.bats --filter "QS: default DataSource"
```

Bats is available via most package managers (`apt install bats`, `brew install bats-core`).

## Test categories

### Quick Start (QS-1 through QS-6)

One test per README Quick Start example. Each validates the full YAML output end-to-end:

| Test | Command | What it validates |
|---|---|---|
| QS-1 | `--vms=10 --namespaces=2` | DataSource DV (no explicit size), snapshot, 10 VMs, auto cloud-init, labels, VM spec |
| QS-2 | `--datasource=fedora --vms=5` | Fedora DataSource in DV, snapshot path, auto cloud-init |
| QS-3 | `--dv-url=... --vms=10` | URL import DV with explicit size, snapshot, 10 VMs, no auto cloud-init |
| QS-4 | `--cloudinit=...stress... --vms=10` | Custom cloud-init Secret per namespace, secretRef, not auto-applied |
| QS-5 | `-n --vms=10` | Dry-run outputs YAML, no `oc apply`, no completion message |
| QS-6 | `--delete=a3f7b2` | Delete dry-run shows correct `oc delete` command |

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
