# Interview Artist and Intro Qualification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Resolve first-person artist references using optional project context, move nameless Intros to appropriate Spotlight naming, and remove redundant Types choices.

**Architecture:** Persist an optional interviewArtist on EditorDocumentState and capture it in SuggestionRunSnapshot. Add optional interview_artist to the immutable V2 request, preserving absent-key identity for old runs. Fresh configured-v4/fields-v2 orchestration retains versioned older behavior and qualifies Intros after extraction before final overlap resolution.

**Tech Stack:** SwiftUI, Observable models, Swift Testing/CustomDump/Sharing; Python/pytest and request journals.

**Approved spec:** [Interview artist design](../specs/2026-09-08-interview-artist-design.md).

## Task 1: Project identity and menu UI

**Files:** `QuickInterviewEditor/QuickInterviewEditor/Models/EditorDocumentState.swift`; `Views/Pages/Project/ProjectModel.swift`, `ProjectView.swift`; `Views/Pages/SuggestionSettings/SuggestionSettingsModel.swift`, `SuggestionSettingsView.swift`; `Views/Pages/CutSuggestions/CutSuggestionsPageModel.swift`, `CutSuggestionsPageView.swift`; existing Editor wiring and corresponding tests.

- [x] Add failing model tests for trimmed optional import name, persistence/old decode/retranscription, settings Save/Clear/Undo and isolation from app-wide rule drafts, and singleton/default versus custom/multiple-type menu rows. Coordinate root-owned Swift tests so RED is actually observed before implementation.
- [x] Add `var interviewArtist: String?` with default nil and decodeIfPresent to document state. Import's optional text field seeds new content without overwriting existing project context during retranscription. Use model-owned display text and bindings; no view business logic.
- [x] Add project Interview navigation in settings, draft text and explicit Save via existing document mutation callback pattern. Use page/model callbacks wired through EditorModel.mutateDocument for Undo and autosave. Retain Numbering behavior and independent rule drafts.
- [x] Add a model-derived list of visible child filter rows: empty only for the one unrenamed conventional built-in child; otherwise existing rows. View renders that list. Group state still uses all actual child types.
- [x] Root runs focused suites with `make -C QuickInterviewEditor test-fast ONLY=PlayolaInterviewEditorTests/CutSuggestionsPageTests` and relevant Project/Settings/Editor suites; inspect actual counts.

## Task 2: Snapshot and cross-language transport

**Files:** `Models/SuggestionRun.swift`, `Models/CutSuggestOptions.swift`, `Core/LiveCutSuggester.swift`, `Core/SuggestionRecoveryArchive.swift`, `Views/Pages/CutSuggestions/SuggestionRunModel.swift`; corresponding Swift tests.

- [x] Test old snapshot decode, fresh captured name, encoded optional context, identity validation rejecting a changed name, and resume using the original name after project edits. Run tests RED.
- [x] Add defaulted optional `interviewArtist` to snapshot Codable and decodeIfPresent. Capture `document.interviewArtist` at fresh start; use configured-v4 and fields-v2 for fresh defaults while keeping explicitly historical versions unchanged.
- [x] Encode optional `interview_artist` from snapshot. Recovery immutableRequest copies this key only if present and validateManifest compares it to the snapshot, treating absent and nil appropriately without altering historical bytes.
- [x] Run focused recovery/wire/run suites and adjust fresh-default expectations only; do not rewrite historical fixtures.

## Task 3: Extraction evidence and Intro fallback

**Files:** `cut_suggester/configured_run.py`, `suggestion_config.py`, `configured_discovery.py`, `extraction.py`, a focused helper module if needed; Python tests.

- [x] Add failing tests for optional context validation/identity, own-music/other-artist extraction prompt instructions, old prompt byte parity, successful double-null qualification, single-field retention, failed-request retry, removed definitions, omitted naming fields, fallback Spotlight naming fields/IDs, overlap restoration, and replay after either extraction stage.
- [x] Add configured-v4 to the broad routing branch while leaving v3 semantics/prompt bytes pinned. Optional interview_artist must be nonblank text when supplied; immutable_request includes it only when present. Add interview context only for fields-v2.
- [x] For v4 Intro extraction, request both available default qualification fields regardless of naming-template references. Existing configured field instructions remain authoritative. Keep extra qualification values separate from the set of values Swift names require.
- [x] After validated successful extraction, identify double-null Intros. Prefer restoring an existing overlapping tuned Spotlight. Otherwise convert complete 15–240-second commentary to the configured Spotlight, recompute candidate UUID from final type/span, clear old fields, and extract the Spotlight's own required fields. Omit when Spotlight is absent or outside bounds. Reapply surviving Intro priority and same-type deduplication, preserving unrelated custom/imaging candidates.
- [x] Keep failed batches visible/retryable, and journal successful extraction requests so resume never repeats paid successes. Run `.venv/bin/python -m pytest tests -q` and inspect completion.

## Task 4: Integrate and review

- [x] Independently review spec compliance and code quality across the three tasks. Resolve findings within the approved scope.
- [x] Update README and validation evidence. Run full Swift and Python suites, then `make -C QuickInterviewEditor format-check` and `make -C QuickInterviewEditor lint`. One xcodebuild owner; no interactive waiting UI harness.
- [x] Check `git diff --check`, record actual tests and live-recall limitations, and commit locally. Do not alter the user's existing projects, push, or release.

## Completion

Implemented and independently reviewed. See [validation evidence](../reviews/2026-09-08-interview-artist.md). Final Spotlight extraction keeps normal batching and reuses successful journaled fields even when qualification changes the selected set.
