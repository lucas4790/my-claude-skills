# Security model

Everything under `plugins/` is **third-party prompt text and code** that Claude Code loads into your sessions. Treat it like any dependency: read it before you trust it.

## Trust tiers

`sources.json` marks each upstream `high` or `low` trust.

| Tier | Sources | How updates land |
|---|---|---|
| high | anthropics/skills, anthropics/claude-plugins-official, dotnet/skills, vercel-labs/agent-browser | Daily sync commits straight to `main` after `scripts/validate.py` passes |
| low | community repos (Aaronontheweb, Misaka-Mikoto-Tech, mattpocock, eabait) | Daily sync opens a **pull request** on branch `sync/low-trust`; nothing reaches `main` until a human merges |
| pinned external | `caveman` (runs hooks via `node` on every prompt) | Referenced by exact `sha` in `marketplace.json`; `scripts/bump-pinned.sh` proposes bumps in the same low-trust PR |

## What the validator checks

`scripts/validate.py` runs in CI and before every commit the workflow makes:

- manifests parse, plugin names unique, every source dir and `plugin.json` exists, declared skill paths resolve
- every `SKILL.md` has frontmatter with `name` and `description`, is under 200 KB
- no file over 5 MB
- external sources use https and a 40-char sha
- `SKILLS.md` is current
- warns (does not fail) on prompt-injection phrases, `curl | sh`, base64 decode, zero-width unicode, API-key references — these appear in the PR body for review

## Reviewing a low-trust PR

1. Open the PR; read the validator warnings in the body.
2. Diff every changed `SKILL.md`, `agents/*.md`, `commands/*.md`, `hooks/`, `scripts/`.
3. Look for instructions aimed at the model rather than the user (exfiltration, "ignore", hidden text), new shell commands, new network calls.
4. Merge or close. Closed PRs are re-opened on the next sync if upstream still differs.

## Plugins that execute code

| Plugin | What runs |
|---|---|
| `caveman` | `node` hooks on `SessionStart` and every `UserPromptSubmit` |
| `claude-security` | shell hooks (from Anthropic) |
| `dotnet`, `pyright-lsp` | language servers (`dnx roslyn-language-server`, `pyright-langserver`) |
| `terraform` | `hashicorp/terraform-mcp-server` docker container |
| `agent-browser` | Chrome via `agent-browser` CLI |
| `codebase-onboarding` | `scripts/analyze.py` (python) |

## Reporting

Open an issue on this repo for anything suspicious in vendored content; report upstream too.
