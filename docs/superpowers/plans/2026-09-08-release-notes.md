# Repository and Sparkle Release Notes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a root changelog the required source for concise release notes, embed each matching version in Sparkle's update dialog, and provide a safe local command for backfilling the published 2.0.0 appcast item.

**Architecture:** A focused Ruby component owns changelog section extraction and Markdown appcast-description mutation. Both the normal appcast generator and an explicit offline backfill CLI use that component; Fastlane fails early when the built marketing version has no changelog entry, and CI exercises the parser and XML behavior without building or publishing an app.

**Tech Stack:** Markdown, Ruby 3.3 standard library (`REXML`, `Minitest`, `Tempfile`), Fastlane, GitHub Actions, Sparkle 2.9.6 appcast XML.

---

## File Structure

- Create `CHANGELOG.md` — the single user-facing release history, with `Unreleased` and a backfilled 2.0.0 section.
- Create `packaging/release_notes.rb` — parse one exact changelog version, set a Markdown appcast description, update an existing appcast item, and expose `extract`/`backfill` CLI commands.
- Create `packaging/test/release_notes_test.rb` — isolated extraction, XML mutation, and CLI behavior tests using temporary files.
- Modify `packaging/appcast.rb` — require a notes file and use the shared Markdown-description writer instead of the placeholder CDATA.
- Modify `QuickInterviewEditor/fastlane/Fastfile` — preflight the current marketing version's notes, verify the built version matches, and pass the extracted notes to `appcast.rb`.
- Modify `.github/workflows/tests.yml` — syntax-check and test the release-notes component and verify the checked-in marketing version has notes.
- Modify `README.md` — link to the repository release history.
- Modify `packaging/README.md` — document changelog preparation, Sparkle presentation, and the deliberate 2.0.0 backfill procedure.

No Swift source or Xcode project configuration changes are needed.

### Task 1: Add the user-facing changelog and exact-version extractor

**Files:**
- Create: `CHANGELOG.md`
- Create: `packaging/release_notes.rb`
- Create: `packaging/test/release_notes_test.rb`

- [ ] **Step 1: Write extraction tests first**

Create `packaging/test/release_notes_test.rb` using `Minitest`. Use in-memory
Markdown for parser tests; do not depend on the real changelog for unit behavior.

Cover these cases:

```ruby
require "minitest/autorun"
require_relative "../release_notes"

class ReleaseNotesTest < Minitest::Test
  CHANGELOG = <<~MARKDOWN
    # Changelog

    ## [Unreleased]

    - Work in progress.

    ## [2.0.0] - 2026-09-08

    - Save and reopen `.pie` projects.
    - Review suggestions before export.

    ## [1.9.0] - 2026-08-01

    - Older work.
  MARKDOWN

  def test_extracts_only_the_exact_release_body
    assert_equal <<~MARKDOWN.strip, ReleaseNotes.extract(CHANGELOG, "2.0.0")
      - Save and reopen `.pie` projects.
      - Review suggestions before export.
    MARKDOWN
  end

  def test_rejects_invalid_version
    error = assert_raises(ReleaseNotes::Error) {
      ReleaseNotes.extract(CHANGELOG, "v2.0")
    }
    assert_match(/semantic version/, error.message)
  end

  def test_rejects_missing_version
    error = assert_raises(ReleaseNotes::Error) {
      ReleaseNotes.extract(CHANGELOG, "3.0.0")
    }
    assert_match(/missing/, error.message)
  end
end
```

Add separate tests for duplicate matching headings and a matching heading whose
body is blank before the next level-two heading.

- [ ] **Step 2: Run the extraction tests and verify they fail**

Run:

```bash
ruby packaging/test/release_notes_test.rb
```

Expected: FAIL because `packaging/release_notes.rb` does not exist.

- [ ] **Step 3: Implement the minimal extraction module**

Create `packaging/release_notes.rb` with:

