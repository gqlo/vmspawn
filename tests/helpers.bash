# Shared helpers for vstorm bats tests

# Set up mock oc for the entire test file. Call from setup_file.
# Ensures tests never run real "oc" commands against a cluster.
setup_oc_mock() {
    if [[ -z "${_VSTORM_MOCK_OC_DIR:-}" ]]; then
	_VSTORM_MOCK_OC_DIR=$(mktemp -d)
	_create_mock_oc "$_VSTORM_MOCK_OC_DIR"
	export PATH="$_VSTORM_MOCK_OC_DIR:$PATH"
	export _VSTORM_MOCK_OC_DIR
    fi
}

# Create a mock oc script that satisfies all prerequisite checks
# and returns MOCK_ACCESS_MODE for StorageProfile queries.
# Usage: _create_mock_oc <directory>
_create_mock_oc() {
    local dir=$1
    mkdir -p "$dir"
    cat > "$dir/oc" << 'MOCKEOF'
#!/bin/bash
case "$1" in
    whoami) echo "test-user" ;;
    get)
        case "$2" in
            storageprofile)
                if [[ -n "${MOCK_ACCESS_MODE:-}" ]]; then
                    echo "$MOCK_ACCESS_MODE"
                else
                    exit 1
                fi
                ;;
            storageclass)
                # Return binding mode when -o jsonpath is used
                if [[ "$*" == *"volumeBindingMode"* && -n "${MOCK_BIND_MODE:-}" ]]; then
                    echo "$MOCK_BIND_MODE"
                fi
                ;;
            datavolume) echo "Succeeded" ;;
            volumesnapshot) echo "true" ;;
            vm)
                # `oc get vm -A --no-headers` (optionally `-l batch-id=X`),
                # or `oc get vm -n NAMESPACE --no-headers`.
                # Set MOCK_VM_LINES (newline-separated
                # "NAMESPACE NAME AGE STATUS READY" rows) for a static response.
                _vm_ns=""
                _args=("$@")
                for ((_i=2; _i<${#_args[@]}; _i++)); do
                    if [[ "${_args[_i]}" == "-n" ]]; then
                        _vm_ns="${_args[_i+1]:-}"
                        break
                    fi
                done
                _emit_vm_lines() {
                    local lines=$1
                    if [[ -n "$_vm_ns" ]]; then
                        # Namespaced `oc get vm -n NS` omits the namespace column;
                        # MOCK_VM_LINES always uses the cluster-wide "NS NAME ..." shape.
                        printf '%s\n' "$lines" | awk -v ns="$_vm_ns" '$1 == ns {print substr($0, index($0, $2))}'
                    else
                        printf '%s\n' "$lines"
                    fi
                }
                if [[ -n "${MOCK_VM_STATUS_TICKS_FILE:-}" ]]; then
                    _t=0
                    [[ -f "$MOCK_VM_STATUS_TICKS_FILE" ]] && _t=$(cat "$MOCK_VM_STATUS_TICKS_FILE")
                    if (( _t > 0 )); then
                        [[ -n "${MOCK_VM_LINES:-}" ]] && _emit_vm_lines "$MOCK_VM_LINES"
                        _t=$((_t - 1))
                        echo "$_t" > "$MOCK_VM_STATUS_TICKS_FILE"
                    else
                        [[ -n "${MOCK_VM_LINES_STOPPED:-}" ]] && _emit_vm_lines "$MOCK_VM_LINES_STOPPED"
                    fi
                elif [[ -n "${MOCK_VM_LINES:-}" ]]; then
                    _emit_vm_lines "$MOCK_VM_LINES"
                fi
                ;;
            ns)
                # `oc get ns -l batch-id=X --no-headers`, `oc get ns -l batch-id`,
                # or `oc get ns NAMESPACE --no-headers`.
                _ns_name=""
                if [[ "$3" != "-l" && -n "${3:-}" ]]; then
                    _ns_name="$3"
                fi
                if [[ -n "$_ns_name" ]]; then
                    if [[ -n "${MOCK_CLEANUP_TICKS_FILE:-}" && -n "${MOCK_LEFTOVER_NS:-}" && "$_ns_name" == "$MOCK_LEFTOVER_NS" ]]; then
                        _t=0
                        [[ -f "$MOCK_CLEANUP_TICKS_FILE" ]] && _t=$(cat "$MOCK_CLEANUP_TICKS_FILE")
                        if (( _t > 0 )); then
                            printf '%s Active\n' "$_ns_name"
                        fi
                    elif [[ -n "${MOCK_NS_LINES:-}" ]] && printf '%s\n' "$MOCK_NS_LINES" | grep -qx "$_ns_name"; then
                        printf '%s Active\n' "$_ns_name"
                    fi
                elif [[ -n "${MOCK_NS_CALLS_FILE:-}" ]]; then
                    _n=0
                    [[ -f "$MOCK_NS_CALLS_FILE" ]] && _n=$(cat "$MOCK_NS_CALLS_FILE")
                    _n=$((_n + 1))
                    echo "$_n" > "$MOCK_NS_CALLS_FILE"
                    if (( _n == 1 )); then
                        [[ -n "${MOCK_NS_LINES:-}" ]] && printf '%s\n' "$MOCK_NS_LINES"
                    else
                        _t=0
                        [[ -n "${MOCK_CLEANUP_TICKS_FILE:-}" && -f "$MOCK_CLEANUP_TICKS_FILE" ]] && _t=$(cat "$MOCK_CLEANUP_TICKS_FILE")
                        if (( _t > 0 )) && [[ -n "${MOCK_LEFTOVER_NS:-}" ]]; then
                            printf '%s\n' "$MOCK_LEFTOVER_NS"
                        fi
                    fi
                elif [[ -n "${MOCK_NS_LINES:-}" ]]; then
                    printf '%s\n' "$MOCK_NS_LINES"
                fi
                ;;
            pvc)
                # `oc get pvc -A --no-headers` or `oc get pvc -n NAMESPACE --no-headers`,
                # used by watch_batch_delete_cleanup() / watch_namespace_delete_cleanup().
                _pvc_ns=""
                _args=("$@")
                for ((_i=2; _i<${#_args[@]}; _i++)); do
                    if [[ "${_args[_i]}" == "-n" ]]; then
                        _pvc_ns="${_args[_i+1]:-}"
                        break
                    fi
                done
                if [[ -n "${MOCK_CLEANUP_TICKS_FILE:-}" ]]; then
                    _t=0
                    [[ -f "$MOCK_CLEANUP_TICKS_FILE" ]] && _t=$(cat "$MOCK_CLEANUP_TICKS_FILE")
                    if (( _t > 0 )) && [[ -n "${MOCK_LEFTOVER_NS:-}" ]]; then
                        if [[ -z "$_pvc_ns" || "$_pvc_ns" == "$MOCK_LEFTOVER_NS" ]]; then
                            printf '%s fake-pvc-1 Bound fake-pv-1 1Gi RWX fake-sc 1m\n' "$MOCK_LEFTOVER_NS"
                        fi
                    fi
                fi
                ;;
            pv)
                # `oc get pv -o jsonpath='...name... ...claimRef.namespace...'`,
                # used by watch_batch_delete_cleanup() to find PVs still
                # bound to a batch namespace. Emits one fake "name namespace"
                # row while MOCK_CLEANUP_TICKS_FILE is > 0.
                if [[ -n "${MOCK_CLEANUP_TICKS_FILE:-}" ]]; then
                    _t=0
                    [[ -f "$MOCK_CLEANUP_TICKS_FILE" ]] && _t=$(cat "$MOCK_CLEANUP_TICKS_FILE")
                    if (( _t > 0 )) && [[ -n "${MOCK_LEFTOVER_NS:-}" ]]; then
                        printf 'fake-pv-1 %s\n' "$MOCK_LEFTOVER_NS"
                    fi
                fi
                ;;
            volumeattachment)
                # `oc get volumeattachment -o jsonpath='...name... ...persistentVolumeName...'`,
                # used by watch_batch_delete_cleanup() to find VolumeAttachments
                # referencing a leftover batch PV. Emits one fake row bound to
                # the same fake PV name as the `pv` case above, and is the
                # single place that decrements MOCK_CLEANUP_TICKS_FILE (this
                # is always the last of the four queries per poll iteration).
                if [[ -n "${MOCK_CLEANUP_TICKS_FILE:-}" ]]; then
                    _t=0
                    [[ -f "$MOCK_CLEANUP_TICKS_FILE" ]] && _t=$(cat "$MOCK_CLEANUP_TICKS_FILE")
                    if (( _t > 0 )); then
                        printf 'fake-va-1 fake-pv-1\n'
                        _t=$((_t - 1))
                    fi
                    echo "$_t" > "$MOCK_CLEANUP_TICKS_FILE"
                fi
                ;;
            *) ;;
        esac
        ;;
    apply) cat > /dev/null ;;
    *) ;;
