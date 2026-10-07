# Security model

Everything under `plugins/` is **third-party prompt text and code** that Claude Code loads into your sessions. Treat it like any dependency: read it before you trust it.

## Trust tiers

`sources.json` marks each upstream `high` or `low` trust.

| Tier | Sources | How updates land |
|---|---|---|
| high | anthropics/skills, anthropics/claude-plugins-official, dotnet/skills, MicrosoftDocs/agent-skills, vercel-labs/agent-browser | Daily sync opens a **pull request** on branch `sync/high-trust`; expected to be a quick merge, but a human still looks |
| low | community repos (Aaronontheweb, Misaka-Mikoto-Tech, mattpocock, eabait), github/awesome-copilot | Daily sync opens a **pull request** on branch `sync/low-trust`; read it |
| pinned external | `caveman` (runs hooks via `node` on every prompt) | Referenced by exact `sha` in `marketplace.json`; `scripts/bump-pinned.sh` proposes bumps in the low-trust PR |

Nothing reaches `main` without a pull request: branch protection requires a PR and a green `validate-pr` check, for admins too, and automation never pushes to `main`. Sync PRs are created with `GITHUB_TOKEN`, which does not trigger workflows, so the sync job validates them itself and reports the `validate-pr` status (structural problems fail it; injection hits only annotate the PR). The tier only decides which PR a change lands in, so trusted vendors don't hold up review of community sources.

The sync job also runs the repo tests (`scripts/run-tests.sh`) and the skill code-block tests (`scripts/test-skill-examples.sh`) on the synced tree, which is unreviewed upstream code (the Pester runner and runnable python blocks execute examples): both run as a throwaway user with an empty environment on a copy of the tree, and its leftover processes are killed; the workflow token is passed only to the PR step and the checkout keeps no credentials. Local changes to vendored files live in `patches/` (repo-owned, reviewed like any other change) and are re-applied on every sync.

`sync.sh` copies no symlink. A symlink in what a copy entry writes, or a `from` that is itself one or passes through one, fails that source (its paths and lock entry stay as committed) with an `error:` line that names the link and its target. Two things make a vendored link dangerous. `cp` follows a link out of the upstream clone: an upstream `LICENSE -> ../../.git/config` points at the checkout's own git config and would be copied as a regular file with whatever that config holds (before the workflow stopped persisting credentials, its token header; on a maintainer's machine, remotes and credential helpers). And when Claude Code copies a plugin into its cache, it keeps a link that resolves inside the plugin, skips one that leaves the marketplace, and replaces one that resolves elsewhere in the marketplace with that file's content, so an upstream link could pull another plugin's or the repo's files into this plugin. A link that stays inside the plugin is refused too: git on Windows without symlink support turns it into a text file. List the link's path in the copy entry's `exclude` to drop it.

Both sync PRs regenerate `SKILLS.md` and `UPSTREAM.lock.json`, so after merging one the other may show a conflict. Don't resolve it by hand: the next run (daily, or `workflow_dispatch`) rebuilds each branch from `main` with `--force`. An open sync PR is closed automatically (branch deleted, review comments included) once upstream no longer differs from `main`.

## What the validator checks

`scripts/validate.py` runs on every PR and on every sync (a PR that touches `plugins/` or `.claude-plugin/` also runs `claude plugin validate`):

- manifests parse, plugin names unique, every source dir and `plugin.json` exists, declared skill paths resolve;
  a `SKILL.md` that a plugin's explicit `skills` list leaves out is a warning (it would never load)
- every `SKILL.md` has frontmatter with a non-empty `name` and `description`, is under 200 KB
- no file over 5 MB
- external sources use https and a 40-char sha
- `SKILLS.md` is current

### Injection scan

