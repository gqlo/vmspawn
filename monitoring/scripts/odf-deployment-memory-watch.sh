#!/usr/bin/env bash
# Re-apply ODF deployment memory limits if OCS or upgrades revert them.
# See ocp-lab/learning/ocp-admin/high-scale-config-notes.md (OpenShift Data Foundation).
#
# Two kinds of targets:
#   TARGETS      Deployments owned by the StorageCluster — patch the Deployment
#                directly (OCS re-applies these fields; this loop just wins the race).
#   CSV_TARGETS  Deployments owned by a ClusterServiceVersion via OLM (e.g.
#                rook-ceph-operator) — patching the Deployment gets reverted within
#                seconds, so these must be patched on the CSV itself. The CSV name is
#                version-specific (e.g. rook-ceph-operator.v4.22.0-rhodf) and changes on
#                every operator upgrade, so each cycle re-resolves the active
#                (Succeeded-phase) CSV by name prefix instead of hardcoding a version.

set -euo pipefail

readonly NAMESPACE="${NAMESPACE:-openshift-storage}"
readonly INTERVAL="${INTERVAL:-5}"
readonly DESIRED_MEMORY="${DESIRED_MEMORY:-2G}"
# OCS operator default for ocs-metrics-exporter (1.5Gi) — do not patch
readonly OCS_DEFAULT_MEMORY_BYTES=1610612736

readonly -a TARGETS=(
  csi-addons-controller-manager:manager
  ocs-metrics-exporter:ocs-metrics-exporter
  ocs-client-operator-controller-manager:manager
)

# csv-name-prefix:deployment-name:container-name
readonly -a CSV_TARGETS=(
  rook-ceph-operator:rook-ceph-operator:rook-ceph-operator
)

# Kubernetes quantity → bytes (binary Ki/Mi/Gi/Ti and decimal K/M/G/T).
memory_bytes() {
  python3 - "$1" <<'PY'
import sys
q = sys.argv[1].strip()
units = {
    "Ki": 2**10, "Mi": 2**20, "Gi": 2**30, "Ti": 2**40,
    "K": 10**3, "M": 10**6, "G": 10**9, "T": 10**12,
}
for suf, mul in units.items():
    if q.endswith(suf):
        print(int(float(q[: -len(suf)]) * mul))
        break
else:
    print(int(q))
PY
}

memory_limit_ok() {
  local current="$1"
  local want="${2:-$DESIRED_MEMORY}"
  local current_bytes

  current_bytes="$(memory_bytes "$current")"
  # 1536Mi / 1.5Gi — OCS-managed default, leave as-is
  [[ "$current_bytes" -eq "$OCS_DEFAULT_MEMORY_BYTES" ]] && return 0
  [[ "$current_bytes" -ge "$(memory_bytes "$want")" ]]
}

container_index() {
  local deployment="$1"
  local container="$2"

  oc get deployment "$deployment" -n "$NAMESPACE" -o json \
    | jq -r --arg name "$container" '
        .spec.template.spec.containers
        | to_entries[]
        | select(.value.name == $name)
        | .key
        | tostring
      ' | head -n1
}

get_memory_limit() {
  local deployment="$1"
  local container="$2"
  local idx

  idx="$(container_index "$deployment" "$container")"
  [[ -n "$idx" ]] || return 1
  oc get deployment "$deployment" -n "$NAMESPACE" \
    -o "jsonpath={.spec.template.spec.containers[${idx}].resources.limits.memory}"
}

patch_memory_limit() {
  local deployment="$1"
  local container="$2"
  local idx

  idx="$(container_index "$deployment" "$container")"
  [[ -n "$idx" ]] || return 1

  oc patch deployment "$deployment" -n "$NAMESPACE" --type=json -p="[
    {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/${idx}/resources/limits/memory\", \"value\": \"$DESIRED_MEMORY\"}
  ]"
}

check_target() {
  local deployment container current after label idx

  deployment="${1%%:*}"
  container="${1#*:}"
  label="${deployment}/${container}"

  idx="$(container_index "$deployment" "$container")" || idx=""
  current="$(get_memory_limit "$deployment" "$container")" || {
    printf '%s %s: skip (deployment or container %q not found)\n' "$(date -Iseconds)" "$label" "$container"
    return 0
  }

  if memory_limit_ok "$current"; then
    printf '%s %s[containers/%s]: OK %s\n' "$(date -Iseconds)" "$label" "$idx" "$current"
    return 0
  fi

  printf '%s %s[containers/%s]: limit %s (%s bytes) < want %s (%s bytes), patching\n' \
    "$(date -Iseconds)" "$label" "$idx" "$current" "$(memory_bytes "$current")" \
    "$DESIRED_MEMORY" "$(memory_bytes "$DESIRED_MEMORY")"

  patch_memory_limit "$deployment" "$container"

  after="$(get_memory_limit "$deployment" "$container")"
  if memory_limit_ok "$after"; then
    printf '%s %s: patched OK, now %s\n' "$(date -Iseconds)" "$label" "$after"
  else
    printf '%s %s: patch accepted but limit still %s — likely OCS reconciling the Deployment (owner: StorageCluster)\n' \
      "$(date -Iseconds)" "$label" "$after"
  fi
}

