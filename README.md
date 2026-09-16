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
| `csharp-patterns` | [Aaronontheweb/dotnet-skills](https://github.com/Aaronontheweb/dotnet-skills) | 12 curated C# design skills: coding standards, concurrency, nullable, API/type design, config, DI, serialization, project structure, packages, Testcontainers, AOT |
| `powershell` | [Misaka-Mikoto-Tech/agent-skills](https://github.com/Misaka-Mikoto-Tech/agent-skills) | safe native-command invocation, quoting, escaping, encoding, `Start-Process` rules |
| `mattpocock-skills` | [mattpocock/skills](https://github.com/mattpocock/skills) | 24 engineering skills: grill-me / grill-with-docs, to-spec, to-tickets, tdd, domain-modeling, triage, implement, handoff… (`code-review` excluded in favour of `pr-review-toolkit`); run `setup-matt-pocock-skills` once per repo |
| `agent-browser` | [vercel-labs/agent-browser](https://github.com/vercel-labs/agent-browser) | browser automation CLI skill (navigate, forms, screenshots, extraction, QA); `install.sh` sets up the CLI + Chrome |
| `spec-kit` | [github/spec-kit](https://github.com/github/spec-kit) | repo-owned bootstrap skill: installs Spec Kit via `uvx`/`uv tool` and guides the `/speckit.*` workflow; the `speckit-*` skills are generated per project by the CLI |
| `component-documentation` | repo-owned | writes complete operational documentation for one infrastructure component (ingress, telemetry, alerting, security tooling, cluster services, Terraform) — purpose, architecture, deployment order, config per environment, monitoring, backup/recovery, runbooks, risks, ownership |
| `codebase-onboarding` | [eabait/codebase-onboarding-skill](https://github.com/eabait/codebase-onboarding-skill) | generates a DeepWiki-style, source-linked wiki with diagrams to learn how a repo works; `pip install -r scripts/requirements.txt` optional for deeper analysis. Upstream repo LICENSE is MIT while the SKILL.md frontmatter says Apache-2.0; both permissive |
| `terraform` | [anthropics/claude-plugins-official](https://github.com/anthropics/claude-plugins-official) (HashiCorp) | Terraform MCP server in docker: registry, provider and module docs lookup |
| `pyright-lsp` | [anthropics/claude-plugins-official](https://github.com/anthropics/claude-plugins-official) | Python language server; `install.sh` installs `pyright` |
| `caveman` | [JuliusBrussee/caveman](https://github.com/JuliusBrussee/caveman) | terse "caveman mode" that cuts ~65% of output tokens; `/caveman` commands + skills |

`caveman` is referenced directly from upstream (not vendored) because it is a full plugin with runtime hooks and a split MIT/BSL license. It is pinned to an exact commit `sha`; `scripts/bump-pinned.sh` proposes updates via PR.

## How syncing works

- `sources.json` lists each upstream repo, the ref to track, a `trust` tier, and which paths to copy where.
- `scripts/sync.sh` sparse-clones each source, copies the paths in (deleting anything upstream removed), records the synced commit in `UPSTREAM.lock.json`, then regenerates `SKILLS.md`. Flags: `--trust high|low`, `--only NAME`, `--locked` (rebuild from lockfile SHAs).
- `scripts/validate.py` checks manifests, skill frontmatter, file sizes, sha pins and catalog freshness, and scans every text file under `plugins/` for prompt-injection, exfiltration, credential-access and remote-execution patterns (`--diff REF` limits the scan to lines added since `REF`; see [SECURITY.md](SECURITY.md)).
- `.github/workflows/sync-upstream.yml` runs daily at 06:00 UTC (and on dispatch) and opens one PR per tier (`sync/high-trust`, `sync/low-trust`, the latter also carrying pinned-sha bumps) with the validator's hits for the added lines in the body; automation never pushes to `main`. Pull requests touching plugins run the validator plus `claude plugin validate`, and a high-severity hit in the added lines fails the check.

See [SECURITY.md](SECURITY.md) for the trust model. Run locally with `scripts/sync.sh` (needs `git`, `rsync`, `jq`, `python3`).

## Adding a source

1. Add an entry to `sources.json` with the repo, ref, `trust` (`high` only for vendors you would run code from unreviewed), and `copy` mappings into `plugins/<name>/...` (a copy entry may list `exclude` paths, relative to `from`).
2. If it is a bare skills folder (not a full plugin), add `plugins/<name>/.claude-plugin/plugin.json`.
3. Add a plugin entry to `.claude-plugin/marketplace.json` pointing at `./plugins/<name>`.
4. Run `scripts/sync.sh --only <name>` and `python3 scripts/validate.py`, then commit.

## Licensing

Repo scaffolding (`scripts/`, workflow, manifests) is MIT. Vendored content keeps its upstream license; see the `LICENSE` and `THIRD_PARTY_NOTICES.md` files inside each `plugins/*` directory.
