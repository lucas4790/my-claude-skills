# AGENTS.md

Instructions for coding agents (Claude Code, GitHub Copilot CLI / coding agent, VS Code) working on this repo.
There is deliberately no CLAUDE.md: Claude Code reads this file when none exists.

## What this repo is
A plugin marketplace (`.claude-plugin/marketplace.json`) consumed unchanged by Claude Code, Copilot CLI and
VS Code. Most of `plugins/` is **vendored** from upstream repos listed in `sources.json` and rewritten by
`scripts/sync.sh` (rsync `--delete`), so hand edits there are lost on the next sync.

## Rules
- Do not edit vendored content. Change `sources.json` (repo, ref, trust, copy/exclude) and run
  `scripts/sync.sh --only <source>` instead. Which paths are vendored: every `copy[].to` in `sources.json`.
- Repo-owned files you may edit: `plugins/component-documentation/`, `plugins/spec-kit/`,
  every `plugins/*/.claude-plugin/plugin.json` that `sources.json` does not copy, `plugins/pyright-lsp/plugin.json`
  (Copilot manifest), `profiles.json`, `settings/`, `scripts/`, installers, docs.
- Adding a plugin: `sources.json` entry → `plugins/<name>/.claude-plugin/plugin.json` if upstream has none →
  `.claude-plugin/marketplace.json` entry → add it to exactly one profile in `profiles.json` →
  README plugin table → `scripts/sync.sh --only <name>`.
- `trust: "high"` only for vendors whose code you would run unreviewed; everything else is `low`.
- Changes to `settings/permissions*.json` widen what agents may run unprompted on every machine that merged
  them; keep them read-only and explain each rule in the PR.
- Never push to `main`; open a PR. The sync workflow opens its own PRs.

## Checks before a PR
```bash
python3 scripts/validate.py          # manifests, skills, profiles, injection scan; regenerates SKILLS.md
bash -n install.sh install-copilot.sh scripts/*.sh
shellcheck install.sh install-copilot.sh scripts/*.sh
claude plugin validate plugins/<changed-plugin>   # if the claude CLI is available
```
Commit a regenerated `SKILLS.md` together with the change that caused it.

## Portability (Claude Code + Copilot)
- Skills follow the Agent Skills spec: `name` = folder name, lowercase-hyphen, ≤ 64 chars; description ≤ 1024 chars.
- In repo-owned skills avoid Claude-only syntax (`$ARGUMENTS`, `` !`cmd` `` injection, `${CLAUDE_PLUGIN_ROOT}` in
  markdown, Workflow/Agent tool names); describe arguments in plain language and use relative paths.
- LSP servers need `extensionToLanguage` for Claude Code (`.claude-plugin/plugin.json`) and `fileExtensions` for
  Copilot (root `plugin.json`, read before `.claude-plugin/plugin.json`); keep both manifests' `name` identical.
