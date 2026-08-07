# Data collector + dashboard

Ingests guest and vstorm JSON (`POST /v1/results`), indexes it in SQLite, and serves
the browser dashboard. Design notes:
[`docs/workload-result-sync-and-dashboard.md`](../../docs/workload-result-sync-and-dashboard.md).

| Path | Role |
|------|------|
| [`serve.py`](serve.py) | HTTP server (ingest API + static UI) |
| [`restart-service.sh`](restart-service.sh) | After `git pull`: sync unit if needed, `daemon-reload`, restart, healthz |
| [`vstorm-data-collector.service`](vstorm-data-collector.service) | systemd unit |
| [`data-collector.env.example`](data-collector.env.example) | Env file template |
| [`static/`](static/) | Dashboard assets |
| [`seed_dummy.py`](seed_dummy.py) | Optional dummy data for UI demos |
| [`collect_batch_dv_created.py`](collect_batch_dv_created.py) | Used by vstorm for DV/PVC timestamps |

Default listen: `0.0.0.0:8080`. Binding there exposes plain HTTP ingest/control
APIs — use only on trusted or lab networks, or set a bearer `TOKEN`.

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
| `LISTEN` | Bind `HOST:PORT` | `0.0.0.0:8080` |
| `DATA_DIR` | SQLite + JSON under this directory | `$VSTORM_HOME/monitoring/data-collector/workload-result-data` |
| `TOKEN` | Optional bearer token (empty = no auth) | leave blank or a secret |

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
3. Probes `/healthz` (skip with `--no-health`; skip unit sync with `--no-sync-unit`)

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
| `status=203/EXEC` or missing script | `VSTORM_HOME` in `/etc/vstorm/data-collector.env` points at the real checkout; `run-serve.sh` is executable |
| Permission denied on data dir | `chown` `DATA_DIR` to the service `User=` |
| Port already in use | Change `LISTEN` or stop the other process on that port |
| Guests / vstorm cannot POST | Firewall / security groups; URL must be reachable from guests and the create host |
| `401 Unauthorized` | `TOKEN` set on the server but client missing `RESULT_SERVER_TOKEN` / Bearer header |
| Empty dashboard | Confirm POSTs with `journalctl -u vstorm-data-collector` and files under `DATA_DIR/results/` |
