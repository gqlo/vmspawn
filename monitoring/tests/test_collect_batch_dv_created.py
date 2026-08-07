#!/usr/bin/env python3
"""Unit tests for monitoring/data-collector/collect_batch_dv_created.py."""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

_HELPER = (
    Path(__file__).resolve().parent.parent
    / "data-collector"
    / "collect_batch_dv_created.py"
)


def _load():
    spec = importlib.util.spec_from_file_location("collect_batch_dv_created", _HELPER)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load {_HELPER}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules["collect_batch_dv_created"] = mod
    spec.loader.exec_module(mod)
    return mod


col = _load()

NS = "abcd12-ns-1"
BASENAME = "rhel9"
BATCH = "abcd12"
VM = "rhel9-abcd12-1"


def _dv(
    name: str,
    *,
    ns: str = NS,
    created: str,
    ready: str | None = None,
    bound: str | None = None,
    phase: str = "Succeeded",
    labels: dict | None = None,
    claim: str | None = None,
) -> dict:
    conditions = []
    if ready:
        conditions.append(
            {
                "type": "Ready",
                "status": "True",
                "lastTransitionTime": ready,
            }
        )
    if bound:
        conditions.append(
            {
                "type": "Bound",
                "status": "True",
                "lastTransitionTime": bound,
            }
        )
    status: dict = {"phase": phase, "conditions": conditions}
    if claim:
        status["claimName"] = claim
    return {
        "metadata": {
            "name": name,
            "namespace": ns,
            "creationTimestamp": created,
            "labels": labels or {"batch-id": BATCH},
        },
        "status": status,
    }


def _pvc(
    name: str,
    *,
    ns: str = NS,
    created: str,
    labels: dict | None = None,
) -> dict:
    return {
        "metadata": {
            "name": name,
            "namespace": ns,
            "creationTimestamp": created,
            "labels": labels or {"batch-id": BATCH},
        }
    }


def _vs(
    name: str,
    *,
    ns: str = NS,
    created: str,
    ready: bool = True,
    ready_at: str | None = None,
    labels: dict | None = None,
) -> dict:
    status: dict = {"readyToUse": ready}
    if ready and ready_at:
        status["creationTime"] = ready_at
    return {
        "metadata": {
            "name": name,
            "namespace": ns,
            "creationTimestamp": created,
            "labels": labels or {"batch-id": BATCH},
        },
        "status": status,
    }


