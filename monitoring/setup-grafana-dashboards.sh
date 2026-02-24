#!/usr/bin/env bash
# Provision Grafana dashboards from ConfigMaps so they persist across pod restarts.
# Usage: setup-grafana-dashboards.sh [namespace] [dashboard1.json [dashboard2.json ...]]
#   namespace  Optional first arg if it does not end in .json. Default: dittybopper
#   *.json     Optional. Create one ConfigMap from all and mount at provisioning path.

set -e

DEPLOYMENT="dittybopper"
CONTAINER="dittybopper"
PROVIDER_NAME="grafana-dashboards-provider"
DASHBOARDS_CM="grafana-dashboards-default"
PROVIDER_MOUNT="/etc/grafana/provisioning/dashboards"
DEFAULT_MOUNT="/etc/grafana/provisioning/dashboards/default"

# Parse args: [namespace] [file1.json [file2.json ...]]
NAMESPACE="dittybopper"
FILES=()
if [[ $# -gt 0 && "$1" != *.json ]]; then
  NAMESPACE="$1"
  shift
fi
FILES=("$@")

has_volume() {
  oc get "deployment/${DEPLOYMENT}" -n "${NAMESPACE}" -o jsonpath='{.spec.template.spec.volumes[*].name}' \
    | tr ' ' '\n' | grep -q "^${1}$"
}

# 1. Provider ConfigMap
oc apply -f - << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${PROVIDER_NAME}
  namespace: ${NAMESPACE}
data:
  dashboards.yaml: |
    apiVersion: 1
    providers:
      - name: 'default'
        orgId: 1
        folder: ''
        type: file
        options:
          path: ${DEFAULT_MOUNT}
EOF

# 2. Add provider volume if missing
if ! has_volume "${PROVIDER_NAME}"; then
  oc set volume "deployment/${DEPLOYMENT}" -n "${NAMESPACE}" \
    --add --name="${PROVIDER_NAME}" --type=configmap \
    --configmap-name="${PROVIDER_NAME}" --mount-path="${PROVIDER_MOUNT}" -c "${CONTAINER}"
fi

# 3. Optional: create dashboards ConfigMap from JSON file(s) and add volume
if [[ ${#FILES[@]} -gt 0 ]]; then
  for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || { echo "Not a file: $f" >&2; exit 1; }
  done
  from_file_args=()
  for f in "${FILES[@]}"; do from_file_args+=(--from-file="$f"); done
  oc create configmap "${DASHBOARDS_CM}" "${from_file_args[@]}" -n "${NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
  if ! has_volume "${DASHBOARDS_CM}"; then
    oc set volume "deployment/${DEPLOYMENT}" -n "${NAMESPACE}" \
      --add --name="${DASHBOARDS_CM}" --type=configmap --configmap-name="${DASHBOARDS_CM}" \
      --mount-path="${DEFAULT_MOUNT}" -c "${CONTAINER}"
  fi
fi

oc rollout status "deployment/${DEPLOYMENT}" -n "${NAMESPACE}" --timeout=120s
