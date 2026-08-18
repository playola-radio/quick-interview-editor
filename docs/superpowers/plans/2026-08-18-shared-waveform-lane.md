# Shared Waveform Lane — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.
>
> **This is a self-contained brief for a FRESH context.** You are refactoring the core waveform stack of a native macOS SwiftUI app (QuickInterviewEditor) so one reusable waveform component is used identically in the main editor and a slice-detail modal. Read the spec first; then read the files it names before writing code.
>
> **Point-Free Workflow is mandatory.** Before writing code in ANY task, invoke every applicable `pfw-*` skill and list them in your checklist: `pfw-observable-models`, `pfw-dependencies`, `pfw-testing` + `pfw-custom-dump` (use `expectNoDifference`/`expectDifference`, never raw `#expect(a==b)` for value comparisons), `pfw-modern-swiftui` (views, `.sheet(item:)`, `@State`/`let` for reference-type models), `pfw-identified-collections`, `pfw-case-paths`.

**Goal:** Extract a reusable `WaveformLaneView` (ruler + waveform body + zoom/scroll/pan/click) backed only by a `WaveformModel`, used by both the main editor and the slice-detail modal, each with an independent viewport — giving the modal full zoom/scroll/pan + a clickable ruler.

**Architecture:** MV + `@Observable` (not MVVM/TCA), Point-Free libs, ZERO logic in views. `WaveformModel` is already a self-contained geometry engine; the coupling is in the view layer, which is bound to `EditorModel`. The lane holds a `WaveformModel` (reads geometry/display/zoom-state directly) and takes injected values (`playheadSample`, `highlightRange`) + semantic callbacks (raw view-x) + an optional audition overlay — no `EditorModel`.

