# Bug Tracker

Bugs discovered by automated analysis and testing. Each entry includes the date found, severity, status, and details.

---

## BUG-001: Unbound variable in `check_file_exists()`

| Field | Value |
|---|---|
| **Date found** | 2026-02-12 |
| **Severity** | Medium |
| **Status** | Fixed |
| **File** | `vmspawn`, line 395 |
| **Found by** | Agent -- discovered while adding ERR-10 through ERR-15 test cases |

### Description

The `check_file_exists()` function referenced an undefined variable `$file` instead of the function parameter `$1` in its error message. Under `set -eu`, this caused an "unbound variable" crash instead of producing the intended user-friendly error.

### Symptom

When a required template file was missing from `CREATE_VM_PATH`, the script exited with:

```
./vmspawn: line 395: file: unbound variable
```

instead of the intended:

```
namespace.yaml not found on /path/to/templates
```

### Before (buggy)

```bash
check_file_exists() {
    find_file_on_path "${1:-}" >/dev/null || fatal "$file not found on $CREATE_VM_PATH"
}
```

### After (fixed)

```bash
check_file_exists() {
    find_file_on_path "${1:-}" >/dev/null || fatal "${1:-} not found on $CREATE_VM_PATH"
}
```

### Impact

Affected all 7 callers of `check_file_exists()` -- any missing template (`namespace.yaml`, `volumesnap.yaml`, `vm-snap.yaml`, `vm-datasource.yaml`, `vm-clone.yaml`, `dv-datasource.yaml`, `dv.yaml`) would trigger the crash. In practice, only affects users who override `CREATE_VM_PATH` or accidentally delete a template file.

### Tests added

ERR-10 through ERR-15 in `tests/vmspawn.bats` -- each verifies a missing template produces a clear error message.

### Notes

A linter like `shellcheck` would have flagged `$file` as an undefined variable (SC2154).

---

## BUG-002: Unrecognized options show no error message

| Field | Value |
|---|---|
| **Date found** | 2026-02-12 |
| **Severity** | Low |
| **Status** | Fixed |
| **File** | `vmspawn`, lines 158 and 169 |
| **Found by** | Agent -- discovered during error-handling review |

### Problem

When a user passed an unrecognized option (e.g. `--foobar` or `-Z`), the script printed the full help/usage text and exited with status 1, but never told the user *which* option was unrecognized. For long options like `--foobar`, there was no indication at all of what went wrong -- it just looked like the user asked for help.

### Before

```
$ ./vmspawn --foobar
Usage: ./vmspawn [options] [number_of_vms ...
    options:
        -n                      Show what commands would be run
        ...
        (50+ lines of help text)
```

### After

```
$ ./vmspawn --foobar
Error: unrecognized option '--foobar'. Run './vmspawn -h' to see all options.

$ ./vmspawn -Z
Error: unrecognized option '-Z'. Run './vmspawn -h' to see all options.
```

### Fix

1. Changed the `*` catch-all in `process_option()` to call `fatal` with the option name instead of `help`
2. Changed the `*` catch-all in the `getopts` loop to call `fatal` with `OPTARG` (the actual option character)
3. Prefixed the `getopts` optstring with `:` to suppress default error messages and let us show our own

### Tests updated

ERR-6 and ERR-7 in `tests/vmspawn.bats` now verify that the error message includes the unrecognized option name and a hint to run `-h`.

---

## BUG-003: Input validation runs too late — bad arguments cause log file creation and cluster hangs

| Field | Value |
|---|---|
| **Date found** | 2026-02-18 |
| **Severity** | Medium |
| **Status** | Fixed |
| **File** | `vmspawn`, lines ~282–494 |
| **Found by** | Manual testing (`./vmspawn --vms=-1` on a live cluster) |

### Problem

Pure argument validation (numeric checks, range checks, positional arg count) ran ~200 lines after log file creation and cluster interaction. Invalid inputs like `--vms=-1` triggered log file creation and `oc` network calls that could hang indefinitely — the validation that would reject them was never reached.

### Steps to reproduce

```bash
./vmspawn --vms=-1
```

### Before (buggy)

```
2026-02-18 08:28:14 Log file created: logs/f73977-rhel9-2026-02-18T08:28:14.log
^C    # hangs on oc calls, validation never reached
```

Execution order was:

1. Log file creation (line ~282)
2. `check_prerequisites()` — multiple `oc` network calls (line ~465)
3. `detect_access_mode()` — more `oc` calls (line ~472)
4. Input validation (line ~494) — too late

### After (fixed)

```
Error: Number of VMs must be a positive integer
Try './vmspawn --help' for more information.
```

Exits instantly with code 1, no log file created, no cluster contact.

### Fix

Moved the argument validation block (positional arg count, numeric parsing, `NUM_VMS`/`NUM_NAMESPACES` assignment, and range checks) to right after option parsing — before log file creation and any cluster interaction.

### Tests

Existing tests (ERR-1 through ERR-5, OPT-12) continue to pass. No new tests needed — the validation logic is unchanged, only its position in the script moved earlier.

---

<!-- Add new bugs above this line using the next sequential BUG-NNN number -->
