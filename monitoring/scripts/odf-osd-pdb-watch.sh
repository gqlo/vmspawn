#!/usr/bin/env bash
# Delete Rook OSD PodDisruptionBudgets when they (re)appear so node drains are not blocked.
# Targets the global idle PDB (rook-ceph-osd) and zone-scoped PDBs (rook-ceph-osd-zone-*).
# See ocp-lab/learning/ceph/odf-pdb-vs-mcp-drain.md

set -euo pipefail

readonly NAMESPACE="${NAMESPACE:-openshift-storage}"
readonly INTERVAL="${INTERVAL:-3}"
readonly GLOBAL_PDB="${GLOBAL_PDB:-rook-ceph-osd}"
readonly ZONE_PDB_PREFIX="${ZONE_PDB_PREFIX:-rook-ceph-osd-zone-}"

list_zone_pdbs() {
  oc get pdb -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -E "^${ZONE_PDB_PREFIX}" || true
}

delete_pdb() {
  local name="$1"

  if oc delete pdb "$name" -n "$NAMESPACE" --ignore-not-found --wait=false; then
    printf '%s deleted pdb/%s in %s\n' "$(date -Iseconds)" "$name" "$NAMESPACE"
  else
    printf '%s failed to delete pdb/%s in %s\n' "$(date -Iseconds)" "$name" "$NAMESPACE" >&2
  fi
}

check_and_delete() {
  local name zone_pdbs=()

  if oc get pdb "$GLOBAL_PDB" -n "$NAMESPACE" &>/dev/null; then
    delete_pdb "$GLOBAL_PDB"
  fi

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    zone_pdbs+=("$name")
  done < <(list_zone_pdbs)

  for name in "${zone_pdbs[@]}"; do
    delete_pdb "$name"
  done

  if [[ ${#zone_pdbs[@]} -eq 0 ]] && ! oc get pdb "$GLOBAL_PDB" -n "$NAMESPACE" &>/dev/null; then
    printf '%s no OSD PDBs present in %s\n' "$(date -Iseconds)" "$NAMESPACE"
  fi
}

printf '%s watching %s for %s and %s* (every %ss)\n' \
  "$(date -Iseconds)" "$NAMESPACE" "$GLOBAL_PDB" "$ZONE_PDB_PREFIX" "$INTERVAL"

while true; do
  check_and_delete
  sleep "$INTERVAL"
done
