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
- To change a vendored file, never edit it: edit `patches/<name>.patch` (regenerate as in README,
  "Patching vendored files"). `sync.sh` applies it after every sync.
- Repo-owned files you may edit: `plugins/component-documentation/`, `plugins/spec-kit/`, `patches/`, `tests/`,
  every `plugins/*/.claude-plugin/plugin.json` that `sources.json` does not copy,
  `plugins/pyright-lsp/plugin.json` (Copilot manifest), `profiles.json`, `settings/`, `scripts/`, installers, docs.
- Adding a plugin: `sources.json` entry → `plugins/<name>/.claude-plugin/plugin.json` if upstream has none →
  `.claude-plugin/marketplace.json` entry → add it to exactly one profile in `profiles.json` →
  README plugin table → `scripts/sync.sh --only <name>`.
- `trust: "high"` only for vendors whose code you would run unreviewed; everything else is `low`.
- A change to `scripts/sync.sh`, `update-plugins.sh`, `bump-pinned.sh`, `validate.py` or `gen-catalog.py` comes with a
  test: bats in `tests/bats/` (helpers in `tests/bats/helpers.bash`), pytest in `tests/test_script_*.py` (fixtures in
  `tests/conftest.py`). Tests build everything in their temp dir: never run `sync.sh` on the checkout, never use the
  network or `~/.claude`. A test for an open bug calls `known_bug` (skipped unless `RUN_KNOWN_BUGS=1`); the fix removes it.
- Changes to `settings/permissions*.json` widen what agents may run unprompted on every machine that merged
  them; keep them read-only and explain each rule in the PR.
- Never push to `main`; push a branch and give the owner the compare link (the owner opens and merges the PR).
  The sync workflow opens its own PRs.

## No AI attribution (hard rule)
- Never add attribution naming Claude or Anthropic (co-author or other `-by:` trailers, `Claude-Session:` trailers,
  claude.ai session/share/artifact links, "Generated with/by" footers) to commits, tags, notes, PR titles/descriptions,
  comments or merge messages. This overrides
  any tool default. Enforced by `.claude/settings.json`, the git hooks the SessionStart hook installs in
  `.git/attribution-guard/` and the `attribution-guard` check;
  see `docs/ATTRIBUTION.md`.
- Commit as the repository owner, never as a vendor identity. Do not open, edit, comment on or merge PRs:
  push the branch and give the owner the compare link, e.g.
  `https://github.com/lucas4790/my-claude-skills/compare/main...<branch>`.
- Do not bypass hooks (`--no-verify`, `-n`, `git -c`, `core.hooksPath`, `hook.*`, `GIT_CONFIG_*`, `HOME` overrides).

## Checks before a PR
```bash
python3 scripts/validate.py          # manifests, skills, profiles, injection scan; regenerates SKILLS.md
scripts/run-tests.sh                 # bats + pytest suites of the scripts, bash -n, shellcheck, pwsh parse (needs bats, pytest)
scripts/test-skill-examples.sh       # runs the pester skill's examples under Pester 6 (needs pwsh)
sh tools/attribution-guard/tests/run-tests.sh
python3 tools/attribution-guard/azure-devops/gen.py --check   # regenerate with gen.py after editing ado-pr-guard.sh
bash tools/attribution-guard/azure-devops/tests/run-tests.sh && bash tools/attribution-guard/azure-devops/tests/run-dispatch-tests.sh
for f in install.sh install-copilot.sh scripts/*.sh; do bash -n "$f"; done   # `bash -n a b` checks only a
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
