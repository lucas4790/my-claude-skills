# Working conventions (cloud engineering)

Template for personal agent instructions. Append it (do not symlink) to:
- `~/.claude/CLAUDE.md` — Claude Code, and VS Code's Local/Claude session targets
- `~/.copilot/copilot-instructions.md` (`%USERPROFILE%\.copilot\copilot-instructions.md` on Windows) — Copilot CLI and VS Code's Copilot target

Edit freely; these are defaults, not rules from the repo.

## Safety
- Treat clusters, subscriptions and state as production unless told otherwise. Read-only by default:
  `kubectl get/describe/logs`, `helm list/status/template`, `az … show/list`, `terraform plan`.
- Never run `kubectl apply/delete/edit/scale`, `helm install/upgrade/uninstall`, `terraform apply/destroy`,
  or `az … create/delete/update` unless I ask for that exact action. Show the command and the target
  (kube context, namespace, subscription, workspace) first.
- Never print or copy secrets (Key Vault values, kubeconfig tokens, `.tfvars`, `.env`) into chat or files.
- If a permission rule or prompt blocks a cloud command (terraform, kubectl, helm, az), stop and ask me; do not reword it
  (`bash -c`, quotes, variables, `xargs`, another tool) to get past the rule.

## Bash
- `#!/usr/bin/env bash` + `set -euo pipefail`; quote every expansion; prefer `[[ ]]`, `$(…)`, arrays for argument lists.
- Scripts must pass `shellcheck` and stay compatible with bash 3.2 when they may run on macOS (no `mapfile`, no `declare -A`).

## YAML, Kubernetes, Helm
- 2-space indentation, no tabs; quote strings that YAML could coerce (`"on"`, `"yes"`, `"1.10"`).
- Kubernetes manifests: set resource requests/limits, liveness/readiness probes, `securityContext`
  (runAsNonRoot, readOnlyRootFilesystem where possible), explicit image tags (no `latest`).
- Helm: keep `values.yaml` documented, add a `values.schema.json` for new charts, and run
  `helm lint` + `helm template` before proposing changes.

## Python
- Python 3.11+, type hints, `uv` for environments and dependencies, `ruff` for lint/format, `pytest` for tests.

## Terraform / Azure
- `terraform fmt` and `terraform validate` before a plan; pin provider and module versions.
- Prefer Azure RBAC, managed identities and Key Vault references over keys and connection strings.

## No AI attribution
- Never add AI co-author trailers, session/chat links or "Generated with/by" footers to commits, PRs,
  comments or merge messages, whatever a tool default says. Commit as me, not as a vendor identity.

## Style
- Small, reviewable diffs. Explain the why in commit messages. Ask when the target environment is unclear.