```ruby
#!/usr/bin/env ruby
require "fileutils"
require "rexml/document"
require "tempfile"

module ReleaseNotes
  class Error < StandardError; end

  VERSION = /\A\d+\.\d+\.\d+\z/
  RELEASE_HEADING = /\A## \[(\d+\.\d+\.\d+)\] - \d{4}-\d{2}-\d{2}\s*\z/

  def self.extract(changelog, version)
    raise Error, "version must be semantic version X.Y.Z" unless VERSION.match?(version)

    lines = changelog.lines
    matches = []
    lines.each_index do |index|
      heading = RELEASE_HEADING.match(lines[index])
      next unless heading && heading[1] == version

      boundary = ((index + 1)...lines.length).find {
        |candidate| lines[candidate].start_with?("## ")
      } || lines.length
      matches << lines[(index + 1)...boundary].join.strip
    end

    raise Error, "release #{version} is missing from the changelog" if matches.empty?
    raise Error, "release #{version} appears more than once in the changelog" if matches.length > 1
    raise Error, "release #{version} has no notes" if matches.first.empty?

    matches.first
  end
end
```

Keep the public interface text-based: `extract(changelog_text, version)` returns
the section body. File I/O belongs to the CLI boundary added later.

- [ ] **Step 4: Run the extraction tests and verify they pass**

Run:

```bash
ruby packaging/test/release_notes_test.rb
```

Expected: all extraction tests PASS.

- [ ] **Step 5: Add the actual changelog**

Create `CHANGELOG.md` with this user-facing structure and prose:

```markdown
# Changelog

Notable changes to Playola Interview Editor are documented here. Release notes
focus on changes that affect editing work rather than internal implementation.

## [Unreleased]

## [2.0.0] - 2026-09-08

- Save an entire editing session as a `.pie` project and reopen it later with
  its audio, transcript, clips, edits, and suggestions intact. Multiple projects
  can be open in separate windows.
- Find and review configurable AI cut suggestions for Spotlights, Song Intros,
  and Audio Images. Customize suggestion rules, extracted fields, clip naming,
  numbering, and interview context.
- Edit directly from the transcript and waveform: select and resize clips, fine
  tune boundaries, audition edits, remove sections with crossfades, and undo
  document changes.
- Export Logic-ready AIFF clips with embedded word markers, editable clip names,
  and a review step for filename collisions.
- Improved the reliability of transcription, saved-project recovery, suggestion
  searches, playback, and export.
```

- [ ] **Step 6: Prove the real 2.0.0 section extracts cleanly**

Temporarily invoke the module directly:

```bash
ruby -Ipackaging -rrelease_notes -e 'puts ReleaseNotes.extract(File.read("CHANGELOG.md"), "2.0.0")'
```

Expected: only the five 2.0.0 bullets print; `Unreleased` and the heading do not.

- [ ] **Step 7: Commit the changelog and parser**

```bash
git add CHANGELOG.md packaging/release_notes.rb packaging/test/release_notes_test.rb
git commit -m "feat(release): add versioned changelog source"
```

### Task 2: Embed required Markdown notes in newly generated appcast items

**Files:**
- Modify: `packaging/release_notes.rb`
- Modify: `packaging/test/release_notes_test.rb`
- Modify: `packaging/appcast.rb:1-98`

- [ ] **Step 1: Write failing appcast-description tests**

Add tests that build a minimal `REXML::Document`, call the intended helper, then
serialize and reparse it:

```ruby
def test_sets_a_markdown_description_that_round_trips_special_text
  document = REXML::Document.new(<<~XML)
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel><item><title>Version 2.0.0</title></item></channel>
    </rss>
  XML
  item = document.elements["rss/channel/item"]
  notes = "- Audio & export <work> safely.\n- A CDATA edge: ]]>"

  ReleaseNotes.set_description(item, notes)

  output = String.new
  document.write(output)
  reparsed = REXML::Document.new(output)
  description = reparsed.elements["rss/channel/item/description"]
  assert_equal "markdown", description.attribute("sparkle:format").value
  assert_equal notes, description.text
end
```

