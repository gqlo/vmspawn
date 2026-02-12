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

<!-- Add new bugs above this line using the next sequential BUG-NNN number -->
