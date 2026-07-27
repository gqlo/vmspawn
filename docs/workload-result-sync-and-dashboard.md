# Workload result sync and dashboard

Design for capturing guest workload results (initially fio), syncing host-side vstorm **manifests** (run inventory), and controlling **when / how often** a guest workload runs from a web dashboard — not only forever loops.

Related: [cloud-init and fio workload](cloud-init-fio-workload.md), [logging and batch manifests](logging.md). Collector: [`monitoring/workload-result/`](../monitoring/workload-result/). First guest integration: [`workload/cloudinit-fio-workload.yaml`](../workload/cloudinit-fio-workload.yaml). Same control + result schema is intended for other workloads later (e.g. stress-ng).

## Goals

- **Flexible run control from the dashboard** for each VM (or whole batch):
  - **idle** — do not run the workload (dashboard **Idle** button; also the API `stop` mode, which collapses to idle)
  - **once** — run one cycle, then idle
  - **count N** — run N cycles, then idle
  - **forever** — keep cycling until policy is set back to idle
- After each completed guest cycle, POST structured JSON (metrics + identity) to a collector.
- Dashboard home: **list of vstorm runs**, each with a **VM status summary** (configured / checked in / idle / running / queued / waiting / error / stale); drill into VMs and payloads; charts; archive/notes/delete.
- From **vstorm on the host**, once per run, POST a **manifest** (inventory + sizing + cmdline); join guest cycles on `batch_id`.
- Work for **fio first**, but keep the control plane workload-agnostic (`workload_kind` on results; run policy applies to the guest workload service, e.g. `fio-workload.service`).

## Non-goals (v1)

- Pushing commands **into** the guest (no inbound HTTP/SSH/`virtctl` required for control)
- Time-based fio as the only cycle definition (`FIO_TIME_BASED=1` remains supported as a cycle length, not as the control model)
- Embedding raw vstorm stdout into every guest cycle payload
- Grafana / Prometheus wiring for guest workload JSON (existing Grafana under [`monitoring/dashboard/`](../monitoring/dashboard/) stays for CNV/Prom)
- Host-side harvest of guest journals via `virtctl` / `helpers/log-vm`
- Multi-user RBAC or multi-tenant isolation
- TLS / HTTPS for the collector (v1 is plain **HTTP** on a trusted/lab network)
- Live rewriting of fio tunables mid-cycle from the dashboard (policy is “how many cycles”; env/cloud-init still sets size/bs/etc. for v1)

## Assumptions

| Decision | Choice |
|----------|--------|
| Control direction | **Pull**: guests poll the collector for desired run policy (VMs usually have egress only) |
| Cycle unit | One workload invocation (for fio: one size- or time-based job); then re-check policy |
| Default at boot | With `RESULT_SERVER_URL`: default **idle** (wait for dashboard). Override with `WORKLOAD_RUN_MODE=forever` for soak. Without URL: forever loop, no poll. |
| Transport | **HTTP** (not HTTPS) JSON over a reachable lab network: guests POST results + GET policy; vstorm POSTs manifests. Example: `http://<host>:8080/v1/results`. TLS out of scope for v1; optional bearer token still allowed. |
| Record types | `manifest` (host inventory) \| `result` (finished workload job) \| `error` (incident) \| `heartbeat` (agent state); join on `batch_id` |
| Server role | One process: ingest + policy store + query + dashboard |
| Collector | Python (`monitoring/workload-result/serve.py`), stdlib preferred |

## Current gap

Status vs this design (as of the current tree).

### Done

| Area | Status |
|------|--------|
| Guest capture | Timestamps, fio JSON, result/error/heartbeat payloads, POST + pending spool when `RESULT_SERVER_URL` is set. |
| Run control (poll) | Guest polls `GET /v1/policy` before each cycle; default `WORKLOAD_RUN_MODE=idle` when URL is set. |
| Policy API | `GET /v1/policy`, `PUT .../vms/{vm}/policy`, `POST .../batches/{id}/policy` fan-out; remaining decrements on **result** ingest. |
| Per-VM + batch dashboard controls | VM page and run page: Run once / Run N / Forever / Idle. |
| VM status rollups | Home + run detail: configured / checked in / idle / running / queued / waiting / error / stale. |
| Host manifest | **vstorm** POSTs `record_type: "manifest"` / `source: "vstorm"` after create (and after `--wait`) when `RESULT_SERVER_URL` is in `--env`; includes `log_path` + truncated `log_text`. Same inventory idea as the on-disk `logs/batch-*.manifest`, posted to the collector. |
| Batch id inject | **vstorm** auto-injects `VSTORM_BATCH_ID` into `{VSTORM_GUEST_ENV}` cloud-inits. |
| Agent heartbeats | Guest POSTs `record_type: "heartbeat"` while idle / running / on poll errors. |
| Collector + browse UI | Ingest, SQLite, runs list, run/VM/payload views. |
| Transport | Plain HTTP (v1). |

