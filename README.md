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
| `azure-agent-skills` | [MicrosoftDocs/agent-skills](https://github.com/MicrosoftDocs/agent-skills) (official Microsoft) | 32 curated Azure skills — DevOps (Azure DevOps, Pipelines, Repos, Artifacts, Boards, ACR), platform (AKS, Key Vault, RBAC, Monitor, Managed Grafana, Policy, ARM, Cost, Logic Apps, Well-Architected, OpenTelemetry, Functions) and networking (VNet, DNS, Private Link, NAT, LB, App Gateway, WAF, Front Door, Firewall, Network Watcher, Bastion, VPN, DDoS). Structured Microsoft Learn indexes, not command recipes: they tell the model what to look up and fetch the live docs through the [Learn MCP server](https://learn.microsoft.com/training/support/mcp) |
| `csharp-patterns` | [Aaronontheweb/dotnet-skills](https://github.com/Aaronontheweb/dotnet-skills) | 12 curated C# design skills: coding standards, concurrency, nullable, API/type design, config, DI, serialization, project structure, packages, Testcontainers, AOT |
| `powershell` | [Misaka-Mikoto-Tech/agent-skills](https://github.com/Misaka-Mikoto-Tech/agent-skills) | safe native-command invocation, quoting, escaping, encoding, `Start-Process` rules |
| `mattpocock-skills` | [mattpocock/skills](https://github.com/mattpocock/skills) | 24 engineering skills: grill-me / grill-with-docs, to-spec, to-tickets, tdd, domain-modeling, triage, implement, handoff… (`code-review` excluded in favour of `pr-review-toolkit`); run `setup-matt-pocock-skills` once per repo |
| `agent-browser` | [vercel-labs/agent-browser](https://github.com/vercel-labs/agent-browser) | browser automation CLI skill (navigate, forms, screenshots, extraction, QA); `install.sh` sets up the CLI + Chrome |
| `spec-kit` | [github/spec-kit](https://github.com/github/spec-kit) | repo-owned bootstrap skill: installs Spec Kit via `uvx`/`uv tool` and guides the `/speckit.*` workflow; the `speckit-*` skills are generated per project by the CLI |
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
