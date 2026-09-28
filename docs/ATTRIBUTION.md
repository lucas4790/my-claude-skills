# No AI attribution in commits and pull requests

Rule for this repository and for the owner's work: no commit, pull request, comment or merge
commit may credit an AI tool, and none may link to a chat or session. That covers co-author
trailers naming Claude or Anthropic, `noreply@anthropic.com`, `Claude-Session:` trailers, claude.ai
session, share and artifact links, and "Generated with/by Claude Code" footers. The word "claude"
itself is fine, because this repository is about Claude Code (`claude-security`, `.claude-plugin/`).
The single pattern list is [`tools/attribution-guard/patterns.ere`](../tools/attribution-guard/patterns.ere).

No single switch covers every source. The protection is layered, and each layer states what it
guarantees and where it stops.

## Where attribution comes from

| Source | Stopped by |
|---|---|
| The model writes trailers and footers because Claude Code tells it to | `attribution` setting (layer 1), hooks (layers 2–3), CI (layer 4) |
| Anthropic's hosted GitHub MCP server appends a footer to PR bodies and comments server-side, and the PR shows a "claude" app badge | deny rules on those tools (layer 2); the badge cannot be removed afterwards |
| Cloud sessions commit as `Claude <noreply@anthropic.com>`; GitHub credits every commit author as co-author of a squash merge | owner as author in cloud sessions (layer 3), identity check (layers 3–4) |
| An agent merges with its own commit message | deny rules on merge tools (layer 2), squash with PR title and empty body (layer 5), main audit (layer 4) |
| GitHub's default squash message copies branch commit messages | squash with PR title and empty body (layer 5) |
| Copilot and VS Code co-author settings | layer 1 (Copilot CLI and VS Code settings) |

## Layers

1. **Off at the source.**
   - The repository's [`.claude/settings.json`](../.claude/settings.json) sets `"attribution": {"commit": "", "pr": "", "sessionUrl": false}`. It applies locally and in single-repository cloud sessions.
   - Your own machines need the same object in `~/.claude/settings.json`, merged from [`settings/claude-guardrails.json`](../settings/claude-guardrails.json); `install.sh` / `install.ps1` set it.
   - Copilot CLI: `includeCoAuthoredBy: false` in `~/.copilot/settings.json`, set by `install-copilot.*`.
   - VS Code: `"git.addAICoAuthor": "off"` (see [`settings/vscode-settings.jsonc`](../settings/vscode-settings.jsonc)).
   - Claude Code enforces all of these; but the model still writes the text, so they are not a guarantee on their own.
2. **Agents cannot publish or merge** (`.claude/settings.json` `permissions.deny`, enforced by Claude Code).
   - Blocked: every GitHub MCP tool that creates PR, issue or comment text, merges, or commits through the API.
   - Blocked: `gh pr create/edit/merge/comment/review` and `gh issue create/edit/comment`.
   - Blocked: the ways around git hooks (`--no-verify`, `git config core.hooksPath/hook.*/--global`, `git -c`).
   - Agents push a branch and hand you a link; **you open and merge the PR yourself**.
   - A PreToolUse hook ([`claude-pretooluse.sh`](../tools/attribution-guard/claude-pretooluse.sh)) additionally blocks any Bash, PowerShell or GitHub tool call whose text matches the patterns.
3. **Git hooks.**
   - In this repository, `.githooks/commit-msg` strips attribution lines and rejects a commit authored as `noreply@anthropic.com`. `.githooks/pre-push` refuses to push commits that still carry either.
   - The SessionStart hook ([`session-start.sh`](../tools/attribution-guard/session-start.sh)) sets `core.hooksPath=.githooks`.
   - In cloud sessions the same hook makes the owner ([`cloud-author`](../tools/attribution-guard/cloud-author)) the commit author. The committer stays the cloud identity, because the environment requires it for signing, and a squash merge does not carry it to main.
   - For every repository on a machine, including work repositories: `sh tools/attribution-guard/install.sh`. With Git ≥ 2.54 it uses config-based hooks, which run next to husky, lefthook or pre-commit. Older Git gets a chaining dispatcher. `install.sh` / `install.ps1` run it for you.