class TestCollectBatchTimestamps(unittest.TestCase):
    def test_snapshot_path_emits_base_dv_and_snapshot_fields(self) -> None:
        out = col.collect_batch_timestamps(
            basename=BASENAME,
            batch_id=BATCH,
            vms=[f"{NS}/{VM}"],
            ns_list=[NS],
            dv_doc={
                "items": [
                    _dv(
                        f"{BASENAME}-base",
                        created="2026-07-22T05:48:30Z",
                        ready="2026-07-22T05:48:40Z",
                        bound="2026-07-22T05:48:41Z",
                    ),
                    _dv(
                        VM,
                        created="2026-07-22T05:49:10Z",
                        ready="2026-07-22T05:49:12Z",
                        bound="2026-07-22T05:49:13Z",
                    ),
                    _dv(
                        f"{VM}-data",
                        created="2026-07-22T05:49:14Z",
                        ready="2026-07-22T05:49:14Z",
                        bound="2026-07-22T05:49:16Z",
                    ),
                ]
            },
            pvc_doc={
                "items": [
                    _pvc(f"{BASENAME}-base", created="2026-07-22T05:48:31Z"),
                    _pvc(VM, created="2026-07-22T05:49:12Z"),
                    _pvc(f"{VM}-data", created="2026-07-22T05:49:15Z"),
                ]
            },
            vs_doc={
                "items": [
                    _vs(
                        f"{BASENAME}-snap",
                        created="2026-07-22T05:48:50Z",
                        ready_at="2026-07-22T05:48:55Z",
                    ),
                ]
            },
        )

        self.assertEqual(out["base_dv_created_at"], "2026-07-22T05:48:30Z")
        self.assertEqual(out["base_dv_ready_at"], "2026-07-22T05:48:40Z")
        self.assertEqual(out["base_dv_bound_at"], "2026-07-22T05:48:41Z")
        self.assertEqual(len(out["base_dv"]), 1)
        self.assertEqual(out["base_dv"][0]["role"], "base")

        self.assertEqual(out["snapshot_created_at"], "2026-07-22T05:48:50Z")
        self.assertEqual(out["snapshot_ready_at"], "2026-07-22T05:48:55Z")
        self.assertTrue(out["snapshots"][0]["ready"])

        self.assertEqual(out["vm_dv_created"][VM], "2026-07-22T05:49:10Z")
        self.assertEqual(out["vm_dv_ready"][VM], "2026-07-22T05:49:12Z")
        self.assertEqual(out["vm_dv_bound"][VM], "2026-07-22T05:49:13Z")
        self.assertEqual(out["vm_data_dv_created"][VM], "2026-07-22T05:49:14Z")
        self.assertEqual(out["vm_data_dv_ready"][VM], "2026-07-22T05:49:14Z")
        self.assertEqual(out["vm_data_dv_bound"][VM], "2026-07-22T05:49:16Z")

        self.assertEqual(out["vm_pvc_created"][VM], "2026-07-22T05:49:12Z")
        self.assertEqual(out["vm_pvc_bound"][VM], "2026-07-22T05:49:13Z")
        self.assertEqual(out["vm_data_pvc_created"][VM], "2026-07-22T05:49:15Z")
        self.assertEqual(out["vm_data_pvc_bound"][VM], "2026-07-22T05:49:16Z")
        self.assertEqual(out["pvc_bound_at"], "2026-07-22T05:48:41Z")

    def test_unready_snapshot_omits_snapshot_ready_at(self) -> None:
        out = col.collect_batch_timestamps(
            basename=BASENAME,
            batch_id=BATCH,
            vms=[f"{NS}/{VM}"],
            ns_list=[NS],
            dv_doc={"items": []},
            pvc_doc={"items": []},
            vs_doc={
                "items": [
                    _vs(f"{BASENAME}-snap", created="2026-07-22T05:48:50Z", ready=False),
                ]
            },
        )
        self.assertEqual(out["snapshot_created_at"], "2026-07-22T05:48:50Z")
        self.assertNotIn("snapshot_ready_at", out)
        self.assertFalse(out["snapshots"][0]["ready"])
        self.assertNotIn("ready_at", out["snapshots"][0])

    def test_filters_other_namespaces_and_batches(self) -> None:
        out = col.collect_batch_timestamps(
            basename=BASENAME,
            batch_id=BATCH,
            vms=[f"{NS}/{VM}"],
            ns_list=[NS],
            dv_doc={
                "items": [
                    _dv(
                        f"{BASENAME}-base",
                        created="2026-07-22T05:48:30Z",
                        ready="2026-07-22T05:48:40Z",
                    ),
                    _dv(
                        "other-base",
                        ns="other-ns",
                        created="2026-07-22T05:40:00Z",
                        ready="2026-07-22T05:40:01Z",
                        labels={"batch-id": "zzzzzz"},
                    ),
                ]
            },
            pvc_doc={"items": []},
            vs_doc={
                "items": [
                    _vs(f"{BASENAME}-snap", created="2026-07-22T05:48:50Z"),
                    _vs(
                        "foreign-snap",
                        ns="other-ns",
                        created="2026-07-22T05:40:00Z",
                        labels={"batch-id": "zzzzzz"},
                    ),
                ]
            },
        )
        self.assertEqual(len(out["base_dv"]), 1)
        self.assertEqual(out["base_dv"][0]["name"], f"{BASENAME}-base")
        self.assertEqual(len(out["snapshots"]), 1)
        self.assertEqual(out["snapshots"][0]["name"], f"{BASENAME}-snap")

    def test_no_base_or_snapshot_when_absent(self) -> None:
        out = col.collect_batch_timestamps(
            basename=BASENAME,
            batch_id=BATCH,
            vms=[f"{NS}/{VM}"],
            ns_list=[NS],
            dv_doc={
                "items": [
                    _dv(
                        VM,
                        created="2026-07-22T05:49:10Z",
                        ready="2026-07-22T05:49:12Z",
                    ),
                ]
            },
            pvc_doc={"items": [_pvc(VM, created="2026-07-22T05:49:11Z")]},
            vs_doc={"items": []},
        )
        self.assertNotIn("base_dv", out)
        self.assertNotIn("base_dv_created_at", out)
        self.assertNotIn("snapshots", out)
        self.assertNotIn("snapshot_created_at", out)
        self.assertEqual(out["vm_dv_created"][VM], "2026-07-22T05:49:10Z")

    def test_empty_docs_yield_empty_payload(self) -> None:
        out = col.collect_batch_timestamps(
            basename=BASENAME,
            batch_id=BATCH,
            vms=[],
            ns_list=[],
            dv_doc={},
            pvc_doc={},
            vs_doc={},
        )
        self.assertEqual(out, {})

    def test_cli_reads_json_files_from_env(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            dv_path = Path(td) / "dv.json"
            pvc_path = Path(td) / "pvc.json"
            vs_path = Path(td) / "vs.json"
            dv_path.write_text(
                json.dumps(
                    {
                        "items": [
                            _dv(
                                f"{BASENAME}-base",
                                created="2026-07-22T05:48:30Z",
                                ready="2026-07-22T05:48:40Z",
                                bound="2026-07-22T05:48:41Z",
                            )
                        ]
                    }
                ),
                encoding="utf-8",
            )
            pvc_path.write_text(json.dumps({"items": []}), encoding="utf-8")
            vs_path.write_text(
                json.dumps(
                    {
                        "items": [
                            _vs(
                                f"{BASENAME}-snap",
                                created="2026-07-22T05:48:50Z",
                                ready_at="2026-07-22T05:48:55Z",
                            )
                        ]
                    }
                ),
                encoding="utf-8",
            )
            env = {
                "BASENAME": BASENAME,
                "BATCH_ID": BATCH,
                "VM_JSON": json.dumps([f"{NS}/{VM}"]),
                "NS_JSON": json.dumps([NS]),
                "DV_JSON_FILE": str(dv_path),
                "PVC_JSON_FILE": str(pvc_path),
                "VS_JSON_FILE": str(vs_path),
            }
            old = {k: os.environ.get(k) for k in env}
            try:
                os.environ.update(env)
                out = col.collect_from_env()
            finally:
                for k, v in old.items():
                    if v is None:
                        os.environ.pop(k, None)
                    else:
                        os.environ[k] = v
            self.assertEqual(out["base_dv_created_at"], "2026-07-22T05:48:30Z")
            self.assertEqual(out["snapshot_ready_at"], "2026-07-22T05:48:55Z")


if __name__ == "__main__":
    unittest.main()
