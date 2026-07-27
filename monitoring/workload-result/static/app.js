/* Workload-result dashboard (hash router). */

const state = {
  chart: null,
  timer: null,
};

function $(sel) {
  return document.querySelector(sel);
}

function fmtTs(ts) {
  if (ts == null) return "—";
  if (typeof ts === "string" && ts.trim()) return ts.trim();
  const d = new Date(Number(ts) * 1000);
  if (Number.isNaN(d.getTime())) return String(ts);
  return d.toISOString().replace(/\.\d{3}Z$/, "Z");
}

/** Display timestamp: prefer ISO string (with timezone), else format unix seconds as UTC …Z. */
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

function fmtVmChips(s) {
  if (!s) return "—";
  const parts = [];
  if (s.running) parts.push(`${s.running} running`);
  if (s.queued) parts.push(`${s.queued} queued`);
  if (s.idle) parts.push(`${s.idle} idle`);
  if (s.waiting) parts.push(`${s.waiting} waiting`);
  if (s.error) parts.push(`${s.error} error`);
  if (s.stale) parts.push(`${s.stale} stale`);
  const head = `${s.configured ?? "—"} cfg · ${s.checked_in ?? 0} in`;
  return parts.length ? `${head} · ${parts.join(" · ")}` : head;
}

async function api(path, opts = {}) {
  const res = await fetch(path, {
    headers: { Accept: "application/json", ...(opts.body ? { "Content-Type": "application/json" } : {}), ...(opts.headers || {}) },
    ...opts,
  });
  const text = await res.text();
  let data = null;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = { error: text };
  }
  if (!res.ok) {
    throw new Error((data && data.error) || res.statusText || "request failed");
  }
  return data;
}

