#!/usr/bin/env bats
# Extract the embedded fio script from cloud-init YAML and test it (syntax, startup output).
# No standalone script file: the YAML is the source of truth; we extract at test time.

load 'helpers'

YAML="workload/cloudinit-fio-workload.yaml"

# The embedded script installs fio when missing, then prints startup.
# CI/minimal runners often have no fio and no working package install;
# prepend a no-op fio so runtime tests see the banner and branch lines.
setup_file() {
    _WL_MOCK_FIO_BIN=$(mktemp -d)
    cat > "$_WL_MOCK_FIO_BIN/fio" << 'MOCKEOF'
#!/bin/bash
exit 0
MOCKEOF
    chmod +x "$_WL_MOCK_FIO_BIN/fio"
    export PATH="$_WL_MOCK_FIO_BIN:$PATH"

    _WL_FIO_DIR=$(mktemp -d)
    export FIO_DIRECTORY="$_WL_FIO_DIR"
}

teardown_file() {
    [[ -n "${_WL_MOCK_FIO_BIN:-}" ]] && rm -rf "$_WL_MOCK_FIO_BIN"
    [[ -n "${_WL_FIO_DIR:-}" ]] && rm -rf "$_WL_FIO_DIR"
}

# Extract the first write_files content block (the script) from the YAML.
# Output: script with leading 6-space indent stripped, to a temp file; echo path.
_extract_fio_script() {
    local out
    out=$(mktemp)
    # First write_files content block only (script); next "  - path:" ends it.
    awk '
        /^    content: \|$/ && !block_done { in_block=1; next }
        in_block && /^  - path:/ { in_block=0; block_done=1; next }
        in_block {
            if (/^      .*/) print substr($0, 7)
            else if (/^[[:space:]]*$/) print ""
        }
    ' "$YAML" > "$out"
    echo "$out"
}

# ---------------------------------------------------------------
# FIO-1: Script can be extracted from cloud-init YAML
# ---------------------------------------------------------------
@test "FIO: script can be extracted from cloudinit YAML" {
    local script_path
    script_path=$(_extract_fio_script)
    [[ -f "$script_path" ]]
    [[ -s "$script_path" ]]
    grep -q '#!/bin/bash' "$script_path"
    grep -q 'WORKLOAD_TYPE' "$script_path"
    grep -q 'FIO_RUNTIME' "$script_path"
    grep -q 'FIO_TIME_BASED' "$script_path"
    rm -f "$script_path"
}