Also test that an existing `description` is replaced rather than duplicated and
that blank notes raise `ReleaseNotes::Error`.

- [ ] **Step 2: Run the focused tests and verify they fail**

Run:

```bash
ruby packaging/test/release_notes_test.rb -n /description/
```

Expected: FAIL because `ReleaseNotes.set_description` is undefined.

- [ ] **Step 3: Implement the shared Markdown-description writer**

Add to `ReleaseNotes`:

```ruby
def self.set_description(item, notes)
  raise Error, "release notes are empty" if notes.strip.empty?

  item.delete_element("description") while item.elements["description"]
  description = item.add_element("description")
  description.add_attribute("sparkle:format", "markdown")
  description.text = notes
  description
end
```

Use an escaped XML text node rather than CDATA. That round-trips Markdown
characters safely even when the prose contains the CDATA terminator `]]>`.

- [ ] **Step 4: Run the focused tests and verify they pass**

Run:

```bash
ruby packaging/test/release_notes_test.rb -n /description/
```

Expected: PASS.

- [ ] **Step 5: Make notes mandatory in `appcast.rb`**

Update the script contract to:

```ruby
# packaging/appcast.rb <dmg> <public-download-url> <sign_update_path> <notes_file>
require_relative "release_notes"

dmg, url, sign_update, notes_file = ARGV
abort "usage: appcast.rb <dmg> <download-url> <sign_update> <notes_file>" unless notes_file
abort "notes file not found: #{notes_file}" unless File.file?(notes_file)
notes = File.read(notes_file)
abort "release notes are empty: #{notes_file}" if notes.strip.empty?
```

Remove the `See the changelog.` fallback. Replace the existing description/CDATA
creation with:

```ruby
ReleaseNotes.set_description(item, notes)
```

Extend the post-serialization semantic validation:

```ruby
description = built.elements["description"] or abort "generated item missing description"
abort "generated item description is not markdown" unless description.attribute("sparkle:format")&.value == "markdown"
abort "generated item release notes changed during XML serialization" unless description.text == notes
```

- [ ] **Step 6: Syntax-check both Ruby files and run all tests**

Run:

```bash
ruby -c packaging/release_notes.rb
ruby -c packaging/appcast.rb
ruby packaging/test/release_notes_test.rb
```

Expected: each syntax check reports `Syntax OK`; all tests PASS.

- [ ] **Step 7: Commit appcast Markdown support**

```bash
git add packaging/release_notes.rb packaging/test/release_notes_test.rb packaging/appcast.rb
git commit -m "feat(release): embed Markdown notes in appcast"
```

### Task 3: Add the offline existing-release backfill command

**Files:**
- Modify: `packaging/release_notes.rb`
- Modify: `packaging/test/release_notes_test.rb`

- [ ] **Step 1: Write failing backfill tests**

Use an appcast fixture with two items and capture the target item's title,
`pubDate`, internal `sparkle:version`, and enclosure attributes before mutation.
Test that:

- Version `2.0.0` gets exactly one Markdown `description` with the supplied text.
- The target's non-description fields and enclosure attributes are unchanged.
- The unrelated item and its description are unchanged.
- A missing requested `sparkle:shortVersionString` raises.
- Two items with the requested short version raise.
- Notes containing `&`, `<`, and `]]>` survive serialize/reparse exactly.

The main assertion should resemble:

```ruby
output = ReleaseNotes.backfill_appcast(appcast_xml, "2.0.0", notes)
updated = REXML::Document.new(output)
items = updated.elements.to_a("rss/channel/item")
target = items.fetch(0)

assert_equal notes, target.elements["description"].text
assert_equal "markdown", target.elements["description"].attribute("sparkle:format").value
assert_equal original_enclosure, attributes(target.elements["enclosure"])
assert_equal original_other_description, items.fetch(1).elements["description"].text
```

