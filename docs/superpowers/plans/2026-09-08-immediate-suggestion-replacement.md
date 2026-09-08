# Immediate Suggestion Replacement Implementation Plan

**Goal:** Confirming Replace Suggestions immediately clears the previous suggestions, before asynchronous search preparation. Cancel preserves the document. Saved clips and their issued numbers remain safe.

**Architecture:** Add a synchronous throwing `onReplacementConfirmed` intent to `SuggestionRunModel`. Call it after validating the confirmation and before fresh/resumed work. Wire it through the editor's existing non-undoable mutation funnel to clear `cutSuggestions` and `suggestionBatch`; that funnel rebases history and publishes document changes for autosave. Fresh preparation and confirmed resume capture the resulting empty baseline. Failures, cancellation, and discarding the new run leave the cleared list empty.

**Tech Stack:** Swift Observable models, Swift Testing, CustomDump, existing recovery fixtures.

- [x] Update run tests to assert an empty list before provider work and after failure/cancel/discard. Changed-baseline resume tests must insert a new suggestion after clearing before requesting replacement again. Verify RED.
- [x] Add `onReplacementConfirmed: @MainActor () throws -> Void`, defaulting to a missing-run error; invoke it before the first await in `replaceConfirmed()`. Surface callback failures without starting work.
- [x] Wire the editor callback using `mutateDocument(recordUndo: false) { $0.cutSuggestions = []; $0.suggestionBatch = nil }`. Preserve the editor callback when test recovery fixtures are installed.
- [x] Add editor integration coverage: confirmation immediately publishes the cleared document, preserves clips/numbering, and undoing earlier clip edits cannot resurrect suggestions. Verify preparation observes the cleared list.
- [x] Update dialog wording and the current spec/README to describe immediate clearing and empty results during failures. Run full Swift tests, formatting/lint, independent review, and commit locally.

## Validation

Regression RED: five expected failures demonstrated suggestions remaining before provider completion and after failure/cancel/discard. The local Xcode incremental build initially reused stale test objects; removing only the affected generated object files forced compilation of the edited sources. No project regeneration or dependency changes were needed.

Editor integration verifies clearing before recovery preparation, publication of the empty document for autosave, preservation of saved clips and numbering, and no resurrection through undo. Existing parameterized tests cover provider, extraction, preparation, invalid-output, cancellation, and valid-empty outcomes. Resume checks verify replacement confirmation and a fingerprint of the newly cleared baseline.

Independent read-only review found no actionable issues, including predecessor journal recovery after discard/reopen. Formatting and strict lint passed with zero violations in 264 files. Full Swift suite: 1,547 tests in 124 suites passed in 28.182 seconds, with 14 expected known issues.
