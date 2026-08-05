#!/usr/bin/env node
"use strict";

const { describe, it } = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");

const lib = require(path.join(
  __dirname,
  "..",
  "workload-result",
  "static",
  "dashboard-lib.js"
));

describe("fmtTs", () => {
  it("formats unix seconds as UTC Z", () => {
    assert.equal(lib.fmtTs(1784699425), "2026-07-22T05:50:25Z");
  });

  it("passes through ISO with Z", () => {
    assert.equal(lib.fmtTs("2026-07-22T05:50:25Z"), "2026-07-22T05:50:25Z");
  });

  it("treats naive ISO as UTC", () => {
    assert.equal(lib.fmtTs("2026-07-22T05:50:25"), "2026-07-22T05:50:25Z");
  });

  it("returns em dash for null", () => {
    assert.equal(lib.fmtTs(null), "—");
  });
});

describe("fmtWorkloadStatus / fmtWorkloadColumn", () => {
  it("maps only running to running", () => {
    assert.equal(lib.fmtWorkloadStatus("running"), "running");
    assert.equal(lib.fmtWorkloadStatus("idle"), "idle");
    assert.equal(lib.fmtWorkloadStatus("waiting"), "idle");
    assert.equal(lib.fmtWorkloadStatus("queued"), "idle");
  });

  it("formats running/idle column from summary", () => {
    assert.equal(
      lib.fmtWorkloadColumn({ configured: 8, running: 2, idle: 6 }),
      "2 running · 6 idle"
    );
    assert.equal(lib.fmtWorkloadColumn(null), "—");
  });
});

describe("parseRoute", () => {
  it("defaults to runs list", () => {
    assert.deepEqual(lib.parseRoute("#/runs"), { name: "runs" });
    assert.deepEqual(lib.parseRoute(""), { name: "runs" });
  });

  it("parses batch detail", () => {
    assert.deepEqual(lib.parseRoute("#/runs/a1b2c3"), {
      name: "run",
      batchId: "a1b2c3",
    });
  });

  it("parses vm and cycle routes", () => {
    assert.deepEqual(lib.parseRoute("#/runs/a1b2c3/vms/vm-1"), {
      name: "vm",
      batchId: "a1b2c3",
      vm: "vm-1",
    });
    assert.deepEqual(lib.parseRoute("#/runs/a1b2c3/vms/vm-1/cycles/2"), {
      name: "cycle",
      batchId: "a1b2c3",
      vm: "vm-1",
      cycle: "2",
    });
  });

  it("parses payload route", () => {
    assert.deepEqual(lib.parseRoute("#/runs/a1b2c3/payload/deadbeef"), {
      name: "payload",
      batchId: "a1b2c3",
      resultId: "deadbeef",
    });
  });
});

describe("boot durations and CSV", () => {
  const started = 1000;
  const dvCreated = 1020;
  const vms = [
    { vm_name: "vm-a", namespace: "ns1", boot_timestamp_unix: 1045, dv_created_at_unix: 1020 },
    { vm_name: "vm-b", namespace: "ns1", boot_timestamp_unix: 1100, dv_created_at_unix: 1030 },
    { vm_name: "vm-c", namespace: "ns1", boot_timestamp_unix: null },
  ];

  it("computes DV→boot durations preferring per-VM dv_created", () => {
    assert.deepEqual(lib.bootDurationsSeconds(vms, started, dvCreated), [
      { vm_name: "vm-a", seconds: 25 },
      { vm_name: "vm-b", seconds: 70 },
    ]);
  });

  it("falls back to batch started_at when no DV times", () => {
    const plain = [
      { vm_name: "vm-a", boot_timestamp_unix: 1045 },
      { vm_name: "vm-b", boot_timestamp_unix: 1100 },
    ];
    assert.deepEqual(lib.bootDurationsSeconds(plain, started), [
      { vm_name: "vm-a", seconds: 45 },
      { vm_name: "vm-b", seconds: 100 },
    ]);
  });

  it("summarizes avg/min/max", () => {
    assert.equal(
      lib.fmtBootTimeSummary(vms, started, dvCreated),
      "DV→boot avg 48s · min 25s · max 70s"
    );
    assert.equal(lib.fmtBootTimeSummary([], started), "Boot time —");
  });

  it("builds boot times CSV with DV columns", () => {
    const csv = lib.buildBootTimesCsv("a1b2c3", vms, started, dvCreated);
    const lines = csv.trim().split("\n");
    assert.equal(
      lines[0],
      "batch_id,vm_name,namespace,batch_started_at_utc,dv_created_at_utc,boot_timestamp_utc,boot_duration_s,dv_to_boot_s"
    );
    assert.ok(lines[1].startsWith("a1b2c3,vm-a,ns1,"));
    assert.ok(lines[1].endsWith(",45,25"));
    assert.ok(lines[2].endsWith(",100,70"));
    assert.ok(lines[3].includes("vm-c"));
  });

  it("builds cross-batch timestamps CSV", () => {
    const csv = lib.buildCrossBatchTimestampsCsv([
      {
        batch_id: "b1",
        basename: "rhel9",
        cloudinit: "workload/x.yaml",
        vm_name: "vm-a",
        namespace: "ns1",
        batch_started_at: 1000,
        dv_created_at: 1020,
        boot_timestamp: 1100,
        boot_duration_s: 100,
        dv_to_boot_s: 80,
      },
    ]);
    const lines = csv.trim().split("\n");
    assert.equal(
      lines[0],
      "batch_id,basename,cloudinit,vm_name,namespace,batch_started_at_utc,dv_created_at_utc,boot_timestamp_utc,boot_duration_s,dv_to_boot_s"
    );
    assert.ok(lines[1].startsWith("b1,rhel9,workload/x.yaml,vm-a,ns1,"));
    assert.ok(lines[1].endsWith(",100,80"));
  });

  it("escapes CSV fields", () => {
    assert.equal(lib.csvEscape('a,b'), '"a,b"');
    assert.equal(lib.csvEscape('say "hi"'), '"say ""hi"""');
  });
});

describe("histogramBins", () => {
  it("returns empty for no values", () => {
    assert.deepEqual(lib.histogramBins([]), {
      labels: [],
      counts: [],
      edges: [],
    });
  });

  it("bins identical values into one bar", () => {
    const { labels, counts } = lib.histogramBins([10, 10, 10]);
    assert.equal(labels.length, 1);
    assert.deepEqual(counts, [3]);
  });

  it("places values into multiple bins", () => {
    const { counts, edges } = lib.histogramBins([10, 20, 30, 40], {
      maxBins: 4,
      minWidth: 5,
    });
    assert.ok(counts.reduce((a, b) => a + b, 0) === 4);
    assert.ok(edges.length === counts.length + 1);
  });
});

describe("escapeHtml / statusBadge", () => {
  it("escapes HTML", () => {
    assert.equal(lib.escapeHtml('<a "x">'), "&lt;a &quot;x&quot;&gt;");
  });

  it("renders status badges", () => {
    assert.equal(lib.statusBadge("ok"), '<span class="badge ok">ok</span>');
    assert.ok(lib.statusBadge("post_error").includes("warn"));
    assert.ok(lib.statusBadge(null, 1).includes("fio_error"));
  });
});
