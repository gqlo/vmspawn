#!/usr/bin/env python3
"""
Ideal-point positive distance per (timestamp, worker), matching OpenShift descheduler.

Reads per-worker and avg CSVs for cpu, cpu-pressure, memory, memory-pressure.
Uses positive deviation only (negative -> 0): each dimension = max(0, per_worker - avg).
Distance = sqrt(sum of squared positive deviations), i.e. Euclidean distance from (0,0,0,0).
See: openshift/cluster-kube-descheduler-operator prometheusrule.yaml

Requires: pandas
Run from repo root: python monitoring/compute_euclidean_distance.py
"""

from pathlib import Path

import pandas as pd


def main() -> None:
    base = Path(__file__).resolve().parent / "csv-data"

    # Per-worker: timestamp + one column per worker
    cpu_per = pd.read_csv(base / "cpu-per-worker.csv")
    cpu_pressure_per = pd.read_csv(base / "cpu-pressure-per-worker.csv")
    memory_per = pd.read_csv(base / "memory-per-worker.csv")
    memory_pressure_per = pd.read_csv(base / "memory-pressure-per-worker.csv")

    # Avg: timestamp + single value column "unknown"
    def read_avg(path: Path) -> pd.Series:
        df = pd.read_csv(path)
        return df.set_index("timestamp")["unknown"]

    cpu_avg = read_avg(base / "cpu-avg-workers.csv")
    cpu_pressure_avg = read_avg(base / "cpu-pressure-avg-workers.csv")
    memory_avg = read_avg(base / "memory-avg-workers.csv")
    memory_pressure_avg = read_avg(base / "memory-pressure-avg-workers.csv")

    # Expect same shape and columns across per-worker files
    worker_cols = [c for c in cpu_per.columns if c != "timestamp"]
    for name, df in [
        ("cpu-pressure-per-worker", cpu_pressure_per),
        ("memory-per-worker", memory_per),
        ("memory-pressure-per-worker", memory_pressure_per),
    ]:
        other_cols = [c for c in df.columns if c != "timestamp"]
        if set(other_cols) != set(worker_cols):
            raise ValueError(
                f"{name} columns differ from cpu-per-worker: "
                f"expected {sorted(worker_cols)}, got {sorted(other_cols)}"
            )
        if len(df) != len(cpu_per):
            raise ValueError(
                f"{name} row count {len(df)} != cpu-per-worker {len(cpu_per)}"
            )

    # Align on timestamp: use cpu_per timestamps
    cpu_per_vals = cpu_per.set_index("timestamp")[worker_cols]
    cpu_pressure_per_vals = cpu_pressure_per.set_index("timestamp")[worker_cols]
    memory_per_vals = memory_per.set_index("timestamp")[worker_cols]
    memory_pressure_per_vals = memory_pressure_per.set_index("timestamp")[worker_cols]

    # Broadcast avg (indexed by timestamp) to same index as per-worker
    cpu_avg_b = cpu_avg.reindex(cpu_per_vals.index).values.reshape(-1, 1)
    cpu_pressure_avg_b = cpu_pressure_avg.reindex(cpu_per_vals.index).values.reshape(-1, 1)
    memory_avg_b = memory_avg.reindex(cpu_per_vals.index).values.reshape(-1, 1)
    memory_pressure_avg_b = memory_pressure_avg.reindex(cpu_per_vals.index).values.reshape(-1, 1)

    # Positive deviation only (match descheduler: negative -> 0)
    pos_cpu = (cpu_per_vals - cpu_avg_b).clip(lower=0)
    pos_cpu_pressure = (cpu_pressure_per_vals - cpu_pressure_avg_b).clip(lower=0)
    pos_memory = (memory_per_vals - memory_avg_b).clip(lower=0)
    pos_memory_pressure = (memory_pressure_per_vals - memory_pressure_avg_b).clip(lower=0)

    # Ideal point positive distance = sqrt(sum of squared positive deviations)
    sum_sq = pos_cpu**2 + pos_cpu_pressure**2 + pos_memory**2 + pos_memory_pressure**2
    distance = sum_sq ** 0.5

    out = distance.reset_index()
    out.to_csv(base / "euclidean-distance-per-worker.csv", index=False)
    print(f"Wrote {base / 'euclidean-distance-per-worker.csv'} ({len(out)} rows, {len(worker_cols)} workers)")

    # If distance >= 0.1, print node name and the four positive deviations used in the formula
    threshold = 0.1
    for _, row in out.iterrows():
        ts = row["timestamp"]
        for node in worker_cols:
            dist = row[node]
            if dist < threshold:
                continue
            raw_cpu = cpu_per_vals.loc[ts, node] - cpu_avg.loc[ts]
            raw_cpu_p = cpu_pressure_per_vals.loc[ts, node] - cpu_pressure_avg.loc[ts]
            raw_mem = memory_per_vals.loc[ts, node] - memory_avg.loc[ts]
            raw_mem_p = memory_pressure_per_vals.loc[ts, node] - memory_pressure_avg.loc[ts]
            p_cpu = max(0.0, raw_cpu)
            p_cpu_p = max(0.0, raw_cpu_p)
            p_mem = max(0.0, raw_mem)
            p_mem_p = max(0.0, raw_mem_p)
            print(f"{node}: pos_dev(cpu)={p_cpu:.6g} pos_dev(cpu_pressure)={p_cpu_p:.6g} pos_dev(memory)={p_mem:.6g} pos_dev(memory_pressure)={p_mem_p:.6g} distance={dist:.6g}")


if __name__ == "__main__":
    main()
