# Colorize Log Output

## Design

- Define color constants near the top of `vmspawn` (after `fatal()`, around line 73).
- Only enable colors when stdout is a terminal (`[[ -t 1 ]]`), so colors auto-disable in pipes, redirects, and bats tests -- **no test changes needed**.
- No changes to `log_message()` -- colors flow through `tee` into both stdout and the log file automatically.

## Color scheme

- **Cyan** (`C_VAL`): variable values -- batch IDs, counts, class names, URLs, sizes, file paths, namespace/VM/DV names
- **Red** (`C_ERR`): `Error:` prefix in prerequisite and fatal messages
- **Yellow** (`C_WARN`): `Warning:` prefix text
- **Green** (`C_OK`): success lines ("Prerequisites OK", "completed successfully!", "All DataVolumes are completed", etc.)
- **Bold** (`C_BOLD`): section headers ("Creating namespaces...", "Creating VirtualMachines...", etc.)
- **Reset** (`C_RST`): terminates any color sequence

## Changes

### 1. Color constants (~line 73 in `vmspawn`)

```bash
if [[ -t 1 ]] ; then
    C_VAL=$'\033[0;36m'   # cyan
    C_ERR=$'\033[0;31m'   # red
    C_WARN=$'\033[0;33m'  # yellow
    C_OK=$'\033[0;32m'    # green
    C_BOLD=$'\033[1m'     # bold
    C_RST=$'\033[0m'      # reset
else
    C_VAL= C_ERR= C_WARN= C_OK= C_BOLD= C_RST=
fi
```

### 2. `log_message()` -- no changes needed

Colors pass through `tee -a "$LOG_FILE"` to both stdout and the log file. `cat` and `less -R` render them correctly.

### 3. Wrap variable values across all `log_message` calls

Every interpolated variable in `log_message` gets wrapped with `${C_VAL}...${C_RST}`. For example in `main()`:

```bash
log_message "Batch ID:      ${C_VAL}$BATCH_ID${C_RST}"
log_message "Configuration: ${C_VAL}$NUM_VMS${C_RST} VMs across ${C_VAL}$NUM_NAMESPACES${C_RST} namespaces"
log_message "VM CPU cores:  ${C_VAL}$VM_CPU_CORES${C_RST}"
```

This pattern applies to all ~80 `log_message` calls that contain variables. Key areas:

- **Configuration summary** (lines 1335-1360): batch ID, VM/NS counts, URLs, sizes, class names, CPU, memory, cloud-init path, run strategy
- **Progress messages** (lines 659-928): namespace names, DV names, snapshot names, VM IDs, status values, counts
- **Prerequisite OK** (lines 417-427): storage class, snapshot class
- **Access mode / WFFC detection** (lines 439-481): access mode, storage class
- **Completion summary** (lines 1379-1387): counts
- **Delete / profiling** (lines 1101-1325): batch IDs, paths, targets

### 4. Color `echo "Error: ..."` in `check_prerequisites()` and `fatal()`

- Prefix "Error:" in red in each `echo` call inside `check_prerequisites()` (lines 356-414)
- Update `fatal()` to prefix with red: `echo "${C_ERR}Error:${C_RST} $*"`
  - Callers that already include "Error:" in the string will need the prefix removed to avoid double "Error:" -- but reviewing the callers, only `check_prerequisites` uses raw `echo "Error: ..."`. `fatal` callers pass the full message without "Error:" prefix, e.g. `fatal "Prerequisite check failed..."`. So `fatal()` should get a red-colored prefix.
- Color "Warning:" yellow and "Hint:" dim/yellow in prerequisite messages.

### 5. Bold section headers

Wrap phase-start messages with `C_BOLD`:

```bash
log_message "${C_BOLD}Creating namespaces...${C_RST}"
log_message "${C_BOLD}Creating DataVolumes...${C_RST}"
log_message "${C_BOLD}Creating VolumeSnapshots...${C_RST}"
log_message "${C_BOLD}Creating VirtualMachines...${C_RST}"
```

And green for success lines:

```bash
log_message "${C_OK}Resource creation completed successfully!${C_RST}"
log_message "${C_OK}All DataVolumes are completed successfully!${C_RST}"
```

### 6. Tests -- no changes needed

Colors are gated by `[[ -t 1 ]]`. Under `bats run`, stdout is captured (not a TTY), so `C_VAL` etc. will be empty strings. All existing `[[ "$output" == *"..."* ]]` assertions continue to match.
