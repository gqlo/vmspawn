#!/usr/bin/env python3
"""
Extract VMIM migration time (Succeeded - Pending phaseTransitionTimestamp) in seconds.
Output: CSV with columns "vmim name, time in seconds".

Usage:
  # Single VMIM by name and namespace
  python vmim_migration_time.py --namespace NAMESPACE --name VMIM_NAME [--output out.csv]

  # All VMIMs in a namespace
  python vmim_migration_time.py --namespace NAMESPACE [--output out.csv]

Requires: oc in PATH, cluster access.
"""

import argparse
import csv
import json
import subprocess
import sys
from datetime import datetime


def get_vmim_json(namespace: str, name: str | None) -> dict:
    cmd = ["oc", "get", "vmim", "-n", namespace, "-o", "json"]
    if name:
        cmd.insert(3, name)  # oc get vmim NAME -n NAMESPACE -o json
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        print(result.stderr or result.stdout, file=sys.stderr)
        sys.exit(1)
    return json.loads(result.stdout)


def migration_seconds(item: dict) -> float | None:
    timestamps = item.get("status", {}).get("phaseTransitionTimestamps") or []
    by_phase = {t["phase"]: t["phaseTransitionTimestamp"] for t in timestamps}
    pending = by_phase.get("Pending")
    succeeded = by_phase.get("Succeeded")
    if not pending or not succeeded:
        return None
    t0 = datetime.fromisoformat(pending.replace("Z", "+00:00"))
    t1 = datetime.fromisoformat(succeeded.replace("Z", "+00:00"))
    return (t1 - t0).total_seconds()


def main() -> None:
    parser = argparse.ArgumentParser(description="Extract VMIM migration time (Succeeded - Pending) in seconds")
    parser.add_argument("--namespace", "-n", required=True, help="Namespace")
    parser.add_argument("--name", "-N", default=None, help="VMIM name (omit to list all VMIMs in namespace)")
    parser.add_argument("--output", "-o", default=None, help="Output CSV path (default: stdout)")
    args = parser.parse_args()

    data = get_vmim_json(args.namespace, args.name)
    items = data.get("items", [data]) if "items" in data else [data]

    rows = []
    for item in items:
        name = item.get("metadata", {}).get("name", "")
        sec = migration_seconds(item)
        if sec is not None:
            rows.append((name, f"{sec:.2f}"))
        else:
            rows.append((name, ""))

    out = open(args.output, "w", newline="") if args.output else sys.stdout
    try:
        writer = csv.writer(out)
        writer.writerow(["vmim name", "time in seconds"])
        writer.writerows(rows)
    finally:
        if args.output:
            out.close()

    if not rows:
        sys.exit(1)


if __name__ == "__main__":
    main()
