#!/usr/bin/env python3
"""Collect batch DV / PVC / VolumeSnapshot timestamps for the vstorm manifest.

Reads cluster JSON dumps (or paths via env) and prints a JSON object with
batch-level and per-VM create/ready/bound times. Invoked by ``vstorm`` after
create; unit-tested without a live cluster. Lives under
``monitoring/workload-result/`` next to the result server.
"""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from typing import Any


def to_iso_z(ts: Any) -> str | None:
    if not ts:
        return None
    s = str(ts).strip()
    if s.endswith("Z"):
        return s
    try:
        if s.endswith("+00:00"):
            return s[:-6] + "Z"
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return s


def load_env_json(key: str, default: Any = None) -> Any:
    raw = os.environ.get(key) or ""
    if not raw.strip():
        return {} if default is None else default
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {} if default is None else default


def load_json_file(path: str, default: Any = None) -> Any:
    if not path or not str(path).strip():
        return {} if default is None else default
    try:
        with open(path, "r", encoding="utf-8") as f:
            raw = f.read()
    except OSError:
        return {} if default is None else default
    if not raw.strip():
        return {} if default is None else default
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {} if default is None else default


def load_json_file_env(path_key: str, default: Any = None) -> Any:
    return load_json_file((os.environ.get(path_key) or "").strip(), default)


def dv_condition_times(item: dict) -> tuple[str | None, str | None]:
    """Return (ready_at, bound_at) from DV status.conditions."""
    status = item.get("status") or {}
    ready_ts = None
    completed_ts = None
    bound_ts = None
    for c in status.get("conditions") or []:
        if not isinstance(c, dict):
            continue
        t = to_iso_z(c.get("lastTransitionTime") or "")
        if not t:
            continue
        ctype = str(c.get("type") or "")
        cstatus = str(c.get("status") or "")
        reason = str(c.get("reason") or "")
        if ctype == "Ready" and cstatus == "True":
            ready_ts = t
        elif ctype == "Running" and reason == "Completed":
            completed_ts = t
        elif ctype == "Bound" and cstatus == "True":
            bound_ts = t
    return (ready_ts or completed_ts), bound_ts


