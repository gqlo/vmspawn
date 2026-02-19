# Shared helpers for vmspawn bats tests

# Set up mock oc for the entire test file. Call from setup_file.
# Ensures tests never run real "oc" commands against a cluster.
setup_oc_mock() {
    if [[ -z "${_VMSPAWN_MOCK_OC_DIR:-}" ]]; then
	_VMSPAWN_MOCK_OC_DIR=$(mktemp -d)
	_create_mock_oc "$_VMSPAWN_MOCK_OC_DIR"
	export PATH="$_VMSPAWN_MOCK_OC_DIR:$PATH"
	export _VMSPAWN_MOCK_OC_DIR
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
            *) ;;
        esac
        ;;
    apply) cat > /dev/null ;;
    *) ;;
esac
MOCKEOF
    chmod +x "$dir/oc"
}
