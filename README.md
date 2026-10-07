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

The script installs Claude Code itself if missing, then the marketplace and plugins, then the tools the selected plugins need — only when absent (yamllint also when it is older than 1.30):

| Tool | Needed by | Linux | Windows |
|---|---|---|---|
| git, curl, jq, Node.js | marketplace clone, manifest parsing, caveman hooks | apt / dnf / brew | winget |
| agent-browser + Chrome (+ system libs on Linux) | `agent-browser` | npm, `agent-browser install --with-deps` | npm |
| uv | `spec-kit` | astral.sh installer | astral.sh installer |
| PowerShell 7 + PSScriptAnalyzer + Pester 6 (on Windows next to its built-in Pester 3.4) | `powershell` | snap / brew / dotnet tool | winget |
| .NET 10 SDK | `dotnet` (Roslyn C# LSP) | apt / brew / dotnet-install.sh | winget |
| pyright | `pyright-lsp` | npm | npm |
| yaml-language-server | `yaml-lsp` | npm | npm |
| yamllint ≥ 1.30 | `yaml-hooks` | pipx / uv tool / apt / dnf / brew / pip --user; an older one is replaced through pipx or uv, else a warning | uv tool (no winget package; uv from winget if missing), which also upgrades an older one; a warning if an older one stays first on PATH |
| docker (checked, not installed) | `terraform` MCP server | — | — |

If the Claude desktop app (macOS/Windows) is also installed, the script says so and asks before
proceeding, since installing plugins still needs the CLI even then — the desktop app has no
plugin-install command of its own, but reads the same `~/.claude/plugins` the CLI writes to, so
one install reaches both. Set `MY_CLAUDE_SKILLS_YES=1` to skip that prompt (e.g. for automation); with no
terminal to ask on (a piped run without a tty), `install.sh` stops and says so.

Pass plugin names to install a subset (`./install.sh dotnet powershell`, `.\install.ps1 dotnet, powershell`) or the profiles of [`profiles.json`](profiles.json) (table below): `./install.sh --profile cloud,dotnet`, `.\install.ps1 -Profile cloud, dotnet`, piped `curl -fsSL https://raw.githubusercontent.com/lucas4790/my-claude-skills/main/install.sh | bash -s -- --profile cloud,dotnet`, and, where `irm | iex` takes no arguments, `$env:MY_CLAUDE_SKILLS_PROFILE = 'cloud,dotnet'; irm https://raw.githubusercontent.com/lucas4790/my-claude-skills/main/install.ps1 | iex` (only there: a plain `.\install.ps1` ignores the variable; it stays set in the session, so `Remove-Item Env:MY_CLAUDE_SKILLS_PROFILE` before running the one-liner for every plugin after an `install-copilot.ps1` run, which reads it too). Profiles and plugin names combine, `claude-only` is a profile like the others here, and an empty value or an unknown profile is an error before any plugin is installed. Separate profile names with commas: `--profile cloud dotnet` installs the profile `cloud` and the plugin `dotnet` (the installer warns when a plugin name is also a profile name). Only the selected plugins' tools are installed. What the auto-updater below does with plugins added later depends on that choice (see there). Re-running is safe. `install.sh` and `.\install.ps1` exit 1 when a plugin failed to install; under `irm | iex` the script only warns and never closes the PowerShell window. Or do it by hand:

```bash
claude plugin marketplace add lucas4790/my-claude-skills
claude plugin install <plugin>@my-claude-skills
```

The script also registers a `SessionStart` hook in `~/.claude/settings.json` (Windows: `%USERPROFILE%\.claude\settings.json`; `CLAUDE_CONFIG_DIR` if set) that runs its copy of `scripts/update-plugins.sh` / `.ps1` (the clone's when the installer runs from a clone, else `main`'s) in the background: it refreshes the marketplace, updates the installed plugins and installs only the plugins added to the marketplace since its previous run (it keeps the names it has seen in `plugins/my-claude-skills-known-plugins` in the Claude config dir, one list per config dir; the list only grows, so a plugin that leaves the marketplace and comes back is not reinstalled), so a subset install stays a subset (apart from plugins added later) and an uninstalled plugin stays uninstalled. The installers write that list: the marketplace's plugins minus any whose install failed, so the next update retries those (with `--profile`, a failed plugin of the profiles; re-run the installer to retry a named one outside them, which the installer says). Where there is no list yet (installed before this change), the first run only records it, and when `claude plugin list` fails it only updates. It also refreshes its own copy from the marketplace clone (used from the next run). Throttled to once per 6 h per Claude config dir (`MY_CLAUDE_SKILLS_INTERVAL` seconds to change): the stamp is `plugins/my-claude-skills-last-run` in that config dir, next to its list, so a run in one config dir does not hold back another. The copy is in `~/.local/share/my-claude-skills/` and its log in `~/.cache/my-claude-skills/update.log` (shared by every config dir: each run starts with a line `=== <UTC time> <config dir>`); on Windows both are in `%LOCALAPPDATA%\my-claude-skills\`. Changes apply to the next session. Run it by hand with `--force` (`-Force` for the `.ps1`).

**Profiles and the updater**: with `--profile` (`-Profile`) the installer also records the profiles (`plugins/my-claude-skills-profiles` in the Claude config dir, one name per line) and a snapshot of their plugins that were handled (`plugins/my-claude-skills-profile-plugins`). From then on the updater installs a plugin that is new to that config dir only when `profiles.json` of the marketplace clone lists it in one of the recorded profiles (a plugin that `profiles.json` moves into one of them later counts as new), and logs the other new plugins once, as one line in the update log: `available (outside profiles cloud,dotnet): a, b` (install one by hand with `claude plugin install <name>@my-claude-skills`). Installed plugins are updated whatever their profile, and nothing is ever uninstalled. Running the installer again with `--profile` replaces the record, with plugin names alone leaves it as it is, and without arguments installs everything and removes it. Without a record every new plugin is installed, as before: delete the two files to stop following profiles without reinstalling. When every plugin of the profiles failed to install, the snapshot file is left empty and the updater installs them. When none of the recorded profiles is in `profiles.json` any more (renamed), or the file is unreadable, the updater installs nothing new and decides nothing until it can tell.

**Upgrading an older install**: the installer copies the updater once, so a machine installed before the updater learned to refresh itself runs a frozen copy of the old one (it has no `known-plugins` in it). That copy never refreshes and still installs every marketplace plugin that is missing, so a subset grows to the full set and an uninstalled plugin comes back. Re-run the installer once (with the same plugin names if you installed a subset; it overwrites the copy and does not register the hook twice), or copy the marketplace clone's updater over the installed copy: `~/.claude/plugins/marketplaces/my-claude-skills/scripts/update-plugins.sh` to `~/.local/share/my-claude-skills/update-plugins.sh`, on Windows `%USERPROFILE%\.claude\plugins\marketplaces\my-claude-skills\scripts\update-plugins.ps1` to `%LOCALAPPDATA%\my-claude-skills\update-plugins.ps1`. Then uninstall the plugins you do not want: the new updater's first run records the marketplace's plugins as known and does not bring them back. To follow profiles on an existing install, re-run the installer with `--profile`: it records them and keeps what is installed (uninstall the plugins you do not want yourself), and from then on the updater installs only new plugins of those profiles.

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
| `cloud` | terraform, azure-agent-skills, pyright-lsp, component-documentation, mattpocock-skills, powershell, feature-dev, spec-kit, yaml-lsp | yes |
| `dotnet` | dotnet, dotnet-aspnetcore, dotnet-test, dotnet-data, dotnet-nuget, dotnet-advanced, csharp-patterns | no |
| `extras` | anthropic-skills, codebase-onboarding, agent-browser, caveman (skipped by the Copilot installers on native Windows: POSIX-only hooks) | no |
| `claude-only` | claude-security, commit-commands, code-modernization, pr-review-toolkit, yaml-hooks | never (name them explicitly to force) |

`install.sh` / `install.ps1` take the same names (`--profile`, `-Profile`; see Install) and have no default profile: without arguments they install every plugin. They differ from `install-copilot.*` in three ways: plugin names are added to the profiles (there, naming plugins replaces the profiles), repeated `--profile` values are joined (there, the last one wins), and `claude-only` and caveman are installed like any other plugin (there, `claude-only` is skipped and caveman is skipped on native Windows). Moving a plugin to another profile in `profiles.json` makes it new for the Claude config dirs that follow the profile it moved into.

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

[`settings/permissions.json`](settings/permissions.json) is a curated list of **read-only** inspection commands — `git status`, `git fetch`, `gh pr view`, `az … show`/`list`, `kubectl get`/`describe`/`logs`, `helm list`/`status`/`get`, `terraform plan`/`validate`/`show`, `jq` — so Claude Code stops asking for those. It has no broad wildcards (`az *`, `kubectl *`, `git *`) and no rule for `git diff`/`log`/`show`/`blame`: Claude Code's built-in read-only check already runs their plain forms without asking and asks for the rest (`--output=FILE`, also quoted or passed through `xargs`). Some commands are allowed only in exact forms: `git fetch` as `git fetch`, `git fetch origin`, `git fetch --prune`, `git fetch origin --prune` and `git fetch --all --prune` (`--upload-pack=<command>` runs a command), `terraform fmt` as `terraform fmt -check` with `-diff` and/or `-recursive` (a later `-check=false` makes it rewrite files), and `terraform providers` without a subcommand (`lock`/`mirror` write files).

The other rules end in `*` and cover every flag of their command. For the flags that would let one of these reads run a program, send your cluster credentials elsewhere or write a file, the file has `permissions.ask` rules, and an ask rule wins over an allow rule: `--kubeconfig` for kubectl and helm (a kubeconfig's `exec` credential plugin runs a program), `kubectl --server`/`-s` and `helm --kube-apiserver` (send the kubeconfig's credentials, such as an exec plugin's token, to another API server), `helm --kube-token`, `kubectl --cache-dir`/`--profile` (`--profile` writes `./profile.pprof`; the rule also matches `--profile-output`), `helm --post-renderer`/`--output-dir`/`--repository-cache`/`--repository-config`/`--registry-config`/`--dependency-update`, and `terraform plan -out`/`-generate-config-out`. **These ask rules are a backstop, not a boundary.** Claude Code matches a rule against the command text as written (whitespace collapsed, quotes and backslashes kept), and an allow rule ending in `*` also matches its command run through `xargs`. A quoted or escaped flag (`--ser"ver"=…`, `--kube\config=…`), a combined short flag (`-As <server>`) or flags passed through `xargs` therefore get past the ask rules and run unprompted.

Residual risks of the rules that stay, accepted on purpose:

- A disguised `--kubeconfig` runs the `exec` plugin of any kubeconfig, for example one in the clone; a disguised `--server` or `--kube-apiserver` sends your cluster token to another server; a disguised write flag writes a file.
- `terraform plan` runs the configuration's providers and `external` data sources against the configured backend (it does not apply), so in a clone you do not trust it runs that clone's code. `terraform validate`/`show`/`state show` start the provider plugins that `terraform init` put in `.terraform/`. Remove `Bash(terraform plan *)` from your settings if Claude Code opens Terraform code you would not run yourself.
- Reads can print secrets into the session (`kubectl get secret -o yaml`, `helm get values`, `terraform show`/`output`), and `jq *` reads any file you can read; `jq *` stays because `az … | jq` pipes need every segment allowed.
- `git fetch` talks to the network (it writes only `.git/`).
- Shell redirection is checked apart from the rules: Claude Code 2.1.284 (tested) asks before `> file`, `>|` or `&>` writes a file after an allowed command, and in `acceptEdits` mode allows it inside the working directory like any edit. A Claude Code version without that check would let `jq . a > b` or `kubectl get pods > file` write a file after any rule here.

The rule for changing the list: an allow wildcard belongs in `permissions.json` only if its residual risk is documented here and in the file's `$comment`, and a rule whose flags can run a program from the clone belongs in `permissions-trusted-repo.json`.

[`settings/permissions-trusted-repo.json`](settings/permissions-trusted-repo.json) is a second, separate list of build, test, lint and render commands (`dotnet build`/`test`/`format --verify-no-changes`, `python -m pytest`/`unittest`, `npm test`, `npm run lint`, `helm template`). Every one of them can execute code from the clone (MSBuild targets, `conftest.py`, `package.json` scripts, the program a `helm template --post-renderer` names), which in an untrusted repository is arbitrary code running unprompted. Merge it only on machines where every clone Claude Code opens is one you trust.

The installer does **not** apply either file: widening what Claude may run without asking is a decision to make deliberately, per machine, after reading the list. To merge the read-only list (its allow and ask rules) into `~/.claude/settings.json` (`$CLAUDE_CONFIG_DIR/settings.json` if set) yourself: a union, existing entries first, nothing else touched. A missing or empty file starts as `{}`, a symlinked one is written through, and a file that is not plain JSON (comments, a trailing comma) is left as it is with an error. On Windows, run the snippets from Git Bash, where `~/.claude` is `%USERPROFILE%\.claude`, or from WSL with the `f=` line changed to `f=/mnt/c/Users/<you>/.claude/settings.json`.

```bash
f=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json
src=$(mktemp) && out=$(mktemp) &&
  curl -fsSL https://raw.githubusercontent.com/lucas4790/my-claude-skills/main/settings/permissions.json -o "$src" &&
  mkdir -p "$(dirname "$f")" && touch "$f" &&
  jq -s --slurpfile p "$src" '(.[0] // {}) | reduce ("allow", "ask") as $k (.;
      (.permissions[$k] // []) as $a
      | .permissions[$k] = $a + (($p[0].permissions[$k] // []) | map(select(. as $x | $a | index($x) | not))))' \
    "$f" > "$out" && cat "$out" > "$f" || echo "error: $f not merged" >&2
rm -f "$src" "$out"
```

Same merge for the trusted-repo list, if you want it:

```bash
f=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json
src=$(mktemp) && out=$(mktemp) &&
  curl -fsSL https://raw.githubusercontent.com/lucas4790/my-claude-skills/main/settings/permissions-trusted-repo.json -o "$src" &&
  mkdir -p "$(dirname "$f")" && touch "$f" &&
  jq -s --slurpfile p "$src" '(.[0] // {}) | (.permissions.allow // []) as $a
    | .permissions.allow = $a + ($p[0].permissions.allow | map(select(. as $x | $a | index($x) | not)))' \
    "$f" > "$out" && cat "$out" > "$f" || echo "error: $f not merged" >&2
rm -f "$src" "$out"
```

The merge only adds rules. If you merged an earlier version of the read-only list, remove the rules it no longer has, then merge it again for the exact and ask rules (and the trusted-repo list too if you use it, since this also removes `Bash(helm template *)`, which moved there):

```bash
f=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json
out=$(mktemp) &&
  jq -s '(.[0] // {}) | if .permissions.allow then .permissions.allow -= ["Bash(git diff *)", "Bash(git log *)",
      "Bash(git show *)", "Bash(git blame *)", "Bash(git fetch *)", "Bash(helm template *)",
      "Bash(terraform fmt -check *)", "Bash(terraform fmt -diff *)", "Bash(terraform providers *)"] else . end' \
    "$f" > "$out" && cat "$out" > "$f" || echo "error: $f not changed" >&2
rm -f "$out"
```

Changes to either list are part of reviewing this repo: a PR that adds a rule here is a PR that changes what runs unprompted on every machine that merged it.

### Guardrails (opt-in, manual, recommended)

[`settings/claude-guardrails.json`](settings/claude-guardrails.json) adds `permissions.ask` rules for git commands
that change history, config or remotes (`git push`, `reset`, `clean`, `config`, `git -c …`, `remote add`/`set-url`,
also in their `git -C <dir> …` form, and the same rules for the PowerShell tool, where `git -c` asks only for
`core.hooksPath` and `hook.*` because PowerShell rules ignore case) plus two `env` pins. Ask rules win over allow rules **and over a skill's
`allowed-tools`**, and match past a leading `VAR=value`, so Claude still asks before these even inside a skill that
pre-approves `Bash(git *)`, as `claude-security` does. Since 0.12.0 Claude may start that skill on its own. The
`env` pins keep `code-modernization`'s function-hook module off (`CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=0`, even if
Anthropic's rollout flag enables it) and turn off its usage counts (`CODE_MODERNIZATION_TELEMETRY=0`). Side
effect: `/commit-push-pr` now asks before pushing. It also switches off AI attribution (`attribution`: no co-author trailers, PR footers or session links; see
[`docs/ATTRIBUTION.md`](docs/ATTRIBUTION.md)). Merge (union for `ask`, existing `env` values win, `attribution` is set):

```bash
f=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json
src=$(mktemp) && out=$(mktemp) &&
  curl -fsSL https://raw.githubusercontent.com/lucas4790/my-claude-skills/main/settings/claude-guardrails.json -o "$src" &&
  mkdir -p "$(dirname "$f")" && touch "$f" &&
  jq -s --slurpfile g "$src" '(.[0] // {}) | (.permissions.ask // []) as $a
    | .permissions.ask = $a + ($g[0].permissions.ask | map(select(. as $x | $a | index($x) | not)))
    | .env = ($g[0].env + (.env // {}))
    | .attribution = $g[0].attribution' "$f" > "$out" && cat "$out" > "$f" || echo "error: $f not merged" >&2
rm -f "$src" "$out"
```

Like the snippets under [Permissions baseline](#permissions-baseline-opt-in-manual), it starts a missing or empty file as `{}`, writes through a symlink and leaves a file that is not plain JSON alone with an error. On Windows the file is `%USERPROFILE%\.claude\settings.json`; run it from Git Bash, or from WSL with the `f=` line changed to `f=/mnt/c/Users/<you>/.claude/settings.json`.

#### Cloud guardrails (opt-in, manual)

[`settings/cloud-guardrails.json`](settings/cloud-guardrails.json) is a second, separate file of `permissions.ask` rules for work on production clusters and subscriptions. It asks before the Terraform, kubectl, helm and az commands in the table below, which change something or print secret values or tokens; the verb lists are a sample, not every verb of these tools (see the backstop paragraph). It only adds ask rules (nothing in it allows or denies anything), so merging it never widens what Claude may run. It is for Claude Code only, also in VS Code's **Claude** session target (Copilot CLI and VS Code's Copilot sessions do not read it), and every rule is also there for the PowerShell tool (`PowerShell(...)`; rules there ignore case).

A sentence in [`settings/user-instructions.md`](settings/user-instructions.md) shapes what Claude tries; an ask rule is enforced by Claude Code. It wins over allow rules, over a skill's `allowed-tools` and over a `Bash(terraform *)` you approved once, it prompts in every permission mode (`dontAsk` mode and `claude -p` refuse the call instead of prompting), and it matches past a leading `VAR=value`, `timeout`/`time`/`nice`/`nohup`/`command` and a bare `xargs`, in every part of a `&&`, `;` or `|` chain. Every verb has two rules, `terraform apply *` and `terraform -* apply *`, so flags before the verb are covered too: `terraform -chdir=infra apply`, `kubectl --context prod -n x delete pod y`, `helm --kube-context prod upgrade r c`. A verb of two words (`helm get values`, `kubectl rollout restart`, `kubectl config use-context`) also matches with flags between its words (`helm get -n x values r`); Terraform takes no flags there. `az` has its verb after a group path, so `az * delete *` covers `az group delete`, `az aks nodepool delete` and the rest.

| Tool | Asks before it changes something | Asks before it prints secrets or tokens |
|---|---|---|
| `terraform` | `apply`, `destroy`, `refresh`, `import`, `taint`, `untaint`, `force-unlock`, `state rm`/`mv`/`push`, `workspace new`/`select`/`delete` | `state pull`, `output -json`/`-raw`, `show -json` |
| `kubectl` | `apply`, `create`, `delete`, `replace`, `edit`, `patch`, `scale`, `autoscale`, `set`, `label`, `annotate`, `taint`, `cordon`, `uncordon`, `drain`, `expose`, `run`, `rollout restart`/`undo`/`pause`/`resume`, `exec`, `cp`, `debug`, `port-forward`, `config use-context`/`set*`/`unset`/`delete-*`/`rename-context` | `get` with `secret` anywhere in the command, `config view --raw` or `--flatten` |
| `helm` | `install`, `upgrade`, `uninstall`, `delete`, `rollback`, `push`, `plugin install`/`update` | `get values`/`manifest`/`hooks`/`all` |
| `az` | `create`, `delete`, `update`, `set`, `add`, `remove`, `reset`, `start`, `stop`, `restart`, `deallocate`, `scale`, `upgrade` (the CLI's own too), `purge`, `recover`, `restore`, `import`, `move`, `assign`, `invoke`, `run`, `deploy`, `pipelines build queue`, `create-for-rbac`, `get-credentials`, `update-credentials`, `rotate-certs`, `enable-addons`, `disable-addons`, `delete-machines`, `set-policy`, `delete-policy`, `login`, `rest` | `keyvault secret show`, `keyvault secret download`, `account get-access-token`, `list-keys`, `keys list`, `credential show`, `appsettings list`, `acr login --expose-token` |

Every rule asks and none denies: you run each of these commands yourself, and a deny would also block them when you ask Claude for exactly that action. To turn one into a hard block, copy its rule into `permissions.deny` in your own settings. Merge (union for `ask`, existing entries first):

```bash
f=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json
src=$(mktemp) && out=$(mktemp) &&
  curl -fsSL https://raw.githubusercontent.com/lucas4790/my-claude-skills/main/settings/cloud-guardrails.json -o "$src" &&
  mkdir -p "$(dirname "$f")" && touch "$f" &&
  jq -s --slurpfile g "$src" '(.[0] // {}) | (.permissions.ask // []) as $a
    | .permissions.ask = $a + ($g[0].permissions.ask | map(select(. as $x | $a | index($x) | not)))' \
    "$f" > "$out" && cat "$out" > "$f" || echo "error: $f not merged" >&2
rm -f "$src" "$out"
```

It has the same guarantees and the same Windows note as the snippet above. To drop a rule you find too noisy, delete it from `~/.claude/settings.json` (or in `/permissions`); a later merge adds it back.

**Overlap with `permissions.json`.** An ask rule wins over an allow rule, so if you merged the [read-only list](#permissions-baseline-opt-in-manual) too, these four of its allow rules now ask for the forms that print secrets, and nothing else changes (`tests/test_settings.py` checks that no other allow rule is touched):

| Allow rule | Now asks for | Still runs unprompted |
|---|---|---|
| `kubectl get *` | a `kubectl get` with `secret` in it: `secret`, `secrets`, `cm,secret`, `--raw /api/v1/…/secrets`, and a name such as `secretproviderclass` | `kubectl get pods`; `kubectl describe secret` (names and sizes, no values) also stays allowed, by its own rule `kubectl describe *` |
| `helm get *` | `helm get values`, `manifest`, `hooks`, `all` (also `helm get -n x values r`) | `helm get notes`, `helm get metadata` |
| `terraform output *` | `terraform output -json`, `-raw` | `terraform output` (the list redacts sensitive values), `terraform output <name>` (a named output can print a sensitive value; no rule can tell its name from an ordinary one) |
| `terraform show *` | `terraform show -json` | `terraform show`, `terraform show <plan>` |

**A backstop, not a sandbox.** Claude Code matches a rule against the command text as written, so these spellings get past it: a quoted or escaped verb (`kubectl 'delete'`), `bash -c '…'`, `sh -c`, `eval`, `xargs` with flags (`xargs -n1 kubectl delete`; a bare `xargs` is matched), a verb that comes from the environment or a default value (`terraform $VERB`, `${V:-apply}`), an alias or shell function, a path-qualified or `.exe` tool (`./terraform apply`, `/usr/bin/kubectl delete`, `terraform.exe apply`), a wrapper that Claude Code does not strip (`sudo`, `env`, `watch`), an upper-case spelling in Bash (`kubectl get Secret`) and a tool that is not listed (`tofu`, `argocd`, `flux`). A verb that is not in the table is not asked about either: the lists are a sample, and `az` alone has far more verbs than any list here. Known gaps are `terraform test`, `terraform init -migrate-state`, `terraform state replace-provider`, `helm test`, `kubectl attach`, `kubectl proxy`, `kubectl auth reconcile`, `kubectl certificate approve` and az forms that print secrets, such as `storage account show-connection-string`, `storage account generate-sas` and `webapp deployment list-publishing-profiles`. A few of these Claude Code may ask about anyway (in 2.1.292 a plain `v=apply; terraform $v` was resolved and asked, which its documentation does not promise), but no rule here makes it. A `--dry-run` does not exempt a command.

**False positives** are the price of rules that stay readable: a rule matches words, not meaning. `kubectl get` asks for a name that merely contains `secret`, and `az * set *` for a resource that is literally called `set`. With flags before the verb, any later word that is a verb counts: `kubectl --context prod auth can-i create pods`, `kubectl -n x logs deploy/web -c debug` and `helm -n x diff upgrade r c` ask. Claude Code also matches each rule against the whole command line (the Bash tool, 2.1.292), so a leading wildcard reaches past a pipe or `&&`: `kubectl get pods -A | grep -i secret` and `az account show && npm run build` ask too. `tests/test_settings.py` pins each of these. For a limit that holds, give the identity Claude works with a read-only role in Azure and Kubernetes.

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
| `dotnet-aspnetcore` | [dotnet/skills](https://github.com/dotnet/skills) (official Microsoft) | ASP.NET Core skills: middleware, endpoints, real-time communication, API patterns |
| `dotnet-test` | [dotnet/skills](https://github.com/dotnet/skills) (official Microsoft) | skills and agents for running, writing, analysing and improving .NET tests: filtering, coverage, testability, MSTest |
| `dotnet-data` | [dotnet/skills](https://github.com/dotnet/skills) (official Microsoft) | .NET data access and Entity Framework Core skills |
| `dotnet-nuget` | [dotnet/skills](https://github.com/dotnet/skills) (official Microsoft) | NuGet package management: dependencies and modernization |
| `dotnet-advanced` | [dotnet/skills](https://github.com/dotnet/skills) (official Microsoft) | advanced .NET and C#: file-based C# scripts, P/Invoke, vectorization, NuGet trusted publishing |
| `azure-agent-skills` | [MicrosoftDocs/agent-skills](https://github.com/MicrosoftDocs/agent-skills) (official Microsoft) | 32 curated Azure skills — DevOps (Azure DevOps, Pipelines, Repos, Artifacts, Boards, ACR), platform (AKS, Key Vault, RBAC, Monitor, Managed Grafana, Policy, ARM, Cost, Logic Apps, Well-Architected, OpenTelemetry, Functions) and networking (VNet, DNS, Private Link, NAT, LB, App Gateway, WAF, Front Door, Firewall, Network Watcher, Bastion, VPN, DDoS). Structured Microsoft Learn indexes, not command recipes: they tell the model what to look up and fetch the live docs through the [Microsoft Learn MCP server](https://learn.microsoft.com/training/support/mcp), which the plugin bundles (`microsoftdocs`, `https://learn.microsoft.com/api/mcp`: read-only, no sign-in; Claude Code exposes it as `mcp__plugin_azure-agent-skills_microsoftdocs__*`, and the skills' `mcp_microsoftdocs:*` references resolve to it) |
| `csharp-patterns` | [Aaronontheweb/dotnet-skills](https://github.com/Aaronontheweb/dotnet-skills) | 12 curated C# design skills: coding standards, concurrency, nullable, API/type design, config, DI, serialization, project structure, packages, Testcontainers, AOT |
| `powershell` | [Misaka-Mikoto-Tech/agent-skills](https://github.com/Misaka-Mikoto-Tech/agent-skills), [github/awesome-copilot](https://github.com/github/awesome-copilot) | safe native-command invocation, quoting, escaping, encoding, `Start-Process` rules; Pester 6 testing guidelines (github/awesome-copilot), synced from awesome-copilot with local patches (`patches/pester.patch`) |
| `mattpocock-skills` | [mattpocock/skills](https://github.com/mattpocock/skills) | 24 skills (17 engineering, 7 productivity): grill-me / grill-with-docs, to-spec, to-tickets, tdd, domain-modeling, triage, implement, handoff… (`code-review` excluded in favour of `pr-review-toolkit`); run `setup-matt-pocock-skills` once per repo |
| `agent-browser` | [vercel-labs/agent-browser](https://github.com/vercel-labs/agent-browser) | browser automation CLI skill (navigate, forms, screenshots, extraction, QA); `install.sh` sets up the CLI + Chrome |
| `spec-kit` | [github/spec-kit](https://github.com/github/spec-kit) | repo-owned bootstrap skill: installs Spec Kit via `uvx`/`uv tool` and guides the `/speckit.*` workflow; the `speckit-*` skills are generated per project by the CLI |
| `component-documentation` | repo-owned | writes complete operational documentation for one infrastructure component (ingress, telemetry, alerting, security tooling, cluster services, Terraform) — purpose, architecture, deployment order, config per environment, monitoring, backup/recovery, runbooks, risks, ownership |
| `codebase-onboarding` | [eabait/codebase-onboarding-skill](https://github.com/eabait/codebase-onboarding-skill) | generates a DeepWiki-style, source-linked wiki with diagrams to learn how a repo works; `pip install -r scripts/requirements.txt` optional for deeper analysis. Upstream repo LICENSE is MIT while the SKILL.md frontmatter says Apache-2.0; both permissive |
| `terraform` | [anthropics/claude-plugins-official](https://github.com/anthropics/claude-plugins-official) (HashiCorp) | Terraform MCP server in docker: registry, provider and module docs lookup. Image pinned to 1.3.0 by sha256 digest through `patches/terraform.patch` (upstream pins the tag 0.4.0); re-pin by hand, `bump-pinned.sh` does not touch it. The server's default toolset is `registry`; the HCP Terraform tools need `--toolsets=registry,terraform` and a `TFE_TOKEN` |
| `pyright-lsp` | [anthropics/claude-plugins-official](https://github.com/anthropics/claude-plugins-official) | Python language server; `install.sh` installs `pyright`. The repo-owned root `plugin.json` is the Copilot CLI manifest (Copilot needs `fileExtensions`) |
| `yaml-lsp` | repo-owned ([redhat-developer/yaml-language-server](https://github.com/redhat-developer/yaml-language-server)) | YAML language server: syntax errors, SchemaStore schemas by file name (GitHub Actions, Azure Pipelines, GitLab CI, docker-compose, Kustomize, Helm `Chart.yaml`), schemas per file via modelines, no "Unresolved tag" errors for CloudFormation, GitLab `!reference` and Ansible `!vault`; `install.sh` installs `yaml-language-server`. `.claude-plugin/plugin.json` (Claude Code, with server `settings`) and root `plugin.json` (Copilot CLI, `fileExtensions`, no settings) |
| `yaml-hooks` | repo-owned | Claude Code `PostToolUse` hook: runs `yamllint` after every `.yaml`/`.yml` Write/Edit and adds the errors to Claude's context; the project's `.yamllint` wins over a relaxed default; Helm templates skipped; silent without `yamllint` (`install.sh` installs it), with a `yamllint` found only through a relative `PATH` entry, and for files over 256 KiB; says it is inactive when yamllint is older than 1.30, rejects the config, crashes (a config it cannot load, a file that is not UTF-8) or runs past its time limit |
| `caveman` | [JuliusBrussee/caveman](https://github.com/JuliusBrussee/caveman) | terse "caveman mode" that cuts ~65% of output tokens; `/caveman` commands + skills |

**YAML** (`yaml-lsp`, `yaml-hooks`): the language server picks schemas from [SchemaStore](https://www.schemastore.org/) by file name and downloads the catalog and schemas on first use. Kubernetes manifests are not mapped by folder: yaml-language-server 1.24 flags every valid core `apiVersion: v1` object (ConfigMap, Service, ...) with "Matches multiple schemas when only one must validate" under a `kubernetes` mapping ([#998](https://github.com/redhat-developer/yaml-language-server/issues/998)), treats Helm `values.yaml` as a manifest, and reports "Unable to load schema" for CRDs missing from the catalog. Put a modeline on the first line of a manifest instead, e.g. `# yaml-language-server: $schema=https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master/v1.34.1-standalone-strict/deployment-apps-v1.json`, or for a CRD `https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/<group>/<kind>_<version>.json`. Helm templates with `{{ }}` blocks are not YAML: the language server reports syntax errors in them (it cannot skip files), the yamllint hook skips them. Claude Code starts no plugin language servers in cloud sessions; the hook runs there too. `YAML_HOOKS_WARNINGS=1` (e.g. in `settings.json` `env`) makes the hook list yamllint warnings as well as errors. The hook needs yamllint 1.30 or newer: its default config uses the `anchors` rule (new in 1.30), and with the project's own `.yamllint` it asks `yamllint --list-files` (new in 1.29) which files that config ignores. With an older yamllint, a config yamllint rejects, a yamllint that crashes (a config it cannot load, a file that is not UTF-8) or one that runs past its time limit (15 s for the lint, 5 s each for `--list-files` and `--version`, below the hook's 30 s timeout; a yamllint wrapper that does not `exec` the real one can outlast it), the hook adds one line saying it is inactive and why. Text from yamllint reaches Claude marked as data, not instructions: at most 20 lines of 300 bytes. `install.sh` replaces an older yamllint through pipx or uv and `install.ps1` through uv; without them they warn. In Copilot the server runs without the settings above (Copilot has no `settings` field), so CloudFormation and GitLab tags may show as unresolved.

`caveman` is referenced directly from upstream (not vendored) because it is a full plugin with runtime hooks and a split MIT/BSL license. It is pinned to an exact commit `sha`; `scripts/bump-pinned.sh` proposes updates via PR.

### Listing budget

Every installed plugin costs context in every session, used or not: Claude Code lists each skill and command as one line, `- plugin:name: description`, and fits the whole listing into a character budget. Copilot CLI has a budget too (`SKILL_CHAR_BUDGET`), but its listing format and what it does over the budget were not verified, so the Copilot figures here apply Claude Code's counting rule. [SKILLS.md](SKILLS.md), section "Listing cost", counts it per profile and per plugin (`python3 scripts/gen-catalog.py` regenerates it).

| Client | Budget | Source |
|---|---|---|
| Claude Code | 1% of the context window, in characters, 8,000 when the window is unknown; each entry is cut at 1,536 characters. Claude Code 2.1.292 multiplies the window (tokens) by 4 characters for older models and 3 for newer ones: 30,000 to 40,000 for a 1M-token window, 6,000 to 8,000 for 200K | the 1%, 8,000 and 1,536 are documented; the 3 and 4 were read from the 2.1.292 binary |
| Copilot CLI | 15,000 characters (`SKILL_CHAR_BUDGET`) | the variable exists in 1.0.92; the 15,000 is the default found in 1.0.88 (`docs/ANALYSE.md`, copilot-cli-3) and was not re-verified; the listing format and the effect of going over are not verified |

Over the budget Claude Code keeps every name and drops descriptions, those of the skills you use least first, so a skill that lost its description is found by name only. `skillOverrides` does not apply to plugin skills: the plugin set is the lever. Bundled skills, your own skills and other plugins share the same budget, so a profile that fits here can still be cut.

The tables in SKILLS.md: *Characters* is the cost of the entries including the line break after each, *Names only* what is left when every description is dropped, and "157% of 15,000" the share of a budget in [`profiles.json`](profiles.json) `listingBudget` (Copilot CLI 15,000 for `cloud`, the Copilot default; Claude Code 30,000, a 1M-token window, for every profile). An entry is its qualified name, 5 characters of line overhead and its text, so these numbers (and the `[budget]` lines) are larger than the sum of the description lengths. Skills with `disable-model-invocation: true` cost nothing, agents are not counted, and `caveman` (referenced from upstream) is not measured. The tables change with every description, so two pull requests that each change one conflict in SKILLS.md: run `python3 scripts/gen-catalog.py` and commit the result (the daily sync rebuilds its pull requests from `main` the next day).

`scripts/validate.py` prints `[budget]` warnings: one line per profile over a budget (with `--diff` only when it crossed the budget or grew by more than 500 characters since the base) and, with `--diff`, one line per plugin whose cost grew by more than 500 characters, about one skill. They never change the exit code and are a cost to weigh, not a security finding; the sync job copies them into the body of a sync pull request, where "since HEAD" means the base branch. `--diff` with a range (`A..B`) has no single listing to compare with and prints one line saying so. A malformed `listingBudget` is a `✗` problem (exit 1, also with `--warn-only`), and a profile that is under no client of `listingBudget` is not checked: add a new profile there. A skill whose description plus `when_to_use` is over 1,536 characters (counted with a space between them) gets the `[description]` warning; commands are not checked for length.

To keep the cost down:

- Install only the plugins you need (see [Install](#install), with its Profiles table), and in a work repo enable only those you use there (`settings/project-plugins.json`).
- Raise the Claude Code budget in `~/.claude/settings.json`; every turn then carries a larger listing:

  ```json
  { "skillListingBudgetFraction": 0.03 }
  ```

  The fraction is the listing characters ÷ (window tokens × 4): the `cloud` profile (about 23.6K characters) needs 0.03 on a 200K window, 0.04 on a model that counts 3 characters per token. `SLASH_COMMAND_TOOL_CHAR_BUDGET` sets a fixed character count instead; Copilot CLI has `SKILL_CHAR_BUDGET`.
- `/doctor` estimates the listing cost and its biggest contributors; `/skill-doctor` (Claude Code 2.1.252 and later) shows what each skill costs and which ones you never use. Turn a plugin off with `/plugin`.

## How syncing works

- `sources.json` lists each upstream repo, the ref to track, a `trust` tier, and which paths to copy where.
- **Excluded paths and symlinks.** A path that a copy entry lists in `exclude` is removed from its destination on the next sync (it used to stay), so a folder you start excluding does not linger. That deletes whatever sits at the path, repo-owned files included, and the output of another copy entry whose `to` lies inside this entry's `to` (list that entry after this one). Nothing else changes about what the copy deletes, except that a `.git` file or folder inside the destination goes too (the upstream's `.git` is still not copied). A folder copy's `to` must be a clean path below the repo root (no empty, `.` or `..` part, no `//`; a trailing slash is fine), or the source fails with an `error:` line that says so. `sync.sh` never copies a symlink: a symlink in a folder copy, or a `from` that is one or passes through one (a trailing slash or a link in the middle does not hide it), fails that source like a patch that no longer applies (put back to the last commit, an `error:` line names the link and its target), because `cp` would follow it out of the clone and Claude Code puts a link that resolves elsewhere in the marketplace into the plugin cache as a regular file with that content. Add the link's path (relative to `from`) to `exclude` to drop it. See [SECURITY.md](SECURITY.md).
- **Stamped versions.** Claude Code keeps a plugin on the `version` of its manifest until that string changes, so a vendored plugin whose upstream manifest sets a version (`dotnet*`, `claude-security`, `code-modernization`) stays on its cached copy while upstream changes the files (sync PR #10 changed 19 agent and skill files of `dotnet-test` and left its `0.2.22` alone). After the copies and patches, `scripts/sync.sh` therefore rewrites the `version` of each manifest it vendored (`.claude-plugin/plugin.json`, Copilot's root `plugin.json`, `.codex-plugin/plugin.json`) to `<upstream version>+<7 hex>`, e.g. `0.2.22+3fa91c2` (upstream's `0.5.0+build.7` becomes `0.5.0+build.7.3fa91c2`). The hex is a SHA-256 over every file under `plugins/<name>` that git would commit (tracked or not, the executable bit included; only the `.gitignore` files in the tree apply, not an ignore rule of your own clone, so a local run and CI agree) with the manifests' `version` left out: any change to the plugin's files, a patch included, gives a new stamp, nothing else does, and a version-only bump upstream keeps the hex. Two runs or a `--locked` rebuild give the same bytes. Claude Code (checked with 2.1.292) updates an installed plugin whenever its version string differs, so only plugins whose content changed refresh on users' machines. Copilot CLI and VS Code were not tested: a client that compares versions as semver ignores build metadata (`+...`) and would keep the old copy when only the hex changes. Only the `version` value changes, the rest of the manifest is left as it was written. Not stamped: manifests without a `version` (they follow the marketplace's commits), manifests the repo owns, and plugin folders that two sources write to (`sync.sh` warns, in the sync job's log but not in the PR). A stamp is only as new as the last sync of that plugin: it does not follow a hand edit. Patches apply before the stamp, so make a patch that touches a stamped manifest against upstream's `version` value (step 1 of "Patching vendored files" leaves the stamp in: put the value back before editing); step 3's `cmp` then differs from your version in that `version` line only. The first sync after this was added refreshes each of these plugins once.
- `scripts/sync.sh` sparse-clones each source, copies the paths in (deleting anything upstream removed), applies the source's patches (below), records the synced commit in `UPSTREAM.lock.json`, then regenerates `SKILLS.md`. A source that fails (a patch that no longer applies, a path upstream removed, a copy that cannot be written) is put back to the last commit and keeps its old lock entry; the other sources still sync and the script exits 1. Flags: `--trust high|low`, `--only NAME` (a source's `name` in `sources.json`), `--locked` (rebuild from lockfile SHAs; patches apply there too). An unknown `--trust` value, an `--only` name that matches no source, or a flag without a value or with an empty one exits 2 before anything is synced. Every run also drops the lock entries of sources no longer in `sources.json` (entries of sources that `--only`/`--trust` skip stay), and a file copy whose destination is a directory (upstream turned a folder into a file) replaces that directory.
- `scripts/validate.py` checks manifests, skill frontmatter, file sizes, sha pins and catalog freshness, and scans every text file under `plugins/` for prompt-injection, exfiltration, credential-access and remote-execution patterns (`--diff REF` limits the scan to lines added since `REF`; see [SECURITY.md](SECURITY.md)); it also warns about skill descriptions that route badly (under 80 or over 1024 characters, no "Use when ..." phrase, or two skills sharing most of their distinctive words without naming each other; with `--diff` only for the SKILL.md files that changed), see [Skill trigger evals](#skill-trigger-evals).
- `.github/workflows/sync-upstream.yml` runs daily at 06:00 UTC (and on dispatch) and opens one PR per tier (`sync/high-trust`, `sync/low-trust`, the latter also carrying pinned-sha bumps) with the validator's hits for the added lines in the body; automation never pushes to `main`. Before that it runs the repo tests (`scripts/run-tests.sh`, see [Tests](#tests)) and `scripts/test-skill-examples.sh` (the code blocks of the skills in `tests/skill-examples.json`, see [Skill example tests](#skill-example-tests)) on the synced tree, as a throwaway user without the workflow token, since that tree is unreviewed upstream code; a failure goes on top of the PR (see below). Every pull request runs the validator (a high-severity hit in the added lines fails the check), the repo tests and the skill examples; one that touches `plugins/` or `.claude-plugin/` also runs `claude plugin validate`.
- Both sync PRs open with a digest of what changed (per source and plugin, new and removed skills, the skill description budget, hook, MCP and LSP registrations; `scripts/sync-digest.py`), and the low-trust PR adds what each pinned-plugin bump pulls in (`scripts/bump-pinned.sh`); [Reviewing a sync PR](SECURITY.md#reviewing-a-sync-pr) explains how to read them. After a local `scripts/sync.sh`, `python3 scripts/sync-digest.py --base HEAD` prints the digest (`--head REF` compares two refs instead of the working tree).

See [SECURITY.md](SECURITY.md) for the trust model. Run locally with `scripts/sync.sh` (needs `git`, `rsync`, `jq`, `python3`).

### A red sync run

- **PR titled "... (sync/test failure)"** with a *Sync failure*, *Repo tests failed*, *Skill example tests failed* or *Validator did not finish* section at the top and a failed `validate-pr` status: the rest of the tier synced, but the listed sources stayed at their last synced commit, a test no longer passes on the synced tree (e.g. `tests/evals/triggers.yaml` names a skill upstream renamed), or upstream now ships an example that fails. Do not merge a failing example as is: fix it with a patch (below) or drop the source.
- **Failed workflow run, no PR**: a source failed and nothing else changed. The `error:` lines of the run name the source.
- `error: patches/<name>.patch no longer applies to <source>@<sha>; refresh it (see README)`: upstream changed the lines the patch touches. Refresh the patch as below. The CI clone is shallow, so the 3-way fallback that `sync.sh` tries after a plain `git apply` only succeeds locally, where the patch's base version is in the object store.
- `error: <source>: <from>/<path> is a symlink (-> <target>); ...`, `error: <source>: <from> is a symlink ...` or `error: <source>: cannot copy <from> to "<to>": ...`: upstream added a link, or `sources.json` has a `to` that is not a clean path. Add the link's path to that entry's `exclude` (or point `from` at what the link names), or fix the `to` (see [SECURITY.md](SECURITY.md)). `error: <source>: cannot rewrite the version in <manifest>` means a vendored manifest holds a `version` that `sync.sh` cannot rewrite in place; patch the manifest or ask upstream to spell the key plainly.

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

1. Add an entry to `sources.json` with a `name` (what `--only` takes), the repo, ref, `trust` (`high` only for vendors you would run code from unreviewed), and `copy` mappings into `plugins/<name>/...` (a copy entry may list `exclude` paths, relative to `from`, and a `patch` for local changes; see "Patching vendored files").
2. If it is a bare skills folder (not a full plugin), add `plugins/<name>/.claude-plugin/plugin.json`.
3. Add a plugin entry to `.claude-plugin/marketplace.json` pointing at `./plugins/<name>`.
4. Add the plugin to exactly one profile in `profiles.json` (the validator enforces this).
5. Add a row to the [plugin table](#plugins).
6. Run `scripts/sync.sh --only <source name>`.
7. If its skills have bash, yaml, python, json or PowerShell examples worth checking, add a `report` entry for them to `tests/skill-examples.json` (see [Skill example tests](#skill-example-tests)).
8. Run `python3 scripts/validate.py`, then commit.

Removing a source or renaming one of its skills also means updating `tests/evals/triggers.yaml` (its offline tests fail on unknown skill names).

## Tests

`scripts/run-tests.sh` runs the repo's own tests and prints a summary per suite: every bats suite in `tests/bats/` (among them `sync.sh` copying, `--only`/`--trust`/`--locked`, failing sources and patches; `update-plugins.sh` and `update-plugins.ps1`; `bump-pinned.sh`; `adopt-branch.sh`; `clean-history.sh`; the `yaml-hooks` hook; `install.sh` and `install-copilot.sh` against fake `claude`/`copilot`, and `install.ps1` and `install-copilot.ps1` under pwsh with a Windows PowerShell 5.1 compatibility check; `bash -n`, shellcheck and a PowerShell parse check of the installers and scripts), `python3 -m pytest tests/` (`validate.py`, `gen-catalog.py`, the skill-example checker, the offline checks of the trigger evals and every other pytest suite under `tests/`) and shellcheck of the attribution guard's shell scripts (`tools/attribution-guard`, `.githooks` and the bash steps of its Azure DevOps pipelines). Every test works in a temp dir against local fake upstreams and fake `claude`/`copilot` binaries: no network, and neither the checkout nor `~/.claude` is touched.

Prerequisites: bats-core ≥ 1.4 and pytest (`sudo apt install bats python3-pytest`; macOS: `brew install bats-core` and `python3 -m pip install pytest`), plus git, rsync, jq and python3. shellcheck, pwsh (with Pester 6 for the skill-example checker's Pester cases and PSScriptAnalyzer for the Windows compatibility check), git-filter-repo, yamllint and PyYAML (`python3-yaml`) are optional; the tests that need them are skipped without them (`PWSH=/path/to/pwsh` for a pwsh outside PATH; `SKILL_EXAMPLES_REQUIRE_TOOLS=1`, set in CI, turns a missing tool into a failure). `BASH32=/path/to/bash-3.2` also runs the installers and the updater under macOS's bash 3.2. `scripts/run-tests.sh bats`, `pytest` or `shellcheck` runs only those kinds; `RUN_KNOWN_BUGS=1` also runs tests that document an open bug (marked with `known_bug`; they fail until it is fixed, then the marker goes).

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
shellcheck runs without `~/.shellcheckrc` and `SHELLCHECK_OPTS`, so local settings cannot change a result.
`python3 -m pytest tests/skill_examples` skips its runs of the real config unless `SKILL_EXAMPLES_REAL_CONFIG=1`
(`scripts/test-skill-examples.sh` runs it).
The Pester runner and runnable python blocks execute the examples: only run this on SKILL.md files you trust (the sync
job runs it as a throwaway user on a copy of the tree).

### Skill trigger evals

`tests/evals/triggers.yaml` holds ~50 prompts from daily cloud work (kubectl/helm, Azure DevOps, AKS, Key Vault, networking, Terraform, PowerShell/Pester, .NET tests; a few in Dutch). Each names the skills that must load (`expect`; `a|b` = either one), may load (`accept`) and must not load (`forbid`, the look-alikes); `expect: []` is a negative control. `scripts/eval-triggers.py` runs every prompt through `claude -p` with this repo's plugins (`--plugin-dir`), reads which skills the model loaded (its `Skill` tool calls in the stream-json output) and prints a pass/fail table, per-skill precision/recall and a summary.

```bash
python3 scripts/eval-triggers.py --dry-run                # validate triggers.yaml, print the commands; no model calls
python3 scripts/eval-triggers.py                          # every case (needs `claude` logged in or ANTHROPIC_API_KEY, and PyYAML)
python3 scripts/eval-triggers.py --filter pester --runs 3 # a subset, 3 runs per case (loaded = in at least half)
python3 scripts/eval-triggers.py --profile cloud          # only the plugins of one profile
python3 scripts/eval-triggers.py --listing-budget 0.03 --json out.json --markdown summary.md
```

The model can only load skills: every other tool is removed (`--tools Skill`), no MCP server starts, hooks, skill shell injection and Claude Code's bundled skills are off, and each run gets its own session, an empty working directory, `--max-turns 4` and `--max-budget-usd 0.5`; a run stops as soon as the model starts answering. Without credentials the script prints `SKIPPED` and exits 0 (3 with `--require-credentials`, which the workflow uses after its own secret check); it exits 1 when a case fails (`--no-fail` reports only) and 2 on a bad `triggers.yaml` or `--filter`. A `Skill` call the CLI rejects (an unknown name, a skill with `disable-model-invocation`) is reported, not scored; the summary counts rejected calls and unreadable stream lines. A full run costs roughly $3 with Sonnet (the skill listing is ~12k input tokens per prompt; an Azure skill adds 15-40k when it loads).

`.github/workflows/skill-evals.yml` runs it every Monday and on demand (inputs: model, filter, runs, listing budget, strict) with the `ANTHROPIC_API_KEY` secret, skips with a notice when the secret is not set, and writes the table to the run summary. It never runs on pull requests; those only run the offline checks: `tests/evals/` and the description warnings of `scripts/validate.py`.

**Skill listing budget.** Claude Code fits every skill description into about 1% of the context window. With every plugin of this repo installed the listing is ~58k characters against a 30k budget, so descriptions are cut and some skills stop loading (in the evals azure-boards, azure-private-link and run-tests loaded only with full descriptions). Install a profile instead of everything, or raise the budget in `~/.claude/settings.json`: `"skillListingBudgetFraction": 0.03`. See [Listing budget](#listing-budget).

## Licensing

Repo scaffolding (`scripts/`, workflow, manifests) is MIT. Vendored content keeps its upstream license; see the `LICENSE` and `THIRD_PARTY_NOTICES.md` files inside each `plugins/*` directory.
