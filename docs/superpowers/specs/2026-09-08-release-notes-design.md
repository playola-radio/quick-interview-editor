# Repository and Sparkle Release Notes Design

**Date:** 2026-09-08

## Goal

Keep concise, user-facing release notes in the repository and display the notes
for each app version in Sparkle's standard update UI. Backfill version 2.0.0 and
prevent future releases from shipping the current placeholder text.

## Source of Truth

Add a root `CHANGELOG.md` with an `Unreleased` section followed by dated,
semantic-version sections. Each released version appears exactly once and uses
this shape:

```markdown
## [2.0.0] - 2026-09-08

- Release highlight.
- Another release highlight.
```

The changelog is written for people who use Playola Interview Editor. It
summarizes meaningful features, workflow changes, and notable fixes rather than
listing commits or internal refactors.

The backfilled 2.0.0 section will cover:

- `.pie` project documents, reopening work, and multiple project windows.
- Configurable AI cut suggestions, including types, rules, naming, numbering,
  and interview context.
- Transcript and waveform editing, including clip resizing, fine tuning,
  auditioning, removals, crossfades, and undo.
- Logic-ready AIFF export with word markers and filename-collision review.
- Reliability improvements around transcription, saved projects, suggestions,
  playback, and export.

## Release-Notes Extraction

Add a small Ruby release-notes component under `packaging/`. It reads
`CHANGELOG.md` and returns the body of the section whose version exactly matches
the requested semantic version. The parser stops at the next level-two heading,
so `Unreleased` and neighboring releases cannot leak into the selected notes.

Extraction fails when:

- The requested version is not valid `X.Y.Z` semantic version text.
- The matching version section is missing.
- More than one matching section exists.
- The matching section has no non-whitespace content.

The component has a command-line interface so the release lane, CI, and the
backfill workflow all exercise the same parsing behavior.

## Normal Release Flow

The Fastlane release lane reads `MARKETING_VERSION` from the built app as it
does today. Before creating or uploading the appcast, it asks the release-notes
component to extract that exact version from the root changelog.

`packaging/appcast.rb` embeds the extracted Markdown in the item's
`description` element and marks that element as Markdown using Sparkle's XML
format attribute. The repository pins Sparkle 2.9.6 and targets macOS 15, so the
standard Sparkle UI supports embedded Markdown release notes.

The placeholder fallback, `See the changelog.`, is removed. A release with
missing or invalid notes aborts before any new DMG or appcast is uploaded.

Release data flows as follows:

```text
CHANGELOG.md
  -> exact MARKETING_VERSION section
  -> validated Markdown notes file in packaging/dist
  -> appcast <description sparkle:format="markdown">
  -> S3 appcast.xml
  -> Sparkle update dialog
```

The release runbook adds a required preparation step: move the finished entries
from `Unreleased` into a dated version section before running the release lane.

## Existing 2.0.0 Appcast Backfill

Provide a separate, explicit backfill command for an already-published appcast.
It will:

1. Accept an explicit semantic version and local changelog path.
2. Read a local appcast downloaded by the operator from the production S3 key.
3. Locate exactly one item whose `sparkle:shortVersionString` matches the
   requested version.
4. Replace only that item's `description` with the extracted Markdown and set
   its Markdown format attribute.
5. Preserve the item's title, publication date, build version, enclosure URL,
   length, and EdDSA signature, as well as every other appcast item.
6. Validate the complete output before replacing the local appcast file.

The command will not download from or upload to S3 itself. The runbook provides
explicit AWS download and upload commands, with the upload retaining the
existing `application/xml` content type and `no-cache` cache policy. This keeps
the network mutation visible and deliberate. Implementing this feature does not
publish the backfill; an operator must run the documented production command.

Backfilling an embedded description does not modify the signed DMG enclosure,
so the existing artifact and its EdDSA signature remain unchanged.

## Verification

Add Ruby tests using temporary changelog and appcast fixtures. Cover:

- Exact extraction of the requested release while excluding `Unreleased` and
  adjacent versions.
- Missing, duplicate, empty, and malformed version failures.
- Appcast generation with a Markdown-formatted description.
- Backfilling only the requested existing item while preserving its enclosure
  and all unrelated items.
- Missing and duplicate appcast-item failures.
- XML with special characters and CDATA edge cases remaining well formed.

The existing GitHub Actions `validate` job runs the Ruby test suite alongside
its syntax checks and version-field validation. The implementation also runs
the tests locally without building, signing, notarizing, uploading, or changing
the live appcast.

## Out of Scope

- Creating GitHub Releases. The private repository is not the app's user-facing
  distribution surface.
- Adding a custom in-app What's New window or changelog screen.
- Generating release prose from Git history.
- Publishing any S3 changes from development or CI.
- Rewriting historical releases other than the 2.0.0 changelog entry.
