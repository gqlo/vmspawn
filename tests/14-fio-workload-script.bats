#!/usr/bin/env bats
# Extract the embedded fio script from cloud-init YAML and test it (syntax, startup output).
# No standalone script file: the YAML is the source of truth; we extract at test time.

load 'helpers'

YAML="workload/cloudinit-fio-workload.yaml"

# Clear and return path to recorded mock fio args (one arg per line).
# Mock fio also writes minimal JSON when --output= is present (result sync).
setup_file() {
    _WL_MOCK_FIO_BIN=$(mktemp -d)
    _WL_FIO_ARGS_FILE=$(mktemp)
    export _WL_FIO_ARGS_FILE
    cat > "$_WL_MOCK_FIO_BIN/fio" << MOCKEOF
#!/bin/bash
printf '%s\n' "\$@" > "$_WL_FIO_ARGS_FILE"
out=""
args=("\$@")
for ((i=0; i<\${#args[@]}; i++)); do
    case "\${args[i]}" in
        --output=*) out="\${args[i]#--output=}" ;;
        --output)
            if (( i + 1 < \${#args[@]} )); then out="\${args[i+1]}"; fi
            ;;
    esac
done
if [[ -n "\$out" ]]; then
    mkdir -p "\$(dirname "\$out")"
    printf '%s\n' '{"jobs":[{"jobname":"mock","read":{"iops":1,"bw_bytes":1,"lat_ns":{"mean":1}},"write":{"iops":1,"bw_bytes":1,"lat_ns":{"mean":1}}}]}' > "\$out"
fi
exit 0
MOCKEOF
    chmod +x "$_WL_MOCK_FIO_BIN/fio"
    export PATH="$_WL_MOCK_FIO_BIN:$PATH"

    _WL_FIO_DIR=$(mktemp -d)
    export FIO_DIRECTORY="$_WL_FIO_DIR"
    export RESULT_TIMESTAMP_FILE="$_WL_FIO_DIR/timestamp.txt"
}

teardown_file() {
    [[ -n "${_WL_MOCK_FIO_BIN:-}" ]] && rm -rf "$_WL_MOCK_FIO_BIN"
    [[ -n "${_WL_FIO_DIR:-}" ]] && rm -rf "$_WL_FIO_DIR"
    [[ -n "${_WL_FIO_ARGS_FILE:-}" ]] && rm -f "$_WL_FIO_ARGS_FILE"
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

# Clear and return path to recorded mock fio args (one arg per line).
_fio_args_reset() {
    : > "$_WL_FIO_ARGS_FILE"
}

_fio_args() {
    cat "$_WL_FIO_ARGS_FILE"
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
    _fio_args_reset
    run timeout 2 bash "$script_path" 2>/dev/null || true
    rm -f "$script_path"
    [[ "$output" == *"Starting fio workload"* ]]
    [[ "$output" == *"WORKLOAD_TYPE"* ]]
}

# ---------------------------------------------------------------
# Branch coverage: presets and CUSTOM-OPTS
# ---------------------------------------------------------------
@test "FIO: branch ACTIVE default randrw" {
    local script_path args
    script_path=$(_extract_fio_script)
    unset FIO_CUSTOM_OPTS WORKLOAD_TYPE FIO_RW FIO_TIME_BASED
    _fio_args_reset
    run timeout 3 bash "$script_path" 2>/dev/null || true
    rm -f "$script_path"
    [[ "$output" == *"WORKLOAD_TYPE=randrw"* ]]
    [[ "$output" == *"ACTIVE - Running fio"* ]]
    [[ "$output" == *"until size="* ]]
    [[ "$output" == *"randrw"* ]]
    args=$(_fio_args)
    [[ "$args" == *"--rw=randrw"* ]]
    [[ "$args" == *"--size=1G"* ]]
    [[ "$args" != *"--time_based"* ]]
    [[ "$args" != *"--runtime="* ]]
}

@test "FIO: branch ACTIVE with WORKLOAD_TYPE=randread" {
    local script_path args
    script_path=$(_extract_fio_script)
    unset FIO_CUSTOM_OPTS FIO_TIME_BASED
    export WORKLOAD_TYPE=randread FIO_SIZE=512M
    _fio_args_reset
    run timeout 3 bash "$script_path" 2>/dev/null || true
    rm -f "$script_path"
    [[ "$output" == *"WORKLOAD_TYPE=randread"* ]]
    [[ "$output" == *"ACTIVE - Running fio (randread"* ]]
    args=$(_fio_args)
    [[ "$args" == *"--rw=randread"* ]]
    [[ "$args" == *"--size=512M"* ]]
    [[ "$args" != *"--time_based"* ]]
    [[ "$args" != *"--runtime="* ]]
}

@test "FIO: branch ACTIVE with WORKLOAD_TYPE=randrw" {
    local script_path args
    script_path=$(_extract_fio_script)
    unset FIO_CUSTOM_OPTS FIO_TIME_BASED
    export WORKLOAD_TYPE=randrw FIO_SIZE=256M
    _fio_args_reset
    run timeout 3 bash "$script_path" 2>/dev/null || true
    rm -f "$script_path"
    [[ "$output" == *"WORKLOAD_TYPE=randrw"* ]]
    [[ "$output" == *"ACTIVE - Running fio (randrw"* ]]
    args=$(_fio_args)
    [[ "$args" == *"--rw=randrw"* ]]
    [[ "$args" == *"--size=256M"* ]]
    [[ "$args" != *"--time_based"* ]]
    [[ "$args" != *"--runtime="* ]]
}

@test "FIO: branch ACTIVE with WORKLOAD_TYPE=seqwrite" {
    local script_path args
    script_path=$(_extract_fio_script)
    unset FIO_CUSTOM_OPTS FIO_TIME_BASED
    export WORKLOAD_TYPE=seqwrite FIO_SIZE=128M
    _fio_args_reset
    run timeout 3 bash "$script_path" 2>/dev/null || true
    rm -f "$script_path"
    [[ "$output" == *"WORKLOAD_TYPE=seqwrite"* ]]
    [[ "$output" == *"ACTIVE - Running fio (write"* ]]
    args=$(_fio_args)
    [[ "$args" == *"--rw=write"* ]]
    [[ "$args" == *"--size=128M"* ]]
    [[ "$args" != *"--time_based"* ]]
    [[ "$args" != *"--runtime="* ]]
}

@test "FIO: branch ACTIVE with WORKLOAD_TYPE=seqread" {
    local script_path args
    script_path=$(_extract_fio_script)
    unset FIO_CUSTOM_OPTS FIO_TIME_BASED
    export WORKLOAD_TYPE=seqread FIO_SIZE=64M
    _fio_args_reset
    run timeout 3 bash "$script_path" 2>/dev/null || true
    rm -f "$script_path"
    [[ "$output" == *"WORKLOAD_TYPE=seqread"* ]]
    [[ "$output" == *"ACTIVE - Running fio (read"* ]]
    args=$(_fio_args)
    [[ "$args" == *"--rw=read"* ]]
    [[ "$args" == *"--size=64M"* ]]
    [[ "$args" != *"--time_based"* ]]
    [[ "$args" != *"--runtime="* ]]
}

@test "FIO: branch CUSTOM-OPTS when FIO_CUSTOM_OPTS is set" {
    local script_path args
    script_path=$(_extract_fio_script)
    export FIO_CUSTOM_OPTS="--name=custom --rw=randread --bs=4k --size=1M"
    unset FIO_TIME_BASED
    _fio_args_reset
    run timeout 3 bash "$script_path" 2>/dev/null || true
    rm -f "$script_path"
    [[ "$output" == *"CUSTOM-OPTS"* ]]
    [[ "$output" == *"Running fio (no runtime limit)"* ]]
    args=$(_fio_args)
    [[ "$args" == *"--rw=randread"* ]]
    [[ "$args" == *"--size=1M"* ]]
    [[ "$args" != *"--time_based"* ]]
    [[ "$args" != *"--runtime="* ]]
}

@test "FIO: CUSTOM-OPTS with FIO_TIME_BASED=1 appends runtime" {
    local script_path args
    script_path=$(_extract_fio_script)
    export FIO_CUSTOM_OPTS="--name=custom --rw=randread --bs=4k --size=1M"
    export FIO_TIME_BASED=1 FIO_RUNTIME=1
    _fio_args_reset
    run timeout 3 bash "$script_path" 2>/dev/null || true
    rm -f "$script_path"
    [[ "$output" == *"CUSTOM-OPTS"* ]]
    [[ "$output" == *"Running fio for"* ]]
    args=$(_fio_args)
    [[ "$args" == *"--rw=randread"* ]]
    [[ "$args" == *"--size=1M"* ]]
    [[ "$args" == *"--time_based"* ]]
    [[ "$args" == *"--runtime=1"* ]]
}

@test "FIO: ACTIVE with FIO_TIME_BASED=1 adds time_based runtime" {
    local script_path args
    script_path=$(_extract_fio_script)
    unset FIO_CUSTOM_OPTS
    export WORKLOAD_TYPE=randwrite FIO_TIME_BASED=1 FIO_RUNTIME=7 FIO_SIZE=32M
    _fio_args_reset
    run timeout 3 bash "$script_path" 2>/dev/null || true
    rm -f "$script_path"
    [[ "$output" == *"ACTIVE - Running fio (randwrite"* ]]
    [[ "$output" == *"for 7s"* ]]
    args=$(_fio_args)
    [[ "$args" == *"--rw=randwrite"* ]]
    [[ "$args" == *"--size=32M"* ]]
    [[ "$args" == *"--time_based"* ]]
    [[ "$args" == *"--runtime=7"* ]]
}

@test "FIO: CUSTOM-OPTS startup banner when FIO_CUSTOM_OPTS is set" {
    local script_path
    script_path=$(_extract_fio_script)
    export FIO_CUSTOM_OPTS="--name=custom --rw=randread"
    export FIO_RUNTIME=1
    _fio_args_reset
    run timeout 2 bash "$script_path" 2>/dev/null || true
    rm -f "$script_path"
    [[ "$output" == *"FIO_CUSTOM_OPTS is set"* ]]
    [[ "$output" == *"CUSTOM-OPTS branch"* ]]
}

@test "FIO: CUSTOM-OPTS unset uses normal ACTIVE branch" {
    local script_path args
    script_path=$(_extract_fio_script)
    unset FIO_CUSTOM_OPTS FIO_TIME_BASED
    export WORKLOAD_TYPE=randwrite FIO_SIZE=16M
    _fio_args_reset
    run timeout 3 bash "$script_path" 2>/dev/null || true
    rm -f "$script_path"
    [[ "$output" == *"ACTIVE - Running fio"* ]]
    [[ "$output" != *"Cycle 1: CUSTOM-OPTS"* ]]
    args=$(_fio_args)
    [[ "$args" == *"--rw=randwrite"* ]]
    [[ "$args" == *"--size=16M"* ]]
    [[ "$args" != *"--time_based"* ]]
}

# ---------------------------------------------------------------
# FIO-12: Persistent jobN naming from job.counter
# ---------------------------------------------------------------
@test "FIO: persistent jobN naming and counter file" {
    local script_path args counter
    script_path=$(_extract_fio_script)
    unset FIO_CUSTOM_OPTS FIO_TIME_BASED RESULT_SERVER_URL
    export WORKLOAD_TYPE=randrw FIO_SIZE=16M
    echo 5 > "$FIO_DIRECTORY/job.counter"
    _fio_args_reset
    run timeout 3 bash "$script_path" 2>/dev/null || true
    rm -f "$script_path"
    [[ "$output" == *"job5"* ]]
    [[ "$output" == *"Next job name: job5"* ]]
    args=$(_fio_args)
    [[ "$args" == *"--name=job5"* ]]
    counter=$(tr -d '[:space:]' < "$FIO_DIRECTORY/job.counter")
    # After at least one cycle, counter advanced past 5
    [[ "$counter" -gt 5 ]]
}

# ---------------------------------------------------------------
# FIO-13: Timestamp file appends a line on each service start
# ---------------------------------------------------------------
@test "FIO: timestamp file appends on second start" {
    local script_path lines
    script_path=$(_extract_fio_script)
    unset FIO_CUSTOM_OPTS RESULT_SERVER_URL
    export FIO_SIZE=16M
    : > "$RESULT_TIMESTAMP_FILE"
    run timeout 2 bash "$script_path" 2>/dev/null || true
    run timeout 2 bash "$script_path" 2>/dev/null || true
    rm -f "$script_path"
    # grep -c counts lines even when the final entry lacks a trailing newline
    lines=$(grep -c . "$RESULT_TIMESTAMP_FILE" || true)
    [[ "$lines" -ge 2 ]]
}
