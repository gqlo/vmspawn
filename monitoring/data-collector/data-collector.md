# Data collector + dashboard

Ingests guest and vstorm JSON (`POST /v1/results`), indexes it in SQLite, and serves
the browser dashboard. Design notes:
[`docs/workload-result-sync-and-dashboard.md`](../../docs/workload-result-sync-and-dashboard.md).

| Path | Role |
|------|------|
| [`serve.py`](serve.py) | HTTP server (ingest API + static UI + CORS) |
| [`run-dashboard.sh`](run-dashboard.sh) | Serve **UI only** (point API at local or remote collector) |
| [`run-serve.sh`](run-serve.sh) | Wrapper: env → `serve.py` (used by systemd) |
| [`restart-service.sh`](restart-service.sh) | After `git pull`: sync unit if needed, `daemon-reload`, restart, healthz |
| [`vstorm-data-collector.service`](vstorm-data-collector.service) | systemd unit |
| [`data-collector.env.example`](data-collector.env.example) | Env file template |
| [`static/`](static/) | Dashboard assets (`index.html`, `app.js`, `dashboard-lib.js`, `style.css`) |
| [`seed_dummy.py`](seed_dummy.py) | Optional dummy data for UI demos |
| [`collect_batch_dv_created.py`](collect_batch_dv_created.py) | Used by vstorm for DV/PVC timestamps |

Default listen: `0.0.0.0:8080`. Binding there exposes plain HTTP ingest/control
APIs — use only on trusted or lab networks, or set a bearer `TOKEN`.

## Architecture

### Big picture

```text
┌─────────────────┐     POST /v1/results      ┌──────────────────────────────┐
│  vstorm (host)  │ ─────────────────────────►│  serve.py  (collector API)   │
│  + guest agents │     GET  /v1/policy        │  ThreadingHTTPServer         │
└─────────────────┘ ◄─────────────────────────│                              │
                                              │  ┌─────────┐  ┌───────────┐  │
┌─────────────────┐     GET /v1/batches…      │  │index.db │  │ results/  │  │
│  Browser UI     │ ─────────────────────────►│  │ SQLite  │  │ *.json    │  │
│  static/*.js    │     (+ CORS if cross-origin)│  └─────────┘  └───────────┘  │
└─────────────────┘                           └──────────────────────────────┘
        ▲                                              ▲
        │ same process OR                              │ DATA_DIR
        │ run-dashboard.sh :5500                       │
```

Two deployment shapes:

| Mode | Who serves the UI | Who serves `/v1/*` | Typical use |
|------|-------------------|--------------------|-------------|
| **Combined** | `serve.py` (`:8080/`) | same process | Lab host; open `http://<lab>:8080/` |
| **Split** | `run-dashboard.sh` (`:5500`) | remote `serve.py` | Laptop UI → lab API |

### Component catalog

| Layer | Component | Responsibility |
|-------|-----------|----------------|
| Ingest clients | `vstorm`, guest workloads | `POST /v1/results` (manifest / result / heartbeat / error); guests poll `GET /v1/policy` |
| HTTP API | `serve.py` → `Store` | Auth (optional Bearer), CORS, CRUD over batches/VMs/results |
| Persistence | SQLite `index.db` | Queryable index: batches, results metadata, VM policies, VM list index |
| Persistence | `results/<batch_id>/*.json` | Source-of-truth payloads (full manifest, per-guest JSON) |
| Dashboard | `static/app.js` | Hash router (`#/runs`, `#/runs/<id>`, …); `fetch` to API base |
| Dashboard | `static/dashboard-lib.js` | Pure helpers (formatters, paging math, CSV) |
| Process mgmt | systemd + `run-serve.sh` | Long-running collector on the lab |

### How the dashboard talks to the backend

The UI **never opens SQLite**. It only calls HTTP JSON APIs.

