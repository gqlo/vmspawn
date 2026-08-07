#!/usr/bin/env python3
"""Workload result collector: ingest guest/vstorm JSON, SQLite index, dashboard.

Usage:
  python3 monitoring/data-collector/serve.py --listen 0.0.0.0:8080 --data-dir ./data-collector-data
  python3 monitoring/data-collector/serve.py --listen 127.0.0.1:8080 --data-dir ./data --token SECRET
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import re
import shutil
import sqlite3
import statistics
import sys
import threading
import time
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, unquote, urlparse

SCHEMA_VERSION = 1
HERE = Path(__file__).resolve().parent
STATIC_DIR = HERE / "static"


def _is_manifest(record_type: str) -> bool:
    """Host run inventory (manifest) or legacy record_type=batch."""
    return record_type in ("manifest", "batch")


def _is_result(record_type: str) -> bool:
    """Completed workload invocation (result) or legacy record_type=cycle."""
    return record_type in ("result", "cycle")


def _is_error(record_type: str) -> bool:
    """Guest incident (error) or legacy record_type=event."""
    return record_type in ("error", "event")


def _is_heartbeat(record_type: str) -> bool:
    """Agent heartbeat or legacy record_type=status."""
    return record_type in ("heartbeat", "status")


def _normalize_record_type(record_type: str) -> str:
    return {
        "batch": "manifest",
        "cycle": "result",
        "event": "error",
        "status": "heartbeat",
    }.get(record_type, record_type)


def _day_bounds_utc(day: str) -> tuple[int, int]:
    """Return [start, end) unix bounds for a YYYY-MM-DD calendar day in UTC."""
    start = datetime.strptime(day, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    end = start.timestamp() + 86400
    return int(start.timestamp()), int(end)


def _payload_namespaces(bp: dict[str, Any] | None) -> list[str]:
    if not bp or not isinstance(bp.get("namespaces"), list):
        return []
    return [str(x) for x in bp["namespaces"] if x is not None and str(x).strip()]


def _payload_api_server(bp: dict[str, Any] | None) -> str | None:
    if not bp:
        return None
    cluster = bp.get("cluster")
    if not isinstance(cluster, dict):
        return None
    raw = cluster.get("api_server")
    if raw is None:
        return None
    s = str(raw).strip()
    return s or None


def percentile(sorted_vals: list[float], p: float) -> float | None:
    if not sorted_vals:
        return None
    if len(sorted_vals) == 1:
        return float(sorted_vals[0])
    k = (len(sorted_vals) - 1) * (p / 100.0)
    f = int(k)
    c = min(f + 1, len(sorted_vals) - 1)
    if f == c:
        return float(sorted_vals[f])
    return float(sorted_vals[f] + (sorted_vals[c] - sorted_vals[f]) * (k - f))


def _coerce_unix(val: Any) -> int | None:
    """Parse a payload timestamp to unix seconds (int, digit string, or ISO-8601)."""
    if val is None or isinstance(val, bool):
        return None
    if isinstance(val, (int, float)):
        return int(val)
    if isinstance(val, str):
        s = val.strip()
        if not s:
            return None
        if s.isdigit() or (s.startswith("-") and s[1:].isdigit()):
            return int(s)
        # ISO-8601: …Z or …±HH:MM (and bare datetime treated as UTC if no offset)
        iso = s[:-1] + "+00:00" if s.endswith("Z") else s
        try:
            dt = datetime.fromisoformat(iso)
        except ValueError:
            return None
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return int(dt.timestamp())
    return None


def _payload_unix(payload: dict[str, Any], *keys: str) -> int | None:
    """First parseable timestamp among keys (ISO preferred for new payloads; unix legacy)."""
    for key in keys:
        parsed = _coerce_unix(payload.get(key))
        if parsed is not None:
            return parsed
    return None


def _filename_timestamp(payload: dict[str, Any], reported_at_unix: int) -> str:
    """Filesystem-safe UTC ISO for result filenames (colons → dashes).

    Prefer payload reported_at ISO text when present; else format from unix.
    Example: 2026-07-22T05-52-03Z
    """
    raw = payload.get("reported_at")
    if isinstance(raw, str):
        s = raw.strip()
        if s and _coerce_unix(s) is not None and not (
            s.isdigit() or (s.startswith("-") and s[1:].isdigit())
        ):
            s = s.replace("+00:00", "Z")
            return _safe_name(s.replace(":", "-"))
    dt = datetime.fromtimestamp(reported_at_unix, tz=timezone.utc)
    return dt.strftime("%Y-%m-%dT%H-%M-%SZ")


def extract_fio_metrics(payload: dict[str, Any]) -> tuple[float | None, float | None, float | None]:
    """Return (iops, bw_bytes, lat_ns) from nested fio JSON when present."""
    fio = payload.get("fio_group_reporting")
    if not isinstance(fio, dict):
        return None, None, None
    jobs = fio.get("jobs")
    if not isinstance(jobs, list) or not jobs:
        return None, None, None
    job = jobs[0]
    if not isinstance(job, dict):
        return None, None, None

    iops = 0.0
    bw = 0.0
    lat_samples: list[float] = []
    for side in ("read", "write", "trim"):
        block = job.get(side)
        if not isinstance(block, dict):
            continue
        if "iops" in block:
            try:
                iops += float(block["iops"])
            except (TypeError, ValueError):
                pass
        if "bw_bytes" in block:
            try:
                bw += float(block["bw_bytes"])
            except (TypeError, ValueError):
                pass
        elif "bw" in block:
            # fio sometimes reports KiB/s as bw
            try:
                bw += float(block["bw"]) * 1024.0
            except (TypeError, ValueError):
                pass
        lat = block.get("lat_ns") or block.get("clat_ns")
        if isinstance(lat, dict) and "mean" in lat:
            try:
                lat_samples.append(float(lat["mean"]))
            except (TypeError, ValueError):
                pass

    lat_ns = statistics.mean(lat_samples) if lat_samples else None
    return (iops if iops else None), (bw if bw else None), lat_ns


def workload_fingerprint(payload: dict[str, Any]) -> str | None:
    wl = payload.get("workload")
    if isinstance(wl, dict) and wl:
        parts = [
            str(wl.get("WORKLOAD_TYPE") or wl.get("FIO_RW") or ""),
            str(wl.get("FIO_SIZE") or ""),
            str(wl.get("FIO_BS") or ""),
        ]
        fp = "/".join(p for p in parts if p)
        return fp or None
    if payload.get("cloudinit"):
        return str(payload["cloudinit"])
    return None


class Store:
    def __init__(self, data_dir: Path) -> None:
        self.data_dir = data_dir
        self.results_dir = data_dir / "results"
        self.results_dir.mkdir(parents=True, exist_ok=True)
        self.db_path = data_dir / "index.db"
        self._lock = threading.RLock()
        self._conn = sqlite3.connect(self.db_path, check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        self._init_db()

    def _init_db(self) -> None:
        with self._lock:
            self._conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS batches (
                    batch_id TEXT PRIMARY KEY,
                    basename TEXT,
                    total_vms INTEGER,
                    total_namespaces INTEGER,
                    started_at INTEGER,
                    stopped_at INTEGER,
                    cloudinit TEXT,
                    cores INTEGER,
                    memory TEXT,
                    label TEXT,
                    notes TEXT,
                    archived INTEGER NOT NULL DEFAULT 0,
                    batch_result_id TEXT,
                    updated_at INTEGER
                );

                CREATE TABLE IF NOT EXISTS results (
                    result_id TEXT PRIMARY KEY,
                    batch_id TEXT NOT NULL,
                    source TEXT,
                    workload_kind TEXT,
                    record_type TEXT,
                    hostname TEXT,
                    vm_name TEXT,
                    cycle INTEGER,
                    started_at INTEGER,
                    stopped_at INTEGER,
                    reported_at INTEGER,
                    boot_timestamp_unix INTEGER,
                    cpu_count INTEGER,
                    mem_total_kb INTEGER,
                    fio_rc INTEGER,
                    status TEXT,
                    error_message TEXT,
                    iops REAL,
                    bw_bytes REAL,
                    lat_ns REAL,
                    fingerprint TEXT,
                    file_path TEXT NOT NULL,
                    created_at INTEGER NOT NULL
                );

                CREATE INDEX IF NOT EXISTS idx_results_batch ON results(batch_id);
                CREATE INDEX IF NOT EXISTS idx_results_vm ON results(batch_id, vm_name);
                CREATE INDEX IF NOT EXISTS idx_results_kind ON results(workload_kind);
                CREATE INDEX IF NOT EXISTS idx_results_type ON results(record_type);

                CREATE TABLE IF NOT EXISTS vm_policies (
                    batch_id TEXT NOT NULL,
                    vm_name TEXT NOT NULL,
                    mode TEXT NOT NULL DEFAULT 'idle',
                    remaining INTEGER NOT NULL DEFAULT 0,
                    revision INTEGER NOT NULL DEFAULT 0,
                    updated_at INTEGER,
                    PRIMARY KEY (batch_id, vm_name)
                );
                """
            )
            self._conn.commit()
            self._ensure_columns()

    def _ensure_columns(self) -> None:
        cols = {r[1] for r in self._conn.execute("PRAGMA table_info(results)")}
        if "status" not in cols:
            self._conn.execute("ALTER TABLE results ADD COLUMN status TEXT")
        if "error_message" not in cols:
            self._conn.execute("ALTER TABLE results ADD COLUMN error_message TEXT")
        if "source" not in cols:
            self._conn.execute("ALTER TABLE results ADD COLUMN source TEXT")
        pol_cols = {r[1] for r in self._conn.execute("PRAGMA table_info(vm_policies)")}
        if "last_poll_at" not in pol_cols:
            self._conn.execute("ALTER TABLE vm_policies ADD COLUMN last_poll_at INTEGER")
        if "agent_state" not in pol_cols:
            self._conn.execute("ALTER TABLE vm_policies ADD COLUMN agent_state TEXT")
        if "last_status_at" not in pol_cols:
            self._conn.execute("ALTER TABLE vm_policies ADD COLUMN last_status_at INTEGER")
        if "vmi_phase" not in pol_cols:
            self._conn.execute("ALTER TABLE vm_policies ADD COLUMN vmi_phase TEXT")
        self._conn.commit()

    def close(self) -> None:
        with self._lock:
            self._conn.close()

    def ingest(self, payload: dict[str, Any]) -> dict[str, Any]:
        if payload.get("schema_version") not in (None, SCHEMA_VERSION, 1):
            raise ValueError(f"unsupported schema_version: {payload.get('schema_version')}")

        batch_id = payload.get("batch_id")
        if not batch_id or not isinstance(batch_id, str):
            raise ValueError("batch_id is required")

        # record_type is the primary discriminator.
        # Legacy aliases: batch→manifest, cycle→result, event→error, status→heartbeat.
        legacy_kind = payload.get("workload_kind")
        record_type = str(payload.get("record_type") or "")
        if not record_type:
            if legacy_kind == "vstorm" or payload.get("source") == "vstorm":
                record_type = "manifest"
            else:
                record_type = "result"
        record_type = _normalize_record_type(record_type)
        # Persist normalized type on the stored payload
        payload = {**payload, "record_type": record_type}

        source = payload.get("source")
        if not source:
            source = "vstorm" if _is_manifest(record_type) else "guest"
        source = str(source)

        # workload_kind is guest-workload only (fio, stress-ng, …); omit on manifest.
        if _is_manifest(record_type):
            workload_kind = None if legacy_kind in (None, "vstorm") else str(legacy_kind)
        else:
            workload_kind = str(legacy_kind or "unknown")

        now = int(time.time())
        # Prefer ISO strings (…Z / offset); accept legacy *_unix ints.
        reported_at = _payload_unix(payload, "reported_at", "reported_at_unix") or now
        started_at = _payload_unix(payload, "fio_start", "started_at", "fio_start_unix")
        stopped_at = _payload_unix(payload, "fio_stop", "stopped_at", "fio_stop_unix")
        boot_ts = _payload_unix(payload, "boot_timestamp", "boot_timestamp_unix")

        result_id = str(uuid.uuid4())
        batch_dir = self.results_dir / _safe_name(batch_id)
        batch_dir.mkdir(parents=True, exist_ok=True)

        ts_name = _filename_timestamp(payload, reported_at)

        if _is_manifest(record_type):
            rel_name = "manifest.json"
            file_path = batch_dir / rel_name
            # Drop legacy filename if present
            legacy_batch = batch_dir / "batch.json"
            if legacy_batch.exists() and legacy_batch != file_path:
                try:
                    legacy_batch.unlink()
                except OSError:
                    pass
        elif _is_error(record_type):
            vm = _safe_name(str(payload.get("vm_name") or payload.get("hostname") or "unknown"))
            cycle = payload.get("cycle")
            cycle_s = str(int(cycle)) if cycle is not None else "na"
            status_s = _safe_name(str(payload.get("status") or "error"))
            rel_name = f"error-{vm}-{cycle_s}-{status_s}-{ts_name}-{result_id[:8]}.json"
            file_path = batch_dir / rel_name
        elif _is_heartbeat(record_type):
            vm = _safe_name(str(payload.get("vm_name") or payload.get("hostname") or "unknown"))
            rel_name = f"heartbeat-{vm}-{ts_name}-{result_id[:8]}.json"
            file_path = batch_dir / rel_name
        else:
            # result (legacy: cycle)
            vm = _safe_name(str(payload.get("vm_name") or payload.get("hostname") or "unknown"))
            cycle = payload.get("cycle")
            cycle_s = str(int(cycle)) if cycle is not None else "na"
            rel_name = f"result-{vm}-{cycle_s}-{ts_name}-{result_id[:8]}.json"
            file_path = batch_dir / rel_name

        file_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        rel_path = str(file_path.relative_to(self.data_dir))

        iops, bw_bytes, lat_ns = extract_fio_metrics(payload)
        fingerprint = workload_fingerprint(payload)
        vm_name = payload.get("vm_name") or payload.get("hostname")
        hostname = payload.get("hostname")
        status = payload.get("status") or payload.get("agent_state") or (
            "ok" if payload.get("fio_rc", 0) in (0, None) else "fio_error"
        )
        error_message = payload.get("error_message")

        with self._lock:
            self._conn.execute(
                """
                INSERT INTO results (
                    result_id, batch_id, source, workload_kind, record_type, hostname, vm_name,
                    cycle, started_at, stopped_at, reported_at, boot_timestamp_unix,
                    cpu_count, mem_total_kb, fio_rc, status, error_message, iops, bw_bytes, lat_ns,
                    fingerprint, file_path, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    result_id,
                    batch_id,
                    source,
                    workload_kind,
                    record_type,
                    hostname,
                    vm_name,
                    int(payload["cycle"]) if payload.get("cycle") is not None else None,
                    started_at,
                    stopped_at,
                    reported_at,
                    boot_ts,
                    int(payload["cpu_count"]) if payload.get("cpu_count") is not None else None,
                    int(payload["mem_total_kb"])
                    if payload.get("mem_total_kb") is not None
                    else None,
                    int(payload["fio_rc"]) if payload.get("fio_rc") is not None else None,
                    status,
                    error_message,
                    iops,
                    bw_bytes,
                    lat_ns,
                    fingerprint,
                    rel_path,
                    now,
                ),
            )

            if _is_manifest(record_type):
                # Replace previous manifest result link if any
                old = self._conn.execute(
                    "SELECT batch_result_id FROM batches WHERE batch_id = ?",
                    (batch_id,),
                ).fetchone()
                if old and old["batch_result_id"]:
                    self._conn.execute(
                        """
                        DELETE FROM results
                        WHERE result_id = ? AND record_type IN ('manifest', 'batch')
                        """,
                        (old["batch_result_id"],),
                    )
                self._conn.execute(
                    """
                    INSERT INTO batches (
                        batch_id, basename, total_vms, total_namespaces, started_at, stopped_at,
                        cloudinit, cores, memory, batch_result_id, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(batch_id) DO UPDATE SET
                        basename=excluded.basename,
                        total_vms=excluded.total_vms,
                        total_namespaces=excluded.total_namespaces,
                        started_at=excluded.started_at,
                        stopped_at=excluded.stopped_at,
                        cloudinit=excluded.cloudinit,
                        cores=excluded.cores,
                        memory=excluded.memory,
                        batch_result_id=excluded.batch_result_id,
                        updated_at=excluded.updated_at
                    """,
                    (
                        batch_id,
                        payload.get("basename"),
                        payload.get("total_vms"),
                        payload.get("total_namespaces"),
                        started_at,
                        stopped_at,
                        payload.get("cloudinit"),
                        payload.get("cores"),
                        payload.get("memory"),
                        result_id,
                        now,
                    ),
                )
            else:
                # Ensure batch row exists even if only cycles arrived
                self._conn.execute(
                    """
                    INSERT INTO batches (batch_id, updated_at)
                    VALUES (?, ?)
                    ON CONFLICT(batch_id) DO UPDATE SET updated_at=excluded.updated_at
                    """,
                    (batch_id, now),
                )

            self._conn.commit()

        if _is_result(record_type):
            vm_for_policy = str(payload.get("vm_name") or payload.get("hostname") or "")
            if vm_for_policy:
                self._consume_cycle_policy(batch_id, vm_for_policy)
                # Result means the cycle finished; clear mid-run "running" so the UI
                # does not stay stuck after a one-shot guest that only heartbeats once.
                result_status = str(payload.get("status") or "ok")
                agent_state = (
                    "error"
                    if result_status in ("fio_error", "missing_fio_json", "fio_json_error")
                    else "idle"
                )
                self._touch_agent_status(batch_id, vm_for_policy, agent_state)
        elif _is_heartbeat(record_type):
            vm_for_policy = str(payload.get("vm_name") or payload.get("hostname") or "")
            agent_state = str(payload.get("agent_state") or payload.get("status") or "idle")
            vmi_phase = payload.get("vmi_phase")
            vmi_phase_s = str(vmi_phase).strip() if vmi_phase is not None else None
            if vm_for_policy:
                self._touch_agent_status(
                    batch_id, vm_for_policy, agent_state, vmi_phase=vmi_phase_s
                )

        return {"result_id": result_id, "batch_id": batch_id, "file_path": rel_path}

    def _policy_row_to_dict(self, row: sqlite3.Row | None, batch_id: str, vm_name: str) -> dict[str, Any]:
        if row is None:
            return {
                "batch_id": batch_id,
                "vm_name": vm_name,
                "mode": "idle",
                "remaining": 0,
                "revision": 0,
                "updated_at": None,
                "run": False,
                "agent_state": None,
                "last_poll_at": None,
                "last_status_at": None,
                "vmi_phase": None,
            }
        mode = str(row["mode"] or "idle")
        remaining = int(row["remaining"] or 0)
        run = mode == "forever" or (mode in ("once", "count") and remaining > 0)
        keys = row.keys()
        return {
            "batch_id": batch_id,
            "vm_name": vm_name,
            "mode": mode,
            "remaining": remaining,
            "revision": int(row["revision"] or 0),
            "updated_at": row["updated_at"],
            "run": run,
            "agent_state": row["agent_state"] if "agent_state" in keys else None,
            "last_poll_at": row["last_poll_at"] if "last_poll_at" in keys else None,
            "last_status_at": row["last_status_at"] if "last_status_at" in keys else None,
            "vmi_phase": row["vmi_phase"] if "vmi_phase" in keys else None,
        }

    def get_policy(
        self,
        batch_id: str,
        vm_name: str,
        *,
        default_mode: str | None = None,
        default_remaining: int | None = None,
    ) -> dict[str, Any]:
        """Return policy for a VM; create row on first poll using optional defaults."""
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM vm_policies WHERE batch_id = ? AND vm_name = ?",
                (batch_id, vm_name),
            ).fetchone()
            if row is None:
                mode = (default_mode or "idle").strip().lower()
                if mode not in ("idle", "once", "count", "forever", "stop"):
                    mode = "idle"
                remaining = 0
                if mode == "once":
                    remaining = 1
                    mode = "count"
                elif mode == "count":
                    remaining = max(0, int(default_remaining or 0))
                elif mode == "forever":
                    remaining = 0
                elif mode == "stop":
                    mode = "idle"
                    remaining = 0
                now = int(time.time())
                self._conn.execute(
                    """
                    INSERT INTO vm_policies (
                        batch_id, vm_name, mode, remaining, revision, updated_at, last_poll_at
                    ) VALUES (?, ?, ?, ?, 1, ?, ?)
                    """,
                    (batch_id, vm_name, mode, remaining, now, now),
                )
                self._conn.execute(
                    """
                    INSERT INTO batches (batch_id, updated_at)
                    VALUES (?, ?)
                    ON CONFLICT(batch_id) DO UPDATE SET updated_at=excluded.updated_at
                    """,
                    (batch_id, now),
                )
                self._conn.commit()
                row = self._conn.execute(
                    "SELECT * FROM vm_policies WHERE batch_id = ? AND vm_name = ?",
                    (batch_id, vm_name),
                ).fetchone()
            else:
                now = int(time.time())
                self._conn.execute(
                    "UPDATE vm_policies SET last_poll_at = ? WHERE batch_id = ? AND vm_name = ?",
                    (now, batch_id, vm_name),
                )
                self._conn.commit()
                row = self._conn.execute(
                    "SELECT * FROM vm_policies WHERE batch_id = ? AND vm_name = ?",
                    (batch_id, vm_name),
                ).fetchone()
            return self._policy_row_to_dict(row, batch_id, vm_name)

    def _touch_agent_status(
        self,
        batch_id: str,
        vm_name: str,
        agent_state: str,
        *,
        vmi_phase: str | None = None,
    ) -> None:
        now = int(time.time())
        with self._lock:
            row = self._conn.execute(
                "SELECT revision FROM vm_policies WHERE batch_id = ? AND vm_name = ?",
                (batch_id, vm_name),
            ).fetchone()
            if row is None:
                self._conn.execute(
                    """
                    INSERT INTO vm_policies (
                        batch_id, vm_name, mode, remaining, revision, updated_at,
                        agent_state, last_status_at, last_poll_at, vmi_phase
                    ) VALUES (?, ?, 'idle', 0, 1, ?, ?, ?, ?, ?)
                    """,
                    (batch_id, vm_name, now, agent_state, now, now, vmi_phase),
                )
            elif vmi_phase is not None:
                self._conn.execute(
                    """
                    UPDATE vm_policies
                    SET agent_state = ?, last_status_at = ?, last_poll_at = ?, vmi_phase = ?
                    WHERE batch_id = ? AND vm_name = ?
                    """,
                    (agent_state, now, now, vmi_phase, batch_id, vm_name),
                )
            else:
                self._conn.execute(
                    """
                    UPDATE vm_policies
                    SET agent_state = ?, last_status_at = ?, last_poll_at = ?
                    WHERE batch_id = ? AND vm_name = ?
                    """,
                    (agent_state, now, now, batch_id, vm_name),
                )
            self._conn.execute(
                """
                INSERT INTO batches (batch_id, updated_at)
                VALUES (?, ?)
                ON CONFLICT(batch_id) DO UPDATE SET updated_at=excluded.updated_at
                """,
                (batch_id, now),
            )
            self._conn.commit()

    def set_policy(
        self,
        batch_id: str,
        vm_name: str,
        *,
        mode: str,
        remaining: int | None = None,
    ) -> dict[str, Any]:
        mode = mode.strip().lower()
        if mode not in ("idle", "once", "count", "forever", "stop"):
            raise ValueError(f"invalid mode: {mode}")
        if mode == "stop":
            mode = "idle"
            remaining = 0
        elif mode == "once":
            mode = "count"
            remaining = 1
        elif mode == "idle":
            remaining = 0
        elif mode == "forever":
            remaining = 0
        elif mode == "count":
            if remaining is None:
                raise ValueError("remaining is required for mode=count")
            remaining = max(0, int(remaining))
            if remaining == 0:
                mode = "idle"

        now = int(time.time())
        with self._lock:
            row = self._conn.execute(
                "SELECT revision FROM vm_policies WHERE batch_id = ? AND vm_name = ?",
                (batch_id, vm_name),
            ).fetchone()
            rev = int(row["revision"] or 0) + 1 if row else 1
            self._conn.execute(
                """
                INSERT INTO vm_policies (batch_id, vm_name, mode, remaining, revision, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(batch_id, vm_name) DO UPDATE SET
                    mode=excluded.mode,
                    remaining=excluded.remaining,
                    revision=excluded.revision,
                    updated_at=excluded.updated_at
                """,
                (batch_id, vm_name, mode, int(remaining or 0), rev, now),
            )
            self._conn.execute(
                """
                INSERT INTO batches (batch_id, updated_at)
                VALUES (?, ?)
                ON CONFLICT(batch_id) DO UPDATE SET updated_at=excluded.updated_at
                """,
                (batch_id, now),
            )
            self._conn.commit()
        return self.get_policy(batch_id, vm_name)

    def set_batch_policy(
        self,
        batch_id: str,
        *,
        mode: str,
        remaining: int | None = None,
        vm_names: list[str] | None = None,
    ) -> dict[str, Any]:
        """Set policy on selected VMs, or all known VMs when vm_names is omitted."""
        names: set[str] = set()
        if vm_names is not None:
            if not isinstance(vm_names, list):
                raise ValueError("vm_names must be a list of VM names")
            for name in vm_names:
                n = str(name or "").strip()
                if n:
                    names.add(n)
            if not names:
                raise ValueError("vm_names is empty")
        else:
            with self._lock:
                for r in self._conn.execute(
                    "SELECT vm_name FROM vm_policies WHERE batch_id = ?", (batch_id,)
                ):
                    if r["vm_name"]:
                        names.add(str(r["vm_name"]))
                for r in self._conn.execute(
                    "SELECT DISTINCT vm_name, hostname FROM results WHERE batch_id = ?",
                    (batch_id,),
                ):
                    if r["vm_name"]:
                        names.add(str(r["vm_name"]))
                    elif r["hostname"]:
                        names.add(str(r["hostname"]))
                batch_row = self._conn.execute(
                    "SELECT batch_result_id FROM batches WHERE batch_id = ?", (batch_id,)
                ).fetchone()
                if batch_row and batch_row["batch_result_id"]:
                    bp = self._load_result_payload(batch_row["batch_result_id"])
                    if bp and isinstance(bp.get("vms"), list):
                        for entry in bp["vms"]:
                            entry_s = str(entry)
                            _, _, name = entry_s.partition("/")
                            names.add(name or entry_s)
        if not names:
            raise ValueError("no VMs known for this batch yet")
        items = [
            self.set_policy(batch_id, name, mode=mode, remaining=remaining)
            for name in sorted(names)
        ]
        return {"batch_id": batch_id, "updated": len(items), "items": items}

    def _consume_cycle_policy(self, batch_id: str, vm_name: str) -> None:
        """After a successful cycle ingest, decrement count/once remaining."""
        with self._lock:
            row = self._conn.execute(
                "SELECT mode, remaining, revision FROM vm_policies WHERE batch_id = ? AND vm_name = ?",
                (batch_id, vm_name),
            ).fetchone()
            if not row:
                return
            mode = str(row["mode"] or "idle")
            if mode not in ("once", "count"):
                return
            remaining = max(0, int(row["remaining"] or 0) - 1)
            new_mode = "idle" if remaining == 0 else "count"
            now = int(time.time())
            self._conn.execute(
                """
                UPDATE vm_policies
                SET mode = ?, remaining = ?, revision = ?, updated_at = ?
                WHERE batch_id = ? AND vm_name = ?
                """,
                (new_mode, remaining, int(row["revision"] or 0) + 1, now, batch_id, vm_name),
            )
            self._conn.commit()

    def list_batches(
        self,
        *,
        q: str | None = None,
        archived: str | None = None,
        basename: str | None = None,
        batch_id: str | None = None,
        namespace: str | None = None,
        api_server: str | None = None,
        today: str | None = None,
        date: str | None = None,
        date_from: str | None = None,
        date_to: str | None = None,
    ) -> dict[str, Any]:
        """Return filtered batch list plus filter facets from the full inventory."""
        with self._lock:
            rows = self._conn.execute("SELECT * FROM batches").fetchall()

            # Facets (unfiltered inventory) for UI dropdowns.
            facet_api: set[str] = set()
            facet_ns: set[str] = set()
            facet_batch: set[str] = set()

            enriched: list[dict[str, Any]] = []
            for row in rows:
                bp = None
                if row["batch_result_id"]:
                    bp = self._load_result_payload(row["batch_result_id"])
                namespaces = _payload_namespaces(bp)
                api = _payload_api_server(bp)
                facet_batch.add(str(row["batch_id"]))
                if api:
                    facet_api.add(api)
                for ns in namespaces:
                    facet_ns.add(ns)

                stats = self._cycle_stats(row["batch_id"])
                item = dict(row)
                item["archived"] = bool(row["archived"])
                item.update(stats)
                item["namespaces"] = namespaces
                item["api_server"] = api
                vms = self._vms_for_batch(row["batch_id"], bp)
                item["vm_summary"] = self._vm_summary(vms, row["total_vms"])
                sort_ts = row["started_at"] or stats.get("first_cycle_at") or row["updated_at"] or 0
                item["_sort"] = sort_ts
                item["_bp"] = bp
                enriched.append(item)

            # Date window (UTC calendar days). today=1 wins over date=YYYY-MM-DD.
            start_bound: int | None = None
            end_bound: int | None = None
            today_flag = str(today or "").strip().lower() in ("1", "true", "yes")
            if today_flag:
                day = datetime.now(tz=timezone.utc).strftime("%Y-%m-%d")
                start_bound, end_bound = _day_bounds_utc(day)
            elif date and str(date).strip():
                try:
                    start_bound, end_bound = _day_bounds_utc(str(date).strip())
                except ValueError:
                    pass
            else:
                if date_from and str(date_from).strip():
                    try:
                        start_bound, _ = _day_bounds_utc(str(date_from).strip())
                    except ValueError:
                        pass
                if date_to and str(date_to).strip():
                    try:
                        _, end_bound = _day_bounds_utc(str(date_to).strip())
                    except ValueError:
                        pass

            out: list[dict[str, Any]] = []
            for item in enriched:
                if archived == "1" and not item["archived"]:
                    continue
                if archived == "0" and item["archived"]:
                    continue
                if basename and (item.get("basename") or "") != basename:
                    continue
                if batch_id:
                    needle = batch_id.lower()
                    if needle not in str(item.get("batch_id") or "").lower():
                        continue
                if namespace:
                    needle = namespace.lower()
                    if not any(needle in ns.lower() for ns in item.get("namespaces") or []):
                        continue
                if api_server:
                    needle = api_server.lower()
                    api = (item.get("api_server") or "").lower()
                    if needle not in api:
                        continue
                if q:
                    blob = " ".join(
                        str(x or "")
                        for x in (
                            item.get("batch_id"),
                            item.get("basename"),
                            item.get("cloudinit"),
                            item.get("label"),
                            item.get("api_server"),
                            " ".join(item.get("namespaces") or []),
                        )
                    ).lower()
                    if q.lower() not in blob:
                        continue
                ts = item.get("started_at") or item.get("_sort") or 0
                try:
                    ts_i = int(ts)
                except (TypeError, ValueError):
                    ts_i = 0
                if start_bound is not None and ts_i < start_bound:
                    continue
                if end_bound is not None and ts_i >= end_bound:
                    continue
                out.append(item)

            out.sort(key=lambda x: x.get("_sort") or 0, reverse=True)
            for item in out:
                item.pop("_sort", None)
                item.pop("_bp", None)
            return {
                "items": out,
                "facets": {
                    "batch_ids": sorted(facet_batch),
                    "namespaces": sorted(facet_ns),
                    "api_servers": sorted(facet_api),
                },
            }

    def list_vm_timestamps(
        self,
        *,
        q: str | None = None,
        archived: str | None = None,
        basename: str | None = None,
        batch_id: str | None = None,
        namespace: str | None = None,
        api_server: str | None = None,
        today: str | None = None,
        date: str | None = None,
        date_from: str | None = None,
        date_to: str | None = None,
    ) -> dict[str, Any]:
        """Flat VM timing rows across batches matching list_batches filters."""
        batches = self.list_batches(
            q=q,
            archived=archived,
            basename=basename,
            batch_id=batch_id,
            namespace=namespace,
            api_server=api_server,
            today=today,
            date=date,
            date_from=date_from,
            date_to=date_to,
        )
        items: list[dict[str, Any]] = []
        for b in batches.get("items") or []:
            bid = b.get("batch_id")
            if not bid:
                continue
            detail = self.get_batch(str(bid))
            if not detail:
                continue
            bp = detail.get("batch_payload") or {}
            cloudinit = bp.get("cloudinit") or detail.get("cloudinit")
            batch_started = detail.get("started_at")
            for v in detail.get("vms") or []:
                boot = v.get("boot_timestamp_unix")
                base_dv = v.get("base_dv_created_at_unix")
                base_dv_ready = v.get("base_dv_ready_at_unix")
                base_dv_bound = v.get("base_dv_bound_at_unix")
                snap = v.get("snapshot_created_at_unix")
                snap_ready = v.get("snapshot_ready_at_unix")
                dv = v.get("dv_created_at_unix")
                dv_ready = v.get("dv_ready_at_unix")
                pvc = v.get("pvc_created_at_unix")
                pvc_bound = v.get("pvc_bound_at_unix")
                data_dv = v.get("data_dv_created_at_unix")
                data_dv_ready = v.get("data_dv_ready_at_unix")
                data_pvc = v.get("data_pvc_created_at_unix")
                data_pvc_bound = v.get("data_pvc_bound_at_unix")
                ssh_ready = v.get("ssh_ready_at_unix")
                items.append(
                    {
                        "batch_id": bid,
                        "basename": detail.get("basename") or b.get("basename"),
                        "cloudinit": cloudinit,
                        "namespace": v.get("namespace"),
                        "vm_name": v.get("vm_name"),
                        "batch_started_at": batch_started,
                        "base_dv_created_at": base_dv,
                        "base_dv_ready_at": base_dv_ready,
                        "base_dv_bound_at": base_dv_bound,
                        "snapshot_created_at": snap,
                        "snapshot_ready_at": snap_ready,
                        "dv_created_at": dv,
                        "dv_ready_at": dv_ready,
                        "pvc_created_at": pvc,
                        "pvc_bound_at": pvc_bound,
                        "data_dv_created_at": data_dv,
                        "data_dv_ready_at": data_dv_ready,
                        "data_pvc_created_at": data_pvc,
                        "data_pvc_bound_at": data_pvc_bound,
                        "ssh_ready_at": ssh_ready,
                        "boot_timestamp": boot,
                    }
                )
        return {"items": items, "total": len(items)}

    def _cycle_stats(self, batch_id: str) -> dict[str, Any]:
        cycles = self._conn.execute(
            """
            SELECT iops, bw_bytes, lat_ns, vm_name, started_at, stopped_at, fingerprint, status, fio_rc
            FROM results
            WHERE batch_id = ? AND record_type IN ('result', 'cycle')
            """,
            (batch_id,),
        ).fetchall()
        events = self._conn.execute(
            """
            SELECT COUNT(*) AS c FROM results
            WHERE batch_id = ? AND record_type IN ('error', 'event')
            """,
            (batch_id,),
        ).fetchone()["c"]
        iops_vals = sorted(float(r["iops"]) for r in cycles if r["iops"] is not None)
        bw_vals = sorted(float(r["bw_bytes"]) for r in cycles if r["bw_bytes"] is not None)
        vms = {r["vm_name"] for r in cycles if r["vm_name"]}
        fingerprints = [r["fingerprint"] for r in cycles if r["fingerprint"]]
        started = [r["started_at"] for r in cycles if r["started_at"] is not None]
        error_count = sum(
            1
            for r in cycles
            if (r["status"] and r["status"] != "ok")
            or (r["fio_rc"] is not None and int(r["fio_rc"]) != 0)
        )
        return {
            "cycle_count": len(cycles),
            "event_count": events,
            "error_count": error_count,
            "vms_reporting": len(vms),
            "iops_avg": statistics.mean(iops_vals) if iops_vals else None,
            "iops_p50": percentile(iops_vals, 50),
            "iops_p99": percentile(iops_vals, 99),
            "bw_avg": statistics.mean(bw_vals) if bw_vals else None,
            "bw_p50": percentile(bw_vals, 50),
            "bw_p99": percentile(bw_vals, 99),
            "fingerprint": fingerprints[-1] if fingerprints else None,
            "first_cycle_at": min(started) if started else None,
            "last_cycle_at": max(
                (r["stopped_at"] or r["started_at"] or 0) for r in cycles
            )
            if cycles
            else None,
        }

    def get_batch(self, batch_id: str) -> dict[str, Any] | None:
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM batches WHERE batch_id = ?", (batch_id,)
            ).fetchone()
            if not row:
                # Still allow viewing if only cycles exist
                any_res = self._conn.execute(
                    "SELECT 1 FROM results WHERE batch_id = ? LIMIT 1", (batch_id,)
                ).fetchone()
                if not any_res:
                    return None
                meta: dict[str, Any] = {
                    "batch_id": batch_id,
                    "archived": False,
                    "basename": None,
                    "batch_result_id": None,
                }
            else:
                meta = dict(row)
                meta["archived"] = bool(row["archived"])

            batch_payload = None
            if meta.get("batch_result_id"):
                batch_payload = self._load_result_payload(meta["batch_result_id"])

            stats = self._cycle_stats(batch_id)
            vms = self._vms_for_batch(batch_id, batch_payload)
            series = self._conn.execute(
                """
                SELECT result_id, vm_name, cycle, started_at, stopped_at, iops, bw_bytes, lat_ns,
                       fio_rc, status, error_message, record_type
                FROM results
                WHERE batch_id = ? AND record_type IN ('result', 'cycle', 'error', 'event')
                ORDER BY started_at ASC, cycle ASC, created_at ASC
                """,
                (batch_id,),
            ).fetchall()

            summary = self._vm_summary(vms, meta.get("total_vms"))
            dv_created_at = None
            dv_ready_at = None
            pvc_created_at = None
            pvc_bound_at = None
            base_dv_created_at = None
            base_dv_ready_at = None
            base_dv_bound_at = None
            snapshot_created_at = None
            snapshot_ready_at = None
            dv_count = None
            pvc_count = None
            snapshot_count = None
            if batch_payload:
                dv_created_at = _payload_unix(batch_payload, "dv_created_at")
                dv_ready_at = _payload_unix(batch_payload, "dv_ready_at")
                pvc_created_at = _payload_unix(batch_payload, "pvc_created_at")
                pvc_bound_at = _payload_unix(batch_payload, "pvc_bound_at") or _payload_unix(
                    batch_payload, "dv_bound_at"
                )
                base_dv_created_at = _payload_unix(batch_payload, "base_dv_created_at")
                base_dv_ready_at = _payload_unix(batch_payload, "base_dv_ready_at")
                base_dv_bound_at = _payload_unix(batch_payload, "base_dv_bound_at")
                snapshot_created_at = _payload_unix(batch_payload, "snapshot_created_at")
                snapshot_ready_at = _payload_unix(batch_payload, "snapshot_ready_at")
                if isinstance(batch_payload.get("dv_created"), list):
                    dv_count = len(batch_payload["dv_created"])
                if isinstance(batch_payload.get("pvc_created"), list):
                    pvc_count = len(batch_payload["pvc_created"])
                if isinstance(batch_payload.get("snapshots"), list):
                    snapshot_count = len(batch_payload["snapshots"])
            return {
                **meta,
                **stats,
                "batch_payload": batch_payload,
                "dv_created_at": dv_created_at,
                "dv_ready_at": dv_ready_at,
                "pvc_created_at": pvc_created_at,
                "pvc_bound_at": pvc_bound_at,
                "base_dv_created_at": base_dv_created_at,
                "base_dv_ready_at": base_dv_ready_at,
                "base_dv_bound_at": base_dv_bound_at,
                "snapshot_created_at": snapshot_created_at,
                "snapshot_ready_at": snapshot_ready_at,
                "dv_count": dv_count,
                "pvc_count": pvc_count,
                "snapshot_count": snapshot_count,
                "vms": vms,
                "vm_summary": summary,
                "series": [dict(r) for r in series],
            }

    def _vms_for_batch(
        self, batch_id: str, batch_payload: dict[str, Any] | None
    ) -> list[dict[str, Any]]:
        named: dict[str, dict[str, Any]] = {}

        if batch_payload and isinstance(batch_payload.get("vms"), list):
            for entry in batch_payload["vms"]:
                entry_s = str(entry)
                ns, _, name = entry_s.partition("/")
                if not name:
                    name = entry_s
                    ns = ""
                named[name] = {
                    "vm_name": name,
                    "namespace": ns or None,
                    "from_metadata": True,
                    "cycle_count": 0,
                    "last_stopped_at": None,
                    "latest_iops": None,
                    "latest_bw_bytes": None,
                    "boot_timestamp_unix": None,
                    "dv_created_at_unix": None,
                    "dv_ready_at_unix": None,
                    "pvc_created_at_unix": None,
                    "pvc_bound_at_unix": None,
                    "data_dv_created_at_unix": None,
                    "data_dv_ready_at_unix": None,
                    "data_pvc_created_at_unix": None,
                    "data_pvc_bound_at_unix": None,
                    "cpu_count": None,
                    "mem_total_kb": None,
                    "hostname": None,
                }

        for r in self._conn.execute(
            "SELECT vm_name FROM vm_policies WHERE batch_id = ?", (batch_id,)
        ):
            name = r["vm_name"]
            if name and name not in named:
                named[name] = {
                    "vm_name": name,
                    "namespace": None,
                    "from_metadata": False,
                    "cycle_count": 0,
                    "last_stopped_at": None,
                    "latest_iops": None,
                    "latest_bw_bytes": None,
                    "boot_timestamp_unix": None,
                    "cpu_count": None,
                    "mem_total_kb": None,
                    "hostname": None,
                }

        rows = self._conn.execute(
            """
            SELECT *
            FROM results
            WHERE batch_id = ? AND record_type IN ('result', 'cycle')
            ORDER BY stopped_at ASC, cycle ASC
            """,
            (batch_id,),
        ).fetchall()
        for r in rows:
            name = r["vm_name"] or r["hostname"] or "unknown"
            cur = named.get(name) or {
                "vm_name": name,
                "namespace": None,
                "from_metadata": False,
                "cycle_count": 0,
                "last_stopped_at": None,
                "latest_iops": None,
                "latest_bw_bytes": None,
                "boot_timestamp_unix": None,
                "cpu_count": None,
                "mem_total_kb": None,
                "hostname": None,
            }
            cur["cycle_count"] = int(cur["cycle_count"]) + 1
            cur["hostname"] = r["hostname"] or cur.get("hostname")
            cur["boot_timestamp_unix"] = r["boot_timestamp_unix"] or cur.get(
                "boot_timestamp_unix"
            )
            cur["cpu_count"] = r["cpu_count"] if r["cpu_count"] is not None else cur.get("cpu_count")
            cur["mem_total_kb"] = (
                r["mem_total_kb"] if r["mem_total_kb"] is not None else cur.get("mem_total_kb")
            )
            cur["last_stopped_at"] = r["stopped_at"] or r["started_at"] or cur.get(
                "last_stopped_at"
            )
            cur["latest_iops"] = r["iops"] if r["iops"] is not None else cur.get("latest_iops")
            cur["latest_bw_bytes"] = (
                r["bw_bytes"] if r["bw_bytes"] is not None else cur.get("latest_bw_bytes")
            )
            named[name] = cur

        # Boot heartbeats (shared across workloads) fill boot_timestamp when no result yet.
        for r in self._conn.execute(
            """
            SELECT vm_name, hostname, boot_timestamp_unix
            FROM results
            WHERE batch_id = ?
              AND record_type IN ('heartbeat', 'status')
              AND boot_timestamp_unix IS NOT NULL
            ORDER BY reported_at ASC, created_at ASC
            """,
            (batch_id,),
        ):
            name = r["vm_name"] or r["hostname"] or "unknown"
            cur = named.get(name) or {
                "vm_name": name,
                "namespace": None,
                "from_metadata": False,
                "cycle_count": 0,
                "last_stopped_at": None,
                "latest_iops": None,
                "latest_bw_bytes": None,
                "boot_timestamp_unix": None,
                "cpu_count": None,
                "mem_total_kb": None,
                "hostname": None,
            }
            cur["hostname"] = r["hostname"] or cur.get("hostname")
            if cur.get("boot_timestamp_unix") is None:
                cur["boot_timestamp_unix"] = r["boot_timestamp_unix"]
            named[name] = cur

        batch_dv_unix = (
            _payload_unix(batch_payload, "dv_created_at") if batch_payload else None
        )
        batch_dv_ready_unix = (
            _payload_unix(batch_payload, "dv_ready_at") if batch_payload else None
        )
        batch_pvc_unix = (
            _payload_unix(batch_payload, "pvc_created_at") if batch_payload else None
        )
        batch_pvc_bound_unix = None
        batch_base_dv_unix = None
        batch_base_dv_ready_unix = None
        batch_base_dv_bound_unix = None
        batch_snapshot_unix = None
        batch_snapshot_ready_unix = None
        if batch_payload:
            batch_pvc_bound_unix = _payload_unix(batch_payload, "pvc_bound_at") or _payload_unix(
                batch_payload, "dv_bound_at"
            )
            batch_base_dv_unix = _payload_unix(batch_payload, "base_dv_created_at")
            batch_base_dv_ready_unix = _payload_unix(batch_payload, "base_dv_ready_at")
            batch_base_dv_bound_unix = _payload_unix(batch_payload, "base_dv_bound_at")
            batch_snapshot_unix = _payload_unix(batch_payload, "snapshot_created_at")
            batch_snapshot_ready_unix = _payload_unix(batch_payload, "snapshot_ready_at")

        def _unix_map(key: str) -> dict[str, int]:
            out: dict[str, int] = {}
            if not batch_payload or not isinstance(batch_payload.get(key), dict):
                return out
            for map_key, val in batch_payload[key].items():
                parsed = _coerce_unix(val)
                if parsed is not None:
                    out[str(map_key)] = parsed
            return out

        vm_dv_map = _unix_map("vm_dv_created")
        vm_dv_ready_map = _unix_map("vm_dv_ready")
        vm_pvc_map = _unix_map("vm_pvc_created")
        vm_pvc_bound_map = _unix_map("vm_pvc_bound")
        if not vm_pvc_bound_map:
            vm_pvc_bound_map = _unix_map("vm_dv_bound")
        vm_data_dv_map = _unix_map("vm_data_dv_created")
        vm_data_dv_ready_map = _unix_map("vm_data_dv_ready")
        vm_data_pvc_map = _unix_map("vm_data_pvc_created")
        vm_data_pvc_bound_map = _unix_map("vm_data_pvc_bound")
        if not vm_data_pvc_bound_map:
            vm_data_pvc_bound_map = _unix_map("vm_data_dv_bound")
        vm_ssh_ready_map = _unix_map("vm_ssh_ready")
        batch_ssh_ready_unix = (
            _payload_unix(batch_payload, "ssh_ready_at") if batch_payload else None
        )

        for name, cur in named.items():
            cur["base_dv_created_at_unix"] = batch_base_dv_unix
            cur["base_dv_ready_at_unix"] = batch_base_dv_ready_unix
            cur["base_dv_bound_at_unix"] = batch_base_dv_bound_unix
            cur["snapshot_created_at_unix"] = batch_snapshot_unix
            cur["snapshot_ready_at_unix"] = batch_snapshot_ready_unix
            cur["dv_created_at_unix"] = vm_dv_map.get(name, batch_dv_unix)
            cur["dv_ready_at_unix"] = vm_dv_ready_map.get(name, batch_dv_ready_unix)
            cur["pvc_created_at_unix"] = vm_pvc_map.get(name, batch_pvc_unix)
            cur["pvc_bound_at_unix"] = vm_pvc_bound_map.get(name, batch_pvc_bound_unix)
            cur["data_dv_created_at_unix"] = vm_data_dv_map.get(name)
            cur["data_dv_ready_at_unix"] = vm_data_dv_ready_map.get(name)
            cur["data_pvc_created_at_unix"] = vm_data_pvc_map.get(name)
            cur["data_pvc_bound_at_unix"] = vm_data_pvc_bound_map.get(name)
            cur["ssh_ready_at_unix"] = vm_ssh_ready_map.get(name, batch_ssh_ready_unix)

        # Attach policy / agent status for each VM
        now = int(time.time())
        stale_after = 120
        for name, cur in named.items():
            pol = self._conn.execute(
                "SELECT * FROM vm_policies WHERE batch_id = ? AND vm_name = ?",
                (batch_id, name),
            ).fetchone()
            if pol:
                p = self._policy_row_to_dict(pol, batch_id, name)
                cur["policy_mode"] = p["mode"]
                cur["policy_remaining"] = p["remaining"]
                cur["agent_state"] = p.get("agent_state")
                cur["last_poll_at"] = p.get("last_poll_at")
                cur["vmi_phase"] = p.get("vmi_phase")
                last = p.get("last_poll_at") or p.get("last_status_at")
                if p.get("agent_state") == "running":
                    cur["ui_status"] = "running"
                elif p.get("agent_state") == "error":
                    cur["ui_status"] = "error"
                elif last and (now - int(last)) > stale_after:
                    cur["ui_status"] = "stale"
                elif p["mode"] == "forever" or (p["mode"] == "count" and p["remaining"] > 0):
                    cur["ui_status"] = "queued"
                else:
                    cur["ui_status"] = "idle"
            else:
                cur["policy_mode"] = None
                cur["policy_remaining"] = None
                cur["agent_state"] = None
                cur["last_poll_at"] = None
                cur["vmi_phase"] = None
                cur["ui_status"] = "waiting"

        return sorted(named.values(), key=lambda x: x["vm_name"])

    def _vm_summary(self, vms: list[dict[str, Any]], total_vms: int | None) -> dict[str, Any]:
        counts = {
            "configured": int(total_vms) if total_vms is not None else len(vms),
            "checked_in": 0,
            "idle": 0,
            "running": 0,
            "queued": 0,
            "waiting": 0,
            "error": 0,
            "stale": 0,
            "vmi_running": None,
        }
        vmi_known = 0
        vmi_running = 0
        for v in vms:
            st = v.get("ui_status") or "waiting"
            if st in counts:
                counts[st] += 1
            if st != "waiting":
                counts["checked_in"] += 1
            phase = v.get("vmi_phase")
            if phase:
                vmi_known += 1
                if str(phase).strip().lower() == "running":
                    vmi_running += 1
        if vmi_known:
            counts["vmi_running"] = vmi_running
        return counts

    def get_vm(self, batch_id: str, vm_name: str) -> dict[str, Any] | None:
        with self._lock:
            rows = self._conn.execute(
                """
                SELECT *
                FROM results
                WHERE batch_id = ? AND record_type IN ('result', 'cycle', 'error', 'event')
                  AND (vm_name = ? OR hostname = ?)
                ORDER BY cycle ASC, started_at ASC, created_at ASC
                """,
                (batch_id, vm_name, vm_name),
            ).fetchall()
            batch = self._conn.execute(
                "SELECT * FROM batches WHERE batch_id = ?", (batch_id,)
            ).fetchone()
            if not rows and not batch:
                any_res = self._conn.execute(
                    "SELECT 1 FROM results WHERE batch_id = ? LIMIT 1", (batch_id,)
                ).fetchone()
                if not any_res:
                    return None

            cycles = []
            identity: dict[str, Any] = {"vm_name": vm_name, "batch_id": batch_id}
            for r in rows:
                identity.update(
                    {
                        "hostname": r["hostname"] or identity.get("hostname"),
                        "cpu_count": r["cpu_count"]
                        if r["cpu_count"] is not None
                        else identity.get("cpu_count"),
                        "mem_total_kb": r["mem_total_kb"]
                        if r["mem_total_kb"] is not None
                        else identity.get("mem_total_kb"),
                        "boot_timestamp_unix": r["boot_timestamp_unix"]
                        or identity.get("boot_timestamp_unix"),
                    }
                )
                cycles.append(
                    {
                        "result_id": r["result_id"],
                        "record_type": r["record_type"],
                        "cycle": r["cycle"],
                        "started_at": r["started_at"],
                        "stopped_at": r["stopped_at"],
                        "duration_s": (
                            (r["stopped_at"] - r["started_at"])
                            if r["started_at"] is not None and r["stopped_at"] is not None
                            else None
                        ),
                        "fio_rc": r["fio_rc"],
                        "status": r["status"] if "status" in r.keys() else None,
                        "error_message": r["error_message"]
                        if "error_message" in r.keys()
                        else None,
                        "iops": r["iops"],
                        "bw_bytes": r["bw_bytes"],
                        "lat_ns": r["lat_ns"],
                        "fingerprint": r["fingerprint"],
                        "reported_at": r["reported_at"],
                    }
                )

            if identity.get("boot_timestamp_unix") is None:
                hb = self._conn.execute(
                    """
                    SELECT boot_timestamp_unix, hostname
                    FROM results
                    WHERE batch_id = ?
                      AND record_type IN ('heartbeat', 'status')
                      AND boot_timestamp_unix IS NOT NULL
                      AND (vm_name = ? OR hostname = ?)
                    ORDER BY reported_at ASC, created_at ASC
                    LIMIT 1
                    """,
                    (batch_id, vm_name, vm_name),
                ).fetchone()
                if hb:
                    identity["boot_timestamp_unix"] = hb["boot_timestamp_unix"]
                    identity["hostname"] = hb["hostname"] or identity.get("hostname")

            first_report = min((c["reported_at"] for c in cycles if c.get("reported_at")), default=None)
            boot = identity.get("boot_timestamp_unix")
            identity["first_report_lag_s"] = (
                (first_report - boot) if first_report is not None and boot is not None else None
            )
            policy = self.get_policy(batch_id, vm_name)
            return {
                "identity": identity,
                "cycles": cycles,
                "cycle_count": len(cycles),
                "policy": policy,
            }

    def list_results(
        self,
        batch_id: str,
        *,
        vm: str | None = None,
        record_type: str | None = None,
        limit: int = 200,
        offset: int = 0,
    ) -> dict[str, Any]:
        with self._lock:
            clauses = ["batch_id = ?"]
            args: list[Any] = [batch_id]
            if vm:
                clauses.append("(vm_name = ? OR hostname = ?)")
                args.extend([vm, vm])
            if record_type:
                rt = _normalize_record_type(str(record_type))
                aliases = {
                    "manifest": ("manifest", "batch"),
                    "result": ("result", "cycle"),
                    "error": ("error", "event"),
                    "heartbeat": ("heartbeat", "status"),
                }.get(rt, (rt,))
                placeholders = ", ".join("?" for _ in aliases)
                clauses.append(f"record_type IN ({placeholders})")
                args.extend(aliases)
            where = " AND ".join(clauses)
            total = self._conn.execute(
                f"SELECT COUNT(*) AS c FROM results WHERE {where}", args
            ).fetchone()["c"]
            rows = self._conn.execute(
                f"""
                SELECT result_id, batch_id, source, workload_kind, record_type, hostname, vm_name,
                       cycle, started_at, stopped_at, reported_at, iops, bw_bytes, lat_ns,
                       fio_rc, status, error_message
                FROM results
                WHERE {where}
                ORDER BY reported_at DESC, created_at DESC
                LIMIT ? OFFSET ?
                """,
                [*args, limit, offset],
            ).fetchall()
            return {"total": total, "limit": limit, "offset": offset, "items": [dict(r) for r in rows]}

    def get_result(self, batch_id: str, result_id: str) -> dict[str, Any] | None:
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM results WHERE batch_id = ? AND result_id = ?",
                (batch_id, result_id),
            ).fetchone()
            if not row:
                return None
            payload = self._load_result_payload(result_id)
            meta = dict(row)
            return {"meta": meta, "payload": payload}

    def _load_result_payload(self, result_id: str) -> dict[str, Any] | None:
        row = self._conn.execute(
            "SELECT file_path FROM results WHERE result_id = ?", (result_id,)
        ).fetchone()
        if not row:
            return None
        path = self.data_dir / row["file_path"]
        if not path.is_file():
            return None
        return json.loads(path.read_text(encoding="utf-8"))

    def patch_batch(self, batch_id: str, body: dict[str, Any]) -> dict[str, Any] | None:
        with self._lock:
            row = self._conn.execute(
                "SELECT batch_id FROM batches WHERE batch_id = ?", (batch_id,)
            ).fetchone()
            if not row:
                # create shell row if cycles exist
                any_res = self._conn.execute(
                    "SELECT 1 FROM results WHERE batch_id = ? LIMIT 1", (batch_id,)
                ).fetchone()
                if not any_res:
                    return None
                self._conn.execute(
                    "INSERT INTO batches (batch_id, updated_at) VALUES (?, ?)",
                    (batch_id, int(time.time())),
                )

            fields = []
            args: list[Any] = []
            if "label" in body:
                fields.append("label = ?")
                args.append(body.get("label"))
            if "notes" in body:
                fields.append("notes = ?")
                args.append(body.get("notes"))
            if "archived" in body:
                fields.append("archived = ?")
                args.append(1 if body.get("archived") else 0)
            if not fields:
                raise ValueError("no patchable fields (label, notes, archived)")
            fields.append("updated_at = ?")
            args.append(int(time.time()))
            args.append(batch_id)
            self._conn.execute(
                f"UPDATE batches SET {', '.join(fields)} WHERE batch_id = ?",
                args,
            )
            self._conn.commit()
        return self.get_batch(batch_id)

    def delete_batch(self, batch_id: str) -> bool:
        with self._lock:
            rows = self._conn.execute(
                "SELECT result_id FROM results WHERE batch_id = ?", (batch_id,)
            ).fetchall()
            if not rows and not self._conn.execute(
                "SELECT 1 FROM batches WHERE batch_id = ?", (batch_id,)
            ).fetchone():
                return False
            self._conn.execute("DELETE FROM results WHERE batch_id = ?", (batch_id,))
            self._conn.execute("DELETE FROM batches WHERE batch_id = ?", (batch_id,))
            self._conn.execute("DELETE FROM vm_policies WHERE batch_id = ?", (batch_id,))
            self._conn.commit()
        batch_dir = self.results_dir / _safe_name(batch_id)
        if batch_dir.is_dir():
            shutil.rmtree(batch_dir)
        return True


def _safe_name(name: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "_", name).strip("._")
    return cleaned or "unknown"


class App:
    def __init__(self, store: Store, token: str | None) -> None:
        self.store = store
        self.token = token


def make_handler(app: App):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt: str, *args: Any) -> None:
            sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

        def _check_auth(self) -> bool:
            if not app.token:
                return True
            auth = self.headers.get("Authorization", "")
            if auth == f"Bearer {app.token}":
                return True
            # Allow static UI without token when browsing locally; API still gated.
            # If token set, require it for all API paths.
            self._json(401, {"error": "unauthorized"})
            return False

        def _cors_headers(self) -> None:
            """Allow standalone dashboard origins to call this API (lab use)."""
            origin = (self.headers.get("Origin") or "").strip()
            self.send_header(
                "Access-Control-Allow-Origin", origin if origin else "*"
            )
            self.send_header("Vary", "Origin")
            self.send_header(
                "Access-Control-Allow-Methods",
                "GET, POST, PUT, PATCH, DELETE, OPTIONS",
            )
            self.send_header(
                "Access-Control-Allow-Headers",
                "Authorization, Content-Type, Accept",
            )
            self.send_header("Access-Control-Max-Age", "86400")

        def _read_json(self) -> dict[str, Any]:
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length else b"{}"
            if not raw:
                return {}
            data = json.loads(raw.decode("utf-8"))
            if not isinstance(data, dict):
                raise ValueError("JSON object required")
            return data

        def _json(self, status: int, body: Any) -> None:
            data = json.dumps(body, default=str).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self._cors_headers()
            self.end_headers()
            self.wfile.write(data)

        def _bytes(self, status: int, data: bytes, content_type: str) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self._cors_headers()
            self.end_headers()
            self.wfile.write(data)

        def do_OPTIONS(self) -> None:  # noqa: N802
            self.send_response(204)
            self._cors_headers()
            self.send_header("Content-Length", "0")
            self.end_headers()

        def do_GET(self) -> None:  # noqa: N802
            parsed = urlparse(self.path)
            path = unquote(parsed.path)
            qs = parse_qs(parsed.query)

            if path == "/healthz":
                self._json(200, {"ok": True})
                return

            if path.startswith("/v1/"):
                if not self._check_auth():
                    return
                self._handle_api_get(path, qs)
                return

            self._serve_static(path)

        def do_POST(self) -> None:  # noqa: N802
            parsed = urlparse(self.path)
            path = unquote(parsed.path)
            if not self._check_auth():
                return
            if path == "/v1/results":
                try:
                    payload = self._read_json()
                    result = app.store.ingest(payload)
                    self._json(201, result)
                except ValueError as exc:
                    self._json(400, {"error": str(exc)})
                except json.JSONDecodeError as exc:
                    self._json(400, {"error": f"invalid JSON: {exc}"})
                except Exception as exc:  # noqa: BLE001
                    self._json(500, {"error": str(exc)})
                return

            m = re.fullmatch(r"/v1/batches/([^/]+)/policy", path)
            if m:
                try:
                    body = self._read_json()
                    mode = str(body.get("mode") or "")
                    remaining = body.get("remaining")
                    if remaining is not None:
                        remaining = int(remaining)
                    result = app.store.set_batch_policy(
                        m.group(1),
                        mode=mode,
                        remaining=remaining,
                        vm_names=body.get("vm_names"),
                    )
                    self._json(200, result)
                except ValueError as exc:
                    self._json(400, {"error": str(exc)})
                except json.JSONDecodeError as exc:
                    self._json(400, {"error": f"invalid JSON: {exc}"})
                except Exception as exc:  # noqa: BLE001
                    self._json(500, {"error": str(exc)})
                return

            self._json(404, {"error": "not found"})

        def do_PUT(self) -> None:  # noqa: N802
            if not self._check_auth():
                return
            parsed = urlparse(self.path)
            path = unquote(parsed.path)
            m = re.fullmatch(r"/v1/batches/([^/]+)/vms/([^/]+)/policy", path)
            if not m:
                self._json(404, {"error": "not found"})
                return
            try:
                body = self._read_json()
                mode = str(body.get("mode") or "")
                remaining = body.get("remaining")
                if remaining is not None:
                    remaining = int(remaining)
                policy = app.store.set_policy(
                    m.group(1), m.group(2), mode=mode, remaining=remaining
                )
                self._json(200, policy)
            except ValueError as exc:
                self._json(400, {"error": str(exc)})
            except json.JSONDecodeError as exc:
                self._json(400, {"error": f"invalid JSON: {exc}"})
            except Exception as exc:  # noqa: BLE001
                self._json(500, {"error": str(exc)})

        def do_PATCH(self) -> None:  # noqa: N802
            if not self._check_auth():
                return
            parsed = urlparse(self.path)
            path = unquote(parsed.path)
            m = re.fullmatch(r"/v1/batches/([^/]+)", path)
            if not m:
                self._json(404, {"error": "not found"})
                return
            batch_id = m.group(1)
            try:
                body = self._read_json()
                updated = app.store.patch_batch(batch_id, body)
                if updated is None:
                    self._json(404, {"error": "batch not found"})
                    return
                self._json(200, updated)
            except ValueError as exc:
                self._json(400, {"error": str(exc)})
            except json.JSONDecodeError as exc:
                self._json(400, {"error": f"invalid JSON: {exc}"})
            except Exception as exc:  # noqa: BLE001
                self._json(500, {"error": str(exc)})

        def do_DELETE(self) -> None:  # noqa: N802
            if not self._check_auth():
                return
            parsed = urlparse(self.path)
            path = unquote(parsed.path)
            m = re.fullmatch(r"/v1/batches/([^/]+)", path)
            if not m:
                self._json(404, {"error": "not found"})
                return
            try:
                ok = app.store.delete_batch(m.group(1))
                if not ok:
                    self._json(404, {"error": "batch not found"})
                    return
                self._json(200, {"deleted": True, "batch_id": m.group(1)})
            except Exception as exc:  # noqa: BLE001
                self._json(500, {"error": str(exc)})

        def _handle_api_get(self, path: str, qs: dict[str, list[str]]) -> None:
            if path == "/v1/batches":
                self._json(
                    200,
                    app.store.list_batches(
                        q=(qs.get("q") or [None])[0],
                        archived=(qs.get("archived") or [None])[0],
                        basename=(qs.get("basename") or [None])[0],
                        batch_id=(qs.get("batch_id") or [None])[0],
                        namespace=(qs.get("namespace") or [None])[0],
                        api_server=(qs.get("api_server") or [None])[0],
                        today=(qs.get("today") or [None])[0],
                        date=(qs.get("date") or [None])[0],
                        date_from=(qs.get("date_from") or [None])[0],
                        date_to=(qs.get("date_to") or [None])[0],
                    ),
                )
                return

            if path == "/v1/timestamps":
                self._json(
                    200,
                    app.store.list_vm_timestamps(
                        q=(qs.get("q") or [None])[0],
                        archived=(qs.get("archived") or [None])[0],
                        basename=(qs.get("basename") or [None])[0],
                        batch_id=(qs.get("batch_id") or [None])[0],
                        namespace=(qs.get("namespace") or [None])[0],
                        api_server=(qs.get("api_server") or [None])[0],
                        today=(qs.get("today") or [None])[0],
                        date=(qs.get("date") or [None])[0],
                        date_from=(qs.get("date_from") or [None])[0],
                        date_to=(qs.get("date_to") or [None])[0],
                    ),
                )
                return

            if path == "/v1/policy":
                batch_id = (qs.get("batch_id") or [None])[0]
                vm_name = (qs.get("vm_name") or [None])[0]
                if not batch_id or not vm_name:
                    self._json(400, {"error": "batch_id and vm_name are required"})
                    return
                default_mode = (qs.get("default_mode") or [None])[0]
                default_remaining = (qs.get("default_remaining") or [None])[0]
                rem = int(default_remaining) if default_remaining not in (None, "") else None
                self._json(
                    200,
                    app.store.get_policy(
                        batch_id,
                        vm_name,
                        default_mode=default_mode,
                        default_remaining=rem,
                    ),
                )
                return

            m = re.fullmatch(r"/v1/batches/([^/]+)", path)
            if m:
                detail = app.store.get_batch(m.group(1))
                if detail is None:
                    self._json(404, {"error": "batch not found"})
                    return
                self._json(200, detail)
                return

            m = re.fullmatch(r"/v1/batches/([^/]+)/vms/([^/]+)/policy", path)
            if m:
                self._json(200, app.store.get_policy(m.group(1), m.group(2)))
                return

            m = re.fullmatch(r"/v1/batches/([^/]+)/vms/([^/]+)", path)
            if m:
                detail = app.store.get_vm(m.group(1), m.group(2))
                if detail is None:
                    self._json(404, {"error": "batch/vm not found"})
                    return
                self._json(200, detail)
                return

            m = re.fullmatch(r"/v1/batches/([^/]+)/results/([^/]+)", path)
            if m:
                detail = app.store.get_result(m.group(1), m.group(2))
                if detail is None:
                    self._json(404, {"error": "result not found"})
                    return
                self._json(200, detail)
                return

            m = re.fullmatch(r"/v1/batches/([^/]+)/results", path)
            if m:
                try:
                    limit = int((qs.get("limit") or ["200"])[0])
                    offset = int((qs.get("offset") or ["0"])[0])
                except ValueError:
                    self._json(400, {"error": "invalid limit/offset"})
                    return
                self._json(
                    200,
                    app.store.list_results(
                        m.group(1),
                        vm=(qs.get("vm") or [None])[0],
                        record_type=(qs.get("record_type") or [None])[0],
                        limit=max(1, min(limit, 1000)),
                        offset=max(0, offset),
                    ),
                )
                return

            self._json(404, {"error": "not found"})

        def _serve_static(self, path: str) -> None:
            if path in ("/", ""):
                path = "/index.html"
            # prevent path traversal (path-aware: avoid prefix false positives like static-extra)
            rel = path.lstrip("/")
            static_root = STATIC_DIR.resolve()
            target = (STATIC_DIR / rel).resolve()
            try:
                target.relative_to(static_root)
            except ValueError:
                self._json(403, {"error": "forbidden"})
                return
            if not target.is_file():
                # SPA fallback
                index = STATIC_DIR / "index.html"
                if index.is_file():
                    data = index.read_bytes()
                    self._bytes(200, data, "text/html; charset=utf-8")
                    return
                self._json(404, {"error": "not found"})
                return
            ctype = mimetypes.guess_type(str(target))[0] or "application/octet-stream"
            if ctype.startswith("text/") or ctype.endswith("javascript"):
                ctype = f"{ctype}; charset=utf-8"
            self._bytes(200, target.read_bytes(), ctype)

    return Handler


def parse_listen(value: str) -> tuple[str, int]:
    if ":" not in value:
        raise argparse.ArgumentTypeError("listen must be HOST:PORT")
    host, _, port_s = value.rpartition(":")
    host = host or "0.0.0.0"
    try:
        port = int(port_s)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("invalid port") from exc
    return host, port


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Workload result collector + dashboard")
    parser.add_argument(
        "--listen",
        default="0.0.0.0:8080",
        type=parse_listen,
        help="HOST:PORT to bind (default 0.0.0.0:8080)",
    )
    parser.add_argument(
        "--data-dir",
        type=Path,
        default=Path("./data-collector-data"),
        help="Directory for SQLite index and raw JSON payloads",
    )
    parser.add_argument(
        "--token",
        default=None,
        help="Optional bearer token required for API requests",
    )
    args = parser.parse_args(argv)

    data_dir = args.data_dir.resolve()
    data_dir.mkdir(parents=True, exist_ok=True)
    store = Store(data_dir)
    app = App(store, args.token)
    host, port = args.listen
    handler = make_handler(app)
    server = ThreadingHTTPServer((host, port), handler)
    print(f"data-collector listening on http://{host}:{port}/")
    print(f"data dir: {data_dir}")
    print(f"POST results to http://{host}:{port}/v1/results")
    print(f"GET  policy  http://{host}:{port}/v1/policy?batch_id=&vm_name=")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nshutting down")
    finally:
        server.server_close()
        store.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
