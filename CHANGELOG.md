# Changelog

All notable changes to this marketplace. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning](https://semver.org/), one version for the whole marketplace
(`metadata.version` in `.claude-plugin/marketplace.json`).

- **MAJOR**: a plugin or skill is removed or renamed, or an installer or settings file changes in a way
  that needs action from people who already installed.
- **MINOR**: a plugin, skill, profile or setting is added.
- **PATCH**: fixes, documentation, and the daily upstream syncs.

Releases are tagged `vMAJOR.MINOR.PATCH` by the owner, from `main`, after the version below and in
`marketplace.json` have been bumped in the same pull request. The `Release` workflow checks the two match,
runs the full test suite and publishes the section of this file as the release notes.

## [Unreleased]

## [0.1.0]

First tagged release: the marketplace as it is on `main` when this tag is created. See `README.md` for
the plugins, install profiles, permissions baseline and guardrails, and `docs/ATTRIBUTION.md` for the
attribution guard.
