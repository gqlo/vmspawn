#!/usr/bin/env python3
"""YAML parse, ${threshold} substitution, list/lookup helpers for prom-query."""

from __future__ import annotations

import argparse
import csv
import datetime
import json
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Tuple, Union

import yaml


class QueryNotFoundError(LookupError):
    def __init__(self, name: str, available: List[str]) -> None:
        self.name = name
        self.available = available


class MissingQueryFieldError(ValueError):
    def __init__(self, name: str) -> None:
        super().__init__(f'query "{name}" has no "query" field')
        self.name = name


class MissingThresholdError(ValueError):
    """Raised when ${threshold} appears but no defaults.threshold / per-query threshold."""


def format_threshold_for_subst(thr: Any) -> str:
    """Format threshold for ${threshold} replacement (PromQL rejects bare '.2' literals)."""
    if isinstance(thr, bool):
        return str(thr).lower()
    if isinstance(thr, str):
        s = thr.strip()
        if s.startswith("-."):
            body = s[2:]
            if body and body[0].isdigit():
                return "-0." + body
            return s
        if len(s) >= 2 and s[0] == "." and s[1].isdigit():
            return "0." + s[1:]
        return s
    if isinstance(thr, (int, float)) and not isinstance(thr, bool):
        return str(thr)
    return str(thr)


def load_queries_yaml(path: str) -> Dict[str, Any]:
    with open(path, encoding="utf-8") as f:
        data = yaml.safe_load(f)
    if not isinstance(data, dict) or not data:
        raise ValueError("no queries found in file")
    return data


def subst_threshold(
    text: str,
    entry: Union[dict, None],
    defaults: dict,
    *,
    is_query: bool = False,
) -> str:
    if "${threshold}" not in text:
        return text
    if isinstance(entry, dict):
        thr = entry.get("threshold", defaults.get("threshold"))
    else:
        thr = defaults.get("threshold")
    if thr is None:
        ctx = "query" if is_query else "description"
        raise MissingThresholdError(
            f"{ctx} contains ${{threshold}} but neither defaults.threshold nor "
            "per-query threshold is set"
        )
    return text.replace("${threshold}", format_threshold_for_subst(thr))


# PromQL rejects numeric literals that start with '.' (e.g. ">= .2"). Normalize to ">= 0.2".
_DOT_LITERAL_AFTER_CMP = re.compile(
    r"((?:>=|<=|==|!=|>|<))\s*\.(\d+)"
)


def normalize_promql_comparison_dot_literals(q: str) -> str:
    """Rewrite '>= .2' style comparisons to '>= 0.2' (Prometheus rejects bare '.2' literals)."""
    return _DOT_LITERAL_AFTER_CMP.sub(r"\1 0.\2", q)


def _validate_resolved_query(name: str, q: str) -> None:
    s = q.strip()
    if not s:
        raise ValueError(f'query "{name}" is empty after resolving YAML')
    if s[0] == ".":
        raise ValueError(
            f'query "{name}" starts with "." (invalid PromQL). '
            'Use a leading digit (e.g. 0.2) or fix the YAML "query" field.'
        )


def _finalize_query_string(q: str, entry: Union[dict, None], defaults: dict, name: str) -> str:
    q = q.replace("\r\n", "\n").replace("\r", "\n").strip()
    q = subst_threshold(q, entry, defaults, is_query=True)
    q = normalize_promql_comparison_dot_literals(q)
    _validate_resolved_query(name, q)
    return q


def query_names(data: Dict[str, Any]) -> List[str]:
    return [name for name in data if name != "defaults"]


def format_list_lines(data: Dict[str, Any]) -> List[str]:
    defaults = data.get("defaults", {}) if isinstance(data.get("defaults"), dict) else {}
    has_global_range = bool(defaults.get("start") or defaults.get("step"))
    lines: List[str] = []
    for name, entry in data.items():
        if name == "defaults":
            continue
        if not isinstance(entry, dict):
            lines.append(f"  {name}")
            continue
        desc = entry.get("description", "")
        desc = subst_threshold(desc, entry, defaults, is_query=False)
        is_range = bool(entry.get("start") or entry.get("step")) or has_global_range
        tag = " [range]" if is_range else ""
        if desc:
            lines.append(f"  {name:30s} {desc}{tag}")
        else:
            lines.append(f"  {name}{tag}")
    return lines