- [ ] **Step 2: Run focused tests and verify they fail**

Run:

```bash
ruby packaging/test/release_notes_test.rb -n /backfill/
```

Expected: FAIL because `ReleaseNotes.backfill_appcast` is undefined.

- [ ] **Step 3: Implement pure appcast backfill behavior**

Add:

```ruby
def self.backfill_appcast(appcast, version, notes)
  raise Error, "version must be semantic version X.Y.Z" unless VERSION.match?(version)

  document = REXML::Document.new(appcast)
  channel = document.elements["rss/channel"] or raise Error, "appcast has no rss/channel"
  matches = channel.elements.to_a("item").select do |item|
    item.elements["sparkle:shortVersionString"]&.text&.strip == version
  end
  raise Error, "appcast item #{version} is missing" if matches.empty?
  raise Error, "appcast item #{version} appears more than once" if matches.length > 1

  set_description(matches.first, notes)
  output = String.new
  document.write(output)
  validate_backfill(output, version, notes)
  output
rescue REXML::ParseException => error
  raise Error, "appcast is not valid XML: #{error.message}"
end
```

Implement `validate_backfill` by reparsing, finding exactly one matching item,
and checking its description text and `sparkle:format="markdown"`. Keep it a
private module method so callers cannot skip validation.

- [ ] **Step 4: Run focused tests and verify they pass**

Run:

```bash
ruby packaging/test/release_notes_test.rb -n /backfill/
```

Expected: PASS.

- [ ] **Step 5: Write failing CLI tests**

Use `Dir.mktmpdir`, `Open3.capture3`, and `RbConfig.ruby` to test:

- `extract CHANGELOG VERSION OUTPUT` writes only the selected notes.
- `backfill APPCAST CHANGELOG VERSION` replaces the appcast atomically on
  success.
- A missing changelog section returns non-zero and leaves the existing appcast
  bytes unchanged.
- Unknown commands and wrong argument counts return non-zero with usage text.

- [ ] **Step 6: Run CLI tests and verify they fail**

Run:

```bash
ruby packaging/test/release_notes_test.rb -n /cli/
```

Expected: FAIL because the script has no CLI dispatcher.

- [ ] **Step 7: Implement the CLI and atomic file replacement**

Below the module, guarded by `if $PROGRAM_NAME == __FILE__`, implement:

```text
release_notes.rb extract <changelog> <version> <output>
release_notes.rb backfill <appcast> <changelog> <version>
```

For `extract`, read the changelog, call `ReleaseNotes.extract`, create the output
directory, and write the returned notes plus one trailing newline.

For `backfill`, read both inputs, extract the matching notes, compute the updated
XML fully in memory, write it to a `Tempfile` in the appcast's directory, flush
and close it, then `File.rename` it over the original. Rescue
`ReleaseNotes::Error`, `Errno::ENOENT`, and `REXML::ParseException` at the CLI
boundary, print a concise `error:` message to stderr, and exit non-zero.

- [ ] **Step 8: Run all Ruby tests and a syntax check**

Run:

```bash
ruby -c packaging/release_notes.rb
ruby packaging/test/release_notes_test.rb
```

Expected: syntax is valid and all tests PASS.

- [ ] **Step 9: Commit the backfill tool**

```bash
git add packaging/release_notes.rb packaging/test/release_notes_test.rb
git commit -m "feat(release): add safe appcast notes backfill"
```

### Task 4: Fail releases early when the version has no notes

**Files:**
- Modify: `QuickInterviewEditor/fastlane/Fastfile:104-194`
- Modify: `.github/workflows/tests.yml:87-112`

- [ ] **Step 1: Verify the CLI fails closed and succeeds for the current version**

First request a missing version and verify the command exits non-zero without
creating a usable notes file:

```bash
ruby packaging/release_notes.rb extract CHANGELOG.md 9.9.9 /tmp/missing-release-notes.md
```