**Tech Stack:** SwiftUI + AppKit (`NSViewRepresentable` interaction layers), Point-Free `swift-dependencies`/`swift-sharing`/`swift-custom-dump`, Swift Testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-08-18-shared-waveform-lane-design.md` (read it — it has the full coupling map and Codex review).

## Global Constraints

- **MV + `@Observable`, ZERO logic in views** — no hardcoded user-facing strings; views only lay out and forward. Layout/geometry (frames, spacing, mapping tap-x→sample, positioning a playhead line) IS the view's job and is fine, as long as it's pure geometry over model-provided values.
- **All coordinates are canonical PLAN samples.** Slice range `startSample..<endSample`.
- **Behavior-preserving where stated.** Phase 1 must not change the main editor's behavior — the existing test suite (~660 tests) staying green is the gate. Preserve exact word-select and marquee-with-auto-scroll semantics.
- **The modal's `WaveformModel` must ADOPT the parent's decoded pyramid — never call `load()` (that re-decodes the whole file).**
- **Tests:** Swift Testing, in the test-target dir `QuickInterviewEditor/QuickInterviewEditorTests/…` (NOT colocated in the app tree — a test in the app tree compiles into the app target and never runs). Use `Fixtures.editPlan()` (NOT `EditPlan.fixture`, which degrades to empty in the test process). `@Shared` declared locally per test. NEVER `Task.sleep`. Value comparisons via `expectNoDifference`. Test target must NOT directly link `Dependencies` (only `CustomDump`).
- **Build/test (FOREGROUND, blocking — never background `fastlane`/`xcodebuild`, never `tee` to a background job, never yield on a background wait):** `cd QuickInterviewEditor && xcodegen generate && bundle exec fastlane mac test`. Success = `fastlane.tools finished successfully` / `Suite … passed`, NOT `Executed 0 tests` (that's the empty XCTest harness line). Full run ~4-6 min. Lint: `make lint`. Format: `make format-check`.
- **Reuse, don't rewrite** `WaveformModel`'s geometry, `Waveform`, `TranscriptPageView`, `BoundaryInset`, the transport stack.

## Reference — verified APIs

- `WaveformModel` (`QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/WaveformModel.swift`): `var waveform: Waveform?`, `sampleRate`, `totalSamples`, `viewportWidth`, `samplesPerPixel`, `visibleStartSample`; `func load(url:planSampleRate:durationSamples:) async`; `viewportResized(width:)`; `zoomInTapped()`/`zoomOutTapped()`; `zoomByFactor(_:anchoredAtX:)`; `panByPixels(_:)`; `scrolled(toStartSample:)`; `zoomToFit(_:paddingFraction:)`; `zoomFitToggled(selection:)`; `visibleColumns()`; `columns(in:pixelWidth:)`; `xToSample(_:)`/`sampleToX(_:)`; `span(for:) -> WaveformSpan?`; `playheadX(for:) -> CGFloat?`; `hasUsableGeometry`; `showsLoading`/`showsEmpty`/`loadingMessage`/`emptyMessage`; `caption`; `canZoomIn`/`canZoomOut`/`zoomInLabel`/`zoomOutLabel`. Constants `minSamplesPerPixel`, `zoomStep`.
- `Waveform` (`Core/WaveformClient.swift:14`): `struct Waveform: Sendable, Equatable { var sampleRate: Int; var totalSamples: Int; var levels: [Level] }` (COW value data).
- `EditorModel` (`Views/Pages/Editor/EditorModel.swift`) coupling to relocate/adapt: `playheadX` (:285), `waveformHighlightSpan` (:281), `activeEditingRange` (:190), `rulerMovedPlayhead(toX:)` (:1100), `waveformClicked(atX:extending:)` (:445), `waveformAreaSelectBegan(atX:extending:)`/`Changed(toX:)`/`Ended(toX:)` (:468/:485/:499), `waveformScrolled(deltaX:deltaY:hasPreciseDeltas:optionDown:commandDown:atX:)` (:634), `scrollZoomFactor`/`scrollPanPixels` (:1567/:1574) + `pointsPerScrollLine`/`pixelsPerZoomDouble` constants, `canAudition` (:1307), `auditionStatusText`, `loadWaveform()` (:369), `editSlice`, `editSliceTapped(_:)`.
- Views to refactor (all `Views/Pages/Editor/`): `WaveformView.swift` (`WaveformView`, `WaveformCanvas`, `WaveformPlayhead`, `AuditionEdgeButtons`), `WaveformRulerView.swift` (`WaveformRulerView`, `RulerPlayhead`, `WaveformRulerInteractionLayer`), `WaveformInteractionView.swift` (`WaveformInteractionLayer`).
- Modal: `EditSlice/EditSliceView.swift` (has `SliceOverviewWaveform` to replace), `EditSlice/EditSliceModel.swift` (has `playheadSample`, `overviewWindow`, `columnsProvider`, `onSeek`, `updatePlayback`), `EditorView.swift` (mounts `WaveformView(model:)` at line ~17 and `.sheet(item: $model.editSlice)`).

---

# PHASE 1 — Extract the lane; main editor unchanged (behavior-preserving)

## Task 1: Move the scroll dispatch onto `WaveformModel`

Make ⌘-scroll-zoom / plain-scroll-pan a `WaveformModel` method so the lane's AppKit layers call it directly, with no `EditorModel`.

**Files:** Modify `WaveformModel.swift`, `EditorModel.swift`. Test: `QuickInterviewEditorTests/Views/Pages/Editor/WaveformScrollTests.swift` (new).

**Interfaces produced:** `WaveformModel.func scrolled(deltaX: CGFloat, deltaY: CGFloat, hasPreciseDeltas: Bool, optionDown: Bool, commandDown: Bool, atX positionX: CGFloat)`.

- [ ] **Step 1 — failing test.** New `WaveformScrollTests.swift`: build a `WaveformModel`, give it a viewport + adopted/loaded geometry (use whatever the existing `WaveformTests.swift` does to get usable geometry — read it), then assert `scrolled(..., commandDown: true, ...)` changes `samplesPerPixel` (zoom) anchored at x, and `scrolled(..., commandDown: false, ...)` changes `visibleStartSample` (pan) — mirroring the current `waveformScrolled` behavior. Use `expectDifference`/`expectNoDifference`.
- [ ] **Step 2 — run, verify RED.** `cd QuickInterviewEditor && xcodegen generate && bundle exec fastlane mac test` (foreground).
- [ ] **Step 3 — implement.** Move `scrollZoomFactor`/`scrollPanPixels` + the `pointsPerScrollLine`/`pixelsPerZoomDouble` constants from `EditorModel` onto `WaveformModel`, and add `WaveformModel.scrolled(...)` with the body currently in `EditorModel.waveformScrolled` (:634-648). Change `EditorModel.waveformScrolled` to delegate: `waveform.scrolled(deltaX:…, atX:)` (keep the method so existing callers/tests are unaffected).
- [ ] **Step 4 — run, verify GREEN** (new test + existing `WaveformTests`/`EditorRulerTests` etc. all pass).
- [ ] **Step 5 — lint + commit.** `make lint && make format-check`; `git commit -m "refactor(waveform): move scroll dispatch onto WaveformModel"`.

## Task 2: Extract `WaveformLaneView`; rewire the main editor to use it

The big refactor. Create the reusable lane and make `WaveformView` a thin wrapper whose lane callbacks are adapters calling today's `EditorModel` methods verbatim. Zero behavior change.

**Files:** Create `Views/Pages/Editor/WaveformLaneView.swift`. Modify `WaveformView.swift`, `WaveformRulerView.swift`, `WaveformInteractionView.swift` (relocate their render/interaction subviews into the lane, re-parameterized off `WaveformModel` + callbacks). No new unit test (the existing suite is the gate — the main editor must behave identically); reason about it in the report.

**Interface produced (use these exact names — Phase 2 depends on them):**

```swift
struct WaveformLaneView<Overlay: View>: View {
  let waveform: WaveformModel
  let playheadSample: Int?
  let highlightRange: Range<Int>?
  let onRulerMove: (CGFloat) -> Void            // raw view-x
  let onBodyClick: (CGFloat, Bool) -> Void      // raw view-x, extending
  let onAreaSelectBegan: (CGFloat, Bool) -> Void
  let onAreaSelectChanged: (CGFloat) -> Void
  let onAreaSelectEnded: (CGFloat) -> Void
  @ViewBuilder let auditionOverlay: (WaveformSpan) -> Overlay
}
```

The lane renders: the ruler strip (with a `RulerPlayhead` from `waveform.playheadX(for: playheadSample)`), then the band `ZStack` (`WaveformCanvas` reading `waveform.visibleColumns()` + the highlight rect from `highlightRange.flatMap(waveform.span(for:))`, `WaveformPlayhead` from `playheadX`), the two interaction layers, the audition overlay (shown when the highlight span resolves), and `.onGeometryChange { waveform.viewportResized(width:) }`. Zoom is **not** in the lane (owner header owns the buttons); ⌘+scroll is handled by the interaction layers via `waveform.scrolled(...)`.

- [ ] **Step 1 — build the lane.** Create `WaveformLaneView.swift`. Move `WaveformCanvas`, `WaveformPlayhead` (from `WaveformView.swift`), `RulerPlayhead` (from `WaveformRulerView.swift`), and the two `NSViewRepresentable` interaction layers into it, re-parameterizing each off `WaveformModel` + the injected values/callbacks instead of `EditorModel`:
  - `WaveformCanvas`: reads `waveform.visibleColumns()` + a `highlight: WaveformSpan?` passed in (computed once in the lane body: `highlightRange.flatMap(waveform.span(for:))`).
  - `WaveformPlayhead`/`RulerPlayhead`: `waveform.playheadX(for: playheadSample)`.
  - `WaveformRulerInteractionLayer`: `mouseDown`/`mouseDragged` → `onRulerMove(localX)`; `scrollWheel` → `waveform.scrolled(...)`.
  - `WaveformInteractionLayer`: click/marquee → `onBodyClick`/`onAreaSelect*` (raw x, same drag-threshold logic as today); `scrollWheel` → `waveform.scrolled(...)`.
  - Audition overlay: `.overlay(alignment: .topLeading) { if let span = highlightRange.flatMap(waveform.span(for:)) { auditionOverlay(span) } }`.
- [ ] **Step 2 — rewire `WaveformView`** to a thin wrapper: keep the `header` (transport panel, caption, audition status, zoom buttons — all still `EditorModel`) and below it mount:
  ```swift
  WaveformLaneView(
    waveform: model.waveform,
    playheadSample: model.playheadSample,
    highlightRange: model.activeEditingRange,
    onRulerMove: { model.rulerMovedPlayhead(toX: $0) },
    onBodyClick: { model.waveformClicked(atX: $0, extending: $1) },
    onAreaSelectBegan: { model.waveformAreaSelectBegan(atX: $0, extending: $1) },
    onAreaSelectChanged: { model.waveformAreaSelectChanged(toX: $0) },
    onAreaSelectEnded: { model.waveformAreaSelectEnded(toX: $0) },
    auditionOverlay: { span in
      if model.canAudition { AuditionEdgeButtons(model: model, span: span) }
    }
  )
  ```
  (`activeEditingRange` and `playheadSample` are already `EditorModel` members. `AuditionEdgeButtons` stays `EditorModel`-bound and lives in the main editor wrapper file, not the lane.) Delete the now-relocated subviews from the old files; `WaveformRulerView.swift`/`WaveformInteractionView.swift` are absorbed into the lane (remove or reduce them).
- [ ] **Step 3 — regenerate + build + FULL suite (the gate).** `cd QuickInterviewEditor && xcodegen generate && bundle exec fastlane mac test` (foreground). The entire existing suite must pass with NO behavior change (marquee, word-select, ruler, zoom, pan, audition all identical). If anything changed behaviorally, fix it — the point of Phase 1 is provable equivalence.
- [ ] **Step 4 — lint + commit.** `make lint && make format-check`; `git commit -m "refactor(waveform): extract reusable WaveformLaneView; main editor uses it via adapters"`.

---

# PHASE 2 — Modal gets the real lane + tweaks

## Task 3: `WaveformModel.adopt` + adoption timing

Let a second `WaveformModel` reuse the parent's decoded pyramid with no re-decode.

**Files:** Modify `WaveformModel.swift`, `EditorModel.swift`. Test: `WaveformScrollTests.swift` or a new `WaveformAdoptTests.swift`.

**Interface produced:** `WaveformModel.func adopt(_ waveform: Waveform, sampleRate: Int, totalSamples: Int)`.

- [ ] **Step 1 — failing test.** `adopt` sets `waveform`/`sampleRate`/`totalSamples`, `isLoading == false`, `hasWaveform == true`; and two models that adopt the same `Waveform` but get different `viewportResized`/zoom keep **independent** `samplesPerPixel`/`visibleStartSample` (assert the shared decoded value, independent viewport).
- [ ] **Step 2 — RED.**
- [ ] **Step 3 — implement.** Add `adopt(_:sampleRate:totalSamples:)`: set the three fields + `isLoading = false`; if `viewportWidth > 0`, set `samplesPerPixel = clampedSamplesPerPixel(fitSamplesPerPixel())` and `visibleStartSample = clampedStart(visibleStartSample)` (mirror the tail of `load()`). Then wire timing in `EditorModel`: in `loadWaveform()` after the parent decode, if `editSlice != nil` call `editSlice.adoptParentWaveform(...)` (add a small method on `EditSliceModel` in Task 4); and `editSliceTapped` adopts immediately if `waveform.waveform != nil`.
- [ ] **Step 4 — GREEN.**
- [ ] **Step 5 — lint + commit** `git commit -m "feat(waveform): adopt() to share a decoded pyramid across models"`.

## Task 4: `EditSliceModel` owns a `WaveformModel` scoped to the slice

**Files:** Modify `EditSlice/EditSliceModel.swift`. Test: `EditSlice/EditSliceTests.swift` (in the test-target dir).

**Interfaces produced:** `EditSliceModel.waveform: WaveformModel`; `func adoptParentWaveform(_ w: Waveform, sampleRate: Int, totalSamples: Int)` (adopts + focuses the viewport on the slice with padding); slice-scoped `func rulerMoved(toX:)` / `func bodyClicked(atX:extending:)` that map x→sample via `waveform.xToSample` and move the modal cursor (+ seek if playing — Task 6); `var highlightRange: Range<Int>? { fineTune.draftRange ?? fineTune.committedRange }`.

- [ ] **Step 1 — failing tests.** After `adoptParentWaveform(Fixtures.editPlan()`'s waveform via a constructed `Waveform` or by adopting from a loaded parent — read how tests build a `Waveform`; if none, build a small one with `Waveform.pyramid(...)`), assert: the viewport is focused near the slice range (visible window overlaps `startSample..<endSample`, not the whole file), `waveform.hasWaveform`, and `highlightRange == fineTune.draftRange`. `rulerMoved(toX:)` sets `playheadSample` to `waveform.xToSample(x)` (clamped).
- [ ] **Step 2 — RED.**
- [ ] **Step 3 — implement.** Add `let waveform = WaveformModel()`; `adoptParentWaveform(...)` → `waveform.adopt(...)` then `waveform.zoomToFit(slice.startSample..<slice.endSample, paddingFraction:)` (choose padding, e.g. 0.5, so context shows on both sides — verify `zoomToFit`'s param name/semantics in `WaveformModel.swift`). Add `rulerMoved(toX:)`/`bodyClicked(atX:extending:)` mapping via `waveform.xToSample`, updating `playheadSample` and the scoped transcript current word (reuse `updatePlayback`'s highlight path or `transcript.currentWordChanged(toSample:)`). Keep it geometry→cursor; the seek-during-playback part is Task 6.
- [ ] **Step 4 — GREEN.**
- [ ] **Step 5 — lint + commit** `git commit -m "feat(editor): EditSliceModel owns a slice-scoped WaveformModel"`.

## Task 5: `EditSliceView` mounts the shared lane; near-full-window frame

**Files:** Modify `EditSlice/EditSliceView.swift`. (View — build-gated, no unit test.)

- [ ] **Step 1 — replace `SliceOverviewWaveform`** with `WaveformLaneView(waveform: model.waveform, playheadSample: model.playheadSample, highlightRange: model.highlightRange, onRulerMove: { model.rulerMoved(toX: $0) }, onBodyClick: { model.bodyClicked(atX: $0, extending: $1) }, onAreaSelectBegan/Changed/Ended: no-ops (`{ _,_ in }`/`{ _ in }` — the modal doesn't marquee), auditionOverlay: { _ in EmptyView() })`. Add zoom-in/out buttons (calling `model.waveform.zoomInTapped()`/`zoomOutTapped()`, disabled via `canZoomIn`/`canZoomOut`) to the modal's transport row or a small header. Delete the `SliceOverviewWaveform` struct.
- [ ] **Step 2 — near-full-window frame.** Change `.frame(minWidth: 720, minHeight: 560)` to expand toward the 1200×800 window — e.g. `.frame(minWidth: 1100, idealWidth: 1160, maxWidth: .infinity, minHeight: 720, idealHeight: 760, maxHeight: .infinity)`. Verify the sheet opens large; adjust so it "almost takes up the entire window."
- [ ] **Step 3 — regenerate + build + full suite green** (foreground). Manually reason the lane is wired to the modal's own `waveform`/`playheadSample` (independent viewport).
- [ ] **Step 4 — lint + commit** `git commit -m "feat(editor): modal uses the shared WaveformLaneView (zoom/scroll/ruler) + larger sheet"`.

## Task 6: Interactive seek during playback

**Files:** Modify `EditSliceModel.swift` and/or the `onSeek`/ruler wiring in `EditorModel.editSliceTapped`. Test: `EditSliceTests.swift`.

- [ ] **Step 1 — failing test.** While the modal is "playing" (drive `updatePlayback(sample:isPlaying:true)`), a `rulerMoved(toX:)` / seek must reposition and re-anchor playback (v1: stop + move cursor to the clicked sample), not be silently overwritten. Assert the cursor lands on the clicked sample and playback is stopped/re-anchored (via a spy on the transport closures).
- [ ] **Step 2 — RED.**
- [ ] **Step 3 — implement.** In the modal ruler/seek path, if playing, stop transport (through the existing `onStop`/transport closure) then set the cursor — matching the main editor's `rulerMovedPlayhead` (which calls `stopTransportForRuler()` before setting the cursor). Update the R4/onSeek comment accordingly.
- [ ] **Step 4 — GREEN.**
- [ ] **Step 5 — lint + commit** `git commit -m "fix(editor): modal ruler/seek repositions during playback"`.

## Task 7: 1.0× speed on open, restored on close

**Files:** Modify `EditorModel.swift` (`editSliceTapped` + the modal's `onDismiss` wiring). Test: `EditorEditSlicePresentationTests.swift`.

- [ ] **Step 1 — failing test.** With the shared `playbackRate` set to e.g. 2.0, `editSliceTapped` sets it to 1.0; on dismiss it restores 2.0. (`playbackRate` is `@Shared(.playbackRate)` on `TranscriptPageModel`; set via `transcript.speedSelected(_:)`. Declare the `@Shared` locally in the test.)
- [ ] **Step 2 — RED.**
- [ ] **Step 3 — implement.** In `editSliceTapped`: capture `let saved = transcript.playbackRate` (store on an `@ObservationIgnored private var savedPlaybackRate: Double?`), and if `!= 1.0` call `transcript.speedSelected(1.0)`. In the child's `onDismiss` (or the sheet's `onDismiss`), restore `savedPlaybackRate` via `transcript.speedSelected(saved)` and clear it. Verify restore fires on Save, Cancel, AND Escape dismissal.
- [ ] **Step 4 — GREEN.**
- [ ] **Step 5 — lint + commit** `git commit -m "feat(editor): modal edits at 1.0x speed, restores prior speed on close"`.

## Task 8: Full green + manual QA + adversarial review

- [ ] **Step 1 — full green.** `cd QuickInterviewEditor && xcodegen generate && bundle exec fastlane mac test`; `make lint && make format-check`.
- [ ] **Step 2 — manual QA.** Launch the dev app (`launchctl setenv QIE_ENGINE_REPO "$(git rev-parse --show-toplevel)"`; then `open "$(xcodebuild -scheme QuickInterviewEditor -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}')/QuickInterviewEditor.app"`). Verify: opening the modal (Edit / double-click) never moves the MAIN waveform; the modal waveform zooms (⌘+scroll and buttons), scrolls/pans, and the ruler strip above it click-moves the playhead; zoom/scroll in the modal does NOT move the main lane; the draft cut is highlighted; the modal opens near-full-window at 1.0× and restores your main speed on close; save/cancel/undo still correct.
- [ ] **Step 3 — Codex adversarial pass** (per CLAUDE.md pipeline — this is a real core refactor): `codex` review then challenge on the branch diff; fix what's surfaced; re-run if non-trivial. Focus: no re-decode (adoption timing), independent viewports, no marquee/word-select regression in the main editor, no retain cycles in the new lane callbacks.
- [ ] **Step 4 — hand off** to `/ship` or the PR flow.

## Self-Review (plan author)

- **Spec coverage:** lane extraction (Task 2) with `WaveformModel`-only backing + injected surface (spec "Decision"); scroll-dispatch move (Task 1, spec "Move the scroll dispatch"); `adopt` + timing (Task 3, spec "Pyramid sharing"); modal viewport zoomed-to-slice+padding + highlight=draft (Task 4, spec "Modal viewport"); modal lane mount + near-full-window (Task 5); interactive seek (Task 6, spec "Interactive ruler ⇒ seek"); 1.0× speed (Task 7, spec "Folded-in tweaks"). Non-goals (sheet key monitor, modal marquee, modal audition) are not implemented. ✅
- **Behavior-preservation gate:** Phase 1's adapters call the exact existing `EditorModel` methods with raw x; the auto-scroll timer stays in `EditorModel`; the existing suite is the gate. ✅
- **Type consistency:** `WaveformLaneView` signature is identical in Tasks 2 and 5; `adopt(_:sampleRate:totalSamples:)`, `adoptParentWaveform`, `rulerMoved(toX:)`, `bodyClicked(atX:extending:)`, `highlightRange` used consistently. ✅