def collect_batch_timestamps(
    *,
    basename: str,
    batch_id: str,
    vms: list,
    ns_list: list,
    dv_doc: dict,
    pvc_doc: dict,
    vs_doc: dict,
) -> dict:
    """Build the DV/PVC/snapshot timestamp payload from cluster JSON docs."""
    basename = (basename or "").strip()
    batch_id = (batch_id or "").strip()
    ns_set = {str(n) for n in (ns_list or []) if n}
    for entry in vms or []:
        entry_s = str(entry)
        ns, _, name = entry_s.partition("/")
        if ns:
            ns_set.add(ns)
    ns_prefix = f"vm-{batch_id}-ns-" if batch_id else None

    vm_names: set[str] = set()
    for entry in vms or []:
        entry_s = str(entry)
        ns, _, name = entry_s.partition("/")
        if not name:
            name = entry_s
        if name:
            vm_names.add(name)

    def in_batch_ns(ns: str, labels: dict | None = None) -> bool:
        labels = labels or {}
        if batch_id and str(labels.get("batch-id") or "") == batch_id:
            return True
        if ns_set:
            return ns in ns_set
        if ns_prefix:
            return ns.startswith(ns_prefix)
        return False

    def classify(name: str) -> str:
        if not name:
            return "other"
        if name.endswith("-data"):
            return "data"
        if basename and name == f"{basename}-base":
            return "base"
        if name in vm_names:
            return "root"
        return "other"

    def collect_pvc_items(doc: dict) -> list[dict]:
        out: list[dict] = []
        for it in (doc.get("items") or []):
            md = it.get("metadata") or {}
            name = md.get("name") or ""
            ns = md.get("namespace") or ""
            created = to_iso_z(md.get("creationTimestamp") or "")
            if not name or not created:
                continue
            if not in_batch_ns(ns, md.get("labels") or {}):
                continue
            role = classify(name)
            if role == "other" and name.endswith("-data"):
                role = "data"
            out.append({"namespace": ns, "name": name, "created_at": created, "role": role})
        out.sort(key=lambda d: (d["created_at"], d["namespace"], d["name"]))
        return out

    def collect_dv_items(doc: dict) -> list[dict]:
        out: list[dict] = []
        for it in (doc.get("items") or []):
            md = it.get("metadata") or {}
            name = md.get("name") or ""
            ns = md.get("namespace") or ""
            created = to_iso_z(md.get("creationTimestamp") or "")
            if not name or not created:
                continue
            if not in_batch_ns(ns, md.get("labels") or {}):
                continue
            role = classify(name)
            if role == "other" and name.endswith("-data"):
                role = "data"
            entry: dict[str, Any] = {
                "namespace": ns,
                "name": name,
                "created_at": created,
                "role": role,
            }
            ready, bound = dv_condition_times(it)
            if ready:
                entry["ready_at"] = ready
            if bound:
                entry["bound_at"] = bound
            phase = ((it.get("status") or {}).get("phase") or "")
            if phase:
                entry["phase"] = str(phase)
            claim = ((it.get("status") or {}).get("claimName") or "").strip()
            if claim:
                entry["claim_name"] = claim
            out.append(entry)
        out.sort(key=lambda d: (d["created_at"], d["namespace"], d["name"]))
        return out

    def collect_snapshot_items(doc: dict) -> list[dict]:
        """VolumeSnapshots in batch namespaces: created_at + ready_at."""
        out: list[dict] = []
        for it in (doc.get("items") or []):
            md = it.get("metadata") or {}
            name = md.get("name") or ""
            ns = md.get("namespace") or ""
            created = to_iso_z(md.get("creationTimestamp") or "")
            if not name or not created:
                continue
            if not in_batch_ns(ns, md.get("labels") or {}):
                continue
            entry: dict[str, Any] = {"namespace": ns, "name": name, "created_at": created}
            status = it.get("status") or {}
            ready_flag = status.get("readyToUse")
            if ready_flag is True or str(ready_flag).lower() == "true":
                ready = to_iso_z(status.get("creationTime") or "") or created
                entry["ready_at"] = ready
                entry["ready"] = True
            else:
                entry["ready"] = False
            out.append(entry)
        out.sort(key=lambda d: (d["created_at"], d["namespace"], d["name"]))
        return out

    dv_created = collect_dv_items(dv_doc or {})
    pvc_created = collect_pvc_items(pvc_doc or {})
    snapshots = collect_snapshot_items(vs_doc or {})

    dv_bound_by_claim: dict[tuple[str, str], str] = {}
    for d in dv_created:
        if not d.get("bound_at"):
            continue
        claim = d.get("claim_name") or d["name"]
        dv_bound_by_claim[(d["namespace"], claim)] = d["bound_at"]
        dv_bound_by_claim[(d["namespace"], d["name"])] = d["bound_at"]

    for p in pvc_created:
        b = dv_bound_by_claim.get((p["namespace"], p["name"]))
        if b:
            p["bound_at"] = b

    out: dict[str, Any] = {}
    if dv_created:
        out["dv_created"] = dv_created
        out["dv_created_at"] = min(d["created_at"] for d in dv_created)
        ready_vals = [d["ready_at"] for d in dv_created if d.get("ready_at")]
        if ready_vals:
            out["dv_ready_at"] = min(ready_vals)
        bound_vals = [d["bound_at"] for d in dv_created if d.get("bound_at")]
        if bound_vals:
            out["dv_bound_at"] = min(bound_vals)

    by_ns_name = {(d["namespace"], d["name"]): d for d in dv_created}
    base_by_ns: dict[str, str] = {}
    base_ready_by_ns: dict[str, str] = {}
    base_bound_by_ns: dict[str, str] = {}
    for d in dv_created:
        if d.get("role") == "base" or (basename and d["name"] == f"{basename}-base"):
            base_by_ns[d["namespace"]] = d["created_at"]
            if d.get("ready_at"):
                base_ready_by_ns[d["namespace"]] = d["ready_at"]
            if d.get("bound_at"):
                base_bound_by_ns[d["namespace"]] = d["bound_at"]

    base_dvs = [
        d
        for d in dv_created
        if d.get("role") == "base" or (basename and d["name"] == f"{basename}-base")
    ]
    if base_dvs:
        out["base_dv"] = base_dvs
        out["base_dv_created_at"] = min(d["created_at"] for d in base_dvs)
        base_ready_vals = [d["ready_at"] for d in base_dvs if d.get("ready_at")]
        if base_ready_vals:
            out["base_dv_ready_at"] = min(base_ready_vals)
        base_bound_vals = [d["bound_at"] for d in base_dvs if d.get("bound_at")]
        if base_bound_vals:
            out["base_dv_bound_at"] = min(base_bound_vals)

    if snapshots:
        out["snapshots"] = snapshots
        out["snapshot_created_at"] = min(s["created_at"] for s in snapshots)
        snap_ready_vals = [s["ready_at"] for s in snapshots if s.get("ready_at")]
        if snap_ready_vals:
            out["snapshot_ready_at"] = min(snap_ready_vals)

    vm_dv: dict[str, str] = {}
    vm_data_dv: dict[str, str] = {}
    vm_dv_ready: dict[str, str] = {}
    vm_data_dv_ready: dict[str, str] = {}
    vm_dv_bound: dict[str, str] = {}
    vm_data_dv_bound: dict[str, str] = {}
    for entry in vms or []:
        entry_s = str(entry)
        ns, _, name = entry_s.partition("/")
        if not name:
            name = entry_s
            ns = ""

        def pick_dv(dv_name: str, _ns: str = ns) -> dict | None:
            if _ns and dv_name and (_ns, dv_name) in by_ns_name:
                return by_ns_name[(_ns, dv_name)]
            for d in dv_created:
                if d["name"] == dv_name and (not _ns or d["namespace"] == _ns):
                    return d
            return None

        root = pick_dv(name) if name else None
        if root is None and ns and ns in base_by_ns:
            vm_dv[name] = base_by_ns[ns]
            if ns in base_ready_by_ns:
                vm_dv_ready[name] = base_ready_by_ns[ns]
            if ns in base_bound_by_ns:
                vm_dv_bound[name] = base_bound_by_ns[ns]
        elif root is not None:
            vm_dv[name] = root["created_at"]
            if root.get("ready_at"):
                vm_dv_ready[name] = root["ready_at"]
            if root.get("bound_at"):
                vm_dv_bound[name] = root["bound_at"]

        data_name = f"{name}-data" if name else ""
        data = pick_dv(data_name) if data_name else None
        if data is not None:
            vm_data_dv[name] = data["created_at"]
            if data.get("ready_at"):
                vm_data_dv_ready[name] = data["ready_at"]
            if data.get("bound_at"):
                vm_data_dv_bound[name] = data["bound_at"]

    if vm_dv:
        out["vm_dv_created"] = vm_dv
    if vm_data_dv:
        out["vm_data_dv_created"] = vm_data_dv
    if vm_dv_ready:
        out["vm_dv_ready"] = vm_dv_ready
    if vm_data_dv_ready:
        out["vm_data_dv_ready"] = vm_data_dv_ready
    if vm_dv_bound:
        out["vm_dv_bound"] = vm_dv_bound
    if vm_data_dv_bound:
        out["vm_data_dv_bound"] = vm_data_dv_bound

    if pvc_created:
        out["pvc_created"] = pvc_created
        out["pvc_created_at"] = min(d["created_at"] for d in pvc_created)
        pvc_bound_vals = [d["bound_at"] for d in pvc_created if d.get("bound_at")]
        if pvc_bound_vals:
            out["pvc_bound_at"] = min(pvc_bound_vals)

    pvc_by_ns_name = {(d["namespace"], d["name"]): d for d in pvc_created}
    vm_pvc: dict[str, str] = {}
    vm_data_pvc: dict[str, str] = {}
    vm_pvc_bound: dict[str, str] = {}
    vm_data_pvc_bound: dict[str, str] = {}
    for entry in vms or []:
        entry_s = str(entry)
        ns, _, name = entry_s.partition("/")
        if not name:
            name = entry_s
            ns = ""
        root_pvc = None
        if ns and name and (ns, name) in pvc_by_ns_name:
            root_pvc = pvc_by_ns_name[(ns, name)]
        elif name:
            for d in pvc_created:
                if d["name"] == name and d.get("role") in ("root", "other"):
                    if not ns or d["namespace"] == ns:
                        root_pvc = d
                        break
        if root_pvc is None and ns and basename:
            base_name = f"{basename}-base"
            if (ns, base_name) in pvc_by_ns_name:
                root_pvc = pvc_by_ns_name[(ns, base_name)]
        if root_pvc is not None:
            vm_pvc[name] = root_pvc["created_at"]
            if root_pvc.get("bound_at"):
                vm_pvc_bound[name] = root_pvc["bound_at"]
            elif name in vm_dv_bound:
                vm_pvc_bound[name] = vm_dv_bound[name]
        elif name in vm_dv_bound:
            vm_pvc_bound[name] = vm_dv_bound[name]

        data_name = f"{name}-data" if name else ""
        data_pvc = None
        if ns and data_name and (ns, data_name) in pvc_by_ns_name:
            data_pvc = pvc_by_ns_name[(ns, data_name)]
        elif data_name:
            for d in pvc_created:
                if d["name"] == data_name and (not ns or d["namespace"] == ns):
                    data_pvc = d
                    break
        if data_pvc is not None:
            vm_data_pvc[name] = data_pvc["created_at"]
            if data_pvc.get("bound_at"):
                vm_data_pvc_bound[name] = data_pvc["bound_at"]
            elif name in vm_data_dv_bound:
                vm_data_pvc_bound[name] = vm_data_dv_bound[name]
        elif name in vm_data_dv_bound:
            vm_data_pvc_bound[name] = vm_data_dv_bound[name]

    if vm_pvc:
        out["vm_pvc_created"] = vm_pvc
    if vm_data_pvc:
        out["vm_data_pvc_created"] = vm_data_pvc
    if vm_pvc_bound:
        out["vm_pvc_bound"] = vm_pvc_bound
    if vm_data_pvc_bound:
        out["vm_data_pvc_bound"] = vm_data_pvc_bound

    return out


def collect_from_env() -> dict:
    return collect_batch_timestamps(
        basename=os.environ.get("BASENAME") or "",
        batch_id=os.environ.get("BATCH_ID") or "",
        vms=load_env_json("VM_JSON", []),
        ns_list=load_env_json("NS_JSON", []),
        dv_doc=load_json_file_env("DV_JSON_FILE"),
        pvc_doc=load_json_file_env("PVC_JSON_FILE"),
        vs_doc=load_json_file_env("VS_JSON_FILE"),
    )


def main() -> int:
    print(json.dumps(collect_from_env()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