Then run the command the CI job will use:

```bash
release_version="$(sed -n 's/.*MARKETING_VERSION: "\([0-9][0-9.]*\)".*/\1/p' QuickInterviewEditor/project.yml)"
ruby packaging/release_notes.rb extract CHANGELOG.md "$release_version" packaging/dist/release-notes.md
test -s packaging/dist/release-notes.md
```

Expected: the missing-version command fails with a clear error; the real current
version extracts successfully into a non-empty file.

- [ ] **Step 2: Add an early Fastlane preflight**

Immediately after release environment validation and before the engine build,
read `MARKETING_VERSION` from `project.yml`, validate it as `X.Y.Z`, and extract
its notes:

```ruby
project_yml = File.read("../project.yml")
release_short = project_yml[/MARKETING_VERSION:\s*"(\d+\.\d+\.\d+)"/, 1]
UI.user_error!("MARKETING_VERSION not found in project.yml") unless release_short
notes = "packaging/dist/release-notes-#{release_short}.md"
sh("cd ../.. && ruby packaging/release_notes.rb extract CHANGELOG.md '#{release_short}' '#{notes}'")
```

The semantic-version regex makes interpolation safe. This preflight occurs
before the expensive freeze/sign/notarize steps and before any upload.

- [ ] **Step 3: Verify the built version and pass notes to the appcast generator**

After reading the built app plist, fail if it differs from the preflighted
version:

```ruby
UI.user_error!("built version #{short} does not match release notes #{release_short}") unless short == release_short
```

Change the appcast invocation to include the extracted file:

```ruby
sh("cd ../.. && ruby packaging/appcast.rb '#{dmg}' '#{url}' '#{sign_update}' '#{notes}'")
```

- [ ] **Step 4: Extend the release validation job**

Update `.github/workflows/tests.yml` to:

- Run `ruby -c packaging/release_notes.rb` as well as `appcast.rb`.
- Run `ruby packaging/test/release_notes_test.rb`.
- Extract the `MARKETING_VERSION` from `project.yml` into `/tmp/release-notes.md`
  and assert that file is non-empty.

Do not add AWS credentials, S3 access, signing, or DMG construction to CI.

- [ ] **Step 5: Run the same checks locally**

Run:

```bash
ruby -c packaging/release_notes.rb
ruby -c packaging/appcast.rb
ruby -c QuickInterviewEditor/fastlane/Fastfile
ruby packaging/test/release_notes_test.rb
release_version="$(sed -n 's/.*MARKETING_VERSION: "\([0-9][0-9.]*\)".*/\1/p' QuickInterviewEditor/project.yml)"
ruby packaging/release_notes.rb extract CHANGELOG.md "$release_version" /tmp/playola-release-notes.md
test -s /tmp/playola-release-notes.md
```

Expected: syntax checks report `Syntax OK`, tests PASS, and the extracted file
is non-empty.

- [ ] **Step 6: Commit release and CI wiring**

```bash
git add QuickInterviewEditor/fastlane/Fastfile .github/workflows/tests.yml
git commit -m "build(release): require notes before publishing"
```

### Task 5: Document release preparation and the deliberate 2.0.0 backfill

**Files:**
- Modify: `README.md`
- Modify: `packaging/README.md:130-272`

- [ ] **Step 1: Link the repository changelog**

Add a short `Release notes` section near the top of `README.md` linking to
`CHANGELOG.md`. Do not rewrite the unrelated proof-of-concept documentation in
this change.

- [ ] **Step 2: Update the normal release runbook**

In `packaging/README.md`:

- Add `CHANGELOG.md -> release_notes.rb` before `appcast.rb` in the pipeline.
- Explain that Sparkle 2.9.6 displays the selected Markdown in its standard
  update UI.
- Before `bump`/`release`, require moving finished entries from `Unreleased` to
  `## [X.Y.Z] - YYYY-MM-DD`.
