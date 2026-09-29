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
- Repo-owned files you may edit: `plugins/component-documentation/`, `plugins/spec-kit/`, `plugins/yaml-lsp/`,
  `plugins/yaml-hooks/`, `patches/`, `tests/`,
  every `plugins/*/.claude-plugin/plugin.json` that `sources.json` does not copy,
  `plugins/pyright-lsp/plugin.json` (Copilot manifest), `profiles.json`, `settings/`, `scripts/`, installers, docs.
- Adding a plugin: `sources.json` entry → `plugins/<name>/.claude-plugin/plugin.json` if upstream has none →
  `.claude-plugin/marketplace.json` entry → add it to exactly one profile in `profiles.json` →
  README plugin table → `scripts/sync.sh --only <name>` → a `report` entry in `tests/skill-examples.json` if its skills
  have bash/yaml/python/json/PowerShell examples worth checking.
- `trust: "high"` only for vendors whose code you would run unreviewed; everything else is `low`.
- Hooks in repo-owned plugins never block or fail: every error path exits 0 silently, and findings go to
  `hookSpecificOutput.additionalContext`. A hook that depends on Claude Code's payload or output goes in a
  `claude-only` plugin. A new or changed hook registration under `plugins/` (any event: a `hooks.json`, a
  manifest's `hooks` key or a file it names, `hooks:` frontmatter), or any edit of a reviewed hook file or of a
  script it runs through `${CLAUDE_PLUGIN_ROOT}`, fails `validate.py --diff` until that file is listed with its new
  sha256 in `scripts/reviewed-hooks.json` (the owner reviews both in the same PR; never add or update an entry on
  your own initiative).
- A change to `scripts/sync.sh`, `update-plugins.sh`, `bump-pinned.sh`, `validate.py` or `gen-catalog.py` comes with a
  test: bats in `tests/bats/` (helpers in `tests/bats/helpers.bash`), pytest in `tests/test_script_*.py` (fixtures in
  `tests/conftest.py`). Tests build everything in their temp dir: never run `sync.sh` on the checkout, never use the
  network or `~/.claude`. A test for an open bug calls `known_bug` (skipped unless `RUN_KNOWN_BUGS=1`); the fix removes it.
- `tests/skill-examples.json` lists which skills' code blocks are tested. Repo-owned or patched skills are `enforce`;
  vendored skills without a patch are `report`. Fix a failing vendored example with a patch, not an edit. Every skip
  or shellcheck exclusion needs a `reason`. Never mark SKILL.md blocks with HTML comments (validate.py flags them).
- `scripts/eval-triggers.py` calls the model and costs tokens: run it only with `--dry-run` unless the owner asks (the
  weekly `skill-evals` workflow runs it). Renaming or removing a skill: update `tests/evals/triggers.yaml` (its offline
  tests fail on unknown skill names). New or edited repo-owned skill descriptions start with a when-to-use phrase
  ("Use when ...") and name look-alike skills they are not for; validate.py warns otherwise.
- Changes to `settings/permissions*.json` widen what agents may run unprompted on every machine that merged
  them; explain each rule in the PR. Keep `permissions.json` read-only: an allow rule covers every flag of its
  command, so a flag that would let it run a program or write a file needs an ask rule in the same file (ask wins).
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
scripts/run-tests.sh                 # bats + pytest suites, bash -n, shellcheck (attribution guard included), pwsh checks
                                     # (needs bats, pytest; pwsh + PSScriptAnalyzer for the Windows installer checks)
scripts/test-skill-examples.sh       # code blocks of the skills in tests/skill-examples.json (pwsh + Pester 6, shellcheck, yamllint)
sh plugins/yaml-hooks/tests/test-hook.sh   # yamllint hook (also run by run-tests.sh); lint cases skip without yamllint
python3 scripts/eval-triggers.py --dry-run # triggers.yaml valid, commands print; no model calls
sh tools/attribution-guard/tests/run-tests.sh
python3 tools/attribution-guard/azure-devops/gen.py --check   # regenerate with gen.py after editing ado-pr-guard.sh, match.awk or patterns.ere
bash tools/attribution-guard/azure-devops/tests/run-tests.sh && bash tools/attribution-guard/azure-devops/tests/run-dispatch-tests.sh
for f in install.sh install-copilot.sh scripts/*.sh; do bash -n "$f"; done   # `bash -n a b` checks only a
shellcheck -e SC2016 install.sh install-copilot.sh scripts/*.sh plugins/yaml-hooks/scripts/*.sh plugins/yaml-hooks/tests/*.sh \
  tools/attribution-guard/*.sh tools/attribution-guard/dispatch tools/attribution-guard/tests/*.sh \
  tools/attribution-guard/azure-devops/*.sh tools/attribution-guard/azure-devops/tests/*.sh .githooks/*   # every severity but SC2016
claude plugin validate plugins/<changed-plugin>   # if the claude CLI is available
```
Commit a regenerated `SKILLS.md` together with the change that caused it.

## Portability (Claude Code + Copilot)
- Skills follow the Agent Skills spec: `name` = folder name, lowercase-hyphen, ≤ 64 chars; description ≤ 1024 chars.
- In repo-owned skills avoid Claude-only syntax (`$ARGUMENTS`, `` !`cmd` `` injection, `${CLAUDE_PLUGIN_ROOT}` in
  markdown, Workflow/Agent tool names); describe arguments in plain language and use relative paths.
- LSP servers need `extensionToLanguage` for Claude Code (`.claude-plugin/plugin.json`) and `fileExtensions` for
  Copilot (root `plugin.json`, read before `.claude-plugin/plugin.json`); keep both manifests' `name` identical.
