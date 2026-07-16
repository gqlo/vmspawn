#!/usr/bin/env python3
"""
List KubeVirt CPU model labels on every cluster node.

Output (CSV, one line per node):
  <node name>, <model1>, <model2>, ...

Models are sorted alphabetically. Only labels with value "true" are included.

Usage:
  ./node-cpu-model-migration.py
  ./node-cpu-model-migration.py --output nodes-cpu-migration.csv
  ./node-cpu-model-migration.py --type cpu-model --output nodes-cpu-model.csv

Requires: oc or kubectl in PATH, cluster access.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys

LABEL_PREFIXES = {
    "migration": "cpu-model-migration.node.kubevirt.io/",
    "cpu-model": "cpu-model.node.kubevirt.io/",
}


def kubectl_bin() -> str:
    for cmd in ("oc", "kubectl"):
        if shutil.which(cmd):
            return cmd
    print("error: need oc or kubectl in PATH", file=sys.stderr)
    sys.exit(1)


def get_nodes(cmd: str) -> list[dict]:
    result = subprocess.run(
        [cmd, "get", "nodes", "-o", "json"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        print(result.stderr or result.stdout, file=sys.stderr)
        sys.exit(1)
    data = json.loads(result.stdout)
    return data.get("items", [])


def cpu_models(labels: dict | None, label_prefix: str) -> list[str]:
    if not labels:
        return []
    models: list[str] = []
    for key, value in labels.items():
        if not key.startswith(label_prefix):
            continue
        if str(value).lower() != "true":
            continue
        models.append(key[len(label_prefix) :])
    return sorted(models)


def format_row(node_name: str, models: list[str]) -> str:
    return ", ".join([node_name, *models])


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Extract KubeVirt CPU model labels from all nodes."
    )
    parser.add_argument(
        "-t",
        "--type",
        choices=sorted(LABEL_PREFIXES),
        default="migration",
        help="label set to extract: migration (default) or cpu-model",
    )
    parser.add_argument(
        "-o",
        "--output",
        metavar="FILE",
        help="write CSV to FILE instead of stdout",
    )
    args = parser.parse_args()

    label_prefix = LABEL_PREFIXES[args.type]
    cmd = kubectl_bin()
    nodes = get_nodes(cmd)
    if not nodes:
        print("warning: no nodes found", file=sys.stderr)

    rows = []
    for node in sorted(nodes, key=lambda n: n.get("metadata", {}).get("name", "")):
        name = node.get("metadata", {}).get("name", "")
        labels = node.get("metadata", {}).get("labels") or {}
        rows.append(format_row(name, cpu_models(labels, label_prefix)))

    if args.output:
        with open(args.output, "w", encoding="utf-8") as out:
            for row in rows:
                print(row, file=out)
    else:
        for row in rows:
            print(row)


if __name__ == "__main__":
    main()
