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
                # `oc get vm -A --no-headers`, used both to list existing VMs
                # and to poll for Running/Ready status in wait_for_all_vms.
                # Set MOCK_VM_LINES (newline-separated "NAMESPACE NAME AGE
                # STATUS READY" rows) to simulate VMs already Running.
                if [[ -n "${MOCK_VM_LINES:-}" ]]; then
                    printf '%s\n' "$MOCK_VM_LINES"
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