1. **API base** — header field **API**, stored in `localStorage` key
   `workload-result-api-base`.
   - **Never configured** (`null`): defaults to the PerfScale lab collector
     `http://n42-h01-b02-mx750c.rdu3.labs.perfscale.redhat.com:8080`.
   - **Empty string** (clear + Apply): same-origin relative URLs (combined mode).
   - **Override**: type a URL and Apply, or open `?api=http://host:8080` once.
2. **Requests** — `fetch(apiBase + path)` with optional
   `Authorization: Bearer <token>` from `localStorage` key `workload-result-token`.
3. **CORS** — when the UI origin differs from the API (split mode), `serve.py`
   answers `OPTIONS` preflights and sets `Access-Control-Allow-Origin` for the
   requesting origin.
4. **Routes → APIs** (representative):

| UI route | Primary API calls |
|----------|-------------------|
| `#/runs` | `GET /v1/batches?…` (list metadata only; no full manifests) |
| `#/runs/<batch>` | `GET /v1/batches/<id>?view=summary` then paginated `GET /v1/batches/<id>/vms?limit=&offset=`; boot chart via `GET /v1/batches/<id>/boot-chart` |
| `#/runs/<batch>/vms/<vm>` | `GET /v1/batches/<id>/vms/<vm>` |
| `#/runs/<batch>/timestamps` | `GET /v1/batches/<id>` (full detail) / related timestamp helpers |
| `#/timestamps` | `GET /v1/timestamps?…` |

