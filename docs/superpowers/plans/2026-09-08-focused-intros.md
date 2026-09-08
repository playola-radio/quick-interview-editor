# Single-Subject Intro Guidance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Classify an Intro only when one specific artist or one specific song is the clear central subject of the complete clip.

**Architecture:** Fresh configured-v5 discovery tightens the Intro prompt and built-in guidance. Fresh fields-v3 extraction adds an Intro-only subject check before naming; general discussion with incidental artists returns null for both default identity fields and flows through the existing Spotlight fallback. Preserve older prompt versions and request recovery verbatim. Upgrade exact prior built-in guidance strings without overwriting user edits.

**Tech Stack:** Python/pytest, Swift configuration defaults and version selection, Swift Testing/CustomDump, existing request journals.

## Required semantics

One artist OR one song must be the main subject of the entire candidate. A listener should naturally expect that song or music by that artist next. General discussion about the industry, a genre, a personal story or an artist's influences does not qualify merely because names occur. Roundups and comparisons with two or more coequal artists/songs are Spotlights. Do not choose one recognized name from a list to manufacture an Intro. A genuinely secondary comparison does not disqualify a passage with one clearly dominant subject; count subjects, not name tokens. Artist-only and self-referential song discussion can qualify, but the interview subject's identity alone is not subject evidence.

## Task 1: Versioned Python discovery and extraction

**Files:** `cut_suggester/suggestion_config.py`, `configured_discovery.py`, `configured_run.py`, `extraction.py`; focused Python tests.

- [x] Add RED tests for v5/v3 prompt contracts and real orchestration: multi-artist general talk with explicit double-null becomes Spotlight; single artist/song stays Intro; supporting comparison remains permitted; old v3/v4 discovery and fields-v1/v2 extraction bytes are pinned; custom/non-Intro extraction remains unaffected; successful requests replay without new calls.
- [x] Introduce a focused discovery version configured-v5 while preserving configured-v4 qualification semantics. Both v4/v5 use existing double-null/fallback orchestration and journal reuse; older versions keep exact behavior.
- [x] In v5 Intro discovery, require a single clear central subject and natural transition, and explicitly exclude general discussion, incidental examples, roundups and coequal comparisons. Do not count names mechanically.
- [x] In fields-v3, label each candidate's type in its required evidence. Add a scoped Intro instruction: establish one specific central artist or song before extracting either default identity field; if absent, return null for both despite recognizable mentions or supplied interview identity. Other candidate types use their configured field instructions normally. Carry forward the fields-v2 interview context behavior without modifying older prompt bytes. Count the extra text within existing mandatory input bounds.
- [x] Run `.venv/bin/python -m pytest tests -q`; inspect actual counts and recovery coverage. If credentials already exist in process environment, run a bounded synthetic provider check covering positive/negative subject examples; otherwise record that model recall remains unmeasured.

## Task 2: Swift defaults, migration, and fresh options

**Files:** `Models/SuggestionDefaults.swift`, `Models/CutSuggestOptions.swift`, `Views/Pages/CutSuggestions/SuggestionRunModel.swift`; default/configuration/run tests.

- [x] Update pinned default-guidance assertions and fresh-version expectations first; add migration assertions for both original handoff text and the latest broad text. Run focused Swift tests RED.
- [x] Replace the built-in Intro guide with the required semantics. Expand exact-string guidance migration to recognize both previous default generations, preserving edited instructions/templates and old project/run snapshots. Existing checked revision/atomic store migration remains unchanged.
- [x] Fresh options use configured-v5; fresh extraction selects fields-v3 for v5, fields-v2 for explicit v4, and fields-v1 for earlier versions. Update only fresh-default test expectations; keep historical fixtures.
- [x] Run focused Swift tests then full Swift verification with one xcodebuild owner.

## Task 3: Review and validation

- [x] Independently review single-subject scope, compatibility, user edits, prompt-size bounds, and failure-versus-null behavior.
- [x] Update README and validation notes with concrete examples and any live-evaluation limits. Incorporate the user's false-positive example if provided.
- [x] Run formatting/lint, git diff --check, and commit locally. No existing project mutation, push, or release.

## Validation notes

Python: 454 tests passed in 6.65 seconds. Historical discovery v1–v4 and extraction v1–v2 prompt hashes remain unchanged. Scripted provider cases exercise general multi-artist talk, coequal comparisons, a single artist, a single song, and a secondary comparison. These verify prompt contracts and routing, not measured model accuracy. No provider API credentials were present in the process environment, so no live evaluation ran.

Swift RED: the updated fresh-version assertion and exact broad-default migration assertions failed on the prior production code. An initially stale incremental test build was detected by the missing new test and old test count; touching the changed test sources produced the expected failing run. A later test compilation issue was corrected by injecting immutable options through the fixture initializer.

Independent review: no actionable correctness or compatibility findings. Formatting and strict lint passed with zero violations in 264 Swift files. Full Swift suite: 1,546 tests in 124 suites passed in 29.192 seconds, with 14 expected known issues. Fresh v5/v3 selection, explicit v4/v2 and v3/v1 selection, resumed snapshots, default migration, and user-edited guidance all passed.
