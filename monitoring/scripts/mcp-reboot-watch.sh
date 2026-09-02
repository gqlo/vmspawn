#!/usr/bin/env bash
# Trigger MCP reboot/drain and poll worker nodes until each MachineConfigNode completes.
#
# Timing model (node object watch, polled every INTERVAL seconds):
#   drain_seconds  — cordon until drain done (NodeNotSchedulable → NodeNotReady)
#   boot_seconds   — drain done until boot done (NodeNotReady → NodeSchedulable)
#   total_duration_seconds — per-node wall clock from MCN UPDATED=False to UPDATED=True
# Pool summary (ALL_NODES row): pool_elapsed_seconds = wall clock for entire rollout;
#   sum_total_duration_seconds = sum of per-node totals (includes overlapping queue time).
#
# MCN is used only for rollout detection and completion; not for phase timestamps.

set -euo pipefail

readonly MCP="${MCP:-worker}"
readonly INTERVAL="${INTERVAL:-5}"
readonly RUN_TS="$(date +%Y%m%d-%H%M%S)"
readonly LOG_FILE="${LOG_FILE:-mcp-reboot-watch-${MCP}-${RUN_TS}.log}"
readonly CSV_FILE="${CSV_FILE:-mcp-reboot-watch-${MCP}-${RUN_TS}.csv}"

declare -A node_start_epoch=()
declare -A node_finished=()
declare -A node_milestone_iso=()
declare -A node_duration_secs=()
declare -A node_drain_secs=()
declare -A node_boot_secs=()
declare -A node_prev_unschedulable=()
declare -A node_prev_ready=()
declare -A node_initial_unschedulable=()
declare -a worker_nodes=()

TARGET_CFG=""

exec > >(tee -a "$LOG_FILE") 2>&1
printf '%s Logging to %s\n' "$(date -Iseconds)" "$LOG_FILE"
printf '%s Per-node timing CSV: %s\n' "$(date -Iseconds)" "$CSV_FILE"

require_jq() {
  if ! command -v jq &>/dev/null; then
    printf '%s ERROR: jq is required\n' "$(date -Iseconds)"
    exit 1
  fi
}

format_duration() {
  local secs="$1"
  printf '%dm %ds (%ds total)' $((secs / 60)) $((secs % 60)) "$secs"
}

epoch_to_iso() {
  date -d "@$1" -Iseconds 2>/dev/null || date -u -r "$1" -Iseconds
}

iso_to_epoch() {
  date -d "$1" +%s 2>/dev/null
}

duration_between_iso() {
  local start_iso="$1" end_iso="$2" start_epoch end_epoch diff

  [[ -z "$start_iso" || -z "$end_iso" ]] && return 0
  start_epoch="$(iso_to_epoch "$start_iso")" || return 0
  end_epoch="$(iso_to_epoch "$end_iso")" || return 0
  diff="$((end_epoch - start_epoch))"
  (( diff < 0 )) && return 0
  printf '%s' "$diff"
}

milestone_key() {
  printf '%s|%s' "$1" "$2"
}

milestone_iso() {
  local node="$1" name="$2"
  printf '%s' "${node_milestone_iso[$(milestone_key "$node" "$name")]:-}"
}

reset_node_tracking() {
  local node="$1"

  unset "node_milestone_iso[$(milestone_key "$node" "cordoned")]"
  unset "node_milestone_iso[$(milestone_key "$node" "drain_done")]"
  unset "node_milestone_iso[$(milestone_key "$node" "boot_done")]"
  unset "node_prev_unschedulable[$node]"
  unset "node_prev_ready[$node]"
  unset "node_initial_unschedulable[$node]"
}

record_milestone() {
  local node="$1" name="$2" now="$3" key

  key="$(milestone_key "$node" "$name")"
  [[ -n "${node_milestone_iso[$key]:-}" ]] && return 0

  node_milestone_iso[$key]="$(epoch_to_iso "$now")"
  case "$name" in
    cordoned)   label="NodeNotSchedulable" ;;
    drain_done) label="NodeNotReady" ;;
    boot_done)  label="NodeSchedulable" ;;
    *)          label="$name" ;;
  esac
  printf '%s node/%s %s @ %s\n' "$(date -Iseconds)" "$node" "$label" "$(epoch_to_iso "$now")"
}