### Still open / by design

| Area | Notes |
|------|-------|
| Per-VM `VSTORM_VM_NAME` | Not injected (shared cloud-init Secret per namespace). Guest uses hostname unless user sets `--env VSTORM_VM_NAME=…`. |
| Unset `RESULT_SERVER_URL` | No push/poll; guest still runs **forever** (legacy soak). Intentional. |
| Full log upload API | Batch POST may include truncated `log_text` (64 KiB); separate `POST /v1/batches/{id}/log` not required for v1. |
| Dedicated policy/payload tests | Covered by `monitoring/tests/test_workload_result.py` (helpers, ingest, policy, HTTP). |

## Architecture

```text
  Dashboard UI                    Collector                         Guest agent
  ------------                    ---------                         -----------
  Set policy (once/N/forever) --> store desired policy
                                        ^
                                        |  GET /v1/.../policy  (poll)
                                        |
                                  guest applies policy
                                        |
                                  run 0..N cycles (or forever)
                                        |
                                  POST result JSON --------------> ingest + index
                                                                   (decrement remaining)
                                        |
                                  (optional) POST heartbeat -----> agent_state for UI
```

Guests never need inbound ports. The dashboard never talks to the VM directly.

### End-to-end flow

1. Start collector; open dashboard.
2. Run vstorm with result URL + batch id injection; vstorm POSTs a **manifest** (run inventory).
3. Guest boots, writes timestamp, starts **workload agent** service (fio today).
4. Agent polls collector for **run policy** for its `batch_id` + `vm_name`.
5. User sets policy from dashboard (e.g. “run 3 cycles” on one VM, “forever” on all).
6. Agent runs cycles according to policy; after each cycle, POSTs a **result** JSON. Collector decrements `remaining` on result ingest (for `count` / `once`).
7. When policy is satisfied (`once`/`count` done) or user sets **idle**, agent idles and keeps polling (heartbeats).
8. Failed POSTs spool locally and retry; guest may also POST an **error** record (`post_error`).

## Run policy (control plane)

Desired state lives on the collector. Guests pull it; they do not invent “forever” on their own once control mode is enabled.

### Policy fields

| Field | Meaning |
|-------|---------|
| `mode` | `idle` \| `once` \| `count` \| `forever` \| `stop` |
| `remaining` | For `count` / `once`: cycles left (server decrements on each **result** ingest). Ignored for `forever` / `idle`. |
| `revision` | Monotonic id; bumped when policy is set or remaining is consumed |
| `updated_at` | When the policy last changed |
| `run` | Convenience boolean on GET: whether the guest should start a cycle now |
| `agent_state` / `last_poll_at` / `last_status_at` | Last known guest state (from heartbeats / policy polls) |

Semantics:

- **`idle`** — do not start a new cycle; if a cycle is running, let it finish (v1).
- **`once`** — stored as `count` with `remaining=1`.
- **`count`** — run until `remaining` reaches 0 on the collector, then become `idle`.
- **`forever`** — start another cycle whenever the previous one ends, until policy changes.
- **`stop`** — accepted by the API and immediately stored as `idle` (same as Idle in the UI). No mid-cycle SIGKILL in v1.

### Defaults and boot env

| Variable | Description |
|----------|-------------|
| `RESULT_SERVER_URL` | Collector base or results URL (required for push + poll) |
| `WORKLOAD_RUN_MODE` | Initial policy if none stored yet: `idle` (recommended with dashboard) or `forever` (soak / backward compatible) |
| `WORKLOAD_RUN_COUNT` | If mode is `count` at boot, initial N |
| `WORKLOAD_POLL_SECONDS` | How often to poll policy while idle or between cycles (e.g. 5) |
| `VSTORM_BATCH_ID` / `VSTORM_VM_NAME` | Identity for policy lookup and result join |

