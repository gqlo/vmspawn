#!/usr/bin/env bash
# Trigger MCP reboot/drain and poll worker MachineConfigNodes until each completes a cycle.
# Per-node estimate: UPDATED=False (start) → UPDATED=True (end), polled every INTERVAL seconds.
# Exits when every mcp/$MCP node has been tracked (starts == ends == worker node count).
# Logs all output to a file (LOG_FILE) and writes per-node timing to CSV_FILE.

set -euo pipefail

readonly MCP="${MCP:-worker}"
readonly INTERVAL="${INTERVAL:-5}"
readonly RUN_TS="$(date +%Y%m%d-%H%M%S)"
readonly LOG_FILE="${LOG_FILE:-mcp-reboot-watch-${MCP}-${RUN_TS}.log}"
readonly CSV_FILE="${CSV_FILE:-mcp-reboot-watch-${MCP}-${RUN_TS}.csv}"

declare -A node_start_epoch=()
declare -A node_finished=()
declare -a worker_nodes=()
declare -a pending_nodes=()
declare -a per_node_durations=()

exec > >(tee -a "$LOG_FILE") 2>&1
printf '%s Logging to %s\n' "$(date -Iseconds)" "$LOG_FILE"
printf '%s Per-node timing CSV: %s\n' "$(date -Iseconds)" "$CSV_FILE"

format_duration() {
  local secs="$1"
  printf '%dm %ds (%ds total)' $((secs / 60)) $((secs % 60)) "$secs"
}

epoch_to_iso() {
  date -d "@$1" -Iseconds 2>/dev/null || date -u -r "$1" -Iseconds
}

