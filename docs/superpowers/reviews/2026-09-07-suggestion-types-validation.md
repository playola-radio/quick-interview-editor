# Configurable Suggestions validation

Implementation and review evidence for the approved [design](../specs/2026-09-07-suggestion-types-design.md) and [implementation plan](../plans/2026-09-07-suggestion-types.md).

## Delivered behavior

Suggestions support Spotlights, Song Intros, and four Audio Image defaults, plus custom types. App-wide rules include editable discovery guidance, extraction fields, and naming templates. Project-owned counters support future starting numbers and song-specific overrides. Existing batches retain their captured rules; issued numbers survive clip deletion and Undo. Users can filter types, correct fields, review numbering, replace suggestions while keeping saved clips, and resume interrupted work without repeating successful requests. Generated export names receive explicit collision review.

All 17 implementation tasks received separate specification and code-quality reviews. The final integration commits are `199d424` (Python/editorial) and `42d60f2` (Swift/editor integration). Review fixes were verified before the corresponding task was accepted. No changes were pushed or merged.

## Automated verification

Final Python verification at `199d424` (no subsequent Python changes):

- `python3 -m pytest -q`: **373 passed**, 5.64 seconds.
- `python3 -m evals.cut_suggestions.runner --mode cached --json`: succeeded; all **24** Joe Miller candidate `(start_index, end_index, label)` tuples exactly match the pinned baseline before generated naming.
- `python3 -m evals.cut_suggestions.editorial_runner --mode cached`: succeeded with **9/9 exact expected spans**, no negative matches, no extra predictions, and no unexpected overlaps.

Final Swift verification at `2495dde`, with the temporary native harness removed:

- `make -C QuickInterviewEditor test-fast`: **1,510 tests in 124 suites passed**, 28.732 seconds, with 14 expected known issues and no unexpected failures.
- The full formatting check initially found two misindented continuation lines in `SuggestionNaming.swift`. Only their whitespace was corrected; no behavior changed after the full test run.
- After that whitespace correction, `make -C QuickInterviewEditor format-check`, `make -C QuickInterviewEditor lint`, and `git diff --check` all passed. SwiftLint reported zero violations across 264 files.

Meaningful integration coverage includes the shared V2 request/result fixture, all six defaults and a custom type, strict field-response matching, failed-batch recovery without repeated successful requests, captured discovery-version dispatch, stale configuration drafts, immutable naming snapshots, and atomic replacement across success, empty success, cancellation, and failure. Editor tests cover explicit start 7, acceptance/deletion with a permanent reservation, a later conflict requiring at least 8, offline correction, deletion Undo, and independent project counters. Export tests include actual temporary AIFF renders, exact generated filenames, sanitization/case/UTF-8 collisions, copy-time races, renewed approval, partial-copy retention, and cancellation cleanup.

## Editorial quality evidence

The existing tuned discovery prompt bytes remain unchanged. Fresh configured runs opt into `configured-v2`, which refines Intro boundaries and requests separate repeated imaging takes. Older captured runs retain their original behavior.

Actual gpt-4o responses against the synthetic suggestion-types dataset are committed under `evals/cut_suggestions/editorial_cache/configured-v2/`. An initial run found 9 takes but failed the exact-span gate by trimming relevant Intro setup. After correcting refinement guidance, the integrated pipeline returned all 9 exact spans, correct performer/title fields, separate repeated IDs, a complete promo and its independently usable nested ID, both break transitions, and the unchanged Spotlight. A fresh-journal cached replay produced the same result. The final pass reused three unchanged genuine discovery responses and obtained new refinement/extraction responses.

This is **synthetic gpt-4o evidence**, including the post-commercial example; it is not production Claude validation or a quality guarantee for other recordings. Scripted cross-language integration fixtures demonstrate transport and recovery correctness, not editorial quality. See the [evaluation notes](../../../evals/cut_suggestions/README.md) for commands, metrics, and precise spans.

## Native UI inspection

Production SwiftUI views were hosted in isolated native macOS windows using synthetic document state and injected dependencies. Real screenshots and accessibility actions verified:

- Types all/none/group/subtype selection and visible mixed checkmarks; filtering preserved the accepted clip.
- Combined `Wildflowers 1, Tom Petty` naming preview; missing-field draft correction applied only on Apply; appropriate disabled actions.
- Two configuration windows: Save published a new revision, a stale draft was rejected, Reload adopted the new rules, and Cancel discarded edits.
- Saving a song start of 9 and resetting it; saving a future Spotlight start of 7 and exercising Undo/Redo.
- The replacement dialog explicitly states that saved clips remain safe; Cancel preserved the batch and clip and made no provider request.
- Export collision review displayed requested `ID 7.aiff` and proposed `ID 7 2.aiff` with a visible warning.

The native fixture run ended successfully: 17 tests in one suite, including the temporary interactive test. That test intentionally waited for external UI actions and took 846.9 seconds; its temporary code was removed afterward. An accessibility action failed while transitioning out of the replacement dialog. The session was explicitly finished rather than left waiting. Subsequent native cancel/resume, numbering-conflict correction, deletion/Undo, and export-copy actions were **not completed through the UI**; their model/integration regressions passed separately. Native DocumentGroup Save As and VoiceOver speech were not exercised. Accessible control labels, focus, and enabled states were inspected.

The inspection also found type-wide counter rows incorrectly labeled “Unresolved group.” Commit `2495dde` corrects that label while preserving the existing review/renumber entry point. Its regression failed before the fix; all 26 page tests passed afterward, and independent review found no actionable issues.

Local screenshots, state receipts, and command logs are retained in the gitignored `.context/native-verification/interactive/` directory. No fixture mode, test windows, or temporary automation harness ships in the app.
