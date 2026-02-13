# Cursor Agent Security

This document describes the security configuration for the Cursor AI agent
in this project, including file access controls and best practices.

## Agent Access Model

By default, the Cursor agent has:

- **Read access** to the entire filesystem (all user-readable files).
- **Write access** scoped to the workspace directory only (sandboxed).
- **No network access** unless explicitly granted per command.

Elevated permissions (`full_network`, `all`) require user approval via an
interactive prompt before they take effect.

## Global `.cursorignore`

A global `.cursorignore` file at `~/.cursorignore` prevents the agent from
reading sensitive files across all workspaces. It uses `.gitignore` syntax.

### Current Rules

| Pattern | What It Protects |
|---|---|
| `.ssh/` | SSH private keys, `known_hosts`, config |
| `.kube/` | Kubernetes credentials and cluster configs |
| `.gnupg/` | GPG private keys and keyrings |
| `.config/gh/` | GitHub CLI authentication tokens |
| `.aws/` | AWS credentials and config |
| `.azure/` | Azure CLI credentials |
| `.config/gcloud/` | Google Cloud SDK credentials |
| `.netrc` | Plaintext login credentials |
| `.env` | Environment files with secrets |
| `*.pem` | PEM-encoded certificates and keys |
| `*.key` | Private key files |
| `.password-store/` | `pass` password manager store |
| `.docker/config.json` | Docker registry credentials |
| `.config/containers/auth.json` | Podman/container registry credentials |

### File Location

```text
~/.cursorignore
```

This is the **global** ignore file. You can also place a `.cursorignore` in
any workspace root for project-specific rules.

## Editing the Ignore List

Open the file and add or remove patterns as needed:

```bash
vim ~/.cursorignore
```

Changes take effect after restarting Cursor.

## Limitations

`.cursorignore` blocks the agent's **file-reading tools** (Read, Grep, Glob,
SemanticSearch). However, it does **not** block shell commands. If the agent
runs `cat ~/.kube/config` via the Shell tool and the command is approved (or
matches a command allowlist), the file contents will still be returned.

To mitigate this:

- Review shell commands carefully before approving them, especially any that
  read files outside the workspace.
- Avoid adding broad entries to Cursor's command allowlist that could
  bypass the ignore rules (e.g., allowing all `cat` commands).
- Consider tightening OS-level file permissions (`chmod 600`) on sensitive
  files as an additional layer.

## Best Practices

1. **Review permission prompts carefully.** Granting `all` disables the
   sandbox entirely -- only approve when you understand what the command does.
2. **Keep the ignore list up to date.** If you install new tools that store
   credentials (e.g., Vault, Terraform), add their config paths.
3. **Avoid committing secrets.** The agent will refuse to commit files that
   look like secrets, but `.cursorignore` adds defense in depth by preventing
   it from reading them in the first place.
4. **Use workspace-level ignores** for project-specific sensitive files
   (e.g., `.env.local`, `secrets/`).
