# my-claude-skills

A Claude Code plugin marketplace with the skills and plugins I use, vendored from upstream and kept in sync automatically.

## Install

One command installs the marketplace and every plugin in it:

```bash
# Linux / macOS / WSL
curl -fsSL https://raw.githubusercontent.com/lucas4790/my-claude-skills/main/install.sh | bash
```

```powershell
# Windows
irm https://raw.githubusercontent.com/lucas4790/my-claude-skills/main/install.ps1 | iex
```

The script installs Claude Code itself if missing, then the marketplace and plugins, then the tools the selected plugins need — only when absent:

| Tool | Needed by | Linux | Windows |
|---|---|---|---|
| git, curl, jq, Node.js | marketplace clone, manifest parsing, caveman hooks | apt / dnf / brew | winget |
| agent-browser + Chrome (+ system libs on Linux) | `agent-browser` | npm, `agent-browser install --with-deps` | npm |
| uv | `spec-kit` | astral.sh installer | astral.sh installer |
| PowerShell 7 + PSScriptAnalyzer + Pester | `powershell` | snap / brew / dotnet tool | winget |
| .NET 10 SDK | `dotnet` (Roslyn C# LSP) | apt / brew / dotnet-install.sh | winget |
| pyright | `pyright-lsp` | npm | npm |
| docker (checked, not installed) | `terraform` MCP server | — | — |

If the Claude desktop app (macOS/Windows) is also installed, the script says so and asks before
proceeding, since installing plugins still needs the CLI even then — the desktop app has no
plugin-install command of its own, but reads the same `~/.claude/plugins` the CLI writes to, so
one install reaches both. Set `MY_CLAUDE_SKILLS_YES=1` to skip that prompt (e.g. for automation).

Pass plugin names to install a subset (`./install.sh dotnet powershell`, `.\install.ps1 dotnet, powershell`); only that subset's tools are installed. Re-running is safe. Or do it by hand:

```bash
claude plugin marketplace add lucas4790/my-claude-skills
claude plugin install <plugin>@my-claude-skills
```

The script also registers a `SessionStart` hook (`~/.claude/settings.json`, or `%LOCALAPPDATA%` on Windows) that runs `scripts/update-plugins.sh` / `.ps1` in the background: refreshes the marketplace, installs plugins added to it since last time, and updates installed ones. Throttled to once per 6 h (`MY_CLAUDE_SKILLS_INTERVAL` seconds to change); log in `~/.cache/my-claude-skills/update.log`. Changes apply to the next session. Run it by hand with `--force`.

### No AI attribution

The installers also switch off AI attribution naming Claude or Anthropic: `attribution` in `~/.claude/settings.json`
(no co-author trailers, PR footers or session links), `includeCoAuthoredBy: false` for Copilot CLI, a git
`commit-msg`/`pre-push` guard ([`tools/attribution-guard`](tools/attribution-guard)) that strips or blocks such
lines, and a Claude Code PreToolUse hook that blocks tool calls publishing them (git, gh, az, GitHub and Azure DevOps
MCP tools and REST calls) in every repository, work repos included (`MY_CLAUDE_SKILLS_ATTRIBUTION=keep` skips this;
the session-start updater keeps the git guard current, and on Linux/macOS the hook registration too; on Windows
re-run `install.ps1` after an update that changes the hook). With Git 2.54+ the git guard covers every repository; older Git covers
new clones and repositories where you run `git init` once, not those with their own hooks. This repository adds agent
deny rules, a required `attribution-guard` check and squash-only merges: after merging, run
[`scripts/github-hardening.sh`](scripts/github-hardening.sh) once with an admin `gh` login. Azure DevOps work
repositories get server-side policies and pipelines from `tools/attribution-guard/azure-devops/`. The one-time
steps in order, what each layer guarantees, and the limits of cloud sessions are in
[docs/ATTRIBUTION.md](docs/ATTRIBUTION.md).

### VS Code + GitHub Copilot

The same marketplace works in GitHub Copilot without conversion: Copilot CLI and VS Code (1.110+) read
`.claude-plugin/marketplace.json` and each plugin's `.claude-plugin/plugin.json`. Copilot CLI is the install
engine, and VS Code discovers every plugin Copilot CLI installs (`~/.copilot/installed-plugins`).

```bash
# Linux / macOS / WSL
curl -fsSL https://raw.githubusercontent.com/lucas4790/my-claude-skills/main/install-copilot.sh | bash
bash install-copilot.sh --profile cloud,dotnet      # from a clone: pick profiles
```

```powershell
# Windows
irm https://raw.githubusercontent.com/lucas4790/my-claude-skills/main/install-copilot.ps1 | iex
$env:MY_CLAUDE_SKILLS_PROFILE = 'cloud,dotnet'; irm https://raw.githubusercontent.com/lucas4790/my-claude-skills/main/install-copilot.ps1 | iex
```

The script installs Copilot CLI if missing (winget / `npm i -g @github/copilot`; needs ≥ 1.0.70 for the
sha-pinned caveman), adds the marketplace, installs the chosen profiles and sets
`extraKnownMarketplaces.my-claude-skills.autoUpdate` in `~/.copilot/settings.json`. The Claude Code
SessionStart updater also updates (never adds) the Copilot copies when `copilot` is on PATH.

Then, once in VS Code: turn on `chat.plugins.enabled`, add `lucas4790/my-claude-skills` to
`chat.plugins.marketplaces` via the Settings UI (**Add Item**, so the defaults stay), reload the window and
check **Extensions → `@agentPlugins`**. [`settings/vscode-settings.jsonc`](settings/vscode-settings.jsonc)
lists the other useful settings. With VS Code on Windows and Remote-WSL, run the `.ps1` on the Windows side too.

**Profiles** ([`profiles.json`](profiles.json), every plugin in exactly one):

| Profile | Plugins | Copilot default |
|---|---|---|
| `cloud` | terraform, azure-agent-skills, pyright-lsp, component-documentation, mattpocock-skills, powershell, feature-dev, spec-kit | yes |
| `dotnet` | dotnet, dotnet-aspnetcore, dotnet-test, dotnet-data, dotnet-nuget, dotnet-advanced, csharp-patterns | no |
| `extras` | anthropic-skills, codebase-onboarding, agent-browser, caveman (skipped on native Windows: POSIX-only hooks) | no |
| `claude-only` | claude-security, commit-commands, code-modernization, pr-review-toolkit | never (name them explicitly to force) |

`claude-only` plugins depend on Claude Code features (Workflow engine, `` !`cmd` `` injection, `$ARGUMENTS`,
Claude-only hook events). Use them from Claude Code, or from VS Code's **Claude** session target, which reads
the `~/.claude` plugins that `install.sh` installed.

**Per project**: copy [`settings/project-plugins.json`](settings/project-plugins.json) to a work repo as
`.github/copilot/settings.json` and/or `.claude/settings.json` (keep them identical) and trim `enabledPlugins`;
Claude Code, Copilot CLI, the Copilot coding agent and VS Code then recommend the same plugins there.

**Personal instructions**: append [`settings/user-instructions.md`](settings/user-instructions.md) to
`~/.copilot/copilot-instructions.md` and `~/.claude/CLAUDE.md`.

**Troubleshooting**: plugins or hooks missing on a work machine usually means an org policy
(`ChatPluginsEnabled`, `ChatStrictMarketplaces`, `ChatHooks`, `ChatMCP`, or GitHub's *Editor preview features* /
*MCP servers in Copilot*); run **Developer: Policy Diagnostics**. In Copilot CLI check `copilot plugin list`,
`copilot skill list`, `copilot mcp list`, `copilot lsp list`.

### Permissions baseline (opt-in, manual)

[`settings/permissions.json`](settings/permissions.json) is a curated `permissions.allow` list of **read-only** inspection commands — `git status`/`diff`/`log`, `gh pr view`, `az … show`/`list`, `kubectl get`/`describe`/`logs`, `helm list`/`status`, `terraform plan`/`validate`/`show`, `jq` — so Claude Code stops asking for those. Nothing that mutates state or runs code from the checked-out repository is in it, and there are no broad wildcards (`az *`, `kubectl *`, `git *`). Two edge cases are in on purpose: `git fetch` talks to the network (it writes only `.git/`), and `terraform plan` runs provider and data-source code against the configured backend (it does not apply). Shell redirection is a residual risk of every rule in the list, not just `jq *`: Claude Code matches the command prefix, so `jq . a > b` or `git log > file` can still write a file; `jq *` stays because `az … | jq` pipes need every segment allowed.

[`settings/permissions-trusted-repo.json`](settings/permissions-trusted-repo.json) is a second, separate list of build, test and lint runners (`dotnet build`/`test`/`format --verify-no-changes`, `python -m pytest`/`unittest`, `npm test`, `npm run lint`). Every one of them executes code from the clone (MSBuild targets, `conftest.py`, `package.json` scripts), which in an untrusted repository is arbitrary code running unprompted. Merge it only on machines where every clone Claude Code opens is one you trust.

The installer does **not** apply either file: widening what Claude may run without asking is a decision to make deliberately, per machine, after reading the list. To merge the read-only list into `~/.claude/settings.json` yourself (union, existing entries first, nothing else touched):

```bash
curl -fsSL https://raw.githubusercontent.com/lucas4790/my-claude-skills/main/settings/permissions.json -o /tmp/perms.json
jq --slurpfile p /tmp/perms.json '(.permissions.allow // []) as $a
  | .permissions.allow = $a + ($p[0].permissions.allow | map(select(. as $x | $a | index($x) | not)))'   ~/.claude/settings.json > /tmp/settings.json && mv /tmp/settings.json ~/.claude/settings.json
```

Same merge for the trusted-repo list, if you want it:

```bash
curl -fsSL https://raw.githubusercontent.com/lucas4790/my-claude-skills/main/settings/permissions-trusted-repo.json -o /tmp/perms.json
jq --slurpfile p /tmp/perms.json '(.permissions.allow // []) as $a
  | .permissions.allow = $a + ($p[0].permissions.allow | map(select(. as $x | $a | index($x) | not)))'   ~/.claude/settings.json > /tmp/settings.json && mv /tmp/settings.json ~/.claude/settings.json
```

Changes to either list are part of reviewing this repo: a PR that adds a rule here is a PR that changes what runs unprompted on every machine that merged it.

### Guardrails (opt-in, manual, recommended)

[`settings/claude-guardrails.json`](settings/claude-guardrails.json) adds `permissions.ask` rules for git commands
that change history, config or remotes (`git push`, `reset`, `clean`, `config`, `git -c …`, `remote add`/`set-url`,
also in their `git -C <dir> …` form, and the same rules for the PowerShell tool) plus two `env` pins. Ask rules win over allow rules **and over a skill's
`allowed-tools`**, and match past a leading `VAR=value`, so Claude still asks before these even inside a skill that
pre-approves `Bash(git *)`, as `claude-security` does. Since 0.12.0 Claude may start that skill on its own. The
`env` pins keep `code-modernization`'s function-hook module off (`CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=0`, even if
Anthropic's rollout flag enables it) and turn off its usage counts (`CODE_MODERNIZATION_TELEMETRY=0`). Side
effect: `/commit-push-pr` now asks before pushing. It also switches off AI attribution (`attribution`: no co-author trailers, PR footers or session links; see
[`docs/ATTRIBUTION.md`](docs/ATTRIBUTION.md)). Merge (union for `ask`, existing `env` values win, `attribution` is set):

```bash
curl -fsSL https://raw.githubusercontent.com/lucas4790/my-claude-skills/main/settings/claude-guardrails.json -o /tmp/guard.json
jq --slurpfile g /tmp/guard.json '(.permissions.ask // []) as $a
  | .permissions.ask = $a + ($g[0].permissions.ask | map(select(. as $x | $a | index($x) | not)))
  | .env = ($g[0].env + (.env // {}))
  | .attribution = $g[0].attribution' ~/.claude/settings.json > /tmp/settings.json && mv /tmp/settings.json ~/.claude/settings.json
```

On Windows the file is `%USERPROFILE%\.claude\settings.json`; run the same `jq` from Git Bash or WSL against it.

## Plugins

See [SKILLS.md](SKILLS.md) for the full catalog of every skill, command and agent (regenerated on each sync).

| Plugin | Upstream | Contents |
|---|---|---|
| `anthropic-skills` | [anthropics/skills](https://github.com/anthropics/skills) | 3 curated skills: mcp-builder, skill-creator, webapp-testing |
| `pr-review-toolkit` | [anthropics/claude-plugins-official](https://github.com/anthropics/claude-plugins-official) | `/review-pr` command + six review agents (bugs, silent failures, tests, comments, types, simplification) |
| `feature-dev` | [anthropics/claude-plugins-official](https://github.com/anthropics/claude-plugins-official) | `/feature-dev` command + code-explorer, code-architect, code-reviewer agents |
| `commit-commands` | [anthropics/claude-plugins-official](https://github.com/anthropics/claude-plugins-official) | `/commit`, `/commit-push-pr` and related git workflow commands |
| `claude-security` | [anthropics/claude-plugins-official](https://github.com/anthropics/claude-plugins-official) | deep vulnerability scanning with verified findings and patches |
| `code-modernization` | [anthropics/claude-plugins-official](https://github.com/anthropics/claude-plugins-official) | structured legacy-codebase modernization workflow and review agents |
| `dotnet` | [dotnet/skills](https://github.com/dotnet/skills) (official Microsoft) | Roslyn C# language server (via `dnx`, needs .NET 10 SDK on PATH) + core .NET skills |
| `azure-agent-skills` | [MicrosoftDocs/agent-skills](https://github.com/MicrosoftDocs/agent-skills) (official Microsoft) | 32 curated Azure skills — DevOps (Azure DevOps, Pipelines, Repos, Artifacts, Boards, ACR), platform (AKS, Key Vault, RBAC, Monitor, Managed Grafana, Policy, ARM, Cost, Logic Apps, Well-Architected, OpenTelemetry, Functions) and networking (VNet, DNS, Private Link, NAT, LB, App Gateway, WAF, Front Door, Firewall, Network Watcher, Bastion, VPN, DDoS). Structured Microsoft Learn indexes, not command recipes: they tell the model what to look up and fetch the live docs through the [Microsoft Learn MCP server](https://learn.microsoft.com/training/support/mcp), which the plugin bundles (`microsoftdocs`, `https://learn.microsoft.com/api/mcp`: read-only, no sign-in; Claude Code exposes it as `mcp__plugin_azure-agent-skills_microsoftdocs__*`, and the skills' `mcp_microsoftdocs:*` references resolve to it) |
| `csharp-patterns` | [Aaronontheweb/dotnet-skills](https://github.com/Aaronontheweb/dotnet-skills) | 12 curated C# design skills: coding standards, concurrency, nullable, API/type design, config, DI, serialization, project structure, packages, Testcontainers, AOT |
| `powershell` | [Misaka-Mikoto-Tech/agent-skills](https://github.com/Misaka-Mikoto-Tech/agent-skills), [github/awesome-copilot](https://github.com/github/awesome-copilot) | safe native-command invocation, quoting, escaping, encoding, `Start-Process` rules; Pester 6 testing guidelines (github/awesome-copilot), synced from awesome-copilot with local patches (`patches/pester.patch`) |
| `mattpocock-skills` | [mattpocock/skills](https://github.com/mattpocock/skills) | 24 engineering skills: grill-me / grill-with-docs, to-spec, to-tickets, tdd, domain-modeling, triage, implement, handoff… (`code-review` excluded in favour of `pr-review-toolkit`); run `setup-matt-pocock-skills` once per repo |
| `agent-browser` | [vercel-labs/agent-browser](https://github.com/vercel-labs/agent-browser) | browser automation CLI skill (navigate, forms, screenshots, extraction, QA); `install.sh` sets up the CLI + Chrome |
| `spec-kit` | [github/spec-kit](https://github.com/github/spec-kit) | repo-owned bootstrap skill: installs Spec Kit via `uvx`/`uv tool` and guides the `/speckit.*` workflow; the `speckit-*` skills are generated per project by the CLI |
| `component-documentation` | repo-owned | writes complete operational documentation for one infrastructure component (ingress, telemetry, alerting, security tooling, cluster services, Terraform) — purpose, architecture, deployment order, config per environment, monitoring, backup/recovery, runbooks, risks, ownership |
| `codebase-onboarding` | [eabait/codebase-onboarding-skill](https://github.com/eabait/codebase-onboarding-skill) | generates a DeepWiki-style, source-linked wiki with diagrams to learn how a repo works; `pip install -r scripts/requirements.txt` optional for deeper analysis. Upstream repo LICENSE is MIT while the SKILL.md frontmatter says Apache-2.0; both permissive |
| `terraform` | [anthropics/claude-plugins-official](https://github.com/anthropics/claude-plugins-official) (HashiCorp) | Terraform MCP server in docker: registry, provider and module docs lookup |
| `pyright-lsp` | [anthropics/claude-plugins-official](https://github.com/anthropics/claude-plugins-official) | Python language server; `install.sh` installs `pyright`. The repo-owned root `plugin.json` is the Copilot CLI manifest (Copilot needs `fileExtensions`) |
| `caveman` | [JuliusBrussee/caveman](https://github.com/JuliusBrussee/caveman) | terse "caveman mode" that cuts ~65% of output tokens; `/caveman` commands + skills |

`caveman` is referenced directly from upstream (not vendored) because it is a full plugin with runtime hooks and a split MIT/BSL license. It is pinned to an exact commit `sha`; `scripts/bump-pinned.sh` proposes updates via PR.

## How syncing works

- `sources.json` lists each upstream repo, the ref to track, a `trust` tier, and which paths to copy where.
- `scripts/sync.sh` sparse-clones each source, copies the paths in (deleting anything upstream removed), applies the source's patches (below), records the synced commit in `UPSTREAM.lock.json`, then regenerates `SKILLS.md`. A source that fails (a patch that no longer applies, a path upstream removed) is put back to the last commit and keeps its old lock entry; the other sources still sync and the script exits 1. Flags: `--trust high|low`, `--only NAME`, `--locked` (rebuild from lockfile SHAs; patches apply there too).
- `scripts/validate.py` checks manifests, skill frontmatter, file sizes, sha pins and catalog freshness, and scans every text file under `plugins/` for prompt-injection, exfiltration, credential-access and remote-execution patterns (`--diff REF` limits the scan to lines added since `REF`; see [SECURITY.md](SECURITY.md)).
- `.github/workflows/sync-upstream.yml` runs daily at 06:00 UTC (and on dispatch) and opens one PR per tier (`sync/high-trust`, `sync/low-trust`, the latter also carrying pinned-sha bumps) with the validator's hits for the added lines in the body; automation never pushes to `main`. Before that it runs the repo tests (`scripts/run-tests.sh`, see [Tests](#tests)) and `scripts/test-skill-examples.sh` (the code blocks of the skills in `tests/skill-examples.json`, see [Skill example tests](#skill-example-tests)) on the synced tree, as a throwaway user without the workflow token, since that tree is unreviewed upstream code; a failure goes on top of the PR (see below). Pull requests touching plugins run the validator plus `claude plugin validate`, and a high-severity hit in the added lines fails the check; every pull request also runs the repo tests and the skill examples.

See [SECURITY.md](SECURITY.md) for the trust model. Run locally with `scripts/sync.sh` (needs `git`, `rsync`, `jq`, `python3`).

### A red sync run

- **PR titled "... (sync/test failure)"** with a *Sync failure*, *Repo tests failed* or *Skill example tests failed* section at the top and a failed `validate-pr` status: the rest of the tier synced, but the listed sources stayed at their last synced commit, a test no longer passes on the synced tree (e.g. `tests/evals/triggers.yaml` names a skill upstream renamed), or upstream now ships an example that fails. Do not merge a failing example as is: fix it with a patch (below) or drop the source.
- **Failed workflow run, no PR**: a source failed and nothing else changed. The `error:` lines of the run name the source.
- `error: patches/<name>.patch no longer applies to <source>@<sha>; refresh it (see README)`: upstream changed the lines the patch touches. Refresh the patch as below. The CI clone is shallow, so the 3-way fallback that `sync.sh` tries after a plain `git apply` only succeeds locally, where the patch's base version is in the object store.

### Patching vendored files

Vendored files are never edited by hand (the next sync overwrites them). A copy entry in `sources.json` can name a patch instead, a unified diff in `patches/` relative to the repo root:

```json
{ "from": "instructions/powershell-pester-6.instructions.md",
  "to": "plugins/powershell/skills/pester/SKILL.md",
  "patch": "patches/pester.patch" }
```

`sync.sh` checks that every patch file exists before cloning, applies a source's patches once all of its copies are written (`git apply`, falling back to a 3-way merge), and fails the source when one does not apply. Create or refresh a patch for `<to>` of source `<source>`:

1. Remove the `"patch"` key from the copy entry and run `scripts/sync.sh --only <source>`: `<to>` is now pure upstream. Stage it with `git add <to>`.
2. Edit `<to>` into the version you want, e.g. start from `git show HEAD:<to>` (the last patched version) and take over what upstream changed. Then `git diff -- <to> > patches/<name>.patch` and `git reset -q -- <to>`.
3. Restore the `"patch"` key and run `scripts/sync.sh --only <source>` twice: both times `<to>` must come out byte-identical to your version (`cmp`). Check that the patch holds only your changes, run `scripts/test-skill-examples.sh <to>` (a patched SKILL.md with code blocks belongs in `tests/skill-examples.json` with `"mode": "enforce"`), and commit the patch with `<to>`, `sources.json`, `UPSTREAM.lock.json` and `SKILLS.md`.

## Adding a source

1. Add an entry to `sources.json` with the repo, ref, `trust` (`high` only for vendors you would run code from unreviewed), and `copy` mappings into `plugins/<name>/...` (a copy entry may list `exclude` paths, relative to `from`, and a `patch` for local changes; see "Patching vendored files").
2. If it is a bare skills folder (not a full plugin), add `plugins/<name>/.claude-plugin/plugin.json`.
3. Add a plugin entry to `.claude-plugin/marketplace.json` pointing at `./plugins/<name>`.
4. Add the plugin to exactly one profile in `profiles.json` (the validator enforces this).
5. Run `scripts/sync.sh --only <name>` and `python3 scripts/validate.py`, then commit.

## Tests

`scripts/run-tests.sh` runs the repo's own tests and prints a summary per suite: the bats suites in `tests/bats/` (`sync.sh` copying, `--only`/`--trust`/`--locked`, failing sources and patches; `update-plugins.sh`; `bump-pinned.sh`; `bash -n`, shellcheck and a PowerShell parse check of the installers and scripts) and `python3 -m pytest tests/` (`validate.py`, `gen-catalog.py` and the other pytest suites under `tests/`). Every test works in a temp dir against local fake upstreams and fake `claude`/`copilot` binaries: no network, and neither the checkout nor `~/.claude` is touched.

Prerequisites: bats-core ≥ 1.4 and pytest (`sudo apt install bats python3-pytest`; macOS: `brew install bats-core` and `python3 -m pip install pytest`), plus git, rsync, jq and python3. shellcheck and pwsh are optional; their checks are skipped without them (`PWSH=/path/to/pwsh` for a pwsh outside PATH). `scripts/run-tests.sh bats` or `scripts/run-tests.sh pytest` runs one kind; `RUN_KNOWN_BUGS=1` also runs tests that document an open bug (marked with `known_bug`; they fail until it is fixed, then the marker goes).

### Skill example tests

`scripts/test-skill-examples.sh` checks the fenced code blocks of the skills listed in
[`tests/skill-examples.json`](tests/skill-examples.json), per fence language:

| Fence | Check |
|---|---|
| `powershell`, `pwsh`, `ps1` | PowerShell parser (nothing runs); for a skill with `"runner": "pester"`, every block runs as a Pester 6 test |
| `bash`, `shell` / `sh` | `bash -n` / `sh -n`, then `shellcheck` (dialect from the fence or a `#!` line) |
| `python`, `py` | compiled; run only when listed in `python.runnable` |
| `yaml`, `yml` | parsed with PyYAML (every document), then `yamllint` with [`scripts/skill-examples/yamllint.yaml`](scripts/skill-examples/yamllint.yaml) |
| `json` | parsed |
| anything else | not tested (counted in the summary) |

`<name>` placeholders (`kubectl -n <namespace> get pods`) become a plain word before the shell and PowerShell checks
(`"placeholders": false` turns that off for a skill).

Each skill has a **mode**. `enforce`: a failing block fails the run. `report`: failures print as warnings and never
change the exit status. Repo-controlled skills (repo-owned, or vendored with a patch in `patches/`, like `pester`) are
`enforce`; vendored skills without a patch are `report`, because their fixes go through a patch, never an edit.
`tests/skill_examples` checks this rule, and that every repo-controlled skill with code blocks is listed.

```json
{
  "defaults": {
    "shellcheck": { "exclude": ["SC1091", "SC2034", "SC2154"], "reason": "snippets are fragments" },
    "placeholders": true
  },
  "skills": {
    "plugins/example/skills/demo/SKILL.md": {
      "mode": "enforce",
      "skip": [
        { "block": 4, "reason": "shows an error message, not a command" },
        { "heading": "Anti-patterns", "reason": "wrong on purpose" }
      ],
      "shellcheck": { "exclude": ["SC2010"], "reason": "fixed names only" },
      "python": { "runnable": [7] },
      "powershell": {
        "runner": "pester",
        "stubs": "scripts/skill-examples/support/demo/stubs.ps1",
        "fixtures": "scripts/skill-examples/support/demo/fixtures",
        "allowed_skips": [{ "test": "Should work on Windows", "when": "not-windows", "reason": "Windows-only" }],
        "required_passing": ["handles a"]
      }
    }
  }
}
```

- `block` counts every fenced block of the file from 1, whatever its language (the output prints it:
  `block 4 (bash, line 88, under "Install")`). `heading` matches the heading a block sits under or any enclosing one,
  so a `##` skip covers its `###` subsections. Skips and shellcheck exclusions need a `reason`; a skip that matches no
  block fails the skill. Paths are relative to the repository root; unknown keys are an error.
- `powershell.runner` is `parse` (default) or `pester`. Stubs define the commands the examples call or mock as
  `function global:Name`; fixture files are copied next to the generated tests; `allowed_skips[].when` is `always`,
  `windows`, `not-windows`, `linux`, `not-linux`, `macos` or `not-macos`.

```bash
scripts/test-skill-examples.sh                                            # every skill in the config
scripts/test-skill-examples.sh plugins/powershell/skills/pester/SKILL.md  # only this file
python3 -m pytest tests/skill_examples                                    # tests of the checker itself
```

A file that is not in the config is tested in enforce mode with the defaults (static checks only). Exit status:
0 passed, 1 an enforce-mode example failed, 2 usage, configuration or environment error. Needs python3 (3.10+) and,
for the blocks present, pwsh with Pester 6 (installed for the current user when missing unless
`SKILL_EXAMPLES_NO_INSTALL=1`), shellcheck, yamllint and PyYAML. A missing tool that an enforce-mode skill needs is
exit 2; `SKILL_EXAMPLES_ALLOW_MISSING_TOOLS=1` makes it a warning for local runs, and `SKILL_EXAMPLES_REQUIRE_TOOLS=1`
(CI) makes any missing tool exit 2, report mode included. `TEST_SKILL_EXAMPLES_KEEP=1` keeps the generated files.
The Pester runner and runnable python blocks execute the examples: only run this on SKILL.md files you trust (the sync
job runs it as a throwaway user on a copy of the tree).

## Licensing

Repo scaffolding (`scripts/`, workflow, manifests) is MIT. Vendored content keeps its upstream license; see the `LICENSE` and `THIRD_PARTY_NOTICES.md` files inside each `plugins/*` directory.
