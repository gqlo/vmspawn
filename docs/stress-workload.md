# Stress Workload Simulator

The stress workload simulator uses [stress-ng](https://github.com/ColinIanKing/stress-ng) to generate bursty CPU and memory load inside VMs. It is designed to simulate realistic, uneven workloads for testing live migration, scheduling, and resource management at scale.

## How it works

The simulator runs in an infinite loop of **cycles**. Each cycle:

1. Randomly decides whether the VM is **active** or **idle** (50/50 probability by default)
2. If active, runs `stress-ng` with randomized CPU load and memory pressure for a random duration
3. If idle, sleeps for a random duration
4. Repeats

This creates unpredictable, bursty resource consumption that is more realistic than a constant load.

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `BURST_MIN` | 5s | Minimum cycle duration |
| `BURST_MAX` | 600s | Maximum cycle duration |
| `ACTIVE_PROBABILITY` | 50% | Chance the VM is active in a given cycle |
| `CPU_LOAD_MIN` | 50% | Minimum CPU load when active |
| `CPU_LOAD_MAX` | 100% | Maximum CPU load when active |
| `CPU_CORES` | all (`nproc`) | Number of CPU cores to stress |
| `MEM_WORKERS` | 1 | Number of memory stress workers |
| `MAX_MEM_PERCENT` | 80% | Upper bound for random memory usage (20%-80%) |

## Deployment methods

### Via cloud-init (recommended)

Inject the workload into VMs at boot using `--cloudinit`:

```bash
./vmspawn --cloudinit=helpers/cloudinit-stress-workload.yaml --vms=10 --namespaces=2
```

The cloud-init config ([`helpers/cloudinit-stress-workload.yaml`](../helpers/cloudinit-stress-workload.yaml)) will:

1. Install `stress-ng` via the package manager
2. Write the workload script to `/opt/stress_ng_random_vm.sh`
3. Create and enable a `stress-workload.service` systemd unit that runs forever and survives reboots

### Standalone

Copy and run the script directly inside a VM:

```bash
scp helpers/stress_ng_random_vm.sh root@<vm-ip>:/opt/
ssh root@<vm-ip> 'chmod +x /opt/stress_ng_random_vm.sh && /opt/stress_ng_random_vm.sh'
```

## Files

| File | Description |
|---|---|
| [`helpers/cloudinit-stress-workload.yaml`](../helpers/cloudinit-stress-workload.yaml) | Cloud-init config that installs and enables the workload as a systemd service |
| [`helpers/stress_ng_random_vm.sh`](../helpers/stress_ng_random_vm.sh) | Standalone version of the workload script |

## Monitoring

Check the service status inside a VM:

```bash
systemctl status stress-workload.service
journalctl -u stress-workload.service -f
```

Example output:

```
Cycle 1: ACTIVE - Running stress test for 237 seconds...
  - CPU: 73%
  - Memory: 512 MB (aggressive, vm-keep)
Cycle 2: IDLE - Sleeping for 45 seconds...
Cycle 3: ACTIVE - Running stress test for 89 seconds...
  - CPU: 95%
  - Memory: 512 MB (aggressive, vm-keep)
```