node_field_from_json() {
  local nodes_json="$1" node="$2" field="$3"

  jq -r --arg node "$node" --arg field "$field" '
    .items[] | select(.metadata.name == $node)
    | if $field == "unschedulable" then (.spec.unschedulable // false | tostring)
      elif $field == "ready" then (.status.conditions[]? | select(.type == "Ready") | .status) // "Unknown"
      else empty end
  ' <<<"$nodes_json"
}

fetch_nodes_json() {
  oc get nodes -o json 2>/dev/null
}

init_node_watch_state() {
  local node="$1" nodes_json="$2"

  node_initial_unschedulable[$node]="$(node_field_from_json "$nodes_json" "$node" 'unschedulable')"
  node_prev_unschedulable[$node]="${node_initial_unschedulable[$node]}"
  node_prev_ready[$node]="$(node_field_from_json "$nodes_json" "$node" 'ready')"
}

capture_node_milestones() {
  local node="$1" now="$2" nodes_json="$3"
  local unsched ready prev_unsched prev_ready

  [[ -n "${node_start_epoch[$node]:-}" ]] || return 0
  [[ -n "${node_finished[$node]:-}" ]] && return 0

  unsched="$(node_field_from_json "$nodes_json" "$node" 'unschedulable')"
  ready="$(node_field_from_json "$nodes_json" "$node" 'ready')"
  prev_unsched="${node_prev_unschedulable[$node]:-false}"
  prev_ready="${node_prev_ready[$node]:-}"

  # NodeNotSchedulable: cordon (skip if already unschedulable when rollout tracking began).
  if [[ "$unsched" == "true" && "$prev_unsched" != "true" \
      && "${node_initial_unschedulable[$node]:-false}" != "true" ]]; then
    record_milestone "$node" "cordoned" "$now"
  fi

  # NodeNotReady: drain finished (Ready=False after cordon).
  if [[ -n "$(milestone_iso "$node" cordoned)" && -z "$(milestone_iso "$node" drain_done)" ]]; then
    if [[ "$ready" == "False" || "$ready" == "Unknown" ]]; then
      record_milestone "$node" "drain_done" "$now"
    fi
  fi

  # NodeSchedulable: boot finished (uncordoned, node accepting workloads again).
  if [[ -n "$(milestone_iso "$node" drain_done)" && -z "$(milestone_iso "$node" boot_done)" ]]; then
    if [[ "$unsched" != "true" && "$prev_unsched" == "true" ]]; then
      record_milestone "$node" "boot_done" "$now"
    fi
  fi

  node_prev_unschedulable[$node]="$unsched"
  node_prev_ready[$node]="$ready"
}

latest_milestone() {
  local node="$1"

  [[ -n "$(milestone_iso "$node" boot_done)" ]] && printf 'NodeSchedulable' && return 0
  [[ -n "$(milestone_iso "$node" drain_done)" ]] && printf 'NodeNotReady' && return 0
  [[ -n "$(milestone_iso "$node" cordoned)" ]] && printf 'NodeNotSchedulable' && return 0
  printf 'waiting'
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
  local node now updating=() waiting=() finished=() milestone

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
  if [[ -n "$TARGET_CFG" ]]; then
    printf '  rollout config: %s\n' "$TARGET_CFG"
  else
    printf '  rollout config: (detecting...)\n'
  fi
  printf '  updating (%s): %s\n' "${#updating[@]}" "$(nodes_list "${updating[@]}")"
  printf '  waiting  (%s): %s\n' "${#waiting[@]}" "$(nodes_list "${waiting[@]}")"
  printf '  finished (%s): %s\n' "${#finished[@]}" "$(nodes_list "${finished[@]}")"

  for node in "${updating[@]}"; do
    milestone="$(latest_milestone "$node")"
    printf '    %s: in progress %s (last: %s)\n' \
      "$node" "$(format_duration "$((now - node_start_epoch[$node]))")" "$milestone"
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

fetch_mcn_json() {
  oc get machineconfignode -o json
}

detect_rollout_config() {
  local mcn_json="$1" cfg=""

  cfg="$(jq -r --arg p "$MCP" '
    [.items[]
      | select(.spec.pool.name == $p)
      | select(
          ([.status.conditions[]?
            | select(.type == "Updated" and .status == "False")] | length) > 0
          or (.status.configVersion.desired // "") != (.status.configVersion.current // "")
        )
      | .status.configVersion.desired // empty
    ] | unique | .[0] // empty
  ' <<<"$mcn_json")"

  if [[ -z "$cfg" ]]; then
    cfg="$(jq -r --arg p "$MCP" '
      [.items[]
        | select(.spec.pool.name == $p)
        | .status.configVersion.desired // empty
      ] | unique | if length == 1 then .[0] else empty end
    ' <<<"$mcn_json")"
  fi

  if [[ -n "$cfg" && "$cfg" != "$TARGET_CFG" ]]; then
    if [[ -z "$TARGET_CFG" ]]; then
      printf '%s Rollout rendered config: %s\n' "$(date -Iseconds)" "$cfg"
    else
      printf '%s Rollout rendered config changed: %s -> %s\n' \
        "$(date -Iseconds)" "$TARGET_CFG" "$cfg"
    fi
    TARGET_CFG="$cfg"
  fi
}

node_updated_for_rollout() {
  local node="$1" mcn_json="$2"

  if [[ -z "$TARGET_CFG" ]]; then
    jq -e --arg node "$node" '
      .items[] | select(.metadata.name == $node)
      | .status.conditions[]? | select(.type == "Updated" and .status == "True")
    ' <<<"$mcn_json" >/dev/null
    return
  fi

  jq -e --arg node "$node" --arg cfg "$TARGET_CFG" '
    .items[] | select(.metadata.name == $node)
    | select(.status.configVersion.current == $cfg)
    | .status.conditions[]? | select(.type == "Updated" and .status == "True")
  ' <<<"$mcn_json" >/dev/null
}

record_node_start() {
  local node="$1" now="$2" nodes_json="$3"

  [[ -n "${node_start_epoch[$node]:-}" ]] && return 0

  reset_node_tracking "$node"
  node_start_epoch[$node]="$now"
  init_node_watch_state "$node" "$nodes_json"
  printf '%s machineconfignode/%s update started (UPDATED=False for %s)\n' \
    "$(date -Iseconds)" "$node" "${TARGET_CFG:-unknown config}"
}

record_node_completion() {
  local node="$1" duration="$2" start="$3" end="$4"
  local cord drained boot drain_secs boot_secs

  cord="$(milestone_iso "$node" cordoned)"
  drained="$(milestone_iso "$node" drain_done)"
  boot="$(milestone_iso "$node" boot_done)"

  drain_secs="$(duration_between_iso "$cord" "$drained")"
  boot_secs="$(duration_between_iso "$drained" "$boot")"
  node_duration_secs[$node]="$duration"
  node_drain_secs[$node]="${drain_secs:-0}"
  node_boot_secs[$node]="${boot_secs:-0}"

  {
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$node" \
      "${drain_secs:-}" \
      "${boot_secs:-}" \
      "$duration" \
      "$(epoch_to_iso "$start")" \
      "$(epoch_to_iso "$end")" \
      "$cord" \
      "$drained" \
      "$boot" \
      "${TARGET_CFG:-}"
  } >> "$CSV_FILE"
}

init_csv() {
  printf '%s\n' \
    'node,drain_seconds,boot_seconds,total_duration_seconds,total_start_time,total_end_time,cordoned_ts,drain_done_ts,boot_done_ts,rendered_config' \
    > "$CSV_FILE"
}

append_csv_summary() {
  local pool_end="$1" node sum_drain sum_boot sum_total

  sum_drain=0
  sum_boot=0
  sum_total=0
  for node in "${worker_nodes[@]}"; do
    sum_drain="$((sum_drain + ${node_drain_secs[$node]:-0}))"
    sum_boot="$((sum_boot + ${node_boot_secs[$node]:-0}))"
    sum_total="$((sum_total + ${node_duration_secs[$node]:-0}))"
  done

  {
    printf '%s,%s,%s,%s,%s,%s,,,,\n' \
      "ALL_NODES" \
      "$sum_drain" \
      "$sum_boot" \
      "$sum_total" \
      "$(epoch_to_iso "$start_epoch")" \
      "$(epoch_to_iso "$pool_end")"
  } >> "$CSV_FILE"
}

check_mcn_updates() {
  local node now start end duration elapsed updated_count mcn_json nodes_json

  now="$(date +%s)"
  mcn_json="$(fetch_mcn_json)"
  nodes_json="$(fetch_nodes_json)"
  detect_rollout_config "$mcn_json"

  for node in "${worker_nodes[@]}"; do
    [[ -n "${node_finished[$node]:-}" ]] && continue

    capture_node_milestones "$node" "$now" "$nodes_json"

    if ! node_updated_for_rollout "$node" "$mcn_json"; then
      record_node_start "$node" "$now" "$nodes_json"
      capture_node_milestones "$node" "$now" "$nodes_json"
    elif [[ -n "${node_start_epoch[$node]:-}" ]]; then
      capture_node_milestones "$node" "$now" "$nodes_json"
      start="${node_start_epoch[$node]}"
      end="$now"
      duration="$((end - start))"
      elapsed="$((now - start_epoch))"
      node_finished[$node]=1
      nodes_finished_this_run="$((nodes_finished_this_run + 1))"
      record_node_completion "$node" "$duration" "$start" "$end"
      updated_count="$(oc get mcp "$MCP" -o jsonpath='{.status.updatedMachineCount}')"
      printf '%s machineconfignode/%s UPDATED=True — finished %s (poll est.), %s since pool started (%s/%s MCP updated, %s/%s tracked)\n' \
        "$(date -Iseconds)" "$node" \
        "$(format_duration "$duration")" \
        "$(format_duration "$elapsed")" \
        "$updated_count" "$machine_count" \
        "$nodes_finished_this_run" "${#worker_nodes[@]}"
      if [[ -n "$(milestone_iso "$node" cordoned)" ]]; then
        printf '%s   node phases: drain=%ss boot=%ss total=%ss\n' \
          "$(date -Iseconds)" \
          "$(duration_between_iso "$(milestone_iso "$node" cordoned)" "$(milestone_iso "$node" drain_done)")" \
          "$(duration_between_iso "$(milestone_iso "$node" drain_done)" "$(milestone_iso "$node" boot_done)")" \
          "$duration"
      fi
    fi
  done
}

init_node_tracking() {
  local node now mcn_json nodes_json

  if ! mcn_available; then
    printf '%s ERROR: MachineConfigNode CRD not available — requires OpenShift 4.16+\n' "$(date -Iseconds)"
    exit 1
  fi

  require_jq

  machine_count="$(oc get mcp "$MCP" -o jsonpath='{.status.machineCount}')"
  worker_nodes=()
  nodes_finished_this_run=0
  now="$(date +%s)"
  mcn_json="$(fetch_mcn_json)"
  nodes_json="$(fetch_nodes_json)"
  detect_rollout_config "$mcn_json"

  while read -r node; do
    [[ -z "$node" ]] && continue
    worker_nodes+=("$node")
    if ! node_updated_for_rollout "$node" "$mcn_json"; then
      record_node_start "$node" "$now" "$nodes_json"
      printf '%s machineconfignode/%s already updating at timer start\n' "$(date -Iseconds)" "$node"
    fi
  done < <(mcn_pool_nodes)

  if [[ ${#worker_nodes[@]} -eq 0 ]]; then
    printf '%s ERROR: no MachineConfigNodes found for mcp/%s\n' "$(date -Iseconds)" "$MCP"
    exit 1
  fi

  check_mcn_updates
  printf '%s Tracking %s mcp/%s node(s); poll every %ss (node: NotSchedulable→NotReady→Schedulable)\n' \
    "$(date -Iseconds)" "${#worker_nodes[@]}" "$MCP" "$INTERVAL"
  print_tracking_status
}

print_per_node_summary() {
  local pool_elapsed="$1"
  local node sum_total=0 sum_drain=0 sum_boot=0 avg

  if [[ "$nodes_finished_this_run" -eq 0 ]]; then
    return 0
  fi

  printf '\n%s Per-node total_duration_seconds (%s/%s node(s)):\n' \
    "$(date -Iseconds)" "$nodes_finished_this_run" "${#worker_nodes[@]}"

  for node in "${worker_nodes[@]}"; do
    [[ -n "${node_duration_secs[$node]:-}" ]] || continue
    sum_total="$((sum_total + node_duration_secs[$node]))"
    sum_drain="$((sum_drain + ${node_drain_secs[$node]:-0}))"
    sum_boot="$((sum_boot + ${node_boot_secs[$node]:-0}))"
    printf '  %s: drain=%ss boot=%ss total=%ss (%s)\n' \
      "$node" \
      "${node_drain_secs[$node]:-0}" \
      "${node_boot_secs[$node]:-0}" \
      "${node_duration_secs[$node]}" \
      "$(format_duration "${node_duration_secs[$node]}")"
  done

  avg="$((sum_total / nodes_finished_this_run))"
  printf '%s All nodes: pool_elapsed=%ss (%s), sum_total_duration=%ss, avg_per_node=%ss\n' \
    "$(date -Iseconds)" \
    "$pool_elapsed" "$(format_duration "$pool_elapsed")" \
    "$sum_total" "$avg"
  printf '%s   (pool_elapsed = wall clock for full rollout; sum_total = per-node times added)\n' \
    "$(date -Iseconds)"
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

printf '%s Waiting for %s mcp/%s node(s) to complete this rollout\n' \
  "$(date -Iseconds)" "${#worker_nodes[@]}" "$MCP"
print_tracking_status

while [[ "$nodes_finished_this_run" -lt ${#worker_nodes[@]} ]]; do
  sleep "$INTERVAL"
  check_mcn_updates
  print_tracking_status
  oc get mcp -A
done

elapsed="$(( $(date +%s) - start_epoch ))"
printf '\n%s mcp/%s: all %s worker node(s) tracked — pool elapsed %s\n' \
  "$(date -Iseconds)" "$MCP" "${#worker_nodes[@]}" "$(format_duration "$elapsed")"
append_csv_summary "$(date +%s)"
print_per_node_summary "$elapsed"
printf '%s Full log saved to %s\n' "$(date -Iseconds)" "$LOG_FILE"
printf '%s Per-node timing CSV saved to %s\n' "$(date -Iseconds)" "$CSV_FILE"