def lookup_query_lines(data: Dict[str, Any], name: str) -> Tuple[str, str, str, str]:
    defaults = data.get("defaults", {}) if isinstance(data.get("defaults"), dict) else {}
    entry = data.get(name)
    if entry is None:
        available = [k for k in data if k != "defaults"]
        raise QueryNotFoundError(name, available)
    if isinstance(entry, dict):
        q = entry.get("query")
        if not q:
            raise MissingQueryFieldError(name)
        if not isinstance(q, str):
            q = str(q)
        start = entry.get("start", defaults.get("start", ""))
        end = entry.get("end", defaults.get("end", ""))
        step = entry.get("step", defaults.get("step", ""))
        q = _finalize_query_string(q, entry, defaults, name)
        return (
            "" if start is None else str(start),
            "" if end is None else str(end),
            "" if step is None else str(step),
            q,
        )
    start = defaults.get("start", "")
    end = defaults.get("end", "")
    step = defaults.get("step", "")
    q = _finalize_query_string(str(entry), None, defaults, name)
    return (
        "" if start is None else str(start),
        "" if end is None else str(end),
        "" if step is None else str(step),
        q,
    )


def resolve_timestamp(val: str) -> int:
    if not val:
        raise ValueError("empty time spec")
    if val == "now":
        return int(time.time())
    m = re.fullmatch(r"(\d+)([smhd])", val)
    if m:
        amount, unit = int(m.group(1)), m.group(2)
        mult = {"s": 1, "m": 60, "h": 3600, "d": 86400}
        return int(time.time()) - amount * mult[unit]
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S"):
        try:
            dt = datetime.datetime.strptime(val, fmt).replace(tzinfo=datetime.timezone.utc)
            return int(dt.timestamp())
        except ValueError:
            continue
    raise ValueError(
        f'invalid time spec "{val}" (use "YYYY-MM-DD HH:MM:SS", 30s, 5m, 1h, 2d, or "now")'
    )


def _format_ts(epoch: float) -> str:
    return datetime.datetime.fromtimestamp(epoch, tz=datetime.timezone.utc).strftime(
        "%Y-%m-%d %H:%M:%S"
    )


def series_from_range_json(payload: dict) -> Dict[str, str]:
    """Map timestamp string -> scalar value from a query_range response."""
    if payload.get("status") != "success":
        raise RuntimeError(payload.get("error", payload.get("message", "query failed")))
    results = payload.get("data", {}).get("result", [])
    if len(results) > 1:
        raise ValueError(
            f"query is not single-valued: expected 1 series in payload result, got {len(results)}"
        )
    out: Dict[str, str] = {}
    for result in results:
        metric = result.get("metric", {})
        for ts_epoch, value in result.get("values", []):
            key = _format_ts(float(ts_epoch))
            if key in out:
                raise ValueError(
                    f"duplicate timestamp {key!r} in series_from_range_json "
                    f"(series metric={metric!r}, values={result.get('values', [])!r})"
                )
            out[key] = value
    return out


def write_merged_csv(
    names: List[str],
    series_by_name: Dict[str, Dict[str, str]],
    output_path: str,
) -> None:
    all_ts = sorted({ts for s in series_by_name.values() for ts in s})
    out = Path(output_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["timestamp", *names])
        for ts in all_ts:
            writer.writerow([ts] + [series_by_name[n].get(ts, "") for n in names])