When the agent first registers (or first poll), if no policy row exists, the collector creates one from `WORKLOAD_RUN_MODE` / `WORKLOAD_RUN_COUNT`.

### Why pull, not push

Lab VMs typically reach the collector via egress/NAT. Requiring `virtctl exec`, SSH, or a guest listen port breaks that model. Polling keeps one HTTP server and works for fio and future workloads.

## Guest agent behavior

Replace the hard-coded forever loop with:

```text
  loop forever:
    policy = GET /v1/policy?batch_id=&vm_name=  (creates row from WORKLOAD_RUN_* on first poll)
    if not policy.run:          # idle, or count/once with remaining=0
        POST status (idle) optional
        sleep POLL_SECONDS
        continue
    run one cycle (fio / other)
    POST result record              # collector decrements remaining for count/once
    # re-check policy next iteration (Idle / new N / forever noticed between cycles)
```

- **One cycle** = one fio job (size- or time-based), then report as `record_type: "result"`.
- Persistent `job.counter` / `jobN` naming stays; payload field `cycle` is the sequence number (not the record type).
- Between cycles the agent always re-reads policy so Idle / “run 2 more” apply without restarting systemd.
- Remaining is authoritative on the **collector** (updated on result ingest); the guest trusts `run` / `remaining` from the next GET.
- systemd unit stays `Restart=always` as a crash safety net; the **logical** loop is policy-driven, not “always run fio”.

### Per cycle capture (unchanged intent)

1. Record `fio_start` (UTC ISO-8601 with `Z`).
2. Run fio with `--output-format=json` to a results file.
3. Record `fio_stop`.
4. Build **result** payload (identity, command, `fio_group_reporting`, workload fingerprint).
5. Set `reported_at`; POST; spool on failure.

All payload timestamps are **UTC**, written as ISO-8601 with an explicit timezone (`…Z` or `…+00:00`). The collector still indexes them as unix seconds internally for sorting.

### Boot timestamp

Unchanged: `/root/timestamp.txt` (or under `$FIO_DIRECTORY`); first line = boot; append on later service starts.

## Host-side manifest (vstorm)

One `record_type: "manifest"` / `source: "vstorm"` POST after successful create (and after `--wait`), with names, sizing, cmdline, etc. Auto-inject `VSTORM_BATCH_ID`. This is the collector counterpart of the local `logs/batch-{id}.manifest` inventory — same facts, different place. See fields in the example below.

### Manifest payload example

```json
{
  "schema_version": 1,
  "record_type": "manifest",
  "source": "vstorm",
  "reported_at": "2026-07-22T05:50:00Z",
  "started_at": "2026-07-22T05:48:20Z",
  "stopped_at": "2026-07-22T05:50:00Z",
  "batch_id": "8a494b",
  "basename": "rhel9",
  "total_vms": 10,
  "total_namespaces": 2,
  "namespaces": ["vm-8a494b-ns-1", "vm-8a494b-ns-2"],
  "vms": [
    "vm-8a494b-ns-1/rhel9-8a494b-1",
    "vm-8a494b-ns-1/rhel9-8a494b-2"
  ],
  "cores": 4,
  "memory": "8Gi",
  "cloudinit": "workload/cloudinit-fio-workload.yaml",
  "guest_env": {
    "FIO_SIZE": "1G",
    "RESULT_SERVER_URL": "http://host:8080/v1/results",
    "VSTORM_BATCH_ID": "8a494b",
    "WORKLOAD_RUN_MODE": "idle"
  },
  "storage_class": "ocs-storagecluster-ceph-rbd",
  "volume_mode": "Block",
  "cmdline": ["vstorm", "--cloudinit=workload/cloudinit-fio-workload.yaml", "--cores=4", "--memory=8Gi", "--vms=10"],
  "log_path": "logs/8a494b-2026-07-22T05:48:20.log",
  "log_text": "…truncated host log (up to 64 KiB)…"
}
```

All timestamps are UTC ISO-8601 with an explicit timezone suffix (`Z` = UTC).

## Payload schema (v1)

| Field | Meaning |
|-------|---------|
| `record_type` | `manifest` \| `result` \| `error` \| `heartbeat` |
| `source` | `vstorm` \| `guest` |
| `workload_kind` | Guest only: `fio`, later `stress-ng`, … — omit on manifest |

