# Transcript Page — Step 1 follow-ups (non-blocking)

From the per-task + final whole-branch reviews + Codex adversarial pass. None block
merge of Step 1; bundle the view-polish ones into one small PR, track the rest.

## Fixed after the Codex adversarial pass (in this branch)
- **Selection is now position-based, not ID arithmetic** — `selectedWords` slices the
  transcript by position, so `selectionSummary`/`isSelected`/`selectedSampleRange` are
  correct on sparse/reordered IDs (Codex #1/#2). `selectedSampleRange` guards against an
  inverted range. Regression test: `selectionCountsWordsByPositionNotIDSpan`.
- **App no longer traps on a malformed plan** — `recomputeWords` uses
  `IdentifiedArray(_:uniquingIDsWith:)` instead of `uniqueElements:` (Codex #4).
  Regression test: `duplicateWordIDsDoNotTrap`.
- **Tests prove the dependency injection** — added `viewAppearedUsesInjectedEngineNotBundle`
  with a 2-word sentinel plan, which fails if `loadPlan` is bypassed (Codex #7).
- Codex #6 ("test target can't import Dependencies") was a **false positive** — the suite
  compiles + 15 tests pass via the verified transitive `@testable` link.

## View polish (one cohesive follow-up PR)
- **displayRole enum:** move the view's `color(for:)` boolean-mapping onto the model —
  add `WordViewState.displayRole` (`.selected/.runTogether/.normal`) and `switch` in the
  view (colors stay in the view). Removes the last seam where view logic could creep in.
- **Slider binding:** revert `TranscriptPageView` slider to the plan's `Binding(get:set:)`
  funneling through `sensitivityChanged` (drop the raw `$model` binding + `.onChange`
  double-write). Pairs with the displayRole change.
- **Empty-state string assertions:** test `selectionSummary` == "No selection" and the
  exact `runTogetherCountLabel` string.

## Resolved in Step 2 (plan: `plans/2026-07-04-step2-import-live-engine.md`)
- **testValue SIGTRAP hardening — DONE (Task 4).** `EngineClient.testValue.loadPlan` and the
  new `.transcribe` both now `reportIssue` + throw `EngineClientError.unimplemented(...)` when a
  test forgets to override them, instead of routing to `.fixture`. A separate `previewValue`
  keeps fixture convenience for SwiftUI previews. (`EditPlan.fixture` already degraded
  gracefully via `reportIssue` rather than force-unwrapping.)
- **`Silence` typed as sample indices — DONE (Task 2).** Retyped `EditPlan.Silence` from
  `Double` (which read like seconds) to `startSample: Int`/`endSample: Int`, matching the
  engine's actual sample-valued output. (Surfaced during the Step-2 Codex design pass.)

## Track against Step 3+ (latent, surface when the surface grows)
- **wordTapped repeat-tap edge case:** tapping the same word twice collapses
  `anchor==focus`, so the "third click resets" cycle can be bypassed. Fix + regression test
  when selection interaction is exercised harder.

## Cosmetic
- 2 residual `objc duplicate-class` warnings in test output (down from 6) from a Point-Free
  lib arriving via both the app target and `CustomDump`'s transitive graph. Chase when the
  SPM graph is next touched.
