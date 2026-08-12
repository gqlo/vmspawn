#!/usr/bin/env bash
# Re-apply ODF deployment memory limits if OCS or upgrades revert them.
# See rh-internal-doc/mark-down/high-scale-config-notes.md (OpenShift Data Foundation).

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

while true; do
  for target in "${TARGETS[@]}"; do
    check_target "$target"
  done
  sleep "$INTERVAL"
done
