# Acceptance-Time Suggestion Numbering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Assign consecutive per-type/song numbers only when accepting saved clips, preserving issued identities across Undo and deletion.

**Architecture:** A pure pending-preparation function retains descriptive evidence and the captured configuration without allocating. A pure single-candidate acceptance function uses current project start floors and the permanent ledger; Editor commits its finalized candidate, clip, and issued identity together. Review previews use the same pure allocator without mutation.

**Tech Stack:** Swift 6, Observable models, Swift Testing, Dependencies, CustomDump, IdentifiedCollections.

## Task 1: Establish the acceptance contract with failing tests

**Files:** `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorSuggestionFlowTests.swift`, `QuickInterviewEditor/QuickInterviewEditorTests/Models/SuggestionRunTests.swift`.

- [x] Add an Editor regression using the real run fixture: search four descriptive candidates at start7, reject first, accept third then second, assert names7/8 and no pending reservations; Undo/reaccept second retains8, deleting7 does not release its number.
- [x] Add pure coverage for unissued historical reservations, issued same-owner reuse, independent song/type groups, captured templates, sequence-free templates, and Int.max acceptance failure without mutation.
- [x] Run `make -C QuickInterviewEditor test-fast ONLY=PlayolaInterviewEditorTests/EditorSuggestionFlowTests`; confirm new acceptance-order assertions fail before production edits.

## Task 2: Separate pending preparation and final allocation

**Files:** `QuickInterviewEditor/QuickInterviewEditor/Models/SuggestionRun.swift`, `QuickInterviewEditor/QuickInterviewEditor/Models/SuggestionDocumentMutation.swift`, `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift`, `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/CutSuggestions/SuggestionRunModel.swift`.

- [x] Introduce `preparePendingSuggestions(_:snapshot:starts:issued:)` returning candidates and batch. Use `naming.discoveryLabel` as pending title; retain only reservations already permanently issued to that owner. Preserve extraction/corrections and captured rules; do not allocate or inspect occupied counts.
- [x] Introduce `suggestionForAcceptance(_:batch:starts:issued:)` returning finalized candidate plus updated batch. Resolve normalized grouping using captured type/fields, prefer matching existing issued identity, otherwise allocate `max(startFloor, checkedIssuedMaximumPlusOne)` without pending occupancy. Canonical spelling comes from explicit batch override or previously issued group spelling.
- [x] Relax run-application validation for unassigned pending candidates; continue validating present reservations and finalized accepted candidates.
- [x] Have `suggestionSliceForAcceptance` validate audio/source before final allocation and expose finalized naming to Editor. In Editor's existing `mutateDocument(recordingPermanentReservations:)` transaction set candidate title/naming/status and append slice together.
- [x] Replace both run completion and Editor final-apply batch allocation with pending preparation. Accept older ready/needsNumbering checkpoints offline, without re-requesting provider work.
- [x] Normalize historical pending presentation when opening a document and restoring Undo, preserving saved clips and permanently issued owner identities without requiring another search.
- [x] Run the failing suites and adjust only superseded discovery-numbering expectations; keep pure legacy allocation helpers supported where unused by new flows.

## Task 3: Keep field review non-consuming and previews useful

**Files:** `QuickInterviewEditor/QuickInterviewEditor/Models/SuggestionNumbering.swift`, `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/CutSuggestions/SuggestionReviewModel.swift`, mirrored review tests.

- [x] Field correction changes corrected values only; leaves descriptive title and no newly assigned reservation. Same-group previously issued identity remains recoverable; changed groups allocate only upon acceptance.
- [x] Explicit canonical spelling updates the captured batch's canonical values without renaming saved clips or consuming numbers.
- [x] Compute prospective accepted-name previews with `suggestionForAcceptance`; do not persist preview allocations. Update explanatory copy to acceptance-time behavior.
- [x] Coordinate obsolete pending-renumber UI removal with root; retain compatibility decoding and unused pure helpers without exposing discovery-time allocation in normal actions.
- [x] Seed group spelling from captured explicit overrides, then issued canonical spelling, filtering out non-grouping fields. Derive clean spelling from the current document with sparse unsaved overrides; cover Apply→Undo and concurrent unrelated spelling edits.
- [x] Add regressions for field drafts/Undo, old snapshot after global template edits, missing-field fallback acceptance, and same-song canonical spelling across sequential accepts.

## Task 4: Verify recovery, fixture transport, and export integration

**Files:** existing `SuggestionRunModelTests.swift`, `SuggestionReviewTests.swift`, `EditorSuggestionFlowTests.swift`, `CutSuggestionWireTests.swift`.

- [x] Update fixture integration to assert descriptive pending labels and final template names only at acceptance.
- [x] Update full Editor start7/delete/rerun/Undo/exact-export flow: search completes without number conflict; the next acceptance gets the next safe number; independent project1 stays independent and export collisions still require review.
- [x] Preserve tests for saved clips under empty, failed, cancelled, rejected, and malformed replacement outcomes.
- [x] Run focused suites with repeated `-only-testing:PlayolaInterviewEditorTests/SuiteName` arguments, then scoped `xcrun swift-format lint --strict`, `swiftlint lint --strict`, and `git diff --check`.
- [x] Commit only owned core/model/test files and this plan. Root owns Page/Settings/ReviewView changes, native inspection, final broad verification, and independent reviews.

## Verification receipt

- Acceptance-order RED: `/tmp/acceptance-numbering-red.log`; hydration RED: `/tmp/acceptance-hydration-red.log`; canonical Undo RED: `/tmp/acceptance-canonical-undo-red.log` (four expected failures).
- Final GREEN: `/tmp/acceptance-numbering-final-verified.log`, 145 tests in seven suites, 1.488 seconds, `TEST SUCCEEDED`.
- Suites: EditorSuggestionFlowTests, SuggestionReviewTests, SuggestionRunTests, SuggestionRunModelTests, SuggestionSettingsTests, CutSuggestionsPageTests, CutSuggestionWireTests.
- Strict swift-format and SwiftLint passed for all 11 owned Swift files; `git diff --check` passed.
- Root retains final full-suite validation and independent review ownership.