def prometheus_pod(namespace: str, pod: str) -> str:
    if pod:
        return pod
    r = subprocess.run(
        [
            "oc",
            "get",
            "pods",
            "-n",
            namespace,
            "-l",
            "app.kubernetes.io/name=prometheus",
            "-o",
            "jsonpath={.items[0].metadata.name}",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    found = (r.stdout or "").strip()
    if found:
        return found
    return "prometheus-k8s-0"


def query_range(
    *,
    namespace: str,
    pod: str,
    container: str,
    query: str,
    ts_start: int,
    ts_end: int,
    step: str,
) -> dict:
    r = subprocess.run(
        [
            "oc",
            "exec",
            "-c",
            container,
            "-n",
            namespace,
            pod,
            "--",
            "curl",
            "-s",
            "--data-urlencode",
            f"query={query}",
            "--data-urlencode",
            f"start={ts_start}",
            "--data-urlencode",
            f"end={ts_end}",
            "--data-urlencode",
            f"step={step}",
            "http://localhost:9090/api/v1/query_range",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or "oc exec failed")
    return json.loads(r.stdout)


def run_merge(
    yaml_path: str,
    output: str | None,
    *,
    namespace: str,
    pod: str,
    container: str,
) -> str:
    data = load_queries_yaml(yaml_path)
    names = query_names(data)
    if not names:
        raise ValueError("no queries in file")

    prom_pod = prometheus_pod(namespace, pod)
    print(f"Using pod {prom_pod} in {namespace}", file=sys.stderr)

    merge_start, merge_end, _, _ = lookup_query_lines(data, names[0])
    if not merge_start:
        raise ValueError(f'query "{names[0]}" requires start in YAML defaults')
    ts_start = resolve_timestamp(merge_start)
    ts_end = resolve_timestamp(merge_end or "now")

    series_by_name: Dict[str, Dict[str, str]] = {}
    for name in names:
        start, _end, step, query = lookup_query_lines(data, name)
        if not start or not step:
            raise ValueError(f'query "{name}" requires start and step in YAML defaults')
        print(f"[{name}]", file=sys.stderr)
        payload = query_range(
            namespace=namespace,
            pod=prom_pod,
            container=container,
            query=query,
            ts_start=ts_start,
            ts_end=ts_end,
            step=step,
        )
        series_by_name[name] = series_from_range_json(payload)

    out = output or str(Path(yaml_path).parent / "csv-data" / "combined.csv")
    write_merged_csv(names, series_by_name, out)
    return out


def _die(msg: str) -> None:
    print(msg, file=sys.stderr)
    sys.exit(1)


def _main_merge(argv: List[str]) -> None:
    p = argparse.ArgumentParser(prog="prom_query_yaml")
    p.add_argument("--merge", action="store_true", help="query Prometheus, write one CSV")
    p.add_argument("file", help="queries YAML")
    p.add_argument("-o", "--output", help="output CSV (default: csv-data/combined.csv)")
    p.add_argument("-n", "--namespace", default="openshift-monitoring")
    p.add_argument("-p", "--pod", default="")
    p.add_argument("-c", "--container", default="prometheus")
    args = p.parse_args(argv)
    try:
        out = run_merge(
            args.file,
            args.output,
            namespace=args.namespace,
            pod=args.pod,
            container=args.container,
        )
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as e:
        _die(str(e))
    print(out)


def main(argv: List[str] | None = None) -> None:
    argv = argv if argv is not None else sys.argv[1:]
    if "--merge" in argv:
        _main_merge(argv)
        return

    p = argparse.ArgumentParser(prog="prom_query_yaml")
    sub = p.add_subparsers(dest="cmd", required=True)

    p_list = sub.add_parser("list", help="format lines for prom-query -l")
    p_list.add_argument("file")

    p_names = sub.add_parser("names", help="print query names, one per line")
    p_names.add_argument("file")

    p_lookup = sub.add_parser("lookup", help="print start, end, step, query (4 lines)")
    p_lookup.add_argument("file")
    p_lookup.add_argument("name")

    args = p.parse_args(argv)

    try:
        data = load_queries_yaml(args.file)
    except ValueError:
        _die("(no queries found in file)")
    except OSError as e:
        _die(str(e))

    if args.cmd == "list":
        try:
            for line in format_list_lines(data):
                print(line)
        except MissingThresholdError as e:
            _die(f"Error: {e}")
        return

    if args.cmd == "names":
        for n in query_names(data):
            print(n)
        return

    if args.cmd == "lookup":
        try:
            start, end, step, q = lookup_query_lines(data, args.name)
        except QueryNotFoundError as e:
            _die(
                f'Error: query "{e.name}" not found in {args.file}\n'
                f'Available queries: {", ".join(e.available)}'
            )
        except MissingQueryFieldError as e:
            _die(f"Error: {e}")
        except MissingThresholdError as e:
            _die(f"Error: {e}")
        except ValueError as e:
            _die(f"Error: {e}")
        print(start)
        print(end)
        print(step)
        print(q)
        return


if __name__ == "__main__":
    main()