Every file under `plugins/` that is text (`.md`, `.json`, `.yaml`, `.sh`, `.ps1`, `.py`, `.cs`, `.ts`, … always; any other file, extensionless ones included, unless its first 8 KB hold a NUL byte and are not UTF-8 even without it; a `#!` script and a UTF-16/32 file with a byte-order mark always count, UTF-16/32 is decoded, and NUL bytes are dropped before matching) is matched against patterns in two tiers:

| Severity | Patterns |
|---|---|
| `high` | instructions aimed at the model ("ignore previous instructions", "you are now", "do not tell the user", "without asking the user", "secretly"), HTML comments containing instructions, exfiltration hosts (`webhook.site`, `ngrok`, `hooks.slack.com`, Discord webhooks, `interact.sh`, …), external images with a query string, credential paths (`~/.ssh`, `~/.aws`, `~/.kube`, `id_rsa`, …), token-minting commands (`gh auth token`, `az account get-access-token`, …), API-key / secret references, `curl \| sh`, `irm \| iex`, `base64 -d \| sh`, hook registrations (read as JSON from every `hooks.json`, the `hooks` key of `plugin.json` and marketplace entries and the files it names, and `hooks:` frontmatter in any YAML spelling, where the whole frontmatter then counts as the registration; any event name; each new or changed event, matcher and handler counts; a marketplace registration is tied to its entry's name and source, and a hooks path that cannot be read, such as one from an external source or outside `plugins/`, is itself a registration and gets a warning), hook JSON in other text, zero-width and bidi-override unicode |
| `low` | external images, `base64 -d` on its own, long base64-looking blobs, `eval(` / `Invoke-Expression(` |

A `high` phrase that sits inside quotes (`"ignore previous instructions"`) is downgraded to `low`: that is a skill *describing* injection so it can resist it, which several vendored agents do. This is decided per occurrence: a quoted mention does not hide an unquoted one elsewhere in the file.

A hook registration in a repo-owned plugin that the owner reviewed is listed with the sha256 of its file in [`scripts/reviewed-hooks.json`](scripts/reviewed-hooks.json) and then reported as `[reviewed]`. The entry covers only the hook registration, only while the file is unchanged: any edit of that file in a PR fails `--diff` again (validate.py prints the new hash), and a PR that changes the list gets a notice, so adding or changing an entry is part of reviewing that hook. Scripts a listed hook file (frontmatter hooks included) runs through the plugin root are pinned the same way (`${CLAUDE_PLUGIN_ROOT}`, `$CLAUDE_PLUGIN_ROOT`, `${CLAUDE_PLUGIN_ROOT:-…}`, `%CLAUDE_PLUGIN_ROOT%` or `$env:CLAUDE_PLUGIN_ROOT`, quoted or not, with `/` or `\`); a use of the root that names no script inside the plugin (`cd "$CLAUDE_PLUGIN_ROOT" && …`, a glob, a path leaving the plugin) warns, and fails `--diff` when the hook file changed: each needs its own entry (validate.py warns with the hash to add while one is missing), and an edit of one fails `--diff` until it is listed with its new hash. Files those scripts read or source are not followed; they are reviewed like any other change in the PR diff.

The scan is **diff-aware**. With `--diff REF` only lines added since `REF` (plus whole new files) are scanned, so the same known text does not raise the same warning every day:

| Where | Invocation | Effect of a `high` hit |
|---|---|---|
| Human PR touching `plugins/` | `validate.py --diff origin/main` | check fails (exit 2) — reword or justify in the PR |
| Sync PRs (both tiers) | `validate.py --diff HEAD --warn-only` | listed as `⚠ path:line: [high] …` in the PR body and counted in the title; merge is a human decision |
| Local, no flags | `validate.py` | full scan, warnings only — for a baseline read |

Regexes catch the obvious, not the paraphrased: the PR body tells you *where* to look, not whether it is safe.

## Reviewing a sync PR

Both sync PRs open with a **digest** of what the sync changed (`scripts/sync-digest.py`); the low-trust PR adds what each pinned-plugin bump pulls in (`scripts/bump-pinned.sh`). The validator hits come after them: they say where instruction-shaped text sits, the digest says what is new. Read it top down:

| Part | What it shows | Look twice when |
|---|---|---|
| Sources | each upstream whose commit moved, old to new, with a GitHub compare link (the upstream change log); a pinned plugin (`caveman`) shows as `pinned` | a source moved but no plugin row follows: nothing this repo copies changed |
| Plugins | files added, modified and removed per plugin (a rename shows as one removal and one addition), and a manifest version change | a new plugin, a version jump, or far more files than the compare link explains |
| Skills | new and removed skills (a second `SKILL.md` with an existing name is listed with its path), changed descriptions, and whether the model can invoke the skill on its own; the last line is the net change in the description characters of the skills (commands are not counted), which the skill listing budget is spent on | a new or newly invocable skill (`yes`): its description is loaded into every session; a big budget increase |
| Hooks, MCP and LSP servers | each registration added, removed or changed since `main`, read the way the validator reads hooks (for a hook in a skill's or agent's frontmatter: the frontmatter from its `hooks` key on) | any row: it runs code or opens a connection on every machine that installs the plugin; open the file in its last column. Pinned plugins are not in this tree: their hooks are under Pinned plugins |
| Also | files outside `plugins/`, agents, commands and scripts added or removed, symlinks, submodules and files that became executable | any symlink or executable |
| Pinned plugins (low-trust PR) | per bump: compare link, commits and files from a clone of the upstream repository, manifest version, whether the manifest's `hooks` changed (and for which events), and the changed hook files: those with "hook" in their path or that the manifest names, scripts before docs and tests | `manifest hooks: changed`, a hook script in the list, or a major version jump; if the clone failed there is a warning and the compare link still works |

The digest is capped at about 12 KB and says how many entries it did not show; the Files changed tab has the rest. A changed file over 1 MB is not read: the digest names it (`Not read ...`) and then "None added, removed or changed" is not claimed, so open that file yourself. Names, versions, paths and commands in it come from upstream: they are shortened, stripped of control characters and backticks and printed in code spans, and nothing from the synced tree is run to build it. If a hook or server command in it would look like attribution text to the attribution guard, the workflow lists the registrations without their commands (open the file in the last column); if that is not enough it leaves the digest out and says so. If the digest cannot be built the PR says so in one line and is still opened. The digest narrows where to look; it does not replace the diff. After a local `scripts/sync.sh` the same digest is `python3 scripts/sync-digest.py --base HEAD` (`--head REF` compares two refs).

The whole PR body is kept under GitHub's 65536 characters: every block is cut in lines and width, and when the digest and the pinned block together do not fit, the pinned block and then the digest give way to a one-line note that points to the step log.

1. Open the PR; read the digest, then the validator hits in the body. Every `[high]` line is a file:line to open in context; the body shows at most 60 hit lines, `✗` and `[high]` first, and counts the rest (the Validate step log has them).
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
hook blocks other spellings, GitHub API writes and other `gh` repository writes (settings, variables and secrets,
workflow runs, releases, labels), edits of git config and hook files, and git, gh and az commands,
GitHub/Azure DevOps REST calls and MCP writes whose text carries attribution. The strict `gh` rules count only commands, not commit messages, search text or heredoc bodies, unless a shell runs that text. None of this is airtight against a
determined agent; the git hooks, the required check and the main audit stand behind it. A PR that changes
`.github/workflows/` can add a job named like a required check, so review those changes before merging. The main
audit judges a push with the patterns and matcher from before it (and fails when it cannot read them), but runs the pushed `attribution-audit.yml`, so a
push that edits that workflow can change its own audit. See [docs/ATTRIBUTION.md](docs/ATTRIBUTION.md). A PR that
loosens these rules changes what agents may publish under the owner's name.

## Reporting

Open an issue on this repo for anything suspicious in vendored content; report upstream too.
