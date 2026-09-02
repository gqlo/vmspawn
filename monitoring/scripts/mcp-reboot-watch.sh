#!/usr/bin/env bash
# Trigger MCP reboot/drain and poll worker MachineConfigNodes until each completes a cycle.
# Tracks total time (UPDATED=False→True) and MCN phase timestamps via lastTransitionTime:
#   UpdatePrepared, Cordoned, Drained, AppliedFilesAndOS, RebootedNode, Uncordoned, Updated
# Phase timestamps are captured in order (each phase must follow the previous one) and only
# after node tracking starts, so stale Drained conditions from pool start are ignored.
# Sub-second phases (apply/reboot/uncordon) often show 0s because MCN reports the same second.
# Phase rows are tied to the rollout rendered config (status.configVersion.desired).
# Exits when every mcp/$MCP node has been tracked.
# Logs all output to a file (LOG_FILE) and writes per-node timing to CSV_FILE.

set -euo pipefail

readonly MCP="${MCP:-worker}"
readonly INTERVAL="${INTERVAL:-5}"
readonly RUN_TS="$(date +%Y%m%d-%H%M%S)"
readonly LOG_FILE="${LOG_FILE:-mcp-reboot-watch-${MCP}-${RUN_TS}.log}"
readonly CSV_FILE="${CSV_FILE:-mcp-reboot-watch-${MCP}-${RUN_TS}.csv}"

readonly -a PHASE_TYPES=(
  UpdatePrepared
  Cordoned
  Drained
  AppliedFilesAndOS
  RebootedNode
  Uncordoned
  Updated
)

declare -A node_start_epoch=()
declare -A node_finished=()
declare -A node_phase_iso=()
declare -a worker_nodes=()
declare -a pending_nodes=()
declare -a per_node_durations=()

TARGET_CFG=""

exec > >(tee -a "$LOG_FILE") 2>&1
printf '%s Logging to %s\n' "$(date -Iseconds)" "$LOG_FILE"
printf '%s Per-node timing CSV: %s\n' "$(date -Iseconds)" "$CSV_FILE"

