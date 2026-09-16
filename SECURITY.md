# Security model

Everything under `plugins/` is **third-party prompt text and code** that Claude Code loads into your sessions. Treat it like any dependency: read it before you trust it.

## Trust tiers

`sources.json` marks each upstream `high` or `low` trust.

| Tier | Sources | How updates land |
|---|---|---|
| high | anthropics/skills, anthropics/claude-plugins-official, dotnet/skills, vercel-labs/agent-browser | Daily sync opens a **pull request** on branch `sync/high-trust`; expected to be a quick merge, but a human still looks |
| low | community repos (Aaronontheweb, Misaka-Mikoto-Tech, mattpocock, eabait) | Daily sync opens a **pull request** on branch `sync/low-trust`; read it |
| pinned external | `caveman` (runs hooks via `node` on every prompt) | Referenced by exact `sha` in `marketplace.json`; `scripts/bump-pinned.sh` proposes bumps in the low-trust PR |

Nothing reaches `main` without a pull request: branch protection requires a PR and a green `validate-pr` check, for admins too, and automation never pushes to `main`. Sync PRs are created with `GITHUB_TOKEN`, which does not trigger workflows, so the sync job validates them itself and reports the `validate-pr` status (structural problems fail it; injection hits only annotate the PR). The tier only decides which PR a change lands in, so trusted vendors don't hold up review of community sources.

Both sync PRs regenerate `SKILLS.md` and `UPSTREAM.lock.json`, so after merging one the other may show a conflict. Don't resolve it by hand: the next run (daily, or `workflow_dispatch`) rebuilds each branch from `main` with `--force`.

## What the validator checks

`scripts/validate.py` runs on every PR that touches `plugins/` and on every sync:

- manifests parse, plugin names unique, every source dir and `plugin.json` exists, declared skill paths resolve
- every `SKILL.md` has frontmatter with `name` and `description`, is under 200 KB
- no file over 5 MB
- external sources use https and a 40-char sha
- `SKILLS.md` is current

### Injection scan

Every text file under `plugins/` (`.md`, `.json`, `.yaml`, `.sh`, `.ps1`, `.py`, `.js`, `.ts`, …) is matched against patterns in two tiers:

| Severity | Patterns |
|---|---|
| `high` | instructions aimed at the model ("ignore previous instructions", "you are now", "do not tell the user", "without asking the user", "secretly"), HTML comments containing instructions, exfiltration hosts (`webhook.site`, `ngrok`, `hooks.slack.com`, Discord webhooks, `interact.sh`, …), external images with a query string, credential paths (`~/.ssh`, `~/.aws`, `~/.kube`, `id_rsa`, …), token-minting commands (`gh auth token`, `az account get-access-token`, …), API-key / secret references, `curl \| sh`, `irm \| iex`, `base64 -d \| sh`, hook event registrations, zero-width and bidi-override unicode |
| `low` | external images, `base64 -d` on its own, long base64-looking blobs, `eval(` / `Invoke-Expression(` |

A `high` phrase that sits inside quotes (`"ignore previous instructions"`) is downgraded to `low`: that is a skill *describing* injection so it can resist it, which several vendored agents do.

The scan is **diff-aware**. With `--diff REF` only lines added since `REF` (plus whole new files) are scanned, so the same known text does not raise the same warning every day:

| Where | Invocation | Effect of a `high` hit |
|---|---|---|
| Human PR touching `plugins/` | `validate.py --diff origin/main` | check fails (exit 2) — reword or justify in the PR |
| Sync PRs (both tiers) | `validate.py --diff HEAD --warn-only` | listed with `‼` in the PR body and counted in the title; merge is a human decision |
| Local, no flags | `validate.py` | full scan, warnings only — for a baseline read |

Regexes catch the obvious, not the paraphrased: the PR body tells you *where* to look, not whether it is safe.

## Reviewing a sync PR

1. Open the PR; read the validator hits in the body. Every `‼ [high]` line is a file:line to open in context.
2. Diff every changed `SKILL.md`, `agents/*.md`, `commands/*.md`, `hooks/`, `scripts/`.
3. Look for instructions aimed at the model rather than the user (exfiltration, "ignore", hidden text), new shell commands, new network calls, new hooks.
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
