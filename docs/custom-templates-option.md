# Add --custom-templates Option

## Goal

Add `--custom-templates=PATH` so users can point vmspawn at their own YAML template file or directory from the command line. This overrides the default `templates/` directory (and the `CREATE_VM_PATH` env var when set).

## How Custom Templates Are Processed

### Path resolution

When `--custom-templates=PATH` is set, vmspawn stores it in `CREATE_VM_PATH`.
Each entry in the colon-separated list can be a **file** (`.yaml` / `.yml`) or a **directory**.
Multiple entries are supported: `--custom-templates="/path/a:/path/b"`.
Files and directories can be mixed: `--custom-templates="/home/me/my-vm.yaml:/home/me/templates/"`.
No global `yamlpath` variable — `find_template_by_content` builds its search list internally.

### Template lookup (content-based)

vmspawn discovers templates by **reading file content**, not by filename.
`find_template_by_content(role)` is the single lookup and validation function: it builds the search path from `CREATE_VM_PATH` (split by `:`), appends built-in `templates/` when `CUSTOM_TEMPLATES_SET`, and categorizes by `kind` and structure.
For each path entry: if it is a **file**, check that file directly against the role's detection rules; if it is a **directory**, scan its `.yaml` / `.yml` files.
Returns the first match or exits with error. Users can name files however they want (e.g. `my-ns.yaml`, `fedora-vm.yaml`).

| Template role | Detection |
|---------------|-----------|
| Namespace | `kind: Namespace` |
| DataVolume | `kind: DataVolume` (any variant: URL, DataSource, etc.) |
| VolumeSnapshot | `kind: VolumeSnapshot` (apiVersion snapshot.storage.k8s.io) |
| VirtualMachine | `kind: VirtualMachine` (any variant: snapshot, clone, datasource, containerdisk) |
| Secret (cloud-init) | `kind: Secret` with `userdata:` in data |

`find_template_by_content(role)` iterates over paths and files, applies these rules via `grep`, and returns the first match.

### Required templates by clone mode

Validation checks by **kind** only (Namespace, DataVolume, VolumeSnapshot, VirtualMachine).
The specific sub-type (URL vs DataSource, snapshot vs clone, etc.) is resolved at creation time.

| Mode | Required template kinds |
|------|------------------------|
| Container disk | Namespace, VirtualMachine |
| Non-snapshot | Namespace, DataVolume, VirtualMachine |
| Snapshot | Namespace, DataVolume, VolumeSnapshot, VirtualMachine |
| With --cloudinit | Secret (cloud-init) in addition to above |

### Validation flow (detailed)

**When**: Run only when creating (skip when `DELETE_BATCH` or `DELETE_ALL`). After `detect_access_mode`, before "Creating resources for...". Same block as current `check_file_exists` (lines 583-624).

**Step 1 — Mode pre-check**: Ensure a valid image source is set. If not container disk mode and neither `DATASOURCE` nor `DV_URL` is set, fatal: "Either --datasource, --dv-url, or --containerdisk must be set". (Existing check at line 614-616.)

**Step 2 — Determine required kinds**: Three cases based on mode. Validation checks by `kind` only; the specific sub-type is resolved at creation time.

```
if CONTAINERDISK_IMAGE:
    roles = (namespace, vm)
elif USE_SNAPSHOT:
    roles = (namespace, dv, volumesnapshot, vm)
else:
    roles = (namespace, dv, vm)
if CLOUDINIT_FILE:
    roles += (cloudinit-secret,)
```

**Step 3 — Validate each role**: For each role in `roles`, call `find_template_by_content(role)`. The function searches paths, applies content detection, and returns the file path. If no file matches, it calls `fatal` with a message. Optionally cache the result (role → file path) so later `create_*` functions reuse it without re-scanning.

**Step 4 — Error message format**: `fatal "No <role> template found; required for <mode>. Searched: <paths>"`. Example: `"No VolumeSnapshot template found; required for snapshot mode. Searched: /custom/dir, /path/to/vmspawn/templates"`.

**Step 5 — Cloud-init file check**: If `CLOUDINIT_FILE` is set, verify the file exists (current check at 621-624). This is separate from template validation.

**Partial custom templates**: When `--custom-templates` is set, vmspawn searches the custom path(s) first (files checked directly, directories scanned for `.yaml`/`.yml`), then falls back to the built-in `templates/` directory.
So a user can provide only a VM template file and vmspawn will use built-in templates for Namespace, DataVolume, VolumeSnapshot, and cloud-init Secret.
The search order is: custom path(s) first, then `$(dirname "$0")/templates`.
If no file matches a required role after searching all paths, vmspawn exits with an error.

