# No AI attribution in commits and pull requests

Rule for this repository and for the owner's work: no commit, pull request, comment or merge
commit may carry attribution naming Claude or Anthropic, and none may link to a chat or session.
That covers co-author and other `-by:` trailers naming Claude, Anthropic or an `@anthropic.com`
address, `noreply@anthropic.com`, `Claude-Session:` trailers, claude.ai session, share, chat and
artifact links, claude.site, and "Generated/Built/... with/by/via Claude (Code)" footers. The word
"claude" itself is fine, because this repository is about Claude Code (`claude-security`,
`.claude-plugin/`). The single pattern list is
[`tools/attribution-guard/patterns.ere`](../tools/attribution-guard/patterns.ere); zero-width and
invisible characters (U+00AD, U+034F, U+180E, U+200B–U+200D, U+2060–U+2064, U+FEFF) are removed
before matching. The CI checks on GitHub and Azure DevOps share one matcher,
[`match.awk`](../tools/attribution-guard/match.awk). Copilot trailers are not in the list: the owner's rule is about Claude.

No single switch covers every source. The protection is layered, and each layer states what it
guarantees and where it stops.

## One-time steps, in this order

1. **Merge the PR that adds the guard**, with squash, using a title you write yourself. If the work
   came from a cloud session, first check out the cloud branch on your own machine and run
   `bash scripts/adopt-branch.sh <claude/branch>` from that checkout (the script is not on main
   yet), then open the PR from the new branch (see [Cloud sessions](#cloud-sessions-claudeaicode-mobile-routines-known-limits)).
2. **Then** run `bash scripts/github-hardening.sh` with an admin `gh` login. It refuses to run
   before `attribution-guard.yml` is on main, because it makes the `attribution-guard` check
   required, and that check only exists once the workflow is on the default branch. Run it
   earlier and every open PR waits forever, admins included; the script prints how to undo that.
3. **Then** run **Actions → Attribution audit → Run workflow** (tick *delete runs* to also delete
   workflow runs whose commit message carries attribution), and delete the old revisions in each
   PR's edit history by hand.
4. On every machine: run `install.sh` / `install.ps1` (Claude Code) and `install-copilot.*`
   (Copilot CLI, VS Code). After that the session-start updater keeps the guard current. On Windows the updater refreshes
   the git guard but not the Claude Code hook registration: re-run `install.ps1` after an update that
   changes the hook.
5. Cloud environment (claude.ai, Environment settings, Environment variables): see
   [Cloud sessions](#cloud-sessions-claudeaicode-mobile-routines-known-limits).
6. Work repositories on Azure DevOps: an administrator runs the setup in [Azure DevOps](#azure-devops).

## Where attribution comes from

| Source | Stopped by |
|---|---|
| The model writes trailers and footers because the tool tells it to | `attribution` settings (layer 1), hooks (layers 2–3), CI (layer 4) |
| Anthropic's hosted GitHub MCP server appends a footer to PR bodies and comments server-side, and the PR shows a "claude" app badge | deny rules on those tools (layer 2); the badge cannot be removed afterwards |
| Cloud sessions commit as `Claude <noreply@anthropic.com>`; GitHub credits every commit author as co-author of a squash merge | owner as author in cloud sessions (layer 3), identity checks (layers 3–4), `adopt-branch.sh` for the committer |
| An agent merges with its own commit message | deny rules and the strict PreToolUse hook (layer 2), squash with PR title and empty body (layer 5), main audit (layer 4) |
| GitHub's default squash message copies branch commit messages | squash with PR title and empty body (layer 5) |
| The claude.ai/code **Create PR** button | nothing local: do not use it (see cloud limits) |
| Copilot and VS Code co-author settings | layer 1 (Copilot CLI and VS Code settings) |

## Layers

1. **Off at the source.**
   - The repository's [`.claude/settings.json`](../.claude/settings.json) sets `"attribution": {"commit": "", "pr": "", "sessionUrl": false}`. It applies locally and in single-repository cloud sessions.
   - Your own machines need the same object in `~/.claude/settings.json`, merged from [`settings/claude-guardrails.json`](../settings/claude-guardrails.json); `install.sh` / `install.ps1` set it.
   - Copilot CLI: `includeCoAuthoredBy: false` in `~/.copilot/settings.json`, set by `install-copilot.*`. A repository's `.github/copilot/settings.json` can override it.
   - VS Code: `"git.addAICoAuthor": "off"` (see [`settings/vscode-settings.jsonc`](../settings/vscode-settings.jsonc)).
   - Each tool honours its own setting, but the model or agent still writes the text, so none of these is a guarantee on its own.
2. **Agents are denied the usual publish and merge tools.**
   - `.claude/settings.json` `permissions.deny` (Bash and PowerShell alike): every GitHub MCP tool that creates PR, issue or comment text, merges, or commits through the API; `gh pr create/new/edit/merge/comment/review/close/reopen/ready` and `gh issue create/new/edit/comment`; the usual spellings of hook bypasses (`--no-verify` anywhere in `git commit/merge/push`, `git commit -n`, `git config` on `core.hooksPath` or `hook.*`, `git config --global`, `git -c`; for PowerShell only `git -c core.hooksPath` and `git -c hook.*`, because PowerShell rules ignore case and `git -c *` would also deny `git -C <dir>`; the hook below covers the other keys).
   - A PreToolUse hook ([`claude-pretooluse.sh`](../tools/attribution-guard/claude-pretooluse.sh), matcher `Bash|PowerShell|Monitor|Write|Edit|MultiEdit|NotebookEdit|mcp__.*([Gg]it[Hh]ub|[Aa]do|[Aa]zure|[Dd]ev[Oo]ps).*`) sees the whole command text. It joins line continuations, ignores quotes, backslashes and backticks inside words, and finds git and gh by name even behind a path (`/usr/bin/git`, `git.exe`), so it also catches other spellings and flag orders:
     - always: `--no-verify` in any position, `commit -n`/`-nm`/`-sn`, writing `core.hooksPath` / `hook.*` / `include.path` / `attributionguard.*` config (reads pass), `-c`/`--config-env` overrides of those, `--git-dir`/`--work-tree` on a git write, `GIT_CONFIG_*` / `GIT_DIR` / `HOME` assignments or unsets and `env -i` / `env -` next to a git write (other assignments such as `GIT_AUTHOR_NAME=... git commit` pass), writes to `.git/config`, deleting or disabling hook files (also `chmod -R 644`, `chmod a=r`), and file-tool edits of `.git/config`, `.git/hooks`, `~/.gitconfig` or `~/.config/git`; and any git write command (commit, merge, push, tag, notes, rebase, am, cherry-pick, revert, commit-tree, mktag, replace, update-ref), gh pr/issue/api/release command, az repos/boards/devops/pipelines command, GitHub or Azure DevOps REST call (curl, Invoke-RestMethod) or GitHub/Azure DevOps MCP write whose text carries attribution, also when `\n`, `` `n `` or quotes split it into arguments;
     - with `--strict` (this repository only), in any flag order: `gh pr|issue create|new|edit|merge|comment|review|close|reopen|ready|update-branch|...`; `gh variable|secret set|delete`; `gh repo create|edit|delete|rename|archive|unarchive|fork|sync` and `deploy-key add|delete`; `gh workflow run|enable|disable`; `gh run delete|rerun|cancel`; `gh release create|edit|delete|delete-asset|upload`; `gh label create|edit|delete|clone`; `gh api` writes (`-X POST/PATCH/PUT/DELETE`, or fields with `-f`/`-F`/`--input`, also as `-fkey=value`; an explicit `--method GET` reads), which covers rulesets and branch protection, and GraphQL mutations or queries read from a file; and REST writes to `api.github.com`. Reads (`view`, `list`, `clone`, `gh api` GETs) pass.
     - Read-only MCP tools (`get_`, `list_`, `search_`, `_read`) are not checked. Internal errors fail open with a warning, so a broken install never blocks every tool call; the git hooks and CI stand behind it.
   - **Claude Code, every repository**: `install.sh` / `install.ps1` register the same hook (without `--strict`) in `~/.claude/settings.json`:
     ```json
     {"hooks": {"PreToolUse": [{"matcher": "Bash|PowerShell|Monitor|Write|Edit|MultiEdit|NotebookEdit|mcp__.*([Gg]it[Hh]ub|[Aa]do|[Aa]zure|[Dd]ev[Oo]ps).*",
       "hooks": [{"type": "command", "shell": "bash",
         "command": "f=\"$HOME/.config/git/attribution-guard/claude-pretooluse.sh\"; [ ! -f \"$f\" ] || sh \"$f\""}]}]}}
     ```
     It covers the Azure DevOps MCP tools, `az repos/boards/devops/pipelines` and dev.azure.com REST calls in work repositories. It does not reach cloud sessions.
   - Agents push a branch and hand you a compare link; **you open and merge the PR yourself**. A determined agent can still find a spelling no pattern catches (for example a script that writes into `.git/` with Python instead of a shell command); that is what layers 3–5 are for.
3. **Git hooks.**
   - The commit-msg hook strips attribution lines (a hit on the subject line rejects) and rejects a commit authored by an `@anthropic.com` address. The pre-push hook refuses to push commits, annotated tags (including tags wrapped in tags; more than 10 levels is refused outright) or notes (every note blob in the pushed history) that still carry attribution.
   - The pattern always comes from `patterns.ere` next to the script, never from the environment, and one that does not compile makes every check refuse, never pass. Pre-push reads the real objects (`git replace` is ignored) as UTF-8 whatever `i18n.logOutputEncoding` says.
   - Pre-push checks only what the destination does not have yet, as the remote itself advertises it (`git ls-remote`, a second connection to the remote on every push: over HTTPS without prompts and with a low-speed timeout, over OpenSSH with connect and keep-alive timeouts, though a key passphrase without ssh-agent is asked for again; a listing that fails means every commit being pushed is checked); local `refs/remotes/*` do not count, because anyone can write them, and neither does a listing that an `insteadOf` rule would fetch from another repository. So merging a colleague's commit from the same remote never blocks your push. For a fork, trust its upstream's URL once (by hand; agents are blocked from this key): `git config attributionguard.trustUrl <upstream-url>`.
   - In this repository the SessionStart hook ([`session-start.sh`](../tools/attribution-guard/session-start.sh)) copies the guard into the git directory (`.git/attribution-guard/`) and points `core.hooksPath` there as an absolute path, so the hooks keep working on a branch from before the guard and with `--git-dir` / `--work-tree`; `.githooks/` holds equivalent wrappers for manual use. A hooks path the clone already had (husky, lefthook) is saved as `attributionguard.previousHooksPath` and its hooks still run through the guard's dispatcher; another guard hooks directory (the old path of a moved or copied clone) never counts as one, so `.git/hooks` keep running there. The path is refreshed at every session start; after moving the clone, start a session (or run the script) before committing. In cloud sessions it also makes the owner ([`cloud-author`](../tools/attribution-guard/cloud-author)) the commit author.
   - Checking out a branch from before the guard also removes that branch's `.claude/settings.json` (attribution setting, deny rules, hooks) from the session; the git hooks in `.git` stay in force.
   - For your other repositories, including work repositories: `sh tools/attribution-guard/install.sh` (run by `install.sh` / `install.ps1`, refreshed by the session-start updater).
     - Git ≥ 2.54: config-based hooks. They run next to husky, lefthook or pre-commit, so every repository is covered.
     - Git < 2.54: `init.templateDir`. New clones get the hooks; run `git init` once in an existing repository to add them. Repositories that already have their own `commit-msg`/`pre-push` hook or their own `core.hooksPath` are **not** covered: upgrade Git, or call `attribution-guard.sh` from those hooks.
     - `install.sh --global-hooks-path` (Git < 2.54, opt-in) sets a global `core.hooksPath` dispatcher instead, which covers existing repositories at once but makes pre-commit, lefthook and git-lfs refuse to install their hooks. A repository's own `push-to-checkout`, `post-index-change`, `reference-transaction` and `proc-receive` hooks do not run under it. `install.sh --no-global-hooks-path` switches back.
     - Re-running `install.sh` (also the session-start updater) keeps the chosen mode and the hooks-path choice, and replaces only its own PreToolUse entry in `settings.json` (`CLAUDE_CONFIG_DIR` is honoured).
   - `git commit --no-verify` is caught again at push. `git push --no-verify`, `hook.<name>.enabled=false` (Git 2.54+), `GIT_CONFIG_*` environment variables and, on Git < 2.54, a repository's own `core.hooksPath` skip the guard entirely; agents are denied or blocked on those, and CI is the backstop.
4. **CI** (strict: text in Markdown code blocks counts too; logs name the place and line number, never the matched text, because Actions logs are public).
   - [`attribution-guard.yml`](../.github/workflows/attribution-guard.yml) (`pull_request_target`, so a PR cannot change the check that judges it):
     - strips attribution lines from the PR description;
     - then fails the `attribution-guard` check on any hit in the title, description or commit messages, and on a commit authored **or committed** by an `@anthropic.com` address. Repository variable `ATTRIBUTION_ALLOW_CLOUD_COMMITTER=true` turns the committer into a warning.
   - [`attribution-audit.yml`](../.github/workflows/attribution-audit.yml):
     - fails loudly when attribution, or a vendor author or committer, lands on main, or a pushed tag carries it (message, tagger, nested tags, tagged commit) (red X and failure e-mail). A push to main is judged with the patterns and matcher of main from before that push, so a push that weakens them is still judged by the old ones; a tag with those of main. The workflow file itself comes from the push (GitHub runs a push with the pushed workflow), so a push that also edits `attribution-audit.yml` can still change its own audit: review changes to `.github/workflows/`. A tag on a commit whose workflow file predates the tag trigger starts no run; the cleanup run lists such tags;
     - strips attribution from new issue descriptions, comments and reviews (an issue title is reported and the run fails, so you get an e-mail; commit comments start no workflow, so only cleanup covers them);
     - has a manual **cleanup** run for existing PR and issue descriptions, all comments and workflow runs, and reports every tag, lightweight or annotated, whose message, tagger, nested tags or tagged commit carries attribution (the same walk as for a pushed tag); it fails when anything could not be cleaned.
   - `validate-pr` runs the PR's own code with a read-only token and no stored credentials, so it cannot edit the PR after the check passed.
   - A required check is matched by name: a PR that adds a workflow with a job named `attribution-guard` could report it as passed. Review every change under `.github/workflows/` before merging.
5. **GitHub settings** ([`scripts/github-hardening.sh`](../scripts/github-hardening.sh), run once with an admin `gh` login, after step 1 above):
   - squash-only merges, with the PR title as squash title and an empty squash body; auto-merge off;
   - `attribution-guard` required;
   - the `Default` ruleset pointed at main with squash-only PRs, no deletion, no force-push;
   - merged branches deleted.

## What is guaranteed, and what is not

- **main**: with layers 2 and 5 in place, a merge through the GitHub UI is a squash whose message is the PR title plus an empty body, and the title is checked by the required `attribution-guard` check. A merge through `gh api` or curl can set its own message; in this repository the strict hook blocks those for agents, elsewhere only the main audit reports it afterwards.
- **Your commits on any machine**: the hooks strip or reject attribution at commit time and again at push time, within the limits in layer 3.
- **PR text and comments**: prevention works while agents cannot post (layer 2) and you write PRs yourself. Anything posted anyway is stripped by CI within seconds. But GitHub has already sent notifications, and edit history keeps the old revision until you delete it by hand (the edited label on the PR, then delete the revision).
- **Branch commits in cloud sessions** are public as soon as the session pushes them (see below); CI only checks them once a PR exists.
- **Not available on a personal repository**: GitHub's "Restrict commit metadata" rules, which reject commit messages or author e-mails on push, are GitHub Enterprise only. Push rulesets apply only to private or internal repositories.

## Cloud sessions (claude.ai/code, mobile, routines): known limits

- **Committer.** Every commit a cloud session pushes has committer `Claude <noreply@anthropic.com>` (the environment requires it for signing) and shows "Claude committed" on GitHub. The branch is public as soon as it is pushed, and once a PR references a commit it stays reachable for good. Before opening a PR from cloud work, run on your own machine, from a checkout of the cloud branch (the script brings its own copy of the guard):
  ```bash
  bash scripts/adopt-branch.sh claude/<branch> [new-branch] [base]
  ```
  It re-commits every commit on a branch of your own, with you as author and committer and attribution lines stripped, pushes it, prints the compare link and offers to delete the `claude/` branch. If it stops (for example on a rebase conflict), resolve it and run `git rebase --continue`, then run the script again with the same arguments: it resumes at the checks and the push. When the cloud branch gets more commits, run the same command again: it re-commits only the new ones on top of your branch (the last adopted cloud commit is kept in `git config branch.<new>.adoptedCommit`) and pushes them. A branch adopted with an older version of the script has no such record, so the script stops and prints the `git config` command to record it. GitHub Support can purge the old commits' cached views. Otherwise, do such work locally or through Remote Control.
- **Branch names.** The working branch is always `claude/...` and git can push only to that branch; `adopt-branch.sh` moves the work to a name of your own.
- **Create PR button.** The claude.ai/code "Create PR" button (full or draft) opens the PR as the app, with a generated title and description; no local layer sees it. Use the compare link, or the button's GitHub compose option, and write the title and description yourself.
- **Multi-repository sessions** read only plugin settings from `.claude/settings.json`: no attribution setting, no deny rules, no hooks. Do this work in single-repository sessions. Also set these on the cloud environment:
  - `CLAUDE_CODE_SUPPRESS_SESSION_ATTRIBUTION=1` (undocumented, drops session links);
  - `GIT_AUTHOR_NAME` and `GIT_AUTHOR_EMAIL` (your GitHub noreply address).
- **Never** use Auto-fix or `/code-review ultra --post` on these repositories. Both post "Claude Code" labels that cannot be turned off.
- For work repositories where even this is too much, run Claude Code locally, or through Remote Control with `attribution.sessionUrl: false`, instead of in the cloud.

## Windows

- Hook entries set `"shell": "bash"`, so Claude Code runs them in Git Bash. Without Git Bash, Claude Code falls back to PowerShell and the hooks fail open (a non-2 exit does not block); the git hooks and CI still apply.
- Where Copilot CLI on Windows picks up these hooks, it runs their command strings in PowerShell and treats a failing hook as a denial (github/copilot-cli#4001), so its tool calls in this repository may be refused. Untested; use Copilot CLI from WSL or Git Bash for this repository if that happens.
- `.gitattributes` pins the scripts to LF; the installers also strip CR from the copies they install, so a CRLF checkout cannot break them.

## Azure DevOps

Work repositories on Azure Repos get the same protection server-side, from
[`tools/attribution-guard/azure-devops/`](../tools/attribution-guard/azure-devops/). Locally, the
global git hooks and the user-level PreToolUse hook (layers 2–3) already cover `git`, `az repos`,
the Azure DevOps MCP server and dev.azure.com REST calls.

- **Layer 0, push time**: repository policy *Commit author email validation* with your company
  domain (`*@contoso.com`). A commit authored by any other address, the vendor's included, is
  rejected on push. Do not add `noreply@dev.azure.com` or `*@anthropic.com`.
- **Layer 1, PR time**:
  - squash-only merges (*Limit merge types*);
  - required build validation [`pipelines/attribution-guard.yml`](../tools/attribution-guard/azure-devops/pipelines/attribution-guard.yml) (copy to the work repository as `.azure-pipelines/attribution-guard.yml`). It checks the PR title, description (after stripping attribution lines), the auto-complete merge message, every commit message, author and committer, and every comment. Patterns come from the target branch, never from the PR;
  - a required reviewer for changes to the guard files;
  - [`pipelines/attribution-audit.yml`](../tools/attribution-guard/azure-devops/pipelines/attribution-audit.yml) on every push to main (batched, one run at a time): checks every commit since the one the last run that finished the check covered (runs are tagged `attribution-audited`), with the patterns of that commit, so it catches a merge message edited in the completion dialog and pushes by people with bypass rights (detection only). It fails closed when that commit is gone (force-push) or beyond the fetched history. Its trigger names `main`; change it for another protected branch. Limit: Azure runs CI with the YAML of the pushed commit, so a push by someone with bypass rights can change the audit itself; review changes to `.azure-pipelines/`.
- **Layer 2, text edits and comments** (build validation only re-runs on pushes): the status and
  sweep pipelines run from a protected guard project that imports this repository. Service hooks
  on *PR created/updated/commented* trigger a check that posts the required status
  `attribution-guard/no-ai-attribution`; only statuses from the guard project's build service
  count. A sweep re-checks every active PR twice an hour. That identity needs "View project-level
  information" on the work project and Read plus "Contribute to pull requests" on the work
  repository; without them the status never succeeds and every PR stays blocked.
- **Setup**: an administrator reviews and runs
  ```bash
  ORG_NAME=contoso WORK_PROJECT='Work Project' WORK_REPO=work-repo \
  AUTHOR_EMAIL_PATTERNS='*@contoso.com' REVIEWER=you@contoso.com \
  GUARD_PROJECT=Guard DRY_RUN=1 bash tools/attribution-guard/azure-devops/setup-azure-devops.sh
  ```
  first with `DRY_RUN=1`, then without. It also limits pipeline job tokens to their own project
  and prints the settings it cannot make: forks off, no bypass permissions for contributors,
  Deny on *Create tag* and *Manage notes* for contributors, agents on Code (Read) and Work Items
  (Read) only, and no auto-complete with a prepared merge message. The script is not tested
  against a live organization.
- The pipelines are generated from `ado-pr-guard.sh`, `patterns.ere` and `match.awk` by `gen.py` (`python3 gen.py --check` in CI);
  tests run the guard and every pipeline step against a mock of the Azure DevOps REST API.

## Existing history

- PR descriptions and comments: step 3 of the one-time steps. PRs #12 and #13 keep the app badge; only GitHub Support can delete a PR.
- Commits already on main still carry trailers from before this guard. Rewriting main cleans `git log main`: [HISTORY-CLEANUP.md](HISTORY-CLEANUP.md) is the step-by-step procedure (Dutch), and [`scripts/clean-history.sh`](../scripts/clean-history.sh) rewrites a bare clone with `git filter-repo` (the guard's own strip mode for messages, a mailmap for identities), verifies it and prints the push commands; it never pushes. Do it before one-time step 1 and 2 if you can. It does not remove the old commits from GitHub: every `refs/pull/N/head` still references them, and `/commit/<sha>` pages stay reachable until GitHub Support purges them. After `github-hardening.sh` the `Default` ruleset refuses force-pushes for everyone: disable the ruleset (and allow force-pushes in branch protection) first, force-push, then run the script again. Weigh all that before rewriting.
