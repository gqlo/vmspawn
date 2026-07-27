/* Workload-result dashboard (hash router). */

const state = {
  chart: null,
  timer: null,
  downloadUrl: null,
  selectedBatches: new Set(),
  selectedVms: new Set(),
  selectedVmsBatchId: null,
  filters: {
    q: "",
    archived: "0",
    datePreset: "all", // all | today | day
    date: "",
    batch_id: "",
    namespace: "",
    api_server: "",
  },
};

const TOKEN_KEY = "workload-result-token";

const {
  escapeHtml,
  fmtTs,
  displayTs,
  fmtNum,
  fmtBw,
  fmtWorkloadStatus,
  fmtWorkloadColumn,
  parseRoute,
  statusBadge,
  bootDurationsSeconds,
  fmtBootTimeSummary,
  buildBootTimesCsv,
  histogramBins,
} = globalThis.WorkloadDashboardLib;

function getStoredToken() {
  try {
    return localStorage.getItem(TOKEN_KEY) || "";
  } catch {
    return "";
  }
}

function setStoredToken(token) {
  try {
    if (token) localStorage.setItem(TOKEN_KEY, token);
    else localStorage.removeItem(TOKEN_KEY);
  } catch {
    /* ignore quota / private mode */
  }
}

async function api(path, opts = {}) {
  const headers = {
    Accept: "application/json",
    ...(opts.body ? { "Content-Type": "application/json" } : {}),
    ...(opts.headers || {}),
  };
  const token = getStoredToken();
  if (token && !headers.Authorization) {
    headers.Authorization = `Bearer ${token}`;
  }

  const doFetch = async (hdrs) => {
    const res = await fetch(path, { ...opts, headers: hdrs });
    const text = await res.text();
    let data = null;
    try {
      data = text ? JSON.parse(text) : null;
    } catch {
      data = { error: text };
    }
    return { res, data };
  };

  let { res, data } = await doFetch(headers);
  if (res.status === 401) {
    const entered = window.prompt("Collector requires a bearer token. Enter token:");
    if (entered != null && entered.trim()) {
      setStoredToken(entered.trim());
      headers.Authorization = `Bearer ${entered.trim()}`;
      ({ res, data } = await doFetch(headers));
    }
  }
  if (!res.ok) {
    throw new Error((data && data.error) || res.statusText || "request failed");
  }
  return data;
}

function $(sel) {
  return document.querySelector(sel);
}

function setCrumbs(items) {
  const el = $("#crumbs");
  el.innerHTML = items
    .map((it, i) => {
      const sep = i ? '<span class="sep">/</span>' : "";
      if (it.href) return `${sep}<a href="${escapeHtml(it.href)}">${escapeHtml(it.label)}</a>`;
      return `${sep}<span>${escapeHtml(it.label)}</span>`;
    })
    .join("");
}

function destroyChart() {
  if (state.chart) {
    state.chart.destroy();
    state.chart = null;
  }
  if (state.downloadUrl) {
    URL.revokeObjectURL(state.downloadUrl);
    state.downloadUrl = null;
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
    setCrumbs([{ label: "Batches", href: "#/runs" }, { label: "Error" }]);
    app.innerHTML = `<div class="error">${escapeHtml(err.message)}</div>`;
  }
}