function parseRoute() {
  const h = (location.hash || "#/runs").replace(/^#/, "");
  const parts = h.split("/").filter(Boolean);
  // runs
  // runs/:batch
  // runs/:batch/vms/:vm
  // runs/:batch/payload/:resultId
  // runs/:batch/vms/:vm/cycles/:cycle  -> resolve via results list
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

function setCrumbs(items) {
  const el = $("#crumbs");
  el.innerHTML = items
    .map((it, i) => {
      const sep = i ? '<span class="sep">/</span>' : "";
      if (it.href) return `${sep}<a href="${it.href}">${escapeHtml(it.label)}</a>`;
      return `${sep}<span>${escapeHtml(it.label)}</span>`;
    })
    .join("");
}

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function statusBadge(status, fioRc) {
  const st = status || (fioRc != null && Number(fioRc) !== 0 ? "fio_error" : "ok");
  if (!st || st === "ok") return '<span class="badge ok">ok</span>';
  if (st === "post_error") return `<span class="badge warn">${escapeHtml(st)}</span>`;
  return `<span class="badge err">${escapeHtml(st)}</span>`;
}

function destroyChart() {
  if (state.chart) {
    state.chart.destroy();
    state.chart = null;
  }
}

async function render() {
  const app = $("#app");
  const route = parseRoute();
  destroyChart();
  try {
    if (route.name === "runs") await renderRuns(app);
    else if (route.name === "run") await renderRun(app, route.batchId);
    else if (route.name === "vm") await renderVm(app, route.batchId, route.vm);
    else if (route.name === "cycle") await renderCycle(app, route.batchId, route.vm, route.cycle);
    else if (route.name === "payload") await renderPayload(app, route.batchId, route.resultId);
    else await renderRuns(app);
  } catch (err) {
    setCrumbs([{ label: "Runs", href: "#/runs" }, { label: "Error" }]);
    app.innerHTML = `<div class="error">${escapeHtml(err.message)}</div>`;
  }
}

async function renderRuns(app) {
  setCrumbs([{ label: "Runs" }]);
  const q = ($("#filter-q") && $("#filter-q").value) || "";
  const archived = ($("#filter-archived") && $("#filter-archived").value) || "0";
  const params = new URLSearchParams();
  if (q) params.set("q", q);
  if (archived !== "all") params.set("archived", archived);
  const data = await api("/v1/batches?" + params.toString());
  const items = data.items || [];
  const totals = items.reduce(
    (acc, b) => {
      const s = b.vm_summary || {};
      acc.runs += 1;
      acc.configured += Number(s.configured || b.total_vms || 0);
      acc.checked_in += Number(s.checked_in || 0);
      acc.running += Number(s.running || 0);
      acc.idle += Number(s.idle || 0);
      acc.waiting += Number(s.waiting || 0);
      acc.error += Number(s.error || 0);
      return acc;
    },
    { runs: 0, configured: 0, checked_in: 0, running: 0, idle: 0, waiting: 0, error: 0 }
  );

  app.innerHTML = `
    <div class="panel">
      <div class="row" style="justify-content:space-between;align-items:center">
        <div class="muted mono">
          ${escapeHtml(String(totals.runs))} runs ·
          ${escapeHtml(String(totals.configured))} VMs configured ·
          ${escapeHtml(String(totals.checked_in))} checked in ·
          ${escapeHtml(String(totals.running))} running ·
          ${escapeHtml(String(totals.idle))} idle ·
          ${escapeHtml(String(totals.waiting))} waiting
          ${totals.error ? ` · ${escapeHtml(String(totals.error))} error` : ""}
        </div>
      </div>
      <div class="row" style="margin-top:0.75rem">
        <input type="search" id="filter-q" placeholder="Filter batch id / basename…" value="${escapeHtml(q)}" />
        <select id="filter-archived">
          <option value="0" ${archived === "0" ? "selected" : ""}>Active</option>
          <option value="1" ${archived === "1" ? "selected" : ""}>Archived</option>
          <option value="all" ${archived === "all" ? "selected" : ""}>All</option>
        </select>
        <button type="button" class="btn" id="filter-apply">Apply</button>
      </div>
      ${
        items.length
          ? `<table>
        <thead>
          <tr>
            <th>Batch</th>
            <th>Basename</th>
            <th>Started</th>
            <th>Stopped</th>
            <th>VM status</th>
            <th>Cycles</th>
            <th>Errors</th>
            <th>IOPS avg</th>
            <th>BW avg</th>
            <th>Workload</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          ${items
            .map(
              (b) => `<tr class="clickable" data-href="#/runs/${encodeURIComponent(b.batch_id)}">
              <td class="mono">${escapeHtml(b.batch_id)}${b.archived ? ' <span class="badge archived">archived</span>' : ""}</td>
              <td>${escapeHtml(b.basename || "—")}</td>
              <td class="mono">${escapeHtml(fmtTs(b.started_at))}</td>
              <td class="mono">${escapeHtml(fmtTs(b.stopped_at))}</td>
              <td class="muted">${escapeHtml(fmtVmChips(b.vm_summary))}</td>
              <td>${escapeHtml(String(b.cycle_count ?? 0))}</td>
              <td>${
                b.error_count
                  ? `<span class="badge err">${escapeHtml(String(b.error_count))}</span>`
                  : "0"
              }</td>
              <td>${escapeHtml(fmtNum(b.iops_avg, 0))}</td>
              <td>${escapeHtml(fmtBw(b.bw_avg))}</td>
              <td class="mono">${escapeHtml(b.fingerprint || b.cloudinit || "—")}</td>
              <td><a href="#/runs/${encodeURIComponent(b.batch_id)}">Open</a></td>
            </tr>`
            )
            .join("")}
        </tbody>
      </table>`
          : `<div class="empty">No runs yet. POST batch/cycle payloads to <span class="mono">/v1/results</span>.</div>`
      }
    </div>`;

  $("#filter-apply").onclick = () => render();
  $("#filter-q").onkeydown = (e) => {
    if (e.key === "Enter") render();
  };
  app.querySelectorAll("tr.clickable").forEach((tr) => {
    tr.onclick = (e) => {
      if (e.target.closest("a")) return;
      location.hash = tr.dataset.href;
    };
  });
}

async function renderRun(app, batchId) {
  setCrumbs([
    { label: "Runs", href: "#/runs" },
    { label: batchId },
  ]);
  const b = await api("/v1/batches/" + encodeURIComponent(batchId));
  const bp = b.batch_payload || {};
  const batchResultId = b.batch_result_id;
  const vs = b.vm_summary || {};

  app.innerHTML = `
    <div class="panel">
      <div class="row" style="justify-content:space-between">
        <div>
          <h2 style="margin:0">${escapeHtml(batchId)} ${b.archived ? '<span class="badge archived">archived</span>' : ""}</h2>
          <div class="muted">${escapeHtml(b.basename || "")} · ${escapeHtml(b.fingerprint || b.cloudinit || "")}</div>
          <div class="muted" style="margin-top:0.35rem">${escapeHtml(fmtVmChips(vs))}</div>
        </div>
        <div class="actions">
          ${batchResultId ? `<a class="btn" href="#/runs/${encodeURIComponent(batchId)}/payload/${encodeURIComponent(batchResultId)}">View manifest</a>` : ""}
          <button type="button" class="btn primary" id="btn-batch-once">Run once (all)</button>
          <button type="button" class="btn" id="btn-batch-n">Run N (all)…</button>
          <button type="button" class="btn" id="btn-batch-forever">Forever (all)</button>
          <button type="button" class="btn" id="btn-batch-idle">Idle (all)</button>
          <button type="button" class="btn" id="btn-archive">${b.archived ? "Unarchive" : "Archive"}</button>
          <button type="button" class="btn danger" id="btn-delete">Delete</button>
        </div>
      </div>
      <div class="grid-2" style="margin-top:1rem">
        <dl class="kv">
          <dt>Started</dt><dd class="mono">${escapeHtml(fmtTs(b.started_at))}</dd>
          <dt>Stopped</dt><dd class="mono">${escapeHtml(fmtTs(b.stopped_at))}</dd>
          <dt>Configured VMs</dt><dd>${escapeHtml(String(b.total_vms ?? "—"))}</dd>
          <dt>Cycles</dt><dd>${escapeHtml(String(b.cycle_count ?? 0))} / ${escapeHtml(String(b.vms_reporting ?? 0))} VMs reporting
            ${b.error_count ? ` · <span class="badge err">${escapeHtml(String(b.error_count))} errors</span>` : ""}
            ${b.event_count ? ` · <span class="badge warn">${escapeHtml(String(b.event_count))} events</span>` : ""}
          </dd>
          <dt>Cores / Mem</dt><dd>${escapeHtml(String(b.cores ?? "—"))} / ${escapeHtml(String(b.memory ?? "—"))}</dd>
          <dt>IOPS p50/p99</dt><dd>${escapeHtml(fmtNum(b.iops_p50, 0))} / ${escapeHtml(fmtNum(b.iops_p99, 0))}</dd>
          <dt>BW p50/p99</dt><dd>${escapeHtml(fmtBw(b.bw_p50))} / ${escapeHtml(fmtBw(b.bw_p99))}</dd>
        </dl>
        <div>
          <h3 style="margin-top:0">vstorm metadata</h3>
          <dl class="kv">
            <dt>Namespaces</dt><dd class="mono">${escapeHtml((bp.namespaces || []).join(", ") || "—")}</dd>
            <dt>Storage</dt><dd>${escapeHtml(bp.storage_class || "—")} / ${escapeHtml(bp.volume_mode || "—")}</dd>
            <dt>Cmdline</dt><dd class="mono">${escapeHtml((bp.cmdline || []).join(" ") || "—")}</dd>
            <dt>Guest env</dt><dd class="mono">${escapeHtml(bp.guest_env ? JSON.stringify(bp.guest_env) : "—")}</dd>
            <dt>Notes</dt><dd><input type="text" id="notes" style="width:100%" value="${escapeHtml(b.notes || "")}" placeholder="Notes…" /></dd>
            <dt>Label</dt><dd><input type="text" id="label" style="width:100%" value="${escapeHtml(b.label || "")}" placeholder="Label…" /></dd>
          </dl>
          <button type="button" class="btn primary" id="btn-save-meta">Save notes/label</button>
        </div>
      </div>
    </div>

    <div class="panel">
      <h3 style="margin-top:0">Charts</h3>
      <div class="chart-wrap"><canvas id="metrics-chart"></canvas></div>
    </div>

    <div class="panel">
      <h3 style="margin-top:0">VMs</h3>
      ${
        (b.vms || []).length
          ? `<table>
        <thead><tr><th>VM</th><th>Status</th><th>Policy</th><th>Namespace</th><th>Cycles</th><th>Last stopped</th><th>Latest IOPS</th><th>Latest BW</th><th>Boot</th></tr></thead>
        <tbody>
          ${(b.vms || [])
            .map(
              (v) => `<tr class="clickable" data-href="#/runs/${encodeURIComponent(batchId)}/vms/${encodeURIComponent(v.vm_name)}">
              <td class="mono"><a href="#/runs/${encodeURIComponent(batchId)}/vms/${encodeURIComponent(v.vm_name)}">${escapeHtml(v.vm_name)}</a></td>
              <td>${escapeHtml(v.ui_status || "—")}</td>
              <td class="mono">${escapeHtml(v.policy_mode || "—")}${
                v.policy_remaining != null ? ` · ${escapeHtml(String(v.policy_remaining))}` : ""
              }</td>
              <td class="mono">${escapeHtml(v.namespace || "—")}</td>
              <td>${escapeHtml(String(v.cycle_count || 0))}</td>
              <td class="mono">${escapeHtml(fmtTs(v.last_stopped_at))}</td>
              <td>${escapeHtml(fmtNum(v.latest_iops, 0))}</td>
              <td>${escapeHtml(fmtBw(v.latest_bw_bytes))}</td>
              <td class="mono">${escapeHtml(fmtTs(v.boot_timestamp_unix))}</td>
            </tr>`
            )
            .join("")}
        </tbody>
      </table>`
          : `<div class="empty">No VMs listed yet.</div>`
      }
    </div>`;

  drawSeriesChart(b.series || []);

  async function setBatchPolicy(mode, remaining) {
    const body = { mode };
    if (remaining != null) body.remaining = remaining;
    await api(`/v1/batches/${encodeURIComponent(batchId)}/policy`, {
      method: "POST",
      body: JSON.stringify(body),
    });
    render();
  }
  $("#btn-batch-once").onclick = () => setBatchPolicy("once");
  $("#btn-batch-n").onclick = () => {
    const n = prompt("How many fio cycles per VM?", "2");
    if (n == null) return;
    const remaining = parseInt(n, 10);
    if (!Number.isFinite(remaining) || remaining < 1) {
      alert("Enter a positive integer");
      return;
    }
    setBatchPolicy("count", remaining);
  };
  $("#btn-batch-forever").onclick = () => setBatchPolicy("forever");
  $("#btn-batch-idle").onclick = () => setBatchPolicy("idle");

  $("#btn-archive").onclick = async () => {
    await api("/v1/batches/" + encodeURIComponent(batchId), {
      method: "PATCH",
      body: JSON.stringify({ archived: !b.archived }),
    });
    render();
  };
  $("#btn-delete").onclick = async () => {
    if (!confirm(`Delete run ${batchId} and all stored payloads?`)) return;
    await api("/v1/batches/" + encodeURIComponent(batchId), { method: "DELETE" });
    location.hash = "#/runs";
  };
  $("#btn-save-meta").onclick = async () => {
    await api("/v1/batches/" + encodeURIComponent(batchId), {
      method: "PATCH",
      body: JSON.stringify({
        notes: $("#notes").value,
        label: $("#label").value,
      }),
    });
    render();
  };
  app.querySelectorAll("tr.clickable").forEach((tr) => {
    tr.onclick = (e) => {
      if (e.target.closest("a")) return;
      location.hash = tr.dataset.href;
    };
  });
}

function drawSeriesChart(series) {
  const canvas = $("#metrics-chart");
  if (!canvas || typeof Chart === "undefined") return;
  const labels = series.map((s, i) => s.cycle != null ? `${s.vm_name || "?"}#${s.cycle}` : String(i + 1));
  state.chart = new Chart(canvas, {
    type: "line",
    data: {
      labels,
      datasets: [
        {
          label: "IOPS",
          data: series.map((s) => s.iops),
          borderColor: "#0969da",
          tension: 0.2,
          yAxisID: "y",
        },
        {
          label: "BW bytes/s",
          data: series.map((s) => s.bw_bytes),
          borderColor: "#1a7f37",
          tension: 0.2,
          yAxisID: "y1",
        },
      ],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      interaction: { mode: "index", intersect: false },
      scales: {
        y: { type: "linear", position: "left", title: { display: true, text: "IOPS" } },
        y1: {
          type: "linear",
          position: "right",
          grid: { drawOnChartArea: false },
          title: { display: true, text: "BW B/s" },
        },
      },
    },
  });
}

async function renderVm(app, batchId, vm) {
  setCrumbs([
    { label: "Runs", href: "#/runs" },
    { label: batchId, href: `#/runs/${encodeURIComponent(batchId)}` },
    { label: vm },
  ]);
  const data = await api(
    `/v1/batches/${encodeURIComponent(batchId)}/vms/${encodeURIComponent(vm)}`
  );
  const id = data.identity || {};
  const cycles = data.cycles || [];
  const policy = data.policy || {};

  app.innerHTML = `
    <div class="panel">
      <div class="row" style="justify-content:space-between;align-items:flex-start">
        <div>
          <h2 style="margin-top:0">${escapeHtml(vm)}</h2>
          <dl class="kv">
            <dt>Hostname</dt><dd class="mono">${escapeHtml(id.hostname || "—")}</dd>
            <dt>CPU / RAM</dt><dd>${escapeHtml(String(id.cpu_count ?? "—"))} / ${escapeHtml(
              id.mem_total_kb != null ? fmtNum(id.mem_total_kb, 0) + " KiB" : "—"
            )}</dd>
            <dt>Boot</dt><dd class="mono">${escapeHtml(fmtTs(id.boot_timestamp_unix))}</dd>
            <dt>First report lag</dt><dd>${escapeHtml(
              id.first_report_lag_s != null ? id.first_report_lag_s + "s" : "—"
            )}</dd>
            <dt>Policy</dt><dd class="mono">${escapeHtml(policy.mode || "—")} · remaining=${escapeHtml(
              String(policy.remaining ?? "—")
            )} · rev=${escapeHtml(String(policy.revision ?? "—"))}</dd>
          </dl>
        </div>
        <div class="actions">
          <button type="button" class="btn primary" id="btn-run-once">Run once</button>
          <button type="button" class="btn" id="btn-run-n">Run N…</button>
          <button type="button" class="btn" id="btn-forever">Forever</button>
          <button type="button" class="btn" id="btn-idle">Idle</button>
        </div>
      </div>
    </div>
    <div class="panel">
      <h3 style="margin-top:0">Cycles</h3>
      ${
        cycles.length
          ? `<table>
        <thead><tr><th>Cycle</th><th>Type</th><th>Status</th><th>fio start</th><th>fio stop</th><th>Duration</th><th>fio_rc</th><th>IOPS</th><th>BW</th><th>Error</th><th></th></tr></thead>
        <tbody>
          ${cycles
            .map((c) => {
              const bad =
                (c.status && c.status !== "ok") ||
                (c.fio_rc != null && Number(c.fio_rc) !== 0);
              return `<tr class="clickable${bad ? " row-error" : ""}" data-href="#/runs/${encodeURIComponent(batchId)}/payload/${encodeURIComponent(c.result_id)}">
              <td>${escapeHtml(String(c.cycle ?? "—"))}</td>
              <td class="mono">${escapeHtml(c.record_type || "result")}</td>
              <td>${statusBadge(c.status, c.fio_rc)}</td>
              <td class="mono">${escapeHtml(fmtTs(c.started_at))}</td>
              <td class="mono">${escapeHtml(fmtTs(c.stopped_at))}</td>
              <td>${escapeHtml(c.duration_s != null ? c.duration_s + "s" : "—")}</td>
              <td>${escapeHtml(String(c.fio_rc ?? "—"))}</td>
              <td>${escapeHtml(fmtNum(c.iops, 0))}</td>
              <td>${escapeHtml(fmtBw(c.bw_bytes))}</td>
              <td class="muted">${escapeHtml(c.error_message || "—")}</td>
              <td><a href="#/runs/${encodeURIComponent(batchId)}/payload/${encodeURIComponent(c.result_id)}">Payload</a></td>
            </tr>`;
            })
            .join("")}
        </tbody>
      </table>`
          : `<div class="empty">Waiting for guest results.</div>`
      }
    </div>`;

  async function setPolicy(mode, remaining) {
    const body = { mode };
    if (remaining != null) body.remaining = remaining;
    await api(`/v1/batches/${encodeURIComponent(batchId)}/vms/${encodeURIComponent(vm)}/policy`, {
      method: "PUT",
      body: JSON.stringify(body),
    });
    render();
  }
  $("#btn-run-once").onclick = () => setPolicy("once");
  $("#btn-run-n").onclick = () => {
    const n = prompt("How many fio cycles?", "2");
    if (n == null) return;
    const remaining = parseInt(n, 10);
    if (!Number.isFinite(remaining) || remaining < 1) {
      alert("Enter a positive integer");
      return;
    }
    setPolicy("count", remaining);
  };
  $("#btn-forever").onclick = () => setPolicy("forever");
  $("#btn-idle").onclick = () => setPolicy("idle");

  app.querySelectorAll("tr.clickable").forEach((tr) => {
    tr.onclick = (e) => {
      if (e.target.closest("a")) return;
      location.hash = tr.dataset.href;
    };
  });
}

async function renderCycle(app, batchId, vm, cycle) {
  const list = await api(
    `/v1/batches/${encodeURIComponent(batchId)}/results?vm=${encodeURIComponent(vm)}&record_type=result&limit=500`
  );
  const match = (list.items || []).find((r) => String(r.cycle) === String(cycle));
  if (!match) throw new Error(`cycle ${cycle} not found for ${vm}`);
  location.replace(`#/runs/${encodeURIComponent(batchId)}/payload/${encodeURIComponent(match.result_id)}`);
}

async function renderPayload(app, batchId, resultId) {
  const data = await api(
    `/v1/batches/${encodeURIComponent(batchId)}/results/${encodeURIComponent(resultId)}`
  );
  const meta = data.meta || {};
  const payload = data.payload || {};
  const fio = payload.fio_group_reporting;

  setCrumbs([
    { label: "Runs", href: "#/runs" },
    { label: batchId, href: `#/runs/${encodeURIComponent(batchId)}` },
    ...(meta.vm_name
      ? [{ label: meta.vm_name, href: `#/runs/${encodeURIComponent(batchId)}/vms/${encodeURIComponent(meta.vm_name)}` }]
      : []),
    { label: "Payload" },
  ]);

  app.innerHTML = `
    <div class="panel">
      <div class="row" style="justify-content:space-between">
        <div>
          <h2 style="margin:0">Payload</h2>
          <div class="muted mono">${escapeHtml([meta.record_type, meta.source, meta.workload_kind].filter(Boolean).join(" · "))} · ${escapeHtml(resultId)}</div>
        </div>
        <div class="actions">
          <button type="button" class="btn" id="btn-copy">Copy JSON</button>
          <a class="btn" id="btn-download" href="#">Download</a>
        </div>
      </div>
      <dl class="kv" style="margin-top:1rem">
        <dt>fio start</dt><dd class="mono">${escapeHtml(displayTs(payload.fio_start, payload.fio_start_unix, payload.started_at))}</dd>
        <dt>fio stop</dt><dd class="mono">${escapeHtml(displayTs(payload.fio_stop, payload.fio_stop_unix, payload.stopped_at))}</dd>
        <dt>Reported</dt><dd class="mono">${escapeHtml(displayTs(payload.reported_at, payload.reported_at_unix))}</dd>
        <dt>Command</dt><dd class="mono">${escapeHtml(
          Array.isArray(payload.fio_command) ? payload.fio_command.join(" ") : (payload.cmdline || []).join?.(" ") || "—"
        )}</dd>
        <dt>Exit / status</dt><dd>${escapeHtml(String(payload.fio_rc ?? "—"))} ${statusBadge(payload.status, payload.fio_rc)}</dd>
        <dt>Error</dt><dd>${escapeHtml(payload.error_message || "—")}</dd>
      </dl>
    </div>
    ${
      fio
        ? `<div class="panel">
      <h3 style="margin-top:0">fio_group_reporting</h3>
      <pre class="payload">${escapeHtml(JSON.stringify(fio, null, 2))}</pre>
    </div>`
        : ""
    }
    <div class="panel">
      <h3 style="margin-top:0">Raw payload</h3>
      <pre class="payload" id="raw-json">${escapeHtml(JSON.stringify(payload, null, 2))}</pre>
    </div>`;

  const raw = JSON.stringify(payload, null, 2);
  $("#btn-copy").onclick = async () => {
    await navigator.clipboard.writeText(raw);
    $("#btn-copy").textContent = "Copied";
    setTimeout(() => ($("#btn-copy").textContent = "Copy JSON"), 1200);
  };
  const blob = new Blob([raw], { type: "application/json" });
  const url = URL.createObjectURL(blob);
  const dl = $("#btn-download");
  dl.href = url;
  dl.download = `${batchId}-${resultId.slice(0, 8)}.json`;
}

function setupRefresh() {
  $("#btn-refresh").onclick = () => render();
  const box = $("#auto-refresh");
  const arm = () => {
    if (state.timer) clearInterval(state.timer);
    if (box.checked) state.timer = setInterval(() => render(), 5000);
  };
  box.onchange = arm;
  arm();
}

window.addEventListener("hashchange", () => render());
window.addEventListener("DOMContentLoaded", () => {
  if (!location.hash) location.hash = "#/runs";
  setupRefresh();
  render();
});
