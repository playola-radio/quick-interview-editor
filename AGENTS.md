# Agent instructions

Project rules live in `CLAUDE.md`; read and follow it.

## Release notes (`changelog.d/`)

**Never edit `CHANGELOG.md` in a pull request** — not even `## [Unreleased]`.
A PR with a user-facing change adds one new file,
`changelog.d/<short-kebab-description>.md`: a `### Changes` heading and plain-English
`- ` bullets (format in `changelog.d/README.md`). Pure chores need no file; say so in
the PR body. `fastlane mac bump version:X.Y.Z` rolls the fragments into
`CHANGELOG.md` and deletes them.