### Template processing

Each template file is processed by `process_template()`, which runs `sed` to replace placeholders with runtime values:

- `{BATCH_ID}`, `{VM_BASENAME}`, `{vm-ns}`, `{vm-id}` — batch and VM identity
- `{STORAGE_CLASS}`, `{STORAGE_SIZE}`, `{ACCESS_MODE}` — storage
- `{DATASOURCE}`, `{DATASOURCE_NS}`, `{DV_URL}` — image source
- `{VM_CPU_CORES}`, `{VM_MEMORY}`, `{RUN_STRATEGY}` — VM spec
- etc.

VM templates also use `indent_token()` for `{CLOUDINIT_DISK}`, `{CLOUDINIT_VOLUME}`, `{RESOURCES}` — these must appear alone on a line with leading spaces; the replacement is indented to match.

### Use template values when option matches or is absent

When using custom templates, the template may have **literal values** instead of placeholders (e.g. `batch-id: "abc123"`). In that case:

- **Option not given** — Use the template's value. Extract it and set the runtime variable (e.g. `BATCH_ID=abc123`). The template keeps its literal; the rest of vmspawn uses this value.
- **Option matches template** — Use the template's value (no replacement needed). If the user passed `--batch-id=abc123` and the template has `abc123`, skip replacement.
- **Option differs** — Use the option value. If the user passed `--batch-id=xyz` and the template has `abc123`, replace with `xyz`.

Placeholders like `{BATCH_ID}` are always expanded. This rule applies only to
literal values in known YAML contexts (e.g. `batch-id: "..."`,
`vm-basename: "..."`). Implementation: before processing, scan templates for
literal values in known fields; when the option was not given, extract and set
the corresponding variable. During `process_template`, for literal values:
replace only when the option was given and differs from the template.

### Application flow

1. **Validation** — Before creation, `validate_required_templates()` determines required roles from the clone mode and calls `find_template_by_content` for each.
2. **Per-namespace** — For each namespace, vmspawn processes the Namespace template, applies it via `oc apply -f -`.
3. **Base disk** — In snapshot/URL modes, processes the DataVolume template (URL or DataSource), applies.
4. **Snapshot** — In snapshot mode, processes the VolumeSnapshot template, applies.
5. **VMs** — For each VM, processes the appropriate VM template (with `indent_token` for cloud-init/resources), applies.

Custom templates must use the same `{PLACEHOLDER}` syntax as the built-in templates. See `.cursor/rules/yaml-templates.mdc` for placeholder conventions.

## Implementation

### 1. Refactor: remove yamlpath and find_file_on_path; add find_template_by_content

**Remove**: Global `yamlpath` (line 59), its population (line 64), and `find_file_on_path` (lines 541-552). **Add**: `find_template_by_content(role)` as the single lookup and validation function.

`find_template_by_content` builds the search list internally:

```bash
find_template_by_content() {
    local role=$1
    local paths=()
    IFS=: read -r -a paths <<< "${CREATE_VM_PATH:-$(dirname "$0")/templates}"
    (( CUSTOM_TEMPLATES_SET )) && paths+=( "$(dirname "$0")/templates" )
    for entry in "${paths[@]}"; do
        if [[ -f "$entry" ]]; then
            # entry is a file — check it directly
            # apply detection rules via grep, return if match
            :
        elif [[ -d "$entry" ]]; then
            # entry is a directory — scan its YAML files
            for file in "$entry"/*.yaml "$entry"/*.yml 2>/dev/null; do
                [[ -f "$file" ]] || continue
                # apply detection rules via grep, return first match
            done
        fi
    done
    fatal "No $role template found on CREATE_VM_PATH"
}
```

Detection uses `grep` on file content (e.g. `grep -qE "kind:[[:space:]]*Namespace" "$file"` for Namespace). Handle multi-document YAML. Replace all `find_file_on_path("name.yaml")` and `check_file_exists` calls with `find_template_by_content role`. Remove `check_file_exists` — validation happens inside `find_template_by_content` (fatal if not found).

### 2. Add validate_required_templates()

Implement the validation flow above. Function logic:

