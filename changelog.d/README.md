# changelog.d — one release-note file per pull request

Don't edit `CHANGELOG.md` in a pull request. Every pull request that changes what
a user sees or does adds **one new file** here instead, so two pull requests never
touch the same lines and never conflict.

## Format

Name the file after the change, in short kebab-case: `changelog.d/<short-description>.md`
(for example `changelog.d/keep-clip-names-on-export.md`).

```markdown
### Changes

- Exporting now keeps the clip names you typed instead of renaming them
  "Slice N".
```

- The `### Changes` heading is the only heading allowed.
- Each note is a `- ` bullet in plain English, written for the person editing an
  interview, not for engineers. A long bullet may wrap onto indented lines that
  directly follow it.
- Single-line `<!-- ... -->` comments and blank lines are fine.
- Anything else is an error, and so is a file with no bullets.

These bullets ship as-is in the in-app update notes (Sparkle), so keep them
user-facing. This app has no deploy step, so there is no `### Ops` section; put
any one-off release step in the pull request body.

Pure chores (refactors, tooling, tests, docs) with no user-facing change need no
file — say so in the pull request body.

## At release time

`bundle exec fastlane mac bump version:X.Y.Z` runs
`ruby packaging/changelog.rb roll CHANGELOG.md changelog.d X.Y.Z`, which:

1. reads any bullets still under `## [Unreleased]` in `CHANGELOG.md` (from
   branches opened before this folder existed), then every file here in filename
   order — never this README;
2. writes them all as one `## [X.Y.Z] - YYYY-MM-DD` section and leaves
   `## [Unreleased]` empty apart from a comment pointing here;
3. deletes exactly the files it read.

If any note is malformed (the error names `file:line`), the version is missing, or
`CHANGELOG.md` already has that version, it fails without changing anything.