# ---------------------------------------------------------------
# FIO-2: Extracted script has valid bash syntax
# ---------------------------------------------------------------
@test "FIO: extracted script has valid bash syntax" {
    local script_path
    script_path=$(_extract_fio_script)
    run bash -n "$script_path"
    rm -f "$script_path"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------
# FIO-3: Extracted script runs and prints startup banner
# ---------------------------------------------------------------
@test "FIO: extracted script runs and prints startup with WORKLOAD_TYPE" {
    local script_path
    script_path=$(_extract_fio_script)
    export FIO_RUNTIME=1
    run timeout 2 bash "$script_path" 2>/dev/null || true
    rm -f "$script_path"
    [[ "$output" == *"Starting fio workload"* ]]
    [[ "$output" == *"WORKLOAD_TYPE"* ]]
}

# ---------------------------------------------------------------
# Branch coverage: presets and CUSTOM-OPTS
# ---------------------------------------------------------------
@test "FIO: branch ACTIVE default randrw" {
    local script_path
    script_path=$(_extract_fio_script)
    unset FIO_CUSTOM_OPTS WORKLOAD_TYPE FIO_RW FIO_TIME_BASED
    run timeout 3 bash "$script_path" 2>/dev/null || true
    rm -f "$script_path"
    [[ "$output" == *"WORKLOAD_TYPE=randrw"* ]]
    [[ "$output" == *"ACTIVE - Running fio"* ]]
    [[ "$output" == *"until size="* ]]
    [[ "$output" == *"randrw"* ]]
}

@test "FIO: branch ACTIVE with WORKLOAD_TYPE=randread" {
    local script_path
    script_path=$(_extract_fio_script)
    unset FIO_CUSTOM_OPTS
    export WORKLOAD_TYPE=randread FIO_RUNTIME=1
    run timeout 3 bash "$script_path" 2>/dev/null || true
    rm -f "$script_path"
    [[ "$output" == *"WORKLOAD_TYPE=randread"* ]]
    [[ "$output" == *"ACTIVE - Running fio (randread"* ]]
}

@test "FIO: branch ACTIVE with WORKLOAD_TYPE=randrw" {
    local script_path
    script_path=$(_extract_fio_script)
    unset FIO_CUSTOM_OPTS
    export WORKLOAD_TYPE=randrw FIO_RUNTIME=1
    run timeout 3 bash "$script_path" 2>/dev/null || true
    rm -f "$script_path"
    [[ "$output" == *"WORKLOAD_TYPE=randrw"* ]]
    [[ "$output" == *"ACTIVE - Running fio (randrw"* ]]
}

@test "FIO: branch ACTIVE with WORKLOAD_TYPE=seqwrite" {
    local script_path
    script_path=$(_extract_fio_script)
    unset FIO_CUSTOM_OPTS
    export WORKLOAD_TYPE=seqwrite FIO_RUNTIME=1
    run timeout 3 bash "$script_path" 2>/dev/null || true
    rm -f "$script_path"
    [[ "$output" == *"WORKLOAD_TYPE=seqwrite"* ]]
    [[ "$output" == *"ACTIVE - Running fio (write"* ]]
}

@test "FIO: branch CUSTOM-OPTS when FIO_CUSTOM_OPTS is set" {
    local script_path
    script_path=$(_extract_fio_script)
    export FIO_CUSTOM_OPTS="--name=custom --rw=randread --bs=4k --size=1M"
    unset FIO_TIME_BASED
    run timeout 3 bash "$script_path" 2>/dev/null || true
    rm -f "$script_path"
    [[ "$output" == *"CUSTOM-OPTS"* ]]
    [[ "$output" == *"Running fio (no runtime limit)"* ]]
}

@test "FIO: CUSTOM-OPTS with FIO_TIME_BASED=1 appends runtime" {
    local script_path
    script_path=$(_extract_fio_script)
    export FIO_CUSTOM_OPTS="--name=custom --rw=randread --bs=4k --size=1M"
    export FIO_TIME_BASED=1 FIO_RUNTIME=1
    run timeout 3 bash "$script_path" 2>/dev/null || true
    rm -f "$script_path"
    [[ "$output" == *"CUSTOM-OPTS"* ]]
    [[ "$output" == *"Running fio for"* ]]
}

@test "FIO: CUSTOM-OPTS startup banner when FIO_CUSTOM_OPTS is set" {
    local script_path
    script_path=$(_extract_fio_script)
    export FIO_CUSTOM_OPTS="--name=custom --rw=randread"
    export FIO_RUNTIME=1
    run timeout 2 bash "$script_path" 2>/dev/null || true
    rm -f "$script_path"
    [[ "$output" == *"FIO_CUSTOM_OPTS is set"* ]]
    [[ "$output" == *"CUSTOM-OPTS branch"* ]]
}

@test "FIO: CUSTOM-OPTS unset uses normal ACTIVE branch" {
    local script_path
    script_path=$(_extract_fio_script)
    unset FIO_CUSTOM_OPTS
    export WORKLOAD_TYPE=randwrite FIO_RUNTIME=1
    run timeout 3 bash "$script_path" 2>/dev/null || true
    rm -f "$script_path"
    [[ "$output" == *"ACTIVE - Running fio"* ]]
    [[ "$output" != *"Cycle 1: CUSTOM-OPTS"* ]]
}
