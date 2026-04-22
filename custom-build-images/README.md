# Custom build images

This directory holds the **self-built** minimal guest disk used with vstorm (for example a small x86_64 kernel plus rootfs, imported via `--dv-url` or your own hosting).

- **`vm.qcow2`** — local copy of the built guest image (not tracked in git; see `.gitignore`).

Build recipes or scripts for producing that image can live here as you add them.