Legacy aliases still accepted on ingest: `batch`→`manifest`, `cycle`→`result`, `event`→`error`, `status`→`heartbeat`.

### Result payload (`record_type: "result"`, `workload_kind: "fio"`)

One completed workload invocation (one fio job). Timing: UTC ISO-8601 with explicit timezone (`…Z`). No unix fields in the payload.

```json
{
  "schema_version": 1,
  "record_type": "result",
  "source": "guest",
  "workload_kind": "fio",
  "status": "ok",
  "error_message": null,
  "fio_start": "2026-07-22T05:50:50Z",
  "fio_stop": "2026-07-22T05:52:00Z",
  "reported_at": "2026-07-22T05:52:03Z",
  "boot_timestamp": "2026-07-22T05:50:25Z",
  "service_start": "2026-07-22T05:50:25Z",
  "hostname": "vm-8a494b-1",
  "batch_id": "8a494b",
  "vm_name": "vm-8a494b-1",
  "cycle": 1,
  "job_name": "job1",
  "cpu_count": 4,
  "mem_total_kb": 8165432,
  "fio_command": ["fio", "--name=job1", "..."],
  "fio_rc": 0,
  "fio_group_reporting": { "fio version": "...", "jobs": [] },
  "workload": {
    "WORKLOAD_TYPE": "randrw",
    "FIO_SIZE": "1G",
    "FIO_BS": "4k",
    "FIO_IODEPTH": "16",
    "FIO_NUMJOBS": "1",
    "FIO_DIRECT": "1",
    "FIO_RW": "randrw"
  }
}
```

| Field | Meaning |
|-------|---------|
| `fio_start` / `fio_stop` | fio process start / exit (UTC) |
| `reported_at` | payload build time for POST (UTC) |
| `boot_timestamp` / `service_start` | guest boot / service start (UTC) |
| `cycle` | Sequence number of this invocation on the guest (`jobN`) — not the record type |

Failed fio jobs still POST as `result` (with `status` / `fio_rc`). Unreachable collector → spool under `/var/lib/fio/results/pending/`; optional `record_type: "error"` / `status: "post_error"`.

### Error payload (incident)

Compact guest incident when something fails around reporting (not a metrics sample):

```json
{
  "schema_version": 1,
  "record_type": "error",
  "source": "guest",
  "workload_kind": "fio",
  "status": "post_error",
  "error_message": "failed to POST …; left in guest pending spool",
  "cycle": 1,
  "batch_id": "8a494b",
  "vm_name": "vm-8a494b-1",
  "reported_at": "2026-07-22T05:52:05Z"
}
```

### Heartbeat payload

Lightweight so the dashboard can show idle / running / error without waiting for the next result:

```json
{
  "schema_version": 1,
  "record_type": "heartbeat",
  "source": "guest",
  "workload_kind": "fio",
  "batch_id": "8a494b",
  "vm_name": "vm-8a494b-1",
  "hostname": "vm-8a494b-1",
  "agent_state": "idle",
  "policy_mode": "idle",
  "reported_at": "2026-07-22T05:53:20Z"
}
```

`agent_state`: `idle` \| `running` \| `error` (guest may also use other labels).  
`policy_mode` in the current guest script is the boot env `WORKLOAD_RUN_MODE` (not the last polled collector policy). Authoritative mode/remaining live in the collector `vm_policies` row and on `GET …/policy`.

## Collector and API

One Python process: ingest, **policy store**, query, dashboard.

| Endpoint | Purpose |
|----------|---------|
| `POST /v1/results` | Ingest manifest / result / error / heartbeat |
| `GET /healthz` | Liveness |
| `GET /v1/batches` | List runs |
| `GET /v1/batches/{id}` | Batch detail + VMs + series |
| `GET /v1/batches/{id}/results/{result_id}` | One stored payload |
| `GET /v1/batches/{id}/vms/{vm}` | Per-VM results + **current policy + agent status** |
| `GET /v1/batches/{id}/results` | Filtered results (`record_type=result`, …) |
| `GET /v1/batches/{id}/vms/{vm}/policy` | Desired run policy for that VM |
| `PUT /v1/batches/{id}/vms/{vm}/policy` | Set policy (`mode`, `remaining`, …) — used by dashboard |
| `POST /v1/batches/{id}/policy` | Fan-out: set same policy on all VMs in the batch |
| `DELETE /v1/batches/{id}` | Delete run |
| `PATCH /v1/batches/{id}` | Label / notes / archived |
| Static `/` | Dashboard |

