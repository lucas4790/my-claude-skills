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

Pass plugin names to install a subset (`./install.sh dotnet powershell`, `.\install.ps1 dotnet, powershell`); only that subset's tools are installed. Re-running is safe. Or do it by hand:

```bash
claude plugin marketplace add lucas4790/my-claude-skills
claude plugin install <plugin>@my-claude-skills
```

Claude Code refreshes GitHub marketplaces on startup and auto-updates installed plugins when the repo changes, so nothing else is needed locally.

## Plugins

See [SKILLS.md](SKILLS.md) for the full catalog of every skill, command and agent (regenerated on each sync).

| Plugin | Upstream | Contents |
|---|---|---|
| `anthropic-skills` | [anthropics/skills](https://github.com/anthropics/skills) | every skill under `skills/` (docx, pdf, pptx, xlsx, frontend-design, mcp-builder, skill-creator, webapp-testing, claude-api, ...) |
| `feature-dev` | [anthropics/claude-plugins-official](https://github.com/anthropics/claude-plugins-official) | `/feature-dev` command + code-explorer, code-architect, code-reviewer agents |
| `pr-review-toolkit` | [anthropics/claude-plugins-official](https://github.com/anthropics/claude-plugins-official) | `/review-pr` command + six review agents |
| `commit-commands` | [anthropics/claude-plugins-official](https://github.com/anthropics/claude-plugins-official) | `/commit`, `/commit-push-pr` and related git workflow commands |
| `claude-security` | [anthropics/claude-plugins-official](https://github.com/anthropics/claude-plugins-official) | deep vulnerability scanning with verified findings and patches |
| `code-modernization` | [anthropics/claude-plugins-official](https://github.com/anthropics/claude-plugins-official) | structured legacy-codebase modernization workflow and review agents |
| `dotnet` | [dotnet/skills](https://github.com/dotnet/skills) (official Microsoft) | Roslyn C# language server (via `dnx`, needs .NET 10 SDK on PATH) + core .NET skills |
| `dotnet-aspnetcore`, `dotnet-test`, `dotnet-data`, `dotnet-nuget`, `dotnet-upgrade`, `dotnet-diag`, `dotnet-advanced` | [dotnet/skills](https://github.com/dotnet/skills) | ASP.NET Core, testing (with agents), EF Core, NuGet, framework upgrades, diagnostics, P/Invoke & C# scripts |
| `csharp-patterns` | [Aaronontheweb/dotnet-skills](https://github.com/Aaronontheweb/dotnet-skills) | 12 curated C# design skills: coding standards, concurrency, nullable, API/type design, config, DI, serialization, project structure, packages, Testcontainers, AOT |
| `powershell` | [Misaka-Mikoto-Tech/agent-skills](https://github.com/Misaka-Mikoto-Tech/agent-skills), [ajinkyajacob/powershell-agent-skills](https://github.com/ajinkyajacob/powershell-agent-skills) | safe native-command invocation/quoting + script, module, Pester and CI/CD patterns |
| `mattpocock-skills` | [mattpocock/skills](https://github.com/mattpocock/skills) | 25 engineering skills: grill-me / grill-with-docs, to-spec, to-tickets, code-review (standards + spec axes), tdd, domain-modeling, triage, implement, handoff… run `setup-matt-pocock-skills` once per repo |
| `agent-browser` | [vercel-labs/agent-browser](https://github.com/vercel-labs/agent-browser) | browser automation CLI skill (navigate, forms, screenshots, extraction, QA); needs `npm i -g agent-browser && agent-browser install` |
| `spec-kit` | [github/spec-kit](https://github.com/github/spec-kit) | repo-owned bootstrap skill: installs Spec Kit via `uvx`/`uv tool` and guides the `/speckit.*` workflow; the `speckit-*` skills are generated per project by the CLI |
| `codebase-onboarding` | [eabait/codebase-onboarding-skill](https://github.com/eabait/codebase-onboarding-skill) | generates a DeepWiki-style, source-linked wiki with diagrams to learn how a repo works; `pip install -r scripts/requirements.txt` optional for deeper analysis |
| `explanatory-output-style` | [anthropics/claude-plugins-official](https://github.com/anthropics/claude-plugins-official) | adds educational insights about implementation choices and codebase patterns while working |
| `caveman` | [JuliusBrussee/caveman](https://github.com/JuliusBrussee/caveman) | terse "caveman mode" that cuts ~65% of output tokens; `/caveman` commands + skills |

`caveman` is referenced directly from upstream (not vendored) because it is a full plugin with runtime hooks and a split MIT/BSL license. Claude Code clones and auto-updates it itself.

## How syncing works

- `sources.json` lists each upstream repo, the ref to track, and which paths to copy where.
- `scripts/sync.sh` sparse-clones each source, copies the paths in (deleting anything upstream removed), and records the synced commit in `UPSTREAM.lock.json`, then regenerates `SKILLS.md`.
- `.github/workflows/sync-upstream.yml` runs the script daily at 06:00 UTC (and on manual dispatch) and commits directly to `main` when anything changed.

Run it locally with `scripts/sync.sh` (needs `git`, `rsync`, `jq`, `python3`).

## Adding a source

1. Add an entry to `sources.json` with the repo, ref, and `copy` mappings into `plugins/<name>/...`.
2. If it is a bare skills folder (not a full plugin), add `plugins/<name>/.claude-plugin/plugin.json`.
3. Add a plugin entry to `.claude-plugin/marketplace.json` pointing at `./plugins/<name>`.
4. Run `scripts/sync.sh` and commit.

To have the workflow open a PR instead of pushing to `main`, replace the commit step with `peter-evans/create-pull-request`.

## Licensing

Repo scaffolding (`scripts/`, workflow, manifests) is MIT. Vendored content keeps its upstream license; see the `LICENSE` and `THIRD_PARTY_NOTICES.md` files inside each `plugins/*` directory.
