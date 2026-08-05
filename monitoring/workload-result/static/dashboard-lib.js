/* Pure helpers for the workload-result dashboard (browser + Node tests). */

(function (root) {
  "use strict";

  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function fmtTs(ts) {
    // Always render as UTC ISO-8601 with Z (API stores unix UTC epoch seconds).
    if (ts == null) return "—";
    if (typeof ts === "string" && ts.trim()) {
      const s = ts.trim();
      const n = Number(s);
      if (Number.isFinite(n) && String(n) === s) {
        const d = new Date(n * 1000);
        if (!Number.isNaN(d.getTime())) return d.toISOString().replace(/\.\d{3}Z$/, "Z");
      }
      if (/[zZ]|[+-]\d{2}:?\d{2}$/.test(s)) {
        return s.endsWith("Z") || s.endsWith("z") ? s.replace(/z$/i, "Z") : s;
      }
      const d = new Date(s.includes("T") ? s + "Z" : s + "T00:00:00Z");
      if (!Number.isNaN(d.getTime())) return d.toISOString().replace(/\.\d{3}Z$/, "Z");
      return s;
    }
    const d = new Date(Number(ts) * 1000);
    if (Number.isNaN(d.getTime())) return String(ts);
    return d.toISOString().replace(/\.\d{3}Z$/, "Z");
  }

  function displayTs(...vals) {
    for (const v of vals) {
      if (v == null || v === "") continue;
      if (typeof v === "string" && v.trim()) return v.trim();
      if (typeof v === "number" && Number.isFinite(v)) return fmtTs(v);
    }
    return "—";
  }

  function fmtNum(n, digits = 1) {
    if (n == null || Number.isNaN(Number(n))) return "—";
    const x = Number(n);
    if (Math.abs(x) >= 1e9) return (x / 1e9).toFixed(digits) + "G";
    if (Math.abs(x) >= 1e6) return (x / 1e6).toFixed(digits) + "M";
    if (Math.abs(x) >= 1e3) return (x / 1e3).toFixed(digits) + "k";
    return x.toFixed(digits);
  }

  function fmtBw(bps) {
    if (bps == null) return "—";
    return fmtNum(bps, 1) + " B/s";
  }

  function fmtWorkloadStatus(uiStatus) {
    return uiStatus === "running" ? "running" : "idle";
  }

  /** Batches-list Workload status column: running / idle only. */
  function fmtWorkloadColumn(s) {
    if (!s) return "—";
    const running = Number(s.running || 0);
    const total = Number(s.configured ?? 0);
    const idle = total > 0 ? Math.max(0, total - running) : Number(s.idle || 0);
    return `${running} running · ${idle} idle`;
  }

  /** Parse location hash (or a hash string) into a route object. */
  function parseRoute(hash) {
    const raw =
      hash != null
        ? String(hash)
        : typeof location !== "undefined"
          ? location.hash || "#/runs"
          : "#/runs";
    const h = raw.replace(/^#/, "");
    const parts = h.split("/").filter(Boolean);
    if (parts[0] !== "runs") return { name: "runs" };
    if (parts.length === 1) return { name: "runs" };
    const batchId = decodeURIComponent(parts[1]);
    if (parts.length === 2) return { name: "run", batchId };
    if (parts[2] === "payload" && parts[3]) {
      return { name: "payload", batchId, resultId: decodeURIComponent(parts[3]) };
    }
    if (parts[2] === "vms" && parts[3]) {
      const vm = decodeURIComponent(parts[3]);
      if (parts[4] === "cycles" && parts[5] != null) {
        return { name: "cycle", batchId, vm, cycle: decodeURIComponent(parts[5]) };
      }
      return { name: "vm", batchId, vm };
    }
    return { name: "run", batchId };
  }

  function statusBadge(status, fioRc) {
    const st = status || (fioRc != null && Number(fioRc) !== 0 ? "fio_error" : "ok");
    if (!st || st === "ok") return '<span class="badge ok">ok</span>';
    if (st === "post_error") return `<span class="badge warn">${escapeHtml(st)}</span>`;
    return `<span class="badge err">${escapeHtml(st)}</span>`;
  }

  function createAnchorUnix(vm, batchDvCreatedAt, batchStartedAt) {
    if (vm && vm.dv_created_at_unix != null && Number.isFinite(Number(vm.dv_created_at_unix))) {
      return Number(vm.dv_created_at_unix);
    }
    if (batchDvCreatedAt != null && Number.isFinite(Number(batchDvCreatedAt))) {
      return Number(batchDvCreatedAt);
    }
    if (batchStartedAt != null && Number.isFinite(Number(batchStartedAt))) {
      return Number(batchStartedAt);
    }
    return null;
  }

  function bootDurationsSeconds(vms, batchStartedAt, batchDvCreatedAt) {
    const out = [];
    for (const v of vms || []) {
      const boot = v.boot_timestamp_unix;
      if (boot == null) continue;
      const anchor = createAnchorUnix(v, batchDvCreatedAt, batchStartedAt);
      if (anchor == null) continue;
      const s = Number(boot) - Number(anchor);
      if (!Number.isFinite(s) || s < 0) continue;
      out.push({ vm_name: v.vm_name, seconds: s });
    }
    return out;
  }

  function fmtBootTimeSummary(vms, batchStartedAt, batchDvCreatedAt) {
    const samples = bootDurationsSeconds(vms, batchStartedAt, batchDvCreatedAt);
    if (!samples.length) return "Boot time —";
    const seconds = samples.map((s) => s.seconds);
    const min = Math.min(...seconds);
    const max = Math.max(...seconds);
    const avg = seconds.reduce((a, b) => a + b, 0) / seconds.length;
    const label =
      batchDvCreatedAt != null || (vms || []).some((v) => v.dv_created_at_unix != null)
        ? "DV→boot"
        : "Boot time";
    return `${label} avg ${Math.round(avg)}s · min ${Math.round(min)}s · max ${Math.round(max)}s`;
  }

  function csvEscape(val) {
    const s = val == null ? "" : String(val);
    if (/[",\n\r]/.test(s)) return `"${s.replace(/"/g, '""')}"`;
    return s;
  }

  function buildBootTimesCsv(batchId, vms, batchStartedAt, batchDvCreatedAt) {
    const header = [
      "batch_id",
      "vm_name",
      "namespace",
      "batch_started_at_utc",
      "dv_created_at_utc",
      "boot_timestamp_utc",
      "boot_duration_s",
      "dv_to_boot_s",
    ];
    const startedIso = fmtTs(batchStartedAt);
    const rows = [header.join(",")];
    for (const v of vms || []) {
      const boot = v.boot_timestamp_unix;
      const dv = v.dv_created_at_unix != null ? v.dv_created_at_unix : batchDvCreatedAt;
      let bootDuration = "";
      let dvToBoot = "";
      if (boot != null && batchStartedAt != null) {
        const s = Number(boot) - Number(batchStartedAt);
        if (Number.isFinite(s) && s >= 0) bootDuration = String(Math.round(s));
      }
      if (boot != null && dv != null) {
        const s = Number(boot) - Number(dv);
        if (Number.isFinite(s) && s >= 0) dvToBoot = String(Math.round(s));
      }
      rows.push(
        [
          csvEscape(batchId),
          csvEscape(v.vm_name),
          csvEscape(v.namespace || ""),
          csvEscape(startedIso === "—" ? "" : startedIso),
          csvEscape(dv != null ? fmtTs(dv) : ""),
          csvEscape(boot != null ? fmtTs(boot) : ""),
          csvEscape(bootDuration),
          csvEscape(dvToBoot),
        ].join(",")
      );
    }
    return rows.join("\n") + "\n";
  }

  function histogramBins(values, { maxBins = 12, minWidth = 5 } = {}) {
    if (!values.length) return { labels: [], counts: [], edges: [] };
    const sorted = [...values].sort((a, b) => a - b);
    const lo = sorted[0];
    const hi = sorted[sorted.length - 1];
    if (hi === lo) {
      const label = `${Math.round(lo)}s`;
      return { labels: [label], counts: [values.length], edges: [lo, lo + minWidth] };
    }
    const n = Math.min(maxBins, Math.max(3, Math.ceil(Math.sqrt(values.length))));
    let width = (hi - lo) / n;
    if (width < minWidth) width = minWidth;
    const binCount = Math.max(1, Math.ceil((hi - lo) / width));
    const edges = [];
    for (let i = 0; i <= binCount; i++) edges.push(lo + i * width);
    edges[edges.length - 1] = Math.max(edges[edges.length - 1], hi);
    const counts = new Array(binCount).fill(0);
    for (const v of values) {
      let idx = Math.floor((v - lo) / width);
      if (idx >= binCount) idx = binCount - 1;
      if (idx < 0) idx = 0;
      counts[idx] += 1;
    }
    const labels = [];
    for (let i = 0; i < binCount; i++) {
      const a = Math.round(edges[i]);
      const b = Math.round(edges[i + 1]);
      labels.push(`${a}–${b}s`);
    }
    return { labels, counts, edges };
  }

  const api = {
    escapeHtml,
    fmtTs,
    displayTs,
    fmtNum,
    fmtBw,
    fmtWorkloadStatus,
    fmtWorkloadColumn,
    parseRoute,
    statusBadge,
    createAnchorUnix,
    bootDurationsSeconds,
    fmtBootTimeSummary,
    csvEscape,
    buildBootTimesCsv,
    histogramBins,
  };

  root.WorkloadDashboardLib = api;
  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : this);