Batch list and the VM table are designed to avoid loading multi-thousand-VM
manifest JSON on every page view (see [Data model](#data-model-sqlite--json-files)).

### Data model (SQLite + JSON files)

**Database:** SQLite 3 via Python `sqlite3` (stdlib). File:

`$DATA_DIR/index.db`

**On-disk payloads:**

```text
$DATA_DIR/
  index.db                 # SQLite index
  results/
    <batch_id>/
      manifest.json        # vstorm run inventory (may be large)
      result-*.json        # guest fio/etc. results
      heartbeat-*.json
      error-*.json
```

| SQLite table | Purpose |
|--------------|---------|
| `batches` | One row per batch: sizes, times, label/notes/archived, `batch_result_id`, **list metadata** (`api_server`, `namespaces_json`, `summary_json`) |
| `results` | Indexed fields from every stored JSON (type, VM, cycle, IOPS, boot time, `file_path`, …) |
| `vm_policies` | Per-VM run mode / remaining / agent_state / vmi_phase (dashboard + guest poll) |
| `batch_vms` | Per-VM inventory + DV/PVC timing columns for **paginated** list views |

Ingest flow:

1. Write JSON under `results/<batch_id>/`.
2. Insert/update `results` (+ `batches` / `batch_vms` / `summary_json` for manifests).
3. Dashboard reads via `/v1/*` only.

`summary_json` holds a **small** copy of the manifest (cluster, cmdline, guest env,
counts) without per-VM maps. Full maps stay in `manifest.json` for payload
inspection and full `GET /v1/batches/<id>` (timestamps / “View manifest”).

### API surface (catalog)

| Method | Path | Role |
|--------|------|------|
| `GET` | `/healthz` | Liveness (no auth) |
| `POST` | `/v1/results` | Ingest one JSON record |
| `GET` | `/v1/batches` | Filtered batch list + facets |
| `GET` | `/v1/batches/<id>?view=summary\|full` | Batch detail (`summary` = light; default `full`) |
| `GET` | `/v1/batches/<id>/vms?limit=&offset=` | Paginated VM rows |
| `GET` | `/v1/batches/<id>/boot-chart` | Boot-duration samples for the histogram (loaded async) |
| `GET` | `/v1/batches/<id>/vms/<vm>` | One VM + cycles |
| `GET`/`PUT` | `/v1/batches/<id>/vms/<vm>/policy` | Per-VM policy |
| `PUT` | `/v1/batches/<id>/policy` | Fan-out policy |
| `GET` | `/v1/policy?batch_id=&vm_name=` | Guest poll helper |
| `GET` | `/v1/timestamps` | Cross-batch timing rows |
| `GET` | `/v1/batches/<id>/results[…]` | Result listing / single payload |
| `PATCH`/`DELETE` | `/v1/batches/<id>` | Notes/label/archive / delete batch |

Optional auth: `--token` / `TOKEN=` → Bearer required on `/v1/*` (not `/healthz`).

## Prerequisites

- Python 3 (stdlib only; no pip packages required for `serve.py`)
- A writable data directory for SQLite + JSON payloads
- From a vstorm git checkout (this directory’s repo root)

## Quick start (foreground)

From the **vstorm repo root**:

```bash
python3 monitoring/data-collector/serve.py \
  --listen 0.0.0.0:8080 \
  --data-dir monitoring/data-collector/workload-result-data
```

| URL | Purpose |
|-----|---------|
| `http://<host>:8080/` | Dashboard |
| `http://<host>:8080/v1/results` | Ingest (`POST`) |
| `http://<host>:8080/healthz` | Liveness (no auth) |

## Standalone dashboard (UI only)

Run the static UI on your laptop and point it at a local or remote collector API
(CORS is enabled on `serve.py`):

```bash
# Terminal A — collector on the lab (or locally) with data
python3 monitoring/data-collector/serve.py \
  --listen 0.0.0.0:8080 \
  --data-dir monitoring/data-collector/workload-result-data

# Terminal B — UI only on the laptop
./monitoring/data-collector/run-dashboard.sh
# → http://127.0.0.1:5500/
```

In the header **API** field (defaults to
`http://n42-h01-b02-mx750c.rdu3.labs.perfscale.redhat.com:8080`), change the
collector URL and click **Apply**, or open
`http://127.0.0.1:5500/?api=http://127.0.0.1:8080` for a local collector.
Clear the field and Apply for same-origin (only useful when the UI is served by
`serve.py` itself).

Optional auth:

```bash
python3 monitoring/data-collector/serve.py \
  --listen 0.0.0.0:8080 \
  --data-dir monitoring/data-collector/workload-result-data \
  --token SECRET
```

Use the same secret as `RESULT_SERVER_TOKEN` in `vstorm --env` and as the
dashboard Bearer token.

Or via the wrapper (defaults `DATA_DIR` to `…/monitoring/data-collector/workload-result-data`):

```bash
export VSTORM_HOME=/path/to/vstorm
export LISTEN=0.0.0.0:8080
# export TOKEN=SECRET
./monitoring/data-collector/run-serve.sh
```

## Install as a systemd service

Commands below assume you are in the **vstorm repo root** on the host that will
run the collector (for example the PerfScale lab machine that vstorm’s default
`RESULT_SERVER_URL` points at).

### 1. Create env file

```bash
sudo mkdir -p /etc/vstorm
sudo cp monitoring/data-collector/data-collector.env.example \
  /etc/vstorm/data-collector.env
sudo edit /etc/vstorm/data-collector.env
```

Set at least:

| Variable | Meaning | Example |
|----------|---------|---------|
| `VSTORM_HOME` | Absolute path to this git checkout (**required**) | `/root/workload-collector/vstorm` |
| `PYTHON` | Interpreter for `serve.py` (**≥ 3.7**) | `/usr/bin/python3.11` |
| `LISTEN` | Bind `HOST:PORT` | `0.0.0.0:8080` |
| `DATA_DIR` | SQLite + JSON under this directory | `$VSTORM_HOME/monitoring/data-collector/workload-result-data` |
| `TOKEN` | Optional bearer token (empty = no auth) | leave blank or a secret |

On RHEL 8 lab hosts, `/usr/bin/python3` is often 3.6 and will fail with
`future feature annotations is not defined`. Set `PYTHON=/usr/bin/python3.11`
(or another ≥ 3.7 binary).

`DATA_DIR` stays inside the checkout’s `monitoring/data-collector/` tree (gitignored
as `workload-result-data/`). If unset, `run-serve.sh` uses that path by default.

`EnvironmentFile=/etc/vstorm/data-collector.env` is required by the unit; the
service will not start without that file.

### 2. Install and enable the unit

```bash
sudo cp monitoring/data-collector/vstorm-data-collector.service \
  /etc/systemd/system/vstorm-data-collector.service
sudo systemctl daemon-reload
sudo systemctl enable --now vstorm-data-collector.service
```

### 3. Verify

```bash
systemctl status vstorm-data-collector.service
journalctl -u vstorm-data-collector.service -e
curl -sS http://127.0.0.1:8080/healthz
```

Expected health response includes a JSON body with `"ok": true` (or similar).
Open `http://<host>:8080/` for the dashboard.

### 4. Run as a non-root user (optional)

```bash
sudo chown -R otus:otus /root/workload-collector/vstorm/monitoring/data-collector/workload-result-data
# (use your real DATA_DIR path)

sudo systemctl edit vstorm-data-collector
```

Drop-in example:

```ini
[Service]
User=otus
Group=otus
```

Then:

```bash
sudo systemctl daemon-reload
sudo systemctl restart vstorm-data-collector.service
```

### 5. Update after a git pull

The unit runs `serve.py` and `run-serve.sh` from `VSTORM_HOME`. Python code is
loaded at process start, so restart after updating the checkout:

```bash
# From the vstorm repo root (or any cwd):
./monitoring/data-collector/restart-service.sh
```

That script:

1. Copies `vstorm-data-collector.service` into `/etc/systemd/system/` when it
   differs from the checkout, then `daemon-reload`
2. `systemctl restart vstorm-data-collector.service`
3. Probes `/healthz` with short retries (skip with `--no-health`; skip unit
   sync with `--no-sync-unit`). Override wait with `HEALTH_ATTEMPTS` /
   `HEALTH_INTERVAL_SEC` if needed.

Static dashboard JS/CSS is read from disk per request; a browser refresh is
enough for UI-only changes, but restarting still refreshes `serve.py`.

Manual equivalent:

```bash
sudo systemctl restart vstorm-data-collector.service
```

### 6. Stop / disable

```bash
sudo systemctl stop vstorm-data-collector.service
sudo systemctl disable vstorm-data-collector.service
```

## Wire vstorm to this collector

vstorm defaults `RESULT_SERVER_URL` to the lab collector ingest URL when unset.
Override or clear as needed:

```bash
# Override
vstorm --vms=5 --env RESULT_SERVER_URL=http://<this-host>:8080/v1/results

# Disable POSTs
vstorm --vms=5 --env RESULT_SERVER_URL=
```

With a token:

```bash
vstorm --vms=5 \
  --env RESULT_SERVER_URL=http://<this-host>:8080/v1/results \
  --env RESULT_SERVER_TOKEN=SECRET
```

## Seed dummy data (optional)

With the server running:

```bash
python3 monitoring/data-collector/seed_dummy.py \
  --url http://127.0.0.1:8080/v1/results
# add --token SECRET if required
```

## Troubleshooting

| Symptom | Check |
|---------|--------|
| `bad-setting` / `WorkingDirectory= path is not absolute` | Re-copy the unit from the checkout (older units used `${VSTORM_HOME}` in `WorkingDirectory=`, which systemd rejects), then `daemon-reload` |
| `future feature annotations is not defined` / Python too old | Set `PYTHON=/usr/bin/python3.11` (or ≥ 3.7) in `/etc/vstorm/data-collector.env`, then restart |
| `status=203/EXEC` or missing script | `VSTORM_HOME` in `/etc/vstorm/data-collector.env` points at the real checkout; `run-serve.sh` is executable |
| Permission denied on data dir | `chown` `DATA_DIR` to the service `User=` |
| Port already in use | Change `LISTEN` or stop the other process on that port |
| Guests / vstorm cannot POST | Firewall / security groups; URL must be reachable from guests and the create host |
| `401 Unauthorized` | `TOKEN` set on the server but client missing `RESULT_SERVER_TOKEN` / Bearer header |
| Empty dashboard | Confirm POSTs with `journalctl -u vstorm-data-collector` and files under `DATA_DIR/results/` |