# Name of the currently Succeeded CSV whose name starts with "<prefix>." (e.g.
# "rook-ceph-operator" -> "rook-ceph-operator.v4.22.0-rhodf"). Resolved fresh every
# cycle so an operator upgrade (new CSV name/version) is picked up automatically.
active_csv_name() {
  local prefix="$1"

  oc get csv -n "$NAMESPACE" -o json \
    | jq -r --arg prefix "${prefix}." '
        .items[]
        | select(.metadata.name | startswith($prefix))
        | select(.status.phase == "Succeeded")
        | .metadata.name
      ' | head -n1
}

csv_deployment_index() {
  local csv="$1"
  local deployment="$2"

  oc get csv "$csv" -n "$NAMESPACE" -o json \
    | jq -r --arg name "$deployment" '
        .spec.install.spec.deployments
        | to_entries[]
        | select(.value.name == $name)
        | .key
        | tostring
      ' | head -n1
}

csv_container_index() {
  local csv="$1"
  local dep_idx="$2"
  local container="$3"

  oc get csv "$csv" -n "$NAMESPACE" -o json \
    | jq -r --argjson depIdx "$dep_idx" --arg name "$container" '
        .spec.install.spec.deployments[$depIdx].spec.template.spec.containers
        | to_entries[]
        | select(.value.name == $name)
        | .key
        | tostring
      ' | head -n1
}

get_csv_memory_limit() {
  local csv="$1"
  local dep_idx="$2"
  local container_idx="$3"

  oc get csv "$csv" -n "$NAMESPACE" \
    -o "jsonpath={.spec.install.spec.deployments[${dep_idx}].spec.template.spec.containers[${container_idx}].resources.limits.memory}"
}

patch_csv_memory_limit() {
  local csv="$1"
  local dep_idx="$2"
  local container_idx="$3"

  oc patch csv "$csv" -n "$NAMESPACE" --type=json -p="[
    {\"op\": \"replace\", \"path\": \"/spec/install/spec/deployments/${dep_idx}/spec/template/spec/containers/${container_idx}/resources/limits/memory\", \"value\": \"$DESIRED_MEMORY\"}
  ]"
}

check_csv_target() {
  local prefix deployment container csv dep_idx container_idx current after label

  prefix="$(cut -d: -f1 <<<"$1")"
  deployment="$(cut -d: -f2 <<<"$1")"
  container="$(cut -d: -f3 <<<"$1")"
  label="csv:${prefix}/${deployment}:${container}"

  csv="$(active_csv_name "$prefix")"
  if [[ -z "$csv" ]]; then
    printf '%s %s: skip (no Succeeded CSV matching %q* found)\n' "$(date -Iseconds)" "$label" "$prefix"
    return 0
  fi

  dep_idx="$(csv_deployment_index "$csv" "$deployment")"
  if [[ -z "$dep_idx" ]]; then
    printf '%s %s: skip (deployment %q not found in CSV %s)\n' "$(date -Iseconds)" "$label" "$deployment" "$csv"
    return 0
  fi

  container_idx="$(csv_container_index "$csv" "$dep_idx" "$container")"
  if [[ -z "$container_idx" ]]; then
    printf '%s %s: skip (container %q not found in CSV %s)\n' "$(date -Iseconds)" "$label" "$container" "$csv"
    return 0
  fi

  current="$(get_csv_memory_limit "$csv" "$dep_idx" "$container_idx")" || {
    printf '%s %s: skip (no memory limit set in CSV %s)\n' "$(date -Iseconds)" "$label" "$csv"
    return 0
  }

  if memory_limit_ok "$current"; then
    printf '%s %s[csv=%s,deployments/%s/containers/%s]: OK %s\n' \
      "$(date -Iseconds)" "$label" "$csv" "$dep_idx" "$container_idx" "$current"
    return 0
  fi

  printf '%s %s[csv=%s,deployments/%s/containers/%s]: limit %s (%s bytes) < want %s (%s bytes), patching CSV\n' \
    "$(date -Iseconds)" "$label" "$csv" "$dep_idx" "$container_idx" "$current" "$(memory_bytes "$current")" \
    "$DESIRED_MEMORY" "$(memory_bytes "$DESIRED_MEMORY")"

  patch_csv_memory_limit "$csv" "$dep_idx" "$container_idx"

  after="$(get_csv_memory_limit "$csv" "$dep_idx" "$container_idx")"
  if memory_limit_ok "$after"; then
    printf '%s %s: patched CSV %s OK, now %s (OLM will roll the Deployment)\n' "$(date -Iseconds)" "$label" "$csv" "$after"
  else
    printf '%s %s: patch accepted but CSV %s still shows %s\n' \
      "$(date -Iseconds)" "$label" "$csv" "$after"
  fi
}

while true; do
  for target in "${TARGETS[@]}"; do
    check_target "$target"
  done
  for target in "${CSV_TARGETS[@]}"; do
    check_csv_target "$target"
  done
  sleep "$INTERVAL"
done