Policy GET may accept identity query params if the guest uses a shared results URL, e.g. `GET /v1/policy?batch_id=&vm_name=` as an alias.

### Storage

- Raw JSON under `data/results/{batch_id}/…`
  - Manifest: `manifest.json` (legacy `batch.json` accepted on ingest and rewritten)
  - Results / errors / heartbeats: `result-{vm}-{n}-{ISO}-{id8}.json` (and `error-…` / `heartbeat-…`), where ISO is filesystem-safe UTC (colons → dashes), e.g. `2026-07-22T05-52-03Z`
- SQLite: results index + **`vm_policies`** (`batch_id`, `vm_name`, `mode`, `remaining`, `revision`, `updated_at`, agent status columns)

## Dashboard

Primary UX: **see every vstorm run**, skim **how many VMs are doing what**, drill into one VM, and **control** workload execution — without SSH into guests.

```text
  Home: Runs list (one row per vstorm batch)
      |
      | click batch_id
      v
  Run detail
      |-- VM status chips + manifest / metadata
      |-- batch-wide controls: Idle | Run once | Run N | Forever
      |-- charts
      |-- VM table (per-VM status + policy)
      |
      | click VM
      v
  VM detail  ---- per-VM controls + cycle history
      |
      v
  Cycle / payload view
```

### 1. Runs list (home)

The home page is a **list of runs created by vstorm** — one row per `batch_id`. Prefer rows that have a host `record_type: "manifest"` payload; if only guest cycles have arrived, still show an inferred run so nothing is invisible.

**Summary strip** (across the current list):

| Summary | Meaning |
|---------|---------|
| Runs | Count of listed batches |
| VMs configured | Sum of `configured` / `total_vms` |
| Checked in | Guests that have polled or POSTed (not `waiting`) |
| Running / idle / waiting / error | From per-batch `vm_summary` (chips also show queued / stale when present) |

**Table columns (as implemented):**

| Column | Source |
|--------|--------|
| Batch | `batch_id` (+ archived badge); click → run detail |
| Basename | vstorm metadata |
| Started / Stopped | vstorm `started_at` / `stopped_at` |
| VM status | Chips from `vm_summary` (cfg · in · running / queued / idle / waiting / …) |
| Cycles | Cycle POST count |
| Errors | Error cycle/event count |
| IOPS avg / BW avg | Aggregate from cycles |
| Workload | Fingerprint or cloud-init path |

**Filters:** text search on batch id / basename; active / archived / all. Short poll refresh while the page is open.

### 2. Run detail

Everything for one vstorm batch on one page.

**Summary (top):** batch id, basename, fingerprint/cloud-init, VM status chips, started/stopped, configured VMs, cycle/error counts, cores/memory, IOPS/BW percentiles.

**VM rollup meanings** (same definitions as the VM table `ui_status`):

| Metric | Meaning |
|--------|---------|
| Configured | From vstorm batch `total_vms` / `vms[]` |
| Checked in | Not `waiting` |
| Idle | Policy idle (or remaining 0), not running |
| Running | Agent reports `running` |
| Queued | Policy `once`/`count`/`forever` but not currently in a cycle |
| Waiting | Listed in the manifest VM list (or seen empty), never contacted collector |
| Error / stale | Last status error, or no poll within ~120s |

Example chips: `10 cfg · 8 in · 2 running · 4 idle · 2 waiting`.

**Batch-wide controls:** Idle | Run once | Run N… | Forever. Warn mentally if many VMs are still **waiting** (not checking in) — they will not pick up policy until `RESULT_SERVER_URL` + `VSTORM_BATCH_ID` work.

**vstorm metadata panel:** namespaces, cmdline, guest_env, storage, notes/label — from `record_type: "manifest"`. Button: **View manifest**. Archive / Delete.

**VMs table:**