- State that a missing, duplicate, or empty matching section aborts the release
  before the expensive build and before uploads.
- Update the `appcast.rb` example to include the notes file argument.

- [ ] **Step 3: Add the offline 2.0.0 backfill runbook**

Document these deliberate steps, using the established bucket and key:

```bash
aws --profile default s3 cp \
  s3://playola-static/downloads/PlayolaInterviewEditor/appcast.xml \
  packaging/dist/appcast.xml

ruby packaging/release_notes.rb backfill \
  packaging/dist/appcast.xml CHANGELOG.md 2.0.0

ruby -rrexml/document -e \
  'abort "bad appcast" unless REXML::Document.new(File.read(ARGV.fetch(0))).root' \
  packaging/dist/appcast.xml

aws --profile default s3 cp packaging/dist/appcast.xml \
  s3://playola-static/downloads/PlayolaInterviewEditor/appcast.xml \
  --content-type application/xml --cache-control no-cache
```

State explicitly that the command changes only the local file; the final AWS
command is the user-facing production mutation. Recommend reviewing
`git diff --no-index` between a saved downloaded copy and the updated local XML,
or parsing both, before upload. Do not execute any AWS upload during development.

- [ ] **Step 4: Review documentation commands for copy/paste correctness**

Run only the read/local-mutation half against a temporary copy of a test fixture
or downloaded appcast saved under `.context/`. Never point the test at the live
S3 upload command.

Expected: the local item receives the 2.0.0 Markdown description; its enclosure
URL, length, and signature remain identical.

- [ ] **Step 5: Commit documentation**

```bash
git add README.md packaging/README.md
git commit -m "docs(release): explain notes and appcast backfill"
```

### Task 6: Final verification

**Files:**
- Verify all files changed in Tasks 1-5.

- [ ] **Step 1: Run the complete release-notes test suite**

```bash
ruby packaging/test/release_notes_test.rb
```

Expected: all tests PASS with zero failures and zero errors.

- [ ] **Step 2: Run release-script syntax checks**

```bash
ruby -c packaging/release_notes.rb
ruby -c packaging/appcast.rb
ruby -c QuickInterviewEditor/fastlane/Fastfile
bash -n packaging/make-dmg.sh packaging/sign-app.sh
```

Expected: all checks PASS.

- [ ] **Step 3: Verify the checked-in marketing version has notes**

```bash
release_version="$(sed -n 's/.*MARKETING_VERSION: "\([0-9][0-9.]*\)".*/\1/p' QuickInterviewEditor/project.yml)"
ruby packaging/release_notes.rb extract CHANGELOG.md "$release_version" /tmp/playola-release-notes.md
test -s /tmp/playola-release-notes.md
grep -F '.pie' /tmp/playola-release-notes.md
```

Expected: version `2.0.0` extracts successfully and contains the project-document
highlight.

- [ ] **Step 4: Exercise backfill on a local fixture and compare invariants**

Copy a two-item test appcast into a temporary directory, record the target
enclosure's URL/length/signature and the unrelated item, run the CLI, then parse
and compare those values. Do not access S3.

Expected: only the requested item's description semantics change.

- [ ] **Step 5: Run repository hygiene checks**

```bash
git diff --check origin/main...
git status --short
git log --oneline origin/main..HEAD
```

Expected: no whitespace errors, only planned files are changed, and commits are
small and task-focused.

- [ ] **Step 6: Review the final diff against the approved design**

Confirm:

- `CHANGELOG.md` is the only release-prose source.
- 2.0.0 is backfilled with concise user-facing notes.
- New releases fail closed without exact notes.
- Sparkle descriptions declare Markdown format.
- The backfill command is local-only and preserves enclosure metadata.
- CI performs no network writes or release publication.

- [ ] **Step 7: Commit any final verification-only corrections**

If verification required changes, rerun the affected checks and commit only
those corrections. If no changes were required, do not create an empty commit.