require_jq() {
  if ! command -v jq &>/dev/null; then
    printf '%s ERROR: jq is required for MCN phase tracking\n' "$(date -Iseconds)"
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

phase_index() {
  local phase="$1" i

  for i in "${!PHASE_TYPES[@]}"; do
    if [[ "${PHASE_TYPES[$i]}" == "$phase" ]]; then
      printf '%s' "$i"
      return 0
    fi
  done
  return 1
}

phase_min_epoch() {
  local node="$1" phase="$2" idx prev_phase prev_iso prev_epoch start_epoch

  start_epoch="${node_start_epoch[$node]:-}"
  idx="$(phase_index "$phase")" || return 1

  if (( idx > 0 )); then
    prev_phase="${PHASE_TYPES[$((idx - 1))]}"
    prev_iso="$(phase_iso "$node" "$prev_phase")"
    if [[ -n "$prev_iso" ]]; then
      prev_epoch="$(iso_to_epoch "$prev_iso")" || return 1
      printf '%s' "$prev_epoch"
      return 0
    fi
    return 1
  fi

  [[ -n "$start_epoch" ]] || return 1
  printf '%s' "$start_epoch"
}

can_capture_phase() {
  local node="$1" phase="$2" idx

  idx="$(phase_index "$phase")" || return 1
  (( idx == 0 )) && return 0
  [[ -n "$(phase_iso "$node" "${PHASE_TYPES[$((idx - 1))]}")" ]]
}

phase_transition_epoch() {
  local node="$1" phase="$2" mcn_json="$3" min_epoch ts_epoch

  min_epoch="$(phase_min_epoch "$node" "$phase")" || return 1

  if [[ "$phase" == "Updated" ]]; then
  jq -r --arg node "$node" --arg cfg "$TARGET_CFG" --argjson min_epoch "$min_epoch" '
    [.items[] | select(.metadata.name == $node)
      | select(.status.configVersion.current == $cfg)
      | .status.conditions[]?
      | select(.type == "Updated" and .status == "True")
      | select((.lastTransitionTime | fromdateiso8601) >= $min_epoch)
      | .lastTransitionTime
    ] | max // empty
  ' <<<"$mcn_json"
  else
  jq -r --arg node "$node" --arg phase "$phase" --arg cfg "$TARGET_CFG" --argjson min_epoch "$min_epoch" '
    [.items[] | select(.metadata.name == $node)
      | .status.conditions[]?
      | select(.type == $phase and .status == "True")
      | select(.message | contains($cfg))
      | select(.reason != "NotYetOccurred")
      | select((.lastTransitionTime | fromdateiso8601) >= $min_epoch)
      | .lastTransitionTime
    ] | max // empty
  ' <<<"$mcn_json"
  fi
}

phase_key() {
  printf '%s|%s' "$1" "$2"
}

phase_iso() {
  local node="$1" phase="$2"
  printf '%s' "${node_phase_iso[$(phase_key "$node" "$phase")]:-}"
}

reset_node_phases() {
  local node="$1" phase

  for phase in "${PHASE_TYPES[@]}"; do
    unset "node_phase_iso[$(phase_key "$node" "$phase")]"
  done
}

latest_recorded_phase() {
  local node="$1" phase iso latest="" latest_iso=""

  for phase in "${PHASE_TYPES[@]}"; do
    iso="$(phase_iso "$node" "$phase")"
    [[ -z "$iso" ]] && continue
    if [[ -z "$latest_iso" || "$(iso_to_epoch "$iso")" -gt "$(iso_to_epoch "$latest_iso")" ]]; then
      latest="$phase"
      latest_iso="$iso"
    fi
  done
  printf '%s' "$latest"
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
  local node now updating=() waiting=() finished=() phase

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
    phase="$(latest_recorded_phase "$node")"
    if [[ -n "$phase" ]]; then
      printf '    %s: in progress %s (last phase: %s)\n' \
        "$node" "$(format_duration "$((now - node_start_epoch[$node]))")" "$phase"
    else
      printf '    %s: in progress %s\n' \
        "$node" "$(format_duration "$((now - node_start_epoch[$node]))")"
    fi
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

capture_node_phases() {
  local node="$1" mcn_json="$2" phase key ts existing

  [[ -z "$TARGET_CFG" ]] && return 0
  [[ -n "${node_start_epoch[$node]:-}" ]] || return 0

  for phase in "${PHASE_TYPES[@]}"; do
    can_capture_phase "$node" "$phase" || continue

    key="$(phase_key "$node" "$phase")"
    ts="$(phase_transition_epoch "$node" "$phase" "$mcn_json")"
    [[ -z "$ts" || "$ts" == "null" ]] && continue

    existing="${node_phase_iso[$key]:-}"
    if [[ -z "$existing" || "$(iso_to_epoch "$ts")" -gt "$(iso_to_epoch "$existing")" ]]; then
      if [[ -z "$existing" ]]; then
        printf '%s machineconfignode/%s %s @ %s\n' "$(date -Iseconds)" "$node" "$phase" "$ts"
      fi
      node_phase_iso[$key]="$ts"
    fi
  done
}

record_node_start() {
  local node="$1" now="$2"

  [[ -n "${node_start_epoch[$node]:-}" ]] && return 0

  reset_node_phases "$node"
  node_start_epoch[$node]="$now"
  printf '%s machineconfignode/%s update started (UPDATED=False for %s)\n' \
    "$(date -Iseconds)" "$node" "${TARGET_CFG:-unknown config}"
}

record_node_completion() {
  local node="$1" duration="$2" start="$3" end="$4"
  local prep cord drained applied reboot unc upd
  local queue_secs drain_secs apply_secs reboot_secs uncordon_secs total_phase_secs

  prep="$(phase_iso "$node" UpdatePrepared)"
  cord="$(phase_iso "$node" Cordoned)"
  drained="$(phase_iso "$node" Drained)"
  applied="$(phase_iso "$node" AppliedFilesAndOS)"
  reboot="$(phase_iso "$node" RebootedNode)"
  unc="$(phase_iso "$node" Uncordoned)"
  upd="$(phase_iso "$node" Updated)"

  queue_secs="$(duration_between_iso "$(epoch_to_iso "$start")" "$cord")"
  drain_secs="$(duration_between_iso "$cord" "$drained")"
  apply_secs="$(duration_between_iso "$drained" "$applied")"
  reboot_secs="$(duration_between_iso "$applied" "$reboot")"
  uncordon_secs="$(duration_between_iso "$reboot" "$unc")"
  total_phase_secs="$(duration_between_iso "${prep:-$cord}" "$upd")"
  if [[ -z "$total_phase_secs" ]]; then
    total_phase_secs="$(duration_between_iso "$cord" "$upd")"
  fi

  {
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$node" \
      "${drain_secs:-}" \
      "${apply_secs:-}" \
      "${reboot_secs:-}" \
      "${uncordon_secs:-}" \
      "${total_phase_secs:-}" \
      "${TARGET_CFG:-}" \
      "$duration" \
      "$(epoch_to_iso "$start")" \
      "$(epoch_to_iso "$end")" \
      "$prep" \
      "$cord" \
      "$drained" \
      "$applied" \
      "$reboot" \
      "$unc" \
      "$upd" \
      "${queue_secs:-}"
  } >> "$CSV_FILE"
}

init_csv() {
  printf '%s\n' \
    'node,drain_seconds,apply_seconds,reboot_seconds,uncordon_seconds,total_from_phases_seconds,rendered_config,total_duration_seconds,total_start_time,total_end_time,update_prepared_ts,cordoned_ts,drained_ts,applied_files_and_os_ts,rebooted_node_ts,uncordoned_ts,updated_ts,queue_seconds' \
    > "$CSV_FILE"
}

check_mcn_updates() {
  local node now start end duration elapsed updated_count mcn_json

  now="$(date +%s)"
  pending_nodes=()
  mcn_json="$(fetch_mcn_json)"
  detect_rollout_config "$mcn_json"

  for node in "${worker_nodes[@]}"; do
    [[ -n "${node_finished[$node]:-}" ]] && continue

    capture_node_phases "$node" "$mcn_json"

    if ! node_updated_for_rollout "$node" "$mcn_json"; then
      record_node_start "$node" "$now"
      capture_node_phases "$node" "$mcn_json"
      pending_nodes+=("$node")
    elif [[ -n "${node_start_epoch[$node]:-}" ]]; then
      capture_node_phases "$node" "$mcn_json"
      start="${node_start_epoch[$node]}"
      end="$now"
      duration="$((end - start))"
      elapsed="$((now - start_epoch))"
      node_finished[$node]=1
      nodes_finished_this_run="$((nodes_finished_this_run + 1))"
      per_node_durations+=("$duration")
      record_node_completion "$node" "$duration" "$start" "$end"
      updated_count="$(oc get mcp "$MCP" -o jsonpath='{.status.updatedMachineCount}')"
      printf '%s machineconfignode/%s UPDATED=True — finished %s (poll est.), %s since pool started (%s/%s MCP updated, %s/%s tracked)\n' \
        "$(date -Iseconds)" "$node" \
        "$(format_duration "$duration")" \
        "$(format_duration "$elapsed")" \
        "$updated_count" "$machine_count" \
        "$nodes_finished_this_run" "${#worker_nodes[@]}"
      if [[ -n "$(phase_iso "$node" Cordoned)" && -n "$(phase_iso "$node" Drained)" ]]; then
        printf '%s   phases: queue=%ss drain=%ss apply=%ss reboot=%ss uncordon=%ss (from lastTransitionTime)\n' \
          "$(date -Iseconds)" \
          "$(duration_between_iso "$(epoch_to_iso "$start")" "$(phase_iso "$node" Cordoned)")" \
          "$(duration_between_iso "$(phase_iso "$node" Cordoned)" "$(phase_iso "$node" Drained)")" \
          "$(duration_between_iso "$(phase_iso "$node" Drained)" "$(phase_iso "$node" AppliedFilesAndOS)")" \
          "$(duration_between_iso "$(phase_iso "$node" AppliedFilesAndOS)" "$(phase_iso "$node" RebootedNode)")" \
          "$(duration_between_iso "$(phase_iso "$node" RebootedNode)" "$(phase_iso "$node" Uncordoned)")"
      fi
    else
      pending_nodes+=("$node")
    fi
  done
}

init_node_tracking() {
  local node now mcn_json

  if ! mcn_available; then
    printf '%s ERROR: MachineConfigNode CRD not available — requires OpenShift 4.16+\n' "$(date -Iseconds)"
    exit 1
  fi

  require_jq

  machine_count="$(oc get mcp "$MCP" -o jsonpath='{.status.machineCount}')"
  worker_nodes=()
  nodes_finished_this_run=0
  per_node_durations=()
  now="$(date +%s)"
  mcn_json="$(fetch_mcn_json)"
  detect_rollout_config "$mcn_json"

  while read -r node; do
    [[ -z "$node" ]] && continue
    worker_nodes+=("$node")
    if ! node_updated_for_rollout "$node" "$mcn_json"; then
      record_node_start "$node" "$now"
      capture_node_phases "$node" "$mcn_json"
      printf '%s machineconfignode/%s already updating at timer start\n' "$(date -Iseconds)" "$node"
    fi
  done < <(mcn_pool_nodes)

  if [[ ${#worker_nodes[@]} -eq 0 ]]; then
    printf '%s ERROR: no MachineConfigNodes found for mcp/%s\n' "$(date -Iseconds)" "$MCP"
    exit 1
  fi

  check_mcn_updates
  printf '%s Tracking %s mcp/%s node(s); poll every %ss; phases: %s\n' \
    "$(date -Iseconds)" "${#worker_nodes[@]}" "$MCP" "$INTERVAL" \
    "$(IFS=' '; echo "${PHASE_TYPES[*]}")"
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
    printf '  - %s total update duration (poll est.)\n' "$(format_duration "$dur")"
  done

  avg="$((total / nodes_finished_this_run))"
  printf '%s Average per-node update duration (poll est.): %s\n' \
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
printf '\n%s mcp/%s: all %s worker node(s) tracked — elapsed %s\n' \
  "$(date -Iseconds)" "$MCP" "${#worker_nodes[@]}" "$(format_duration "$elapsed")"
print_per_node_summary
printf '%s Full log saved to %s\n' "$(date -Iseconds)" "$LOG_FILE"
printf '%s Per-node timing CSV saved to %s\n' "$(date -Iseconds)" "$CSV_FILE"
