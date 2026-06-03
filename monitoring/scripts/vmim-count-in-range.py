#!/usr/bin/env python3
"""Count VMIM objects whose Pending→Succeeded interval overlaps a time window."""

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import yaml


def parse_ts(value: str) -> datetime:
    s = value.strip()
    if " " in s and "T" not in s:
        fmt = "%Y-%m-%d %H:%M:%S.%f" if "." in s else "%Y-%m-%d %H:%M:%S"
        return datetime.strptime(s, fmt).replace(tzinfo=timezone.utc)
    dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def get_vmims() -> list[dict]:
    result = subprocess.run(
        ["oc", "get", "vmim", "-A", "-o", "json"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        print(result.stderr or result.stdout, file=sys.stderr)
        sys.exit(1)
    return json.loads(result.stdout).get("items", [])


def pending_succeeded(item: dict) -> tuple[datetime, datetime] | None:
    timestamps = (item.get("status") or {}).get("phaseTransitionTimestamps") or []
    by_phase = {t["phase"]: t["phaseTransitionTimestamp"] for t in timestamps}
    pending = by_phase.get("Pending")
    succeeded = by_phase.get("Succeeded")
    if not pending or not succeeded:
        return None
    return parse_ts(pending), parse_ts(succeeded)


def overlaps(pending: datetime, succeeded: datetime, start: datetime, end: datetime) -> bool:
    return succeeded >= start and pending <= end


def load_range_from_yaml(path: Path) -> tuple[str, str]:
    data = yaml.safe_load(path.read_text()) or {}
    defaults = data.get("defaults") or {}
    start = defaults.get("start")
    end = defaults.get("end")
    if not start or not end:
        print(f"Error: {path} defaults must include start and end", file=sys.stderr)
        sys.exit(1)
    return str(start), str(end)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Count VMIMs (oc get vmim -A) whose Pending→Succeeded interval overlaps --start/--end."
    )
    parser.add_argument(
        "-f", "--file",
        type=Path,
        help="Read start/end from defaults in a prom-queries YAML file",
    )
    parser.add_argument("--start", help="Window start (UTC), e.g. 2026-05-27 15:22:34")
    parser.add_argument("--end", help="Window end (UTC), e.g. 2026-05-29 15:22:03")
    args = parser.parse_args()

    if args.file:
        yaml_start, yaml_end = load_range_from_yaml(args.file)
        start_str = args.start or yaml_start
        end_str = args.end or yaml_end
    else:
        if not args.start or not args.end:
            parser.error("provide --start and --end, or -f/--file with defaults.start/end")
        start_str, end_str = args.start, args.end

    start = parse_ts(start_str)
    end = parse_ts(end_str)
    if end < start:
        print("Error: --end is before --start", file=sys.stderr)
        sys.exit(1)

    count = sum(
        1
        for item in get_vmims()
        if (interval := pending_succeeded(item)) and overlaps(*interval, start, end)
    )
    print(count)


if __name__ == "__main__":
    main()
