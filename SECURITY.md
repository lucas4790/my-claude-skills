# Security model

Everything under `plugins/` is **third-party prompt text and code** that Claude Code loads into your sessions. Treat it like any dependency: read it before you trust it.

## Trust tiers

`sources.json` marks each upstream `high` or `low` trust.

| Tier | Sources | How updates land |
|---|---|---|
| high | anthropics/skills, anthropics/claude-plugins-official, dotnet/skills, vercel-labs/agent-browser | Daily sync opens a **pull request** on branch `sync/high-trust`; expected to be a quick merge, but a human still looks |
| low | community repos (Aaronontheweb, Misaka-Mikoto-Tech, mattpocock, eabait), github/awesome-copilot | Daily sync opens a **pull request** on branch `sync/low-trust`; read it |
| pinned external | `caveman` (runs hooks via `node` on every prompt) | Referenced by exact `sha` in `marketplace.json`; `scripts/bump-pinned.sh` proposes bumps in the low-trust PR |

Nothing reaches `main` without a pull request: branch protection requires a PR and a green `validate-pr` check, for admins too, and automation never pushes to `main`. Sync PRs are created with `GITHUB_TOKEN`, which does not trigger workflows, so the sync job validates them itself and reports the `validate-pr` status (structural problems fail it; injection hits only annotate the PR). The tier only decides which PR a change lands in, so trusted vendors don't hold up review of community sources.

The sync job also runs the repo tests (`scripts/run-tests.sh`) and the skill code-block tests (`scripts/test-skill-examples.sh`) on the synced tree, which is unreviewed upstream code (the Pester runner and runnable python blocks execute examples): both run as a throwaway user with an empty environment on a copy of the tree, and its leftover processes are killed; the workflow token is passed only to the PR step and the checkout keeps no credentials. Local changes to vendored files live in `patches/` (repo-owned, reviewed like any other change) and are re-applied on every sync.

Both sync PRs regenerate `SKILLS.md` and `UPSTREAM.lock.json`, so after merging one the other may show a conflict. Don't resolve it by hand: the next run (daily, or `workflow_dispatch`) rebuilds each branch from `main` with `--force`. An open sync PR is closed automatically (branch deleted, review comments included) once upstream no longer differs from `main`.

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

A hook registration in a repo-owned plugin that the owner reviewed is listed with the sha256 of its file in [`scripts/reviewed-hooks.json`](scripts/reviewed-hooks.json) and then reported as `[reviewed]`. The entry covers only the hook registration, only while the file is unchanged: any edit makes it `high` again (validate.py prints the new hash), so adding or changing an entry is part of reviewing that hook.

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
| `claude-security` | `sh`/`python3` hooks (from Anthropic): banner on `/claude-security`, metrics after its own scripts, a one-line tip after `git push` / `gh pr create` (local `git` calls; off with `CLAUDE_SECURITY_SCAN_TIP=off`), and a `PermissionRequest` hook on `AskUserQuestion` that only acts on the scan's own start confirmation. Since 0.12.0 Claude may start the skill without `/claude-security`, and the skill pre-approves `Bash(git *)`, `Write` and `Edit` for that turn: apply [`settings/claude-guardrails.json`](settings/claude-guardrails.json) so history-, config- and remote-changing git commands still ask |
| `code-modernization` | `sh` + `python3` hooks (from Anthropic) on `SessionStart`, `UserPromptSubmit`, `Stop`, `PostToolUseFailure`, `StopFailure` in every session: whole-number usage counts, gated to `/modernize` work except a once-per-version `health` count; no network of their own (counts go through Claude Code's telemetry). Also a TypeScript function-hook module (`register.ts`: progress pane, x-ray context) that loads only when `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS` is on or Anthropic's rollout flag enables it. The guardrails' `env` pins keep the module off and the counts off |
| `dotnet`, `pyright-lsp` | language servers (`dnx roslyn-language-server`, `pyright-langserver`) |
| `terraform` | `hashicorp/terraform-mcp-server` docker container |
| `agent-browser` | Chrome via `agent-browser` CLI |
| `codebase-onboarding` | `scripts/analyze.py` (python) |
| `yaml-lsp` | `yaml-language-server`, which downloads the SchemaStore catalog and the schemas it matches (and any `$schema` modeline URL) on first use |
| `yaml-hooks` | `sh` hook after every Write/Edit of a `.yaml`/`.yml` file: runs the local `yamllint` on it (no network) and passes the errors to Claude |

`azure-agent-skills` runs no local code but connects to one remote MCP server, Microsoft Learn (`https://learn.microsoft.com/api/mcp`, read-only documentation search and fetch, no credentials): the questions the model looks up leave the machine as search queries. Remove `mcpServers` from its `.claude-plugin/plugin.json`, or disable the server, where that is not acceptable.

GitHub Copilot differs in two ways: VS Code starts a plugin's MCP servers without a trust prompt once the
plugin is installed, and Copilot CLI keeps a skill's `allowed-tools` approvals for the rest of the session
(`/reset-allowed-tools` clears them). `install-copilot.*` therefore skips the `claude-only` profile and keeps
`codebase-onboarding` (which pre-approves `python3`, `pip`, `git`) out of the default.

## No AI attribution

`.claude/settings.json` denies agents (Bash and PowerShell alike) the usual GitHub tools and `gh` commands that
publish PR/issue text, comments, merges or API commits, and the usual spellings of git hook bypasses. A PreToolUse
hook blocks other spellings, GitHub API writes, edits of git config and hook files, and git, gh and az commands,
GitHub/Azure DevOps REST calls and MCP writes whose text carries attribution. None of this is airtight against a
determined agent; the git hooks, the required check and the main audit stand behind it. A PR that changes
`.github/workflows/` can add a job named like a required check, so review those changes before merging. See [docs/ATTRIBUTION.md](docs/ATTRIBUTION.md). A PR that loosens these rules changes what agents may
publish under the owner's name.

## Reporting

Open an issue on this repo for anything suspicious in vendored content; report upstream too.