4. **CI.**
   - [`attribution-guard.yml`](../.github/workflows/attribution-guard.yml) (`pull_request_target`, so a PR cannot change the check that judges it):
     - strips attribution lines from the PR description;
     - then fails the `attribution-guard` check on any hit in the title, description, commit messages or commit authors.
   - [`attribution-audit.yml`](../.github/workflows/attribution-audit.yml):
     - fails loudly when attribution lands on main (red X and failure e-mail);
     - strips it from new comments and reviews;
     - has a manual **cleanup** run for existing PRs, comments and workflow runs.
5. **GitHub settings** ([`scripts/github-hardening.sh`](../scripts/github-hardening.sh), run once with an admin `gh` login):
   - squash-only merges, with the PR title as squash title and an empty squash body;
   - `attribution-guard` required;
   - the `Default` ruleset pointed at main with squash-only PRs;
   - merged branches deleted.

## What is guaranteed, and what is not

- **main**: with layers 2 and 5 in place, the only way to put text on main is a human squash merge, whose message is the PR title plus an empty body. The PR title is checked by the required `attribution-guard` check. The main audit catches anything else after the fact.
- **Your commits on any machine**: the global hooks strip or reject attribution at commit time and again at push time. `--no-verify` skips commit-msg but not pre-push. A repo-local `hook.<name>.enabled=false` or `core.hooksPath` can switch them off in one repository; agents are denied those commands here.
- **PR text and comments**: prevention works while agents cannot post (layer 2) and you write PRs yourself. Anything posted anyway is stripped by CI within seconds. But GitHub has already sent notifications, and edit history keeps the old revision until you delete it by hand (the edited label on the PR, then delete the revision).
- **Not available on a personal repository**: GitHub's "Restrict commit metadata" rules, which reject commit messages or author e-mails on push, are GitHub Enterprise only. Push rulesets apply only to private or internal repositories.

## Cloud sessions (claude.ai/code, mobile, routines): known limits

- **Branch names.** The working branch is always `claude/...` and git can push only to that branch. The name shows on the PR page. Rename the branch in GitHub (Branches, then the pencil icon) before you open the PR. Squash merges keep it out of main's history.
- **Committer.** Branch commits show "Claude committed" on the PR's Commits tab. The squash commit on main is authored by you and committed by GitHub.
- **Multi-repository sessions** read only plugin settings from `.claude/settings.json`: no attribution setting, no deny rules, no hooks. Do this work in single-repository sessions. Also set these on the cloud environment (claude.ai, Environment settings, Environment variables):
  - `CLAUDE_CODE_SUPPRESS_SESSION_ATTRIBUTION=1` (undocumented, drops session links);
  - `GIT_AUTHOR_NAME` and `GIT_AUTHOR_EMAIL` (your GitHub noreply address).
- **Never** use Auto-fix or `/code-review ultra --post` on these repositories. Both post "Claude Code" labels that cannot be turned off.
- For work repositories where even this is too much, run Claude Code locally, or through Remote Control with `attribution.sessionUrl: false`, instead of in the cloud.

## Existing history

- PR descriptions and comments:
  - Run **Actions → Attribution audit → Run workflow** once; tick *delete runs* to also delete workflow runs whose commit message carries attribution.
  - Then remove the old revisions by hand in each PR's edit history.
  - PRs #12 and #13 keep the app badge; only GitHub Support can delete a PR.
- Commits already on main still carry trailers from before this guard. Rewriting main (`git filter-repo --message-callback` and a force-push) cleans `git log main`. It does not remove the old commits from GitHub: every `refs/pull/N/head` still references them, and `/commit/<sha>` pages stay reachable. Weigh that before rewriting.