async function renderRuns(app) {
  setCrumbs([{ label: "Batches" }]);
  const f = state.filters;
  const params = new URLSearchParams();
  if (f.q) params.set("q", f.q);
  if (f.archived !== "all") params.set("archived", f.archived);
  if (f.datePreset === "today") params.set("today", "1");
  else if (f.datePreset === "day" && f.date) params.set("date", f.date);
  if (f.batch_id) params.set("batch_id", f.batch_id);
  if (f.namespace) params.set("namespace", f.namespace);
  if (f.api_server) params.set("api_server", f.api_server);
  const data = await api("/v1/batches?" + params.toString());
  const items = data.items || [];
  const facets = data.facets || {};
  const totals = items.reduce(
    (acc, b) => {
      const s = b.vm_summary || {};
      acc.batches += 1;
      acc.configured += Number(s.configured || b.total_vms || 0);
      acc.checked_in += Number(s.checked_in || 0);
      if (s.vmi_running != null) {
        acc.vmi_running += Number(s.vmi_running || 0);
        acc.vmi_known = true;
      }
      acc.running += Number(s.running || 0);
      acc.idle += Number(s.idle || 0);
      acc.waiting += Number(s.waiting || 0);
      acc.error += Number(s.error || 0);
      return acc;
    },
    {
      batches: 0,
      configured: 0,
      checked_in: 0,
      vmi_running: 0,
      vmi_known: false,
      running: 0,
      idle: 0,
      waiting: 0,
      error: 0,
    }
  );

  const opt = (value, label, selected) =>
    `<option value="${escapeHtml(value)}" ${selected ? "selected" : ""}>${escapeHtml(label)}</option>`;
  const facetOpts = (values, current, emptyLabel) =>
    [opt("", emptyLabel, !current)]
      .concat((values || []).map((v) => opt(v, v, v === current)))
      .join("");

  app.innerHTML = `
    <div class="panel">
      <div class="row" style="justify-content:space-between;align-items:center">
        <div class="muted mono">
          ${escapeHtml(String(totals.batches))} batches ·
          ${escapeHtml(String(totals.configured))} VMs created ·
          ${escapeHtml(String(totals.checked_in))} contacted collector ·
          ${escapeHtml(totals.vmi_known ? String(totals.vmi_running) : "—")} VMI running ·
          ${escapeHtml(String(totals.running))} workload running ·
          ${escapeHtml(String(totals.idle))} idle ·
          ${escapeHtml(String(totals.waiting))} not contacted
          ${totals.error ? ` · ${escapeHtml(String(totals.error))} error` : ""}
        </div>
      </div>
      <form id="filter-form" class="filters" autocomplete="off">
        <label class="filter-field">
          <span>Search</span>
          <input type="search" id="filter-q" placeholder="batch / basename / label…" value="${escapeHtml(f.q)}" />
        </label>
        <label class="filter-field">
          <span>Date</span>
          <select id="filter-date-preset">
            ${opt("all", "All dates", f.datePreset === "all")}
            ${opt("today", "Today (UTC)", f.datePreset === "today")}
            ${opt("day", "Specific day…", f.datePreset === "day")}
          </select>
        </label>
        <label class="filter-field" id="filter-date-wrap" style="${f.datePreset === "day" ? "" : "display:none"}">
          <span>Day (UTC)</span>
          <input type="date" id="filter-date" value="${escapeHtml(f.date)}" />
        </label>
        <label class="filter-field">
          <span>Batch</span>
          <input type="search" id="filter-batch" list="facet-batches" placeholder="batch id…" value="${escapeHtml(f.batch_id)}" />
          <datalist id="facet-batches">${(facets.batch_ids || []).map((v) => `<option value="${escapeHtml(v)}">`).join("")}</datalist>
        </label>
        <label class="filter-field">
          <span>Namespace</span>
          <select id="filter-namespace">
            ${facetOpts(facets.namespaces, f.namespace, "All namespaces")}
          </select>
        </label>
        <label class="filter-field">
          <span>API server</span>
          <select id="filter-api-server">
            ${facetOpts(facets.api_servers, f.api_server, "All API servers")}
          </select>
        </label>
        <label class="filter-field">
          <span>Status</span>
          <select id="filter-archived">
            ${opt("0", "Active", f.archived === "0")}
            ${opt("1", "Archived", f.archived === "1")}
            ${opt("all", "All", f.archived === "all")}
          </select>
        </label>
        <div class="filter-actions">
          <button type="submit" class="btn primary" id="filter-apply">Apply</button>
          <button type="button" class="btn" id="filter-clear">Clear</button>
        </div>
      </form>
      ${
        items.length
          ? `<div class="batch-toolbar">
        <label class="check-all-label"><input type="checkbox" id="batch-check-all" ${
          items.length && items.every((b) => state.selectedBatches.has(b.batch_id)) ? "checked" : ""
        } /> Select all</label>
        <button type="button" class="btn danger" id="btn-delete-selected" ${
          state.selectedBatches.size ? "" : "disabled"
        }>Delete selected (${escapeHtml(String(state.selectedBatches.size))})</button>
      </div>
      <div class="table-wrap"><table>
        <thead>
          <tr>
            <th class="col-check"></th>
            <th>Batch</th>
            <th>Basename</th>
            <th>API server</th>
            <th>Namespaces</th>
            <th>Started</th>
            <th>Stopped</th>
            <th>Workload status</th>
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
              <td class="col-check" onclick="event.stopPropagation()">
                <input type="checkbox" class="batch-check" data-batch="${escapeHtml(b.batch_id)}" ${
                  state.selectedBatches.has(b.batch_id) ? "checked" : ""
                } />
              </td>
              <td class="mono">${escapeHtml(b.batch_id)}${b.archived ? ' <span class="badge archived">archived</span>' : ""}</td>
              <td>${escapeHtml(b.basename || "—")}</td>
              <td class="mono" title="${escapeHtml(b.api_server || "")}">${escapeHtml(
                b.api_server
                  ? b.api_server.replace(/^https?:\/\//, "").replace(/:6443$/, "")
                  : "—"
              )}</td>
              <td class="mono">${escapeHtml((b.namespaces || []).join(", ") || "—")}</td>
              <td class="mono">${escapeHtml(fmtTs(b.started_at))}</td>
              <td class="mono">${escapeHtml(fmtTs(b.stopped_at))}</td>
              <td class="muted">${escapeHtml(fmtWorkloadColumn(b.vm_summary))}</td>
              <td>${escapeHtml(String(b.cycle_count ?? 0))}</td>
              <td>${
                b.error_count
                  ? `<span class="badge err">${escapeHtml(String(b.error_count))}</span>`
                  : "0"
              }</td>
              <td>${escapeHtml(fmtNum(b.iops_avg, 0))}</td>
              <td>${escapeHtml(fmtBw(b.bw_avg))}</td>
              <td class="mono">${escapeHtml(b.fingerprint || b.cloudinit || "—")}</td>
              <td class="row-actions" onclick="event.stopPropagation()">
                <a class="btn" href="#/runs/${encodeURIComponent(b.batch_id)}">Open</a>
                <button type="button" class="btn danger btn-delete-batch" data-batch="${escapeHtml(b.batch_id)}">Delete</button>
              </td>
            </tr>`
            )
            .join("")}
        </tbody>
      </table></div>`
          : `<div class="empty">No batches match these filters. POST batch/cycle payloads to <span class="mono">/v1/results</span>.</div>`
      }
    </div>`;

  const syncFiltersFromForm = () => {
    state.filters.q = ($("#filter-q") && $("#filter-q").value.trim()) || "";
    state.filters.archived = ($("#filter-archived") && $("#filter-archived").value) || "0";
    state.filters.datePreset = ($("#filter-date-preset") && $("#filter-date-preset").value) || "all";
    state.filters.date = ($("#filter-date") && $("#filter-date").value) || "";
    state.filters.batch_id = ($("#filter-batch") && $("#filter-batch").value.trim()) || "";
    state.filters.namespace = ($("#filter-namespace") && $("#filter-namespace").value) || "";
    state.filters.api_server = ($("#filter-api-server") && $("#filter-api-server").value) || "";
  };

  const applyFilters = () => {
    syncFiltersFromForm();
    render();
  };

  const updateBulkDeleteBtn = () => {
    const btn = $("#btn-delete-selected");
    const all = $("#batch-check-all");
    if (btn) {
      btn.disabled = state.selectedBatches.size === 0;
      btn.textContent = `Delete selected (${state.selectedBatches.size})`;
    }
    if (all && items.length) {
      all.checked = items.every((b) => state.selectedBatches.has(b.batch_id));
      all.indeterminate =
        !all.checked && items.some((b) => state.selectedBatches.has(b.batch_id));
    }
  };

  $("#filter-date-preset").onchange = () => {
    const wrap = $("#filter-date-wrap");
    const preset = $("#filter-date-preset").value;
    wrap.style.display = preset === "day" ? "" : "none";
    if (preset === "day" && !$("#filter-date").value) {
      $("#filter-date").value = new Date().toISOString().slice(0, 10);
    }
    // For "day", wait until the date input is set; still apply (uses today's date default).
    applyFilters();
  };
  ["filter-namespace", "filter-api-server", "filter-archived", "filter-date"].forEach((id) => {
    const el = $("#" + id);
    if (el) el.onchange = applyFilters;
  });
  $("#filter-form").onsubmit = (e) => {
    e.preventDefault();
    applyFilters();
  };
  $("#filter-clear").onclick = () => {
    clearFilters();
    render();
  };

  // Drop selections that are no longer in the current list.
  const visibleIds = new Set(items.map((b) => b.batch_id));
  for (const id of [...state.selectedBatches]) {
    if (!visibleIds.has(id)) state.selectedBatches.delete(id);
  }
  updateBulkDeleteBtn();

  const checkAll = $("#batch-check-all");
  if (checkAll) {
    checkAll.onchange = () => {
      if (checkAll.checked) items.forEach((b) => state.selectedBatches.add(b.batch_id));
      else items.forEach((b) => state.selectedBatches.delete(b.batch_id));
      app.querySelectorAll(".batch-check").forEach((cb) => {
        cb.checked = checkAll.checked;
      });
      updateBulkDeleteBtn();
    };
  }
  app.querySelectorAll(".batch-check").forEach((cb) => {
    cb.onchange = () => {
      const id = cb.getAttribute("data-batch");
      if (!id) return;
      if (cb.checked) state.selectedBatches.add(id);
      else state.selectedBatches.delete(id);
      updateBulkDeleteBtn();
    };
  });
  const deleteSelected = $("#btn-delete-selected");
  if (deleteSelected) {
    deleteSelected.onclick = async () => {
      const ids = [...state.selectedBatches];
      if (!ids.length) return;
      if (
        !confirm(
          `Delete ${ids.length} batch${ids.length === 1 ? "" : "es"} (${ids.join(", ")}) and all stored payloads?`
        )
      ) {
        return;
      }
      try {
        for (const id of ids) {
          await api("/v1/batches/" + encodeURIComponent(id), { method: "DELETE" });
          state.selectedBatches.delete(id);
        }
        render();
      } catch (err) {
        alert("Delete failed: " + (err && err.message ? err.message : err));
        render();
      }
    };
  }

  app.querySelectorAll("tr.clickable").forEach((tr) => {
    tr.onclick = (e) => {
      if (e.target.closest("a, button, .row-actions, .col-check, input")) return;
      location.hash = tr.dataset.href;
    };
  });
  app.querySelectorAll(".btn-delete-batch").forEach((btn) => {
    btn.onclick = async (e) => {
      e.preventDefault();
      e.stopPropagation();
      const id = btn.getAttribute("data-batch");
      if (!id) return;
      if (!confirm(`Delete batch ${id} and all stored payloads?`)) return;
      try {
        await api("/v1/batches/" + encodeURIComponent(id), { method: "DELETE" });
        state.selectedBatches.delete(id);
        render();
      } catch (err) {
        alert("Delete failed: " + (err && err.message ? err.message : err));
      }
    };
  });
}

async function renderRun(app, batchId) {
  setCrumbs([
    { label: "Batches", href: "#/runs" },
    { label: batchId },
  ]);
  const b = await api("/v1/batches/" + encodeURIComponent(batchId));
  const bp = b.batch_payload || {};
  const batchResultId = b.batch_result_id;
  const vs = b.vm_summary || {};
  const bootSummary = fmtBootTimeSummary(b.vms || [], b.started_at);
  const vmList = b.vms || [];
  if (state.selectedVmsBatchId !== batchId) {
    state.selectedVms = new Set();
    state.selectedVmsBatchId = batchId;
  }
  const knownNames = new Set(vmList.map((v) => v.vm_name));
  for (const name of [...state.selectedVms]) {
    if (!knownNames.has(name)) state.selectedVms.delete(name);
  }
  const selectedCount = state.selectedVms.size;
  const allSelected = vmList.length > 0 && selectedCount === vmList.length;
  const scopeLabel = selectedCount ? String(selectedCount) : "all";

  app.innerHTML = `
    <div class="panel">
      <div class="row" style="justify-content:space-between">
        <div>
          <h2 style="margin:0">${escapeHtml(batchId)} ${b.archived ? '<span class="badge archived">archived</span>' : ""}</h2>
          <div class="muted">${escapeHtml(b.basename || "")} · ${escapeHtml(b.fingerprint || b.cloudinit || "")}</div>
          <div class="muted" style="margin-top:0.35rem">${escapeHtml(fmtWorkloadColumn(vs))}</div>
          <div class="muted mono" style="margin-top:0.35rem">
            ${escapeHtml(bootSummary)}
            · <a href="#" id="btn-boot-csv">Download boot times CSV</a>
          </div>
        </div>
        <div class="actions">
          ${batchResultId ? `<a class="btn" href="#/runs/${encodeURIComponent(batchId)}/payload/${encodeURIComponent(batchResultId)}">View manifest</a>` : ""}
          <button type="button" class="btn" id="btn-archive">${b.archived ? "Unarchive" : "Archive"}</button>
          <button type="button" class="btn danger" id="btn-delete">Delete</button>
        </div>
      </div>
      <div class="grid-2" style="margin-top:1rem">
        <dl class="kv">
          <dt>Started</dt><dd class="mono">${escapeHtml(fmtTs(b.started_at))}</dd>
          <dt>Stopped</dt><dd class="mono">${escapeHtml(fmtTs(b.stopped_at))}</dd>
          <dt>Created VMs</dt><dd>${escapeHtml(String(b.total_vms ?? "—"))}</dd>
          <dt>Cycles</dt><dd>${escapeHtml(String(b.cycle_count ?? 0))} / ${escapeHtml(String(b.vms_reporting ?? 0))} VMs reporting
            ${b.error_count ? ` · <span class="badge err">${escapeHtml(String(b.error_count))} errors</span>` : ""}
            ${b.event_count ? ` · <span class="badge warn">${escapeHtml(String(b.event_count))} events</span>` : ""}
          </dd>
          <dt>Cores / Mem</dt><dd>${escapeHtml(String(b.cores ?? "—"))} / ${escapeHtml(String(b.memory ?? "—"))}</dd>
        </dl>
        <div>
          <h3 style="margin-top:0">vstorm metadata</h3>
          <dl class="kv">
            <dt>API server</dt><dd class="mono">${escapeHtml((bp.cluster && bp.cluster.api_server) || "—")}</dd>
            <dt>Nodes</dt><dd>${escapeHtml(
              bp.cluster && (bp.cluster.worker_nodes != null || bp.cluster.master_nodes != null)
                ? `${bp.cluster.worker_nodes ?? "—"} worker / ${bp.cluster.master_nodes ?? "—"} master`
                : "—"
            )}</dd>
            <dt>oc version</dt><dd class="mono" style="white-space:pre-wrap">${escapeHtml((bp.cluster && bp.cluster.oc_version) || "—")}</dd>
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
      <h3 style="margin-top:0">VMs</h3>
      ${
        vmList.length
          ? `<div class="batch-toolbar">
        <label class="check-all-label"><input type="checkbox" id="vm-check-all" ${
          allSelected ? "checked" : ""
        } /> Select all</label>
        <span class="muted mono" id="vm-selection-label">${
          selectedCount
            ? `${escapeHtml(String(selectedCount))} selected`
            : "none selected · actions apply to all"
        }</span>
        <div class="actions" style="margin-left:auto">
          <button type="button" class="btn primary" id="btn-batch-once">Run once (${escapeHtml(scopeLabel)})</button>
          <button type="button" class="btn" id="btn-batch-n">Run N (${escapeHtml(scopeLabel)})…</button>
          <button type="button" class="btn" id="btn-batch-forever">Forever (${escapeHtml(scopeLabel)})</button>
          <button type="button" class="btn" id="btn-batch-idle">Idle (${escapeHtml(scopeLabel)})</button>
        </div>
      </div>
      <div class="table-wrap"><table>
        <thead><tr><th class="col-check"></th><th>VM</th><th>Workload status</th><th>Policy</th><th>Namespace</th><th>Cycles</th><th>Last stopped</th><th>Boot</th></tr></thead>
        <tbody>
          ${vmList
            .map(
              (v) => `<tr class="clickable" data-href="#/runs/${encodeURIComponent(batchId)}/vms/${encodeURIComponent(v.vm_name)}">
              <td class="col-check" onclick="event.stopPropagation()">
                <input type="checkbox" class="vm-check" data-vm="${escapeHtml(v.vm_name)}" ${
                  state.selectedVms.has(v.vm_name) ? "checked" : ""
                } />
              </td>
              <td class="mono"><a href="#/runs/${encodeURIComponent(batchId)}/vms/${encodeURIComponent(v.vm_name)}">${escapeHtml(v.vm_name)}</a></td>
              <td>${escapeHtml(fmtWorkloadStatus(v.ui_status))}</td>
              <td class="mono">${escapeHtml(v.policy_mode || "—")}${
                v.policy_remaining != null ? ` · ${escapeHtml(String(v.policy_remaining))}` : ""
              }</td>
              <td class="mono">${escapeHtml(v.namespace || "—")}</td>
              <td>${escapeHtml(String(v.cycle_count || 0))}</td>
              <td class="mono">${escapeHtml(fmtTs(v.last_stopped_at))}</td>
              <td class="mono">${escapeHtml(fmtTs(v.boot_timestamp_unix))}</td>
            </tr>`
            )
            .join("")}
        </tbody>
      </table></div>`
          : `<div class="empty">No VMs listed yet.</div>`
      }
    </div>

    <div class="panel">
      <h3 style="margin-top:0">VM creation → guest boot</h3>
      <p class="muted" style="margin-top:0">
        Seconds from batch create start (DV / VM create, UTC) to the guest boot timestamp (UTC).
      </p>
      <div class="chart-wrap"><canvas id="boot-chart"></canvas></div>
      <div id="boot-chart-empty" class="empty" style="display:none">No boot timestamps yet.</div>
      <div id="boot-chart-stats" class="muted mono" style="margin-top:0.5rem"></div>
    </div>`;

  drawBootHistogram(vmList, b.started_at);

  const bootCsvBtn = $("#btn-boot-csv");
  if (bootCsvBtn) {
    bootCsvBtn.onclick = (e) => {
      e.preventDefault();
      const csv = buildBootTimesCsv(batchId, vmList, b.started_at);
      downloadTextFile(`${batchId}-boot-times.csv`, csv, "text/csv;charset=utf-8");
    };
  }

  function syncVmSelectionUi() {
    const n = state.selectedVms.size;
    const scope = n ? String(n) : "all";
    const label = $("#vm-selection-label");
    if (label) {
      label.textContent = n
        ? `${n} selected`
        : "none selected · actions apply to all";
    }
    const allBox = $("#vm-check-all");
    if (allBox) allBox.checked = vmList.length > 0 && n === vmList.length;
    for (const id of ["btn-batch-once", "btn-batch-n", "btn-batch-forever", "btn-batch-idle"]) {
      const el = document.getElementById(id);
      if (!el) continue;
      if (id === "btn-batch-n") el.textContent = `Run N (${scope})…`;
      else if (id === "btn-batch-once") el.textContent = `Run once (${scope})`;
      else if (id === "btn-batch-forever") el.textContent = `Forever (${scope})`;
      else if (id === "btn-batch-idle") el.textContent = `Idle (${scope})`;
    }
  }

  const checkAll = $("#vm-check-all");
  if (checkAll) {
    checkAll.onchange = () => {
      state.selectedVms.clear();
      if (checkAll.checked) {
        for (const v of vmList) state.selectedVms.add(v.vm_name);
      }
      app.querySelectorAll(".vm-check").forEach((cb) => {
        cb.checked = checkAll.checked;
      });
      syncVmSelectionUi();
    };
  }
  app.querySelectorAll(".vm-check").forEach((cb) => {
    cb.onchange = () => {
      const name = cb.dataset.vm;
      if (cb.checked) state.selectedVms.add(name);
      else state.selectedVms.delete(name);
      syncVmSelectionUi();
    };
  });

  async function setBatchPolicy(mode, remaining) {
    const body = { mode };
    if (remaining != null) body.remaining = remaining;
    if (state.selectedVms.size) {
      body.vm_names = [...state.selectedVms];
    }
    await api(`/v1/batches/${encodeURIComponent(batchId)}/policy`, {
      method: "POST",
      body: JSON.stringify(body),
    });
    render();
  }
  const btnOnce = $("#btn-batch-once");
  if (btnOnce) btnOnce.onclick = () => setBatchPolicy("once");
  const btnN = $("#btn-batch-n");
  if (btnN) {
    btnN.onclick = () => {
      const n = prompt("How many fio cycles per selected VM?", "2");
      if (n == null) return;
      const remaining = parseInt(n, 10);
      if (!Number.isFinite(remaining) || remaining < 1) {
        alert("Enter a positive integer");
        return;
      }
      setBatchPolicy("count", remaining);
    };
  }
  const btnForever = $("#btn-batch-forever");
  if (btnForever) btnForever.onclick = () => setBatchPolicy("forever");
  const btnIdle = $("#btn-batch-idle");
  if (btnIdle) btnIdle.onclick = () => setBatchPolicy("idle");

  $("#btn-archive").onclick = async () => {
    try {
      await api("/v1/batches/" + encodeURIComponent(batchId), {
        method: "PATCH",
        body: JSON.stringify({ archived: !b.archived }),
      });
      render();
    } catch (err) {
      alert("Archive failed: " + (err && err.message ? err.message : err));
    }
  };
  $("#btn-delete").onclick = async () => {
    if (!confirm(`Delete batch ${batchId} and all stored payloads?`)) return;
    try {
      await api("/v1/batches/" + encodeURIComponent(batchId), { method: "DELETE" });
      location.hash = "#/runs";
    } catch (err) {
      alert("Delete failed: " + (err && err.message ? err.message : err));
    }
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
      if (e.target.closest("input")) return;
      location.hash = tr.dataset.href;
    };
  });
}

function downloadTextFile(filename, text, mime) {
  if (state.downloadUrl) {
    URL.revokeObjectURL(state.downloadUrl);
    state.downloadUrl = null;
  }
  const blob = new Blob([text], { type: mime || "text/plain;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  state.downloadUrl = url;
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
}

function drawBootHistogram(vms, startedAt) {
  const canvas = $("#boot-chart");
  const emptyEl = $("#boot-chart-empty");
  const statsEl = $("#boot-chart-stats");
  if (!canvas || typeof Chart === "undefined") return;

  const samples = bootDurationsSeconds(vms, startedAt);
  if (!samples.length) {
    canvas.style.display = "none";
    if (emptyEl) emptyEl.style.display = "";
    if (statsEl) statsEl.textContent = "";
    return;
  }
  canvas.style.display = "";
  if (emptyEl) emptyEl.style.display = "none";

  const seconds = samples.map((s) => s.seconds);
  const { labels, counts, edges } = histogramBins(seconds);
  const sorted = [...seconds].sort((a, b) => a - b);
  const avg = seconds.reduce((a, b) => a + b, 0) / seconds.length;
  if (statsEl) {
    statsEl.textContent =
      `${samples.length} VMs · min ${Math.round(sorted[0])}s · ` +
      `avg ${Math.round(avg)}s · max ${Math.round(sorted[sorted.length - 1])}s`;
  }

  state.chart = new Chart(canvas, {
    type: "bar",
    data: {
      labels,
      datasets: [
        {
          label: "VMs",
          data: counts,
          backgroundColor: "rgba(9, 105, 218, 0.65)",
          borderColor: "#0969da",
          borderWidth: 1,
        },
      ],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: { display: false },
        tooltip: {
          callbacks: {
            afterBody(items) {
              if (!items.length) return "";
              const idx = items[0].dataIndex;
              const a = edges[idx];
              const b = edges[idx + 1];
              const last = idx === counts.length - 1;
              const names = samples
                .filter((s) => s.seconds >= a && (last ? s.seconds <= b : s.seconds < b))
                .map((s) => s.vm_name);
              return names.length ? names.slice(0, 8).join("\n") + (names.length > 8 ? "\n…" : "") : "";
            },
          },
        },
      },
      scales: {
        x: { title: { display: true, text: "Create → guest boot (seconds)" } },
        y: {
          beginAtZero: true,
          ticks: { stepSize: 1, precision: 0 },
          title: { display: true, text: "VM count" },
        },
      },
    },
  });
}

async function renderVm(app, batchId, vm) {
  setCrumbs([
    { label: "Batches", href: "#/runs" },
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
          ? `<div class="table-wrap"><table>
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
      </table></div>`
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
    { label: "Batches", href: "#/runs" },
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
  if (state.downloadUrl) {
    URL.revokeObjectURL(state.downloadUrl);
    state.downloadUrl = null;
  }
  const blob = new Blob([raw], { type: "application/json" });
  const url = URL.createObjectURL(blob);
  state.downloadUrl = url;
  const dl = $("#btn-download");
  dl.href = url;
  dl.download = `${batchId}-${resultId.slice(0, 8)}.json`;
}

function clearFilters() {
  state.filters = {
    q: "",
    archived: "0",
    datePreset: "all",
    date: "",
    batch_id: "",
    namespace: "",
    api_server: "",
  };
  state.selectedBatches.clear();
}

function setupRefresh() {
  $("#btn-refresh").onclick = () => render();
  const box = $("#auto-refresh");
  const arm = () => {
    if (state.timer) clearInterval(state.timer);
    if (box.checked) {
      state.timer = setInterval(() => {
        const ae = document.activeElement;
        if (ae && (ae.tagName === "INPUT" || ae.tagName === "SELECT" || ae.tagName === "TEXTAREA")) {
          return;
        }
        render();
      }, 5000);
    }
  };
  box.onchange = arm;
  arm();
}

function setupBrandHome() {
  const brand = document.querySelector(".brand a");
  if (!brand) return;
  brand.addEventListener("click", (e) => {
    e.preventDefault();
    clearFilters();
    if (location.hash === "#/runs" || location.hash === "#/" || !location.hash) {
      render();
    } else {
      location.hash = "#/runs";
    }
  });
}

window.addEventListener("hashchange", () => render());
window.addEventListener("DOMContentLoaded", () => {
  if (!location.hash) location.hash = "#/runs";
  setupRefresh();
  setupBrandHome();
  render();
});
