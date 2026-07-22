# Cloud-init and fio workload

Run a configurable fio storage I/O workload inside VMs at boot. For VM CPU and memory options (`--cores`, `--memory`, etc.), see the main [README](../README.md#options).

## Quick start: example commands

| Goal | Command |
|------|---------|
| Default (randrw) on medium VMs | `vstorm --cloudinit=workload/cloudinit-fio-workload.yaml --cores=4 --memory=8Gi --vms=10` |
| Mixed random read/write | `vstorm --cloudinit=workload/cloudinit-fio-workload.yaml --env WORKLOAD_TYPE=randrw --vms=5` |
| Sequential write, larger file | `vstorm --cloudinit=workload/cloudinit-fio-workload.yaml --env WORKLOAD_TYPE=seqwrite --env FIO_SIZE=4G --vms=5` |
| Custom block size and queue depth | `vstorm --cloudinit=workload/cloudinit-fio-workload.yaml --env FIO_BS=64k --env FIO_IODEPTH=64 --vms=10` |
| Short time-based cycles for quicker feedback | `vstorm --cloudinit=workload/cloudinit-fio-workload.yaml --env FIO_TIME_BASED=1 --env FIO_RUNTIME=15 --vms=5` |
| Dry-run to preview | `vstorm -n --cloudinit=workload/cloudinit-fio-workload.yaml --env WORKLOAD_TYPE=randread --vms=5` |

Default preset is **randrw** (no `--env` needed). Combine with any VM sizing.

## Image requirements and recommendation

**Default image link:** vstorm uses this disk image by default (override with `--dv-url` or `--datasource`):

**<http://storage.scalelab.redhat.com/lee/vm-images/rhel9-cloud-init.qcow>**

The workload **installs `fio` via the guest's package manager** at first boot. Use vstorm's **default QCOW image** (the URL above) or a **custom QCOW** that has **working DNF/Yum (or APT) repositories** — or has `fio` preinstalled.

**OCP OS images** (DataSources from `openshift-virtualization-os-images`, e.g. `rhel9`) are **minimal**: no enabled repos, no preinstalled `fio`. The workload will fail on them ("There are no enabled repositories" / "failed to install fio").

**We highly recommend using a customized QCOW image**: vstorm's default URL (if that image has repos), or `--dv-url` with your own QCOW2 (repos enabled or fio preinstalled), or a custom DataSource built from such an image. With `--datasource=rhel9` (or similar), the workload will not work unless the image is customized.

Ensure the guest root disk is large enough for `FIO_SIZE` (default `1G`) plus the OS; raise `--storage-size` if needed.

## Run at boot

```bash
vstorm --cloudinit=workload/cloudinit-fio-workload.yaml --vms=10 --namespaces=2
```

Cloud-init will install `fio`, write the workload script to `/opt/fio_workload.sh`, and enable `fio-workload.service` so the workload runs forever (and survives reboots). I/O targets a file under `/var/lib/fio` on the guest root filesystem (exercises the VM PVC/DV backing store).

## Workload presets: `WORKLOAD_TYPE`

| Preset | fio `--rw` | Default `FIO_BS` | Use case |
|--------|------------|------------------|----------|
| `randrw` | `randrw` | `4k` | Mixed random (50/50 unless `FIO_RWMIXREAD` set; default) |
| `randwrite` | `randwrite` | `4k` | Random write pressure |
| `randread` | `randread` | `4k` | Random read latency / IOPS |
| `seqwrite` | `write` | `4k` | Sequential write |
| `seqread` | `read` | `4k` | Sequential read |

```bash
# Default is randrw
vstorm --cloudinit=workload/cloudinit-fio-workload.yaml --cores=4 --memory=8Gi --vms=10

# Write-only or sequential
vstorm --cloudinit=workload/cloudinit-fio-workload.yaml --env WORKLOAD_TYPE=randwrite --vms=10
vstorm --cloudinit=workload/cloudinit-fio-workload.yaml --env WORKLOAD_TYPE=seqwrite --env FIO_SIZE=2G --vms=5
```

## Tuning: env overrides

Override with `--env KEY=VAL` (repeat as needed):

| Parameter | Description |
|-----------|-------------|
| `FIO_DIRECTORY` | Directory for the job file (default `/var/lib/fio`) |
| `FIO_SIZE` | File size per job (default `1G`) |
| `FIO_BS` | Block size (overrides preset default) |
| `FIO_IODEPTH` | Queue depth (default `16`) |
| `FIO_NUMJOBS` | Parallel jobs (default `1`) |
| `FIO_TIME_BASED` | `1` = add `--time_based --runtime`; `0` = no runtime limit (default) |
| `FIO_RUNTIME` | Seconds per cycle when `FIO_TIME_BASED=1` (default `60`) |
| `FIO_DIRECT` | `1` = O_DIRECT (default), `0` = buffered |
| `FIO_RW` | Override `--rw` independently of `WORKLOAD_TYPE` |
| `FIO_RWMIXREAD` | Read percentage for `randrw`/`rw` (default `50`) |
| `FIO_CUSTOM_OPTS` | When set, each cycle runs `fio $FIO_CUSTOM_OPTS` (plus time args only if `FIO_TIME_BASED=1`) |

```bash
# Custom block size and depth
vstorm --cloudinit=workload/cloudinit-fio-workload.yaml \
  --env FIO_BS=64k --env FIO_IODEPTH=64 \
  --cores=4 --memory=8Gi --vms=10

# Larger working set, time-based short cycles
vstorm --cloudinit=workload/cloudinit-fio-workload.yaml \
  --env WORKLOAD_TYPE=randrw --env FIO_SIZE=4G --env FIO_TIME_BASED=1 --env FIO_RUNTIME=30 --vms=5

# Custom fio options (script appends --time_based --runtime only when FIO_TIME_BASED=1)
vstorm --cloudinit=workload/cloudinit-fio-workload.yaml \
  --env 'FIO_CUSTOM_OPTS=--name=custom --filename=/var/lib/fio/custom.dat --rw=randread --bs=4k --iodepth=16 --size=512M --direct=1 --ioengine=libaio' \
  --vms=5
```

## Monitoring

From the host, use **helpers/log-vm** (uses `virtctl ssh`; set `STRESS_WORKLOAD_PASSWORD` to the VM root password from your cloud-init):

```bash
helpers/log-vm -u fio-workload.service <vm-name> <namespace> [lines]
# Example: helpers/log-vm -u fio-workload.service rhel9-abc123-1 vm-abc123-ns-1 30
```

Inside a VM (e.g. via `virtctl console` or SSH):

```bash
systemctl status fio-workload.service
journalctl -u fio-workload.service -f
```

Example output:

```
Starting fio workload (WORKLOAD_TYPE=randrw, running forever)
FIO_RW=randrw | FIO_BS=4k | FIO_IODEPTH=16 | FIO_NUMJOBS=1
FIO_SIZE=1G | FIO_TIME_BASED=0 (no runtime limit) | FIO_DIRECT=1 | FIO_DIRECTORY=/var/lib/fio
Cycle 1: ACTIVE - Running fio (randrw, bs=4k) until size=1G completes...
```

---

## Design and internals

For contributors and users who want to understand or extend the workload.

### Purpose and scope

- **Scope**: How vstorm injects cloud-init userdata into VMs, how that userdata is processed at first boot, the structure of the fio workload, and guest env injection via `--env`.

### End-to-end flow

1. User runs vstorm with `--cloudinit=workload/cloudinit-fio-workload.yaml`.
2. vstorm reads the file, replaces `{VSTORM_GUEST_ENV}` with `--env` lines if present, base64-encodes, and injects into the cloud-init Secret template.
3. A Secret is created per namespace; each VM references it via `cloudInitNoCloud.secretRef`.
4. On first boot, the guest runs cloud-init (`write_files`, `runcmd`, `packages`).

### Cloud-init modules used

| Module | Purpose |
|--------|---------|
| **write_files** | Script at `/opt/fio_workload.sh`, systemd unit, `/etc/default/vstorm-guest-env`. |
| **runcmd** | SSH config, `systemctl daemon-reload`, enable and start `fio-workload.service`. |
| **packages** | Installs `fio`. Requires working repos; not available on minimal OCP OS images. |

### File layout

| Location | Role |
|----------|------|
| **workload/** | Cloud-init YAML (e.g. `cloudinit-fio-workload.yaml`). |
| **templates/cloudinit-secret.yaml** | Secret template with `userdata: {CLOUDINIT_B64}`. |
| **vstorm** | Reads file, replaces `{VSTORM_GUEST_ENV}`, base64-encodes, substitutes into template. |

### Built-in workload structure

[workload/cloudinit-fio-workload.yaml](../workload/cloudinit-fio-workload.yaml): script at `/opt/fio_workload.sh`, systemd unit at
`/etc/systemd/system/fio-workload.service`, env from `--env` in `/etc/default/vstorm-guest-env`.
Each cycle runs fio against a file under `FIO_DIRECTORY` (default `/var/lib/fio`). By default (`FIO_TIME_BASED=0`) there is no `--time_based`/`--runtime`; each cycle runs until `--size` completes, then the outer loop restarts fio. Set `FIO_TIME_BASED=1` to add `--time_based --runtime=${FIO_RUNTIME}` (default `60`s).
**Deployment**: Via `--cloudinit` (recommended), or set env with `--env KEY=VAL`; or copy and run the script standalone inside a VM (`scp` + `ssh`).

### References

- [README.md](../README.md) — Custom cloud-init section
- [workload/cloudinit-fio-workload.yaml](../workload/cloudinit-fio-workload.yaml) — built-in workload cloud-init
- [cloud-init and stress-ng workload](cloud-init-stress-ng-workload.md) — sibling CPU/memory workload
