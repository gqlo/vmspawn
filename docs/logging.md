# Logging and Batch Manifests

vstorm produces two types of output files in the `logs/` directory: **log files** for detailed operation history and **manifest files** for batch inventory.

## Log files

Every live run (non-dry-run) writes a timestamped log file:

```
logs/{BATCH_ID}-{YYYY}-{MM}-{DD}T{HH}:{MM}:{SS}Z.log
```

For example: `logs/a3f7b2-2026-02-11T14:30:05Z.log`

The batch ID is prepended so you can easily find the log for a specific batch:

```bash
# Find logs for a specific batch
ls logs/a3f7b2-*.log

# List all logs sorted by time
ls -lt logs/*.log
```

### What gets logged

Each log entry is prefixed with a UTC `YYYY-MM-DDTHH:MM:SSZ` timestamp. The log captures the full lifecycle:

1. **Configuration** -- batch ID, VM count, namespaces, storage class, snapshot mode, CPU/memory, cloud-init
2. **Prerequisite checks** -- oc CLI, OpenShift Virtualization, storage class validation
3. **Namespace creation** -- which namespaces are created or skipped (already exist)
4. **DataVolume creation** -- one per namespace, with status polling (Pending, Running, Succeeded, Failed)
5. **VolumeSnapshot creation** *(snapshot mode only)* -- one per namespace, with readiness polling
6. **VM creation** -- each VM logged individually with namespace and ID
7. **VM readiness** *(with --wait)* -- periodic progress updates (`5/10 ready`)
8. **Completion summary** -- total resources created

### Log output

Log messages are written to both the terminal (stdout) and the log file simultaneously via `tee`. In dry-run mode (`-n`), messages go to stdout only with no timestamps (since no real operations occur).

### Example log output

```
2026-02-11T14:30:05Z Log file created: logs/a3f7b2-2026-02-11T14:30:05Z.log
2026-02-11T14:30:05Z Prerequisites OK: oc CLI, OpenShift Virtualization, storage class 'ocs-storagecluster-ceph-rbd-virtualization', snapshot class 'ocs-storagecluster-rbdplugin-snapclass'
2026-02-11T14:30:05Z Starting resource creation process...
2026-02-11T14:30:05Z Batch ID:      a3f7b2
2026-02-11T14:30:05Z Configuration: 10 VMs across 2 namespaces
2026-02-11T14:30:05Z DataSource:    rhel9 (from openshift-virtualization-os-images)
2026-02-11T14:30:05Z Storage class: ocs-storagecluster-ceph-rbd-virtualization
2026-02-11T14:30:05Z Snapshot mode: enabled (class: ocs-storagecluster-rbdplugin-snapclass)
2026-02-11T14:30:05Z VM CPU cores:  4
2026-02-11T14:30:05Z VM memory:     8Gi
2026-02-11T14:30:05Z Cloud-init:    helpers/cloudinit-default.yaml
2026-02-11T14:30:05Z Run strategy:  Always
2026-02-11T14:30:05Z Creating namespaces...
2026-02-11T14:30:06Z Creating namespace: vm-a3f7b2-ns-1
2026-02-11T14:30:06Z Creating namespace: vm-a3f7b2-ns-2
2026-02-11T14:30:06Z Creating DataVolumes...
...
2026-02-11T14:31:20Z All DataVolumes are completed successfully!
2026-02-11T14:31:20Z Creating VolumeSnapshots...
...
2026-02-11T14:31:45Z Creating VirtualMachines...
2026-02-11T14:31:45Z Creating VirtualMachine 1 for namespace: vm-a3f7b2-ns-1
...
2026-02-11T14:31:50Z Resource creation completed successfully!
2026-02-11T14:31:50Z Created 2 namespaces, 2 DataVolumes, 2 VolumeSnapshots, and 10 total VirtualMachines
```

## Manifest files

After each successful run, a manifest file is written:

```
logs/batch-{BATCH_ID}.manifest
logs/batch-{BATCH_ID}.manifest.json   # full JSON body POSTed to RESULT_SERVER_URL (when set)
logs/batch-{BATCH_ID}.dv-created.json # DV/PVC timestamp collect sidecar (when non-empty)
```

For example: `logs/batch-a3f7b2.manifest`

The text manifest is a YAML-like summary of what was created:

```yaml
batch-id: a3f7b2
created: 2026-02-11T14:30:05Z
basename: rhel9
total-vms: 10
total-namespaces: 2
namespaces: vm-a3f7b2-ns-1, vm-a3f7b2-ns-2
vms: vm-a3f7b2-ns-1/rhel9-a3f7b2-1, vm-a3f7b2-ns-1/rhel9-a3f7b2-2, ...
```

When `RESULT_SERVER_URL` is supplied via vstorm `--env RESULT_SERVER_URL=...` (not merely a shell-exported variable), vstorm also POSTs the same kind of inventory to the workload-result collector as JSON (`record_type: "manifest"`) and **keeps** that body at `logs/batch-{id}.manifest.json` (pretty-printed) for inspection. See [workload result sync and dashboard](workload-result-sync-and-dashboard.md).

### Listing batches

```bash
# List all batch manifests
ls logs/*.manifest*

# View a specific batch manifest (text summary)
cat logs/batch-a3f7b2.manifest

# View the exact JSON uploaded to the result server
cat logs/batch-a3f7b2.manifest.json
```

### Cleanup

When you delete a batch with `--delete`, the manifest file is automatically removed along with the Kubernetes resources. Log files are kept for historical reference.

## Dry-run YAML files

When running in dry-run mode (`-n`), the generated YAML is saved automatically:

```
logs/{BATCH_ID}-dryrun.yaml
```

For example: `logs/a3f7b2-dryrun.yaml`

This file contains all the Kubernetes resources that would be created, separated by `---` document markers. You can inspect it or apply it manually:

```bash
# Preview what would be created
./vstorm -n --batch-id=a3f7b2 --vms=10 --namespaces=2

# Apply the saved YAML later
oc apply -f logs/a3f7b2-dryrun.yaml
```

The YAML is also printed to stdout as before. Quiet mode (`-q`) does not produce a dry-run file.

## Directory structure

```
logs/
  a3f7b2-2026-02-11T14:30:05.log    # operation log for batch a3f7b2
  a3f7b2-dryrun.yaml                 # dry-run YAML output for batch a3f7b2
  batch-a3f7b2.manifest              # resource inventory for batch a3f7b2
  c1d2e3-2026-02-11T15:00:10.log    # operation log for batch c1d2e3
  batch-c1d2e3.manifest              # resource inventory for batch c1d2e3
```

The `logs/` directory is created automatically on the first run. It is not committed to version control.