1. **Mode pre-check**: If not container disk and no DATASOURCE/DV_URL, fatal with existing message.
2. **Build roles array**: Use the 3-case decision tree (CONTAINERDISK_IMAGE → USE_SNAPSHOT → else).
3. **Validate each role**: Loop over roles, call `find_template_by_content(role)`. Optionally store result in an associative array `template_file[role]=path` so `create_namespaces`, `create_virtualmachines`, etc. can reuse without re-scanning.
4. **Error format**: `fatal "No <role> template found; required for <mode>. Searched: <path1>, <path2>"`. Include the search paths in the message for debugging.
5. **Cloud-init file**: Keep existing check for `CLOUDINIT_FILE` when specified.

Replace the current `check_file_exists` block (lines 593-619). Call `validate_required_templates` in the same place.

**Cache**: Use a global associative array `declare -A template_file` (or
similar). When `find_template_by_content(role)` finds a match, store
`template_file[$role]=$path`. `create_namespaces`, `create_datavolumes`,
`create_virtualmachines`, etc. then use `template_file[namespace]` instead of
calling `find_template_by_content` again. `validate_required_templates` fills
the cache; creation functions read from it.

### 3. Conditional replacement (use template value when option matches or absent)

For custom templates only: (a) **Pre-scan**: before processing, extract literal
values from templates for known fields (`batch-id`, `vm-basename`, etc.). When
the user did not pass the corresponding option, set the runtime variable from
the template (e.g. `BATCH_ID` from `batch-id: "abc123"`). (b) **During
processing**: when replacing, skip if the template value matches the option
value; replace only when the user passed a different value. Use `awk` or a bash
loop for extraction and conditional replacement.

### 4. Add option to process_option

Initialize `CUSTOM_TEMPLATES_SET=0` with the other config variables (around line 65). In vmspawn `process_option()` (around line 199), add:

```bash
customtemplates) CREATE_VM_PATH=$value; CUSTOM_TEMPLATES_SET=1 ;;
```

Handle the `customtemplates` / `custom-templates` token (process_option normalizes `-` and `_`). Set `CUSTOM_TEMPLATES_SET=1` so we know to append built-in templates for partial custom support.

### 5. Add help text

In `help()` (around lines 93-141), add a line:

```
        --custom-templates=PATH  Use YAML templates from PATH (file or
                                 | | | directory; content-based discovery).
                                 | | | Falls back to templates/ for missing
                                 | | | roles (partial custom OK)
```

### 6. Update tab completion

In tab-completion/vmspawn.bash, add `--custom-templates=` to the opts array.

### 7. Update README

In README.md Options section, add a note about `--custom-templates` for custom template files or directories. Document that partial custom is supported (e.g. only a VM template file; built-in used for the rest). Optionally add a short "Custom templates" subsection with an example showing both file and directory usage.

## Files to Change

- vmspawn: refactor — remove `yamlpath` and `find_file_on_path`; add `find_template_by_content()` (handles both file and directory path entries) and `validate_required_templates()` (mode-to-role mapping, validation); replace all lookups with `find_template_by_content`; add conditional replacement; process_option case with `CUSTOM_TEMPLATES_SET`; help text
- tab-completion/vmspawn.bash: add `--custom-templates=` to opts
- README.md: document the option (accepts files or directories) and that filenames are optional (content-based discovery)

## Testing

- Bats test: `vmspawn -n --custom-templates=/path/to/templates --batch-id=... --vms=1` uses the custom dir (reuse existing CREATE_VM_PATH test pattern from tests/02-core-validation.bats)
- Bats test: `--custom-templates=/path/to/my-vm.yaml` with a single file path finds the template by content
- Bats test: `--custom-templates=/path/to/my-vm.yaml:/path/to/templates/` with mixed file and directory paths works correctly
- Bats test: custom-named templates (e.g. `my-ns.yaml`, `fedora-vm.yaml`) work when content matches the expected kind/structure
- Bats test: built-in `templates/` directory works (content matches expected kinds)
- Bats test: partial custom — only VM template file in custom path, built-in used for Namespace/DV/snapshot/secret
- Bats test: `--custom-templates` with missing template (and no built-in match) fails with expected error
- Bats test: snapshot mode with missing VolumeSnapshot template fails with clear validation error
- Bats test: `--custom-templates=/nonexistent/file.yaml` with a path that is neither a file nor a directory is silently skipped (no match found → fatal)
- Bats test: template with literal `batch-id: "abc123"` and no `--batch-id` → output keeps `abc123`
- Bats test: template with literal `batch-id: "abc123"` and `--batch-id=xyz` → output has `batch-id: "xyz"`
- `--custom-templates` takes precedence over `CREATE_VM_PATH` when both are set (option overrides env)