esac
MOCKEOF
    chmod +x "$dir/oc"
}

# Set up a mock curl for the entire test file. Call from setup_file.
# Used to verify post_batch_result_metadata() actually POSTs (and how many
# times / with which manifest_phase) without ever touching the network.
setup_curl_mock() {
    if [[ -z "${_VSTORM_MOCK_CURL_DIR:-}" ]]; then
	_VSTORM_MOCK_CURL_DIR=$(mktemp -d)
	_create_mock_curl "$_VSTORM_MOCK_CURL_DIR"
	export PATH="$_VSTORM_MOCK_CURL_DIR:$PATH"
	export _VSTORM_MOCK_CURL_DIR
    fi
}

# Create a mock curl script that records every invocation instead of hitting
# the network, then always "succeeds" (exit 0) so callers see a normal
# "Posted ..." log line rather than a failure/timeout.
#
# Each POST is appended to $MOCK_CURL_LOG (if set) as one line:
#   "<manifest_phase> <url>"
# where <manifest_phase> is read out of the JSON payload passed via
# `--data-binary @<file>` (vstorm's post_batch_result_metadata always writes
# a top-level "manifest_phase" key of "progress" or "final").
# Usage: _create_mock_curl <directory>
_create_mock_curl() {
    local dir=$1
    mkdir -p "$dir"
    cat > "$dir/curl" << 'MOCKEOF'
#!/bin/bash
url="${@: -1}"
payload_file=""
prev=""
for a in "$@"; do
    if [[ "$prev" == "--data-binary" && "$a" == @* ]]; then
        payload_file="${a#@}"
    fi
    prev="$a"
done
phase="unknown"
if [[ -n "$payload_file" && -f "$payload_file" ]]; then
    phase=$(grep -o '"manifest_phase": *"[^"]*"' "$payload_file" | head -1 | sed -E 's/.*"manifest_phase": *"([^"]*)".*/\1/')
    [[ -n "$phase" ]] || phase="unknown"
fi
if [[ -n "${MOCK_CURL_LOG:-}" ]]; then
    printf '%s %s\n' "$phase" "$url" >> "$MOCK_CURL_LOG"
fi
exit 0
MOCKEOF
    chmod +x "$dir/curl"
}

