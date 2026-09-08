# Broader Intro Suggestions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Find complete commentary about a song or artist without requiring a performance handoff, and prefer Intro naming when the same passage also qualifies as a Spotlight.

**Architecture:** Fresh app searches use `configured-v3`. Keep the tuned Spotlight discovery implementation intact; discover Intros independently through configured window discovery, bypassing the old handoff-only refinement and 75-second ceiling. Preserve historical request versions and their exact recovery prompts. Suggestion types guide editable names; unknown naming fields retain the existing descriptive-label fallback.

**Tech Stack:** Python/pytest; Swift, Swift Testing, CustomDump, Sharing; existing JSON configuration and request journals.

---

## Approved behavior

- An Intro can be meaningful artist commentary about a song or an artist: its history, influence, writing, performance, or reception. No immediate musical handoff, named recording, or exact song title is required.
- Preserve complete useful thoughts; reject isolated names, acknowledgments, and incidental mentions. Keep separate complete repeated performances.
- Intro takes priority over a Spotlight describing substantially the same passage. Suppress a Spotlight only when an Intro covers at least 80% of its sentence span. Retain a longer independently useful story that only partially overlaps an Intro; do not split or truncate it.
- Preserve unrelated Spotlight and imaging behavior, custom type definitions, current numbering at acceptance, editable names, and existing clips.
- Song Title is the principal song discussed or introduced when established. Artist Name is the performer of that song, or the artist being discussed in artist-only commentary. Never substitute a DJ or an unrelated speaker. Missing fields are allowed; no invented title or conditional naming system is needed.
- Upgrade only exact legacy built-in guidance strings and field instructions in app-wide storage, independently per property. Preserve all user edits, templates, IDs, order, and deleted defaults. Persist the upgrade atomically with one checked revision increment; stale drafts must fail. Captured project configurations and resumed searches stay immutable.

## Task 1: Versioned broad discovery and priority

**Files:** `cut_suggester/suggestion_config.py`, `cut_suggester/configured_run.py`, `cut_suggester/configured_discovery.py`; `tests/test_configured_run.py`, `tests/test_configured_discovery.py`.

- [x] Add failing tests using real run orchestration and scripted provider responses: song discussion and artist-only discussion survive without handoffs; fully covered Spotlight loses to Intro; unrelated and only partially covered longer Spotlights survive; short complete intros/repeats survive; missing fields do not discard candidates; v3 resumes without additional successful calls.
- [x] Run `.venv/bin/python -m pytest tests/test_configured_run.py tests/test_configured_discovery.py -q` and record the expected failure.
- [x] Add a distinct broad-discovery version constant, keeping configured-v2 prompt behavior explicit. For v3, remove Intro from the tuned configuration, add its unchanged configured definition to window discovery, and bypass handoff-only refinement. Use the existing 1–240-second complete-take bounds. Keep v2 imaging repetition instructions identical under v3.

```python
# After both discovery paths, before extraction:
intros = [item for item in suggestions if item['product_type'] == 'intro']
suggestions = [item for item in suggestions
               if item['product_type'] != 'spotlight'
               or not any(_overlap(item, intro) / _span_length(item) >= 0.8
                          for intro in intros)]
```

- [x] Describe broad Intro semantics and repeated takes in the v3 configured prompt, with user guidelines controlling discovery. Avoid embedding the obsolete handoff-only filter.
- [x] Run focused tests, including existing v1/v2 refinement/cache tests and tuned prompt golden tests. Document that scripted tests prove routing and retention, not live provider recall.

## Task 2: Fresh defaults and safe stored-default upgrade

**Files:** `QuickInterviewEditor/QuickInterviewEditor/Models/SuggestionDefaults.swift`, `Models/CutSuggestOptions.swift`, `Core/SuggestionConfigurationClient.swift`; corresponding tests under `QuickInterviewEditor/QuickInterviewEditorTests/Models` and `Core`.

- [x] Add failing store tests for upgrading legacy strings at revision 7 to revision 8, preserving edited strings/templates and absent defaults, repeat-load idempotence, stale save rejection, failed-write publication/byte preservation, and overflow. Add a fresh-option version assertion.
- [x] Run `make -C QuickInterviewEditor test-fast ONLY=PlayolaInterviewEditorTests/SuggestionConfigurationClientTests`, verifying nonzero tests and the expected failures.
- [x] Replace built-in Intro guidance and Song Title/Artist Name instructions with the approved semantics above. Keep exact old strings as private migration constants. Add a pure `SuggestionDefaults.upgradingLegacyIntroGuidance(in:)` transformation that changes only matching properties and does not change revision.

```swift
let updated = SuggestionDefaults.upgradingLegacyIntroGuidance(in: configuration)
guard updated != configuration else { return configuration }
let (revision, overflow) = configuration.revision.addingReportingOverflow(1)
guard !overflow else { throw SuggestionConfigurationStoreError.revisionOverflow }
var migrated = updated
migrated.revision = revision
try write(JSONEncoder().encode(migrated), fileURL)
return migrated
```

- [x] Apply migration only during app-wide store loading, after validation and before publication. Fresh options use `configured-v3`; decoded historical options retain their recorded version. Update current-default tests while keeping old fixture snapshots historical.
- [x] Run focused Swift tests and resolve any current-default fixture comparison failures without rewriting immutable old request fixtures.

## Task 3: Review and verification

**Files:** `README.md`, this plan, `docs/superpowers/reviews/2026-09-08-broader-intros.md`.

- [x] Update the user guide: Intro includes song/artist commentary; it supplies an editable suggested name, with descriptive fallback when a song title is unknown.
- [x] Review spec compliance and code quality independently; correct findings before completion.
- [x] Run the full cut-suggester Python tests and Swift tests, followed by `make -C QuickInterviewEditor format-check` and `make -C QuickInterviewEditor lint`. One xcodebuild at a time; capture actual counts and completion.
- [x] Record evidence and limits, check `git diff --check`, and commit the bounded correction locally. No push, merge, release, or modification of the user's existing projects.

## Completion

Implemented and independently reviewed. See [validation evidence](../reviews/2026-09-08-broader-intros.md). Historical fixture setup was corrected to decode captured configuration rather than current defaults; old request JSON remains unchanged.