| Column | Meaning |
|--------|---------|
| VM | Link to VM detail |
| Status | `ui_status`: idle / running / queued / waiting / error / stale |
| Policy | mode + remaining |
| Namespace | From batch `namespace/vm` list when known |
| Cycles | Count received |
| Last stopped | Last cycle end time |
| Latest IOPS / BW | From newest cycle |
| Boot | Boot timestamp when known |

**Charts:** IOPS / BW / latency across cycles.

### 3. VM detail

- Identity: hostname, CPU/RAM, boot timestamp when known.
- **Status strip:** agent state, policy mode/remaining/revision.
- **Per-VM controls:** Idle / Run once / Run N / Forever — after a cycle finishes and policy returns to idle, **Run once** (or Run N) re-runs fio on the same VM.
- **Cycles table:** cycle number, timing, fio_rc, IOPS/BW, status; click → payload view.

### 4. Cycle / payload view

- Highlighted summary (command, timing, exit code).
- Collapsible **`fio_group_reporting`**.
- Full raw JSON (copy / download).
- Same viewer for the vstorm batch payload from run detail.

### Control panel semantics

- Show **current policy** (`mode`, `remaining`, `revision`) from the collector.
- **Idle** — no new cycles (API `mode=idle`; `stop` is accepted and stored as idle).
- **Run once** — one more cycle on this VM (or all VMs if batch-wide), then idle.
- **Run N…** — N cycles then idle.
- **Forever** — soak until Idle.
- Guests that have never polled will not run until they check in (`RESULT_SERVER_URL` / `VSTORM_BATCH_ID`).

### Manage (non-control)

- Archive / unarchive, notes, label, delete run (confirm).

### Browse UX rules

- Home = **vstorm runs first**, not a flat dump of cycle files.
- VM status chips on run detail must match the VM table (same `ui_status` definitions).
- Every stored result is one click from its **full JSON**.
- Deep links: `/#/runs/{batch_id}`, `/#/runs/{batch_id}/vms/{vm}`, payload routes.
- Prefer skim-friendly tables; large JSON behind “View payload”.

## Example usage

```bash
# Terminal A — collector
python3 monitoring/workload-result/serve.py --listen 0.0.0.0:8080 --data-dir ./workload-result-data
# Open http://<host>:8080/

# Terminal B — VMs start idle and wait for dashboard policy
vstorm --cloudinit=workload/cloudinit-fio-workload.yaml \
  --env FIO_SIZE=1G \
  --env RESULT_SERVER_URL=http://<reachable-host>:8080/v1/results \
  --env WORKLOAD_RUN_MODE=idle \
  --cores=4 --memory=8Gi --vms=10 --wait
```

Then in the dashboard: open the run → **Run N = 3** on all VMs (or Forever on one VM for a soak). Guests poll, execute, POST cycles; the collector decrements remaining; guests return to idle when done.

For unattended soak without clicking: `--env WORKLOAD_RUN_MODE=forever` (legacy soak when you do not want to wait for the dashboard).

## Implementation touchpoints

| Area | Status |
|------|--------|
| [`vstorm`](../vstorm) | POSTs `record_type: "manifest"` when `RESULT_SERVER_URL` is in `--env`; auto-injects `VSTORM_BATCH_ID`; optional truncated `log_text` |
| [`workload/cloudinit-fio-workload.yaml`](../workload/cloudinit-fio-workload.yaml) | Policy poll + cycle runner; capture/POST/spool; status heartbeats; default idle when URL set |
| `monitoring/workload-result/serve.py` | Ingest; policy GET/PUT/fan-out; remaining consume on cycle ingest; VM status rollups; ISO filenames |
| `monitoring/workload-result/static/` | Runs list, run/VM/payload views; Idle / Run once / Run N / Forever controls |
| [`docs/cloud-init-fio-workload.md`](cloud-init-fio-workload.md) | Env table includes `RESULT_SERVER_*` / `WORKLOAD_RUN_*` |
| `tests/` | `monitoring/tests/test_workload_result.py` — helpers, ingest/record types, policy, queries, HTTP API |

## References

- [cloud-init and fio workload](cloud-init-fio-workload.md)
- [logging and batch manifests](logging.md)
- [workload/cloudinit-fio-workload.yaml](../workload/cloudinit-fio-workload.yaml)
- [README.md](../README.md) — Cloud-init and `--env`
- [monitoring/](../monitoring/README.md) — cluster Prom/Grafana; guest collector under `monitoring/workload-result/`
