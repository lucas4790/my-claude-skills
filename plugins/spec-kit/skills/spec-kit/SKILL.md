---
name: spec-kit
description: Set up and drive GitHub Spec Kit (Spec-Driven Development) in a project. Use when the user mentions Spec Kit, spec-driven development, SDD, `specify init`, or any `/speckit.*` command, or wants a constitution → spec → plan → tasks → implement workflow. Spec Kit's own `speckit-*` skills are generated per project by its CLI; this skill installs them and explains the order to run them in.
---

# Spec Kit

Spec Kit is a CLI (`specify`) that scaffolds a `.specify/` directory and a set of `speckit-*` skills (or `/speckit.*` slash commands) into a project. The generated content is versioned with the CLI, so always let the CLI produce it rather than copying files by hand.

## 1. Check whether the project already has Spec Kit

```bash
ls .specify 2>/dev/null && ls .claude/skills 2>/dev/null | grep speckit
```

If `.specify/` and `speckit-*` skills exist, skip to step 3.

## 2. Install and initialise

Requires `uv` (https://docs.astral.sh/uv/) and `git`.

```bash
# one-off, no install:
uvx --from git+https://github.com/github/spec-kit.git specify init --here --integration claude --integration-options="--skills"

# or install the CLI persistently, then:
uv tool install specify-cli --from git+https://github.com/github/spec-kit.git
specify init --here --integration claude --integration-options="--skills"
```

- `--here` initialises the current directory; add `--force` if it is non-empty and the user has agreed. Use `--non-interactive` in scripts.
- Omit `--integration-options="--skills"` to get `/speckit.*` slash-command files in `.claude/commands/` instead of skills. Skills mode is preferred.
- Run `specify check` to verify required tools; `specify self upgrade` to update the CLI.
- Tell the user to start a new Claude Code session (or `/reload`) so the generated skills are picked up.

## 3. Workflow order

Run the generated skills in this order; each one reads the artifacts of the previous:

| Step | Skill / command | Purpose |
|---|---|---|
| 1 | `speckit-constitution` | Project principles and non-negotiables (`.specify/memory/constitution.md`) — once per project |
| 2 | `speckit-specify` | Feature spec: what and why, user stories, acceptance criteria — no tech choices |
| 3 | `speckit-clarify` | Interview to resolve under-specified areas — do this before planning |
| 4 | `speckit-plan` | Technical plan with the chosen stack, data model, contracts |
| 5 | `speckit-tasks` | Ordered, dependency-aware task list |
| 6 | `speckit-analyze` | Cross-artifact consistency and coverage check — before implementing |
| 7 | `speckit-checklist` (optional) | Quality checklist for the spec ("unit tests for English") |
| 8 | `speckit-implement` | Execute the tasks |
| 9 | `speckit-converge` / `speckit-taskstoissues` (optional) | Re-assess remaining work / push tasks to GitHub issues |

Each feature lives in its own branch and `specs/<nnn-feature>/` folder created by `speckit-specify`.

## Rules

- Never hand-edit the generated `speckit-*` skills or `.specify/scripts/`; upgrade the CLI and re-run `specify init --here --force` instead.
- Keep tech decisions out of the spec and in the plan.
- If `.specify/extensions.yml` exists, the generated skills honour its hooks — don't bypass them.

Reference: https://github.com/github/spec-kit
