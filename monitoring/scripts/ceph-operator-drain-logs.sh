#!/usr/bin/env bash
# Find rook-ceph-operator pod and append logs to per-pod files.
# Polls every INTERVAL seconds; never truncates saved logs.
# On pod restart, switches to a new pod-named file.
#
# Usage:
#   ./ceph-operator-drain-logs.sh
#   OUT_DIR=/tmp/ceph-logs INTERVAL=3 ./ceph-operator-drain-logs.sh
#
# Watch progress:
#   wc -l ceph-operator-logs-*/latest.log
#   tail -f ceph-operator-logs-*/latest.log

set -euo pipefail

readonly NAMESPACE="${NAMESPACE:-openshift-storage}"
readonly POD_LABEL="${POD_LABEL:-app=rook-ceph-operator}"
readonly INTERVAL="${INTERVAL:-3}"
readonly RUN_TS="$(date +%Y%m%d-%H%M%S)"
readonly OUT_DIR="${OUT_DIR:-ceph-operator-logs-${RUN_TS}}"

current_pod=""

operator_pod() {
  oc get pods -n "$NAMESPACE" -l "$POD_LABEL" \
    -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null \
    | awk '{print $1}'
}

log_file() {
  printf '%s/%s.log' "$OUT_DIR" "$1"
}

previous_log_file() {
  printf '%s/%s-previous.log' "$OUT_DIR" "$1"
}

append_previous() {
  local pod="$1" file tmp
  file="$(previous_log_file "$pod")"
  [[ -f "$file" ]] && return 0
  tmp="$(mktemp)"
  if oc logs -n "$NAMESPACE" "$pod" --previous --timestamps --tail=-1 >"$tmp" 2>/dev/null \
      && [[ -s "$tmp" ]]; then
    cat "$tmp" >>"$file"
    printf '%s saved previous container logs -> %s (%d lines)\n' \
      "$(date -Iseconds)" "$file" "$(wc -l <"$file")"
  fi
  rm -f "$tmp"
}

append_new_lines() {
  local pod="$1" file tmp old_lines new_lines added
  file="$(log_file "$pod")"
  tmp="$(mktemp)"

  if ! oc logs -n "$NAMESPACE" "$pod" --timestamps --tail=-1 >"$tmp" 2>&1; then
    printf '%s oc logs failed for pod/%s (saved logs untouched)\n' "$(date -Iseconds)" "$pod"
    rm -f "$tmp"
    return 1
  fi

  if [[ ! -f "$file" ]]; then
    cat "$tmp" >>"$file"
    printf '%s created %s (%d lines)\n' "$(date -Iseconds)" "$file" "$(wc -l <"$file")"
    rm -f "$tmp"
    return 0
  fi

  old_lines="$(wc -l <"$file")"
  new_lines="$(wc -l <"$tmp")"

  if (( new_lines > old_lines )); then
    added="$((new_lines - old_lines))"
    tail -n +"$((old_lines + 1))" "$tmp" >>"$file"
    printf '%s appended %d lines to %s (total %d)\n' \
      "$(date -Iseconds)" "$added" "$file" "$(wc -l <"$file")"
  elif (( new_lines < old_lines )); then
    local rotated="${file%.log}-rotated-$(date +%s).log"
    cat "$tmp" >>"$rotated"
    printf '%s pod log shrank (%d -> %d); saved snapshot -> %s\n' \
      "$(date -Iseconds)" "$old_lines" "$new_lines" "$rotated"
  else
    printf '%s no new lines for pod/%s (total %d, operator may be idle)\n' \
      "$(date -Iseconds)" "$pod" "$old_lines"
  fi

  rm -f "$tmp"
}

update_latest_link() {
  local pod="$1"
  ln -sf "$(basename "$(log_file "$pod")")" "$OUT_DIR/latest.log"
}

cleanup() {
  printf '%s stopped — logs in %s\n' "$(date -Iseconds)" "$OUT_DIR"
}
trap cleanup EXIT

mkdir -p "$OUT_DIR"
printf '%s logging to %s every %ss (Ctrl+C to stop)\n' "$(date -Iseconds)" "$OUT_DIR" "$INTERVAL"
printf '%s watch: tail -f %s/latest.log\n' "$(date -Iseconds)" "$OUT_DIR"

while true; do
  pod="$(operator_pod)"
  if [[ -z "$pod" ]]; then
    printf '%s no running operator pod\n' "$(date -Iseconds)"
  else
    if [[ "$pod" != "$current_pod" ]]; then
      printf '%s switched to pod/%s\n' "$(date -Iseconds)" "$pod"
      current_pod="$pod"
      append_previous "$pod"
    fi
    append_new_lines "$pod"
    update_latest_link "$pod"
  fi
  sleep "$INTERVAL"
done