# Set up a mock virtctl for the entire test file. Call from setup_file.
# Used to verify stop_batch_vms() actually invokes `virtctl stop <vm> -n
# <namespace>` for every VM (and how many times) without ever touching a
# real cluster.
setup_virtctl_mock() {
    if [[ -z "${_VSTORM_MOCK_VIRTCTL_DIR:-}" ]]; then
	_VSTORM_MOCK_VIRTCTL_DIR=$(mktemp -d)
	_create_mock_virtctl "$_VSTORM_MOCK_VIRTCTL_DIR"
	export PATH="$_VSTORM_MOCK_VIRTCTL_DIR:$PATH"
	export _VSTORM_MOCK_VIRTCTL_DIR
    fi
}

# Create a mock virtctl script. `virtctl stop NAME -n NAMESPACE` appends
# "NAMESPACE/NAME" to $MOCK_VIRTCTL_STOP_LOG (if set) and exits 0, unless
# NAME is listed (comma-separated) in $MOCK_VIRTCTL_STOP_FAIL, in which case
# it exits 1 (simulating a VM that's already gone/stopped) -- to verify
# stop_batch_vms() logs a warning per failed VM but keeps going instead of
# aborting the delete.
# Usage: _create_mock_virtctl <directory>
_create_mock_virtctl() {
    local dir=$1
    mkdir -p "$dir"
    cat > "$dir/virtctl" << 'MOCKEOF'
#!/bin/bash
case "$1" in
    stop)
        name="$2"
        ns=""
        shift 2
        while (($#)); do
            if [[ "$1" == "-n" ]]; then
                ns="$2"
                shift 2
            else
                shift
            fi
        done
        if [[ -n "${MOCK_VIRTCTL_STOP_LOG:-}" ]]; then
            printf '%s/%s\n' "$ns" "$name" >> "$MOCK_VIRTCTL_STOP_LOG"
        fi
        IFS=',' read -ra _fail_names <<< "${MOCK_VIRTCTL_STOP_FAIL:-}"
        for _f in "${_fail_names[@]}"; do
            [[ "$_f" == "$name" ]] && exit 1
        done
        exit 0
        ;;
    *) exit 0 ;;
esac
MOCKEOF
    chmod +x "$dir/virtctl"
}