nodes_list() {
  if [[ $# -eq 0 ]]; then
    printf 'none'
    return 0
  fi

  local IFS=', '
  printf '%s' "$*"
}

print_tracking_status() {
  local node now updating=() waiting=() finished=()

  now="$(date +%s)"
  for node in "${worker_nodes[@]}"; do
    if [[ -n "${node_finished[$node]:-}" ]]; then
      finished+=("$node")
    elif [[ -n "${node_start_epoch[$node]:-}" ]]; then
      updating+=("$node")
    else
      waiting+=("$node")
    fi
  done

  printf '%s --- tracking status (%s/%s done) ---\n' \
    "$(date -Iseconds)" "${#finished[@]}" "${#worker_nodes[@]}"
  printf '  updating (%s): %s\n' "${#updating[@]}" "$(nodes_list "${updating[@]}")"
  printf '  waiting  (%s): %s\n' "${#waiting[@]}" "$(nodes_list "${waiting[@]}")"
  printf '  finished (%s): %s\n' "${#finished[@]}" "$(nodes_list "${finished[@]}")"

  for node in "${updating[@]}"; do
    printf '    %s: in progress %s\n' "$node" "$(format_duration "$((now - node_start_epoch[$node]))")"
  done
}

mcp_updating() {
  [[ "$(oc get mcp "$MCP" -o jsonpath='{.status.conditions[?(@.type=="Updating")].status}')" == "True" ]]
}

mcn_available() {
  oc api-resources --api-group=machineconfiguration.openshift.io -o name 2>/dev/null \
    | grep -qx 'machineconfignodes.machineconfiguration.openshift.io'
}

mcn_pool_nodes() {
  oc get machineconfignode -o jsonpath="{range .items[?(@.spec.pool.name=='${MCP}')]}{.metadata.name}{'\n'}{end}"
}

mcn_updated() {
  local node="$1"

  [[ "$(oc get machineconfignode "$node" -o jsonpath='{.status.conditions[?(@.type=="Updated")].status}')" == "True" ]]
}

record_node_start() {
  local node="$1" now="$2"

  [[ -n "${node_start_epoch[$node]:-}" ]] && return 0

  node_start_epoch[$node]="$now"
  printf '%s machineconfignode/%s UPDATED=False — started (est.)\n' "$(date -Iseconds)" "$node"
}

record_node_completion() {
  local node="$1" duration="$2" start="$3" end="$4"

  printf '%s,%s,%s,%s\n' "$node" "$duration" "$(epoch_to_iso "$start")" "$(epoch_to_iso "$end")" >> "$CSV_FILE"
}

init_csv() {
  printf 'node,duration_seconds,start_time,end_time\n' > "$CSV_FILE"
}

check_mcn_updates() {
  local node now start end duration elapsed updated_count

  now="$(date +%s)"
  pending_nodes=()

  for node in "${worker_nodes[@]}"; do
    [[ -n "${node_finished[$node]:-}" ]] && continue

    if ! mcn_updated "$node"; then
      record_node_start "$node" "$now"
      pending_nodes+=("$node")
    elif [[ -n "${node_start_epoch[$node]:-}" ]]; then
      start="${node_start_epoch[$node]}"
      end="$now"
      duration="$((end - start))"
      elapsed="$((now - start_epoch))"
      node_finished[$node]=1
      nodes_finished_this_run="$((nodes_finished_this_run + 1))"
      per_node_durations+=("$duration")
      record_node_completion "$node" "$duration" "$start" "$end"
      updated_count="$(oc get mcp "$MCP" -o jsonpath='{.status.updatedMachineCount}')"
      printf '%s machineconfignode/%s UPDATED=True — finished %s (est.), %s since pool started (%s/%s MCP updated, %s/%s tracked)\n' \
        "$(date -Iseconds)" "$node" \
        "$(format_duration "$duration")" \
        "$(format_duration "$elapsed")" \
        "$updated_count" "$machine_count" \
        "$nodes_finished_this_run" "${#worker_nodes[@]}"
    else
      pending_nodes+=("$node")
    fi
  done
}

init_node_tracking() {
  local node now

  if ! mcn_available; then
    printf '%s ERROR: MachineConfigNode CRD not available — requires OpenShift 4.16+\n' "$(date -Iseconds)"
    exit 1
  fi

  machine_count="$(oc get mcp "$MCP" -o jsonpath='{.status.machineCount}')"
  worker_nodes=()
  nodes_finished_this_run=0
  per_node_durations=()
  now="$(date +%s)"

  while read -r node; do
    [[ -z "$node" ]] && continue
    worker_nodes+=("$node")
    if ! mcn_updated "$node"; then
      record_node_start "$node" "$now"
      printf '%s machineconfignode/%s already UPDATED=False at timer start\n' "$(date -Iseconds)" "$node"
    fi
  done < <(mcn_pool_nodes)

  if [[ ${#worker_nodes[@]} -eq 0 ]]; then
    printf '%s ERROR: no MachineConfigNodes found for mcp/%s\n' "$(date -Iseconds)" "$MCP"
    exit 1
  fi

  check_mcn_updates
  printf '%s Tracking %s mcp/%s node(s) via UPDATED=False→True (poll every %ss)\n' \
    "$(date -Iseconds)" "${#worker_nodes[@]}" "$MCP" "$INTERVAL"
  print_tracking_status
}

print_per_node_summary() {
  local total avg dur

  if [[ "$nodes_finished_this_run" -eq 0 ]]; then
    return 0
  fi

  printf '\n%s Per-node summary (%s/%s node(s) tracked this run):\n' \
    "$(date -Iseconds)" "$nodes_finished_this_run" "${#worker_nodes[@]}"

  total=0
  for dur in "${per_node_durations[@]}"; do
    total="$((total + dur))"
    printf '  - %s update duration (est.)\n' "$(format_duration "$dur")"
  done

  avg="$((total / nodes_finished_this_run))"
  printf '%s Average per-node update duration (est.): %s\n' \
    "$(date -Iseconds)" "$(format_duration "$avg")"
}

if mcp_updating; then
  printf '%s mcp/%s already Updating=True — skipping reboot trigger\n' "$(date -Iseconds)" "$MCP"
else
  printf '%s Triggering reboot for mcp/%s\n' "$(date -Iseconds)" "$MCP"
  oc adm reboot-machine-config-pool "mcp/$MCP"
fi

printf '%s Waiting for mcp/%s Updating=True before starting timer (poll every %ss)\n' \
  "$(date -Iseconds)" "$MCP" "$INTERVAL"
while ! mcp_updating; do
  printf '\n%s\n' "$(date -Iseconds)"
  oc get mcp -A
  sleep "$INTERVAL"
done

start_epoch="$(date +%s)"
init_csv
init_node_tracking

printf '\n%s mcp/%s Updating=True — timer started\n' "$(date -Iseconds)" "$MCP"
oc get mcp -A
oc get machineconfignode -o wide 2>/dev/null || true

printf '%s Waiting for %s mcp/%s node(s) to complete UPDATED=False→True\n' \
  "$(date -Iseconds)" "${#worker_nodes[@]}" "$MCP"
print_tracking_status

while [[ "$nodes_finished_this_run" -lt ${#worker_nodes[@]} ]]; do
  sleep "$INTERVAL"
  check_mcn_updates
  print_tracking_status
  oc get mcp -A
done

elapsed="$(( $(date +%s) - start_epoch ))"
printf '\n%s mcp/%s: all %s worker node(s) tracked — elapsed %s\n' \
  "$(date -Iseconds)" "$MCP" "${#worker_nodes[@]}" "$(format_duration "$elapsed")"
print_per_node_summary
printf '%s Full log saved to %s\n' "$(date -Iseconds)" "$LOG_FILE"
printf '%s Per-node timing CSV saved to %s\n' "$(date -Iseconds)" "$CSV_FILE"
