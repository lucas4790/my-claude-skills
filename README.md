# my-claude-skills

A Claude Code plugin marketplace with the skills and plugins I use, vendored from upstream and kept in sync automatically.

## Install

```bash
claude plugin marketplace add lucas4790/my-claude-skills
claude plugin install anthropic-skills@my-claude-skills
claude plugin install feature-dev@my-claude-skills
claude plugin install pr-review-toolkit@my-claude-skills
```

Claude Code refreshes GitHub marketplaces on startup and auto-updates installed plugins when the repo changes, so nothing else is needed locally.

## Plugins

| Plugin | Upstream | Contents |
|---|---|---|
| `anthropic-skills` | [anthropics/skills](https://github.com/anthropics/skills) | every skill under `skills/` (docx, pdf, pptx, xlsx, frontend-design, mcp-builder, skill-creator, webapp-testing, claude-api, ...) |
| `feature-dev` | [anthropics/claude-plugins-official](https://github.com/anthropics/claude-plugins-official) | `/feature-dev` command + code-explorer, code-architect, code-reviewer agents |
| `pr-review-toolkit` | [anthropics/claude-plugins-official](https://github.com/anthropics/claude-plugins-official) | `/review-pr` command + six review agents |

## How syncing works

- `sources.json` lists each upstream repo, the ref to track, and which paths to copy where.
- `scripts/sync.sh` sparse-clones each source, copies the paths in (deleting anything upstream removed), and records the synced commit in `UPSTREAM.lock.json`.
- `.github/workflows/sync-upstream.yml` runs the script daily at 06:00 UTC (and on manual dispatch) and commits directly to `main` when anything changed.

Run it locally with `scripts/sync.sh` (needs `git`, `rsync`, `jq`).

## Adding a source

1. Add an entry to `sources.json` with the repo, ref, and `copy` mappings into `plugins/<name>/...`.
2. If it is a bare skills folder (not a full plugin), add `plugins/<name>/.claude-plugin/plugin.json`.
3. Add a plugin entry to `.claude-plugin/marketplace.json` pointing at `./plugins/<name>`.
4. Run `scripts/sync.sh` and commit.

To have the workflow open a PR instead of pushing to `main`, replace the commit step with `peter-evans/create-pull-request`.

## Licensing

Repo scaffolding (`scripts/`, workflow, manifests) is MIT. Vendored content keeps its upstream license; see the `LICENSE` and `THIRD_PARTY_NOTICES.md` files inside each `plugins/*` directory.
