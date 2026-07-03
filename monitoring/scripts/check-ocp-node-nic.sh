#!/usr/bin/env bash
set -uo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [INTERFACE]

Verify that INTERFACE exists on all OCP nodes and show MAC + OVN br-ex uplink.

Examples:
  $(basename "$0")                  # checks ens2f0np0
  $(basename "$0") ens2f0np0
  $(basename "$0") eno12409np1

Environment:
  CONTAINER   ovnkube-node container (default: ovn-controller)
EOF
  exit "${1:-0}"
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage 0

IFACE="${1:-ens2f0np0}"
CONTAINER="${CONTAINER:-ovn-controller}"

# Basic sanity check on interface name
if [[ ! "$IFACE" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "ERROR: invalid interface name: $IFACE" >&2
  usage 1
fi

mapfile -t lines < <(
  oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node \
    -o custom-columns=NODE:.spec.nodeName,NAME:.metadata.name --no-headers 2>&1
)

if [ ${#lines[@]} -eq 0 ] || [[ "${lines[0]}" == *"Error"* ]]; then
  echo "ERROR: no ovnkube-node pods found (check oc login/context):" >&2
  oc get pods -n openshift-ovn-kubernetes 2>&1 | grep -i ovn || true
  exit 1
fi

printf "Checking interface: %s\n\n" "$IFACE"
printf "%-35s %-8s %-18s %s\n" "NODE" "EXISTS" "MAC" "OVN_UPLINK"
printf "%-35s %-8s %-18s %s\n" "----" "------" "---" "----------"

missing=0

for line in "${lines[@]}"; do
  node=$(awk '{print $1}' <<< "$line")
  pod=$(awk '{print $2}' <<< "$line")

  out=$(oc exec -n openshift-ovn-kubernetes "$pod" -c "$CONTAINER" -- sh -c "
    exists=no; mac=MISSING; ovn=unknown
    if [ -e /sys/class/net/${IFACE} ]; then
      exists=yes
      mac=\$(cat /sys/class/net/${IFACE}/address)
    fi
    for p in \$(ovs-vsctl list-ports br-ex 2>/dev/null); do
      t=\$(ovs-vsctl get interface \"\$p\" type 2>/dev/null | tr -d '\"')
      case \"\$t\" in system|\"\") ovn=\$p; break;; esac
    done
    echo \"\$exists \$mac \$ovn\"
  " 2>&1) || out="error error error ($out)"

  exists=$(awk '{print $1}' <<< "$out")
  mac=$(awk '{print $2}' <<< "$out")
  ovn=$(awk '{print $3}' <<< "$out")

  printf "%-35s %-8s %-18s %s\n" "$node" "$exists" "$mac" "$ovn"
  [ "$exists" = "yes" ] || ((missing++)) || true
done

echo
if [ "$missing" -eq 0 ]; then
  echo "OK: ${IFACE} exists on all nodes"
else
  echo "WARN: ${IFACE} missing or errors on $missing node(s)"
fi
