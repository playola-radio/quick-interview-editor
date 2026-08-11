# Waveform Multi-Select + Logic-Parity Zoom/Nav Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Logic-Pro-parity waveform interaction to the editor — Shift-click to extend the word selection, cursor-anchored mouse-wheel zoom, wheel pan, and the ⌘←/⌘→/Z zoom keys — with all logic in the `@Observable` models.

**Architecture:** All decision logic lives in `WaveformModel`, `EditorModel`, and `TranscriptPageModel`. Two thin AppKit surfaces translate raw events into model calls: a window-scoped `NSEvent` key monitor for editor-global shortcuts, and a transparent `NSView` interaction layer over the waveform `Canvas` for scroll/click/drag. The `Canvas` stays a pure renderer.

**Tech Stack:** SwiftUI + AppKit (`NSViewRepresentable`, `NSEvent`), swift-dependencies, Swift Testing, swift-custom-dump. Spec: `docs/superpowers/specs/2026-08-11-waveform-multiselect-zoom-design.md`.

## Global Constraints

- **MV architecture:** `@MainActor @Observable` models hold all state + logic; views/NSViews are dumb translators. Zero logic in views — no conditional deciding what to show/do.
- **Testing:** Swift Testing (`import Testing`, `@MainActor struct …Tests`, `@Test`). Value comparisons use `expectNoDifference` from `CustomDump`, not `#expect(a == b)`. No `Task.sleep`. Tests use fixtures/synthetic geometry — no audio, no subprocess, no `NSEvent`.
- **Build/test (headless):** `cd QuickInterviewEditor && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates`. Success = the `Test run with N tests … passed` line (Swift Testing prints `Executed 0 tests` for the empty XCTest harness — ignore that line).
- **New files:** the Xcode project is XcodeGen-generated. **After creating any new `.swift` file, run `cd QuickInterviewEditor && xcodegen generate` before building.** Files added to existing directories are picked up by the directory globs.
- **Lint/format before each commit:** `cd QuickInterviewEditor && make format && make lint`.
- **Commit messages:** no `Co-Authored-By` / co-sign trailer (per user's global rule).
- **Coordinates:** everything in PLAN samples; `samplesPerPixel` larger = more zoomed out; `minSamplesPerPixel = 8`, `zoomStep = 2` already exist on `WaveformModel`.
- **Scroll/pan/zoom sign:** device sign conventions vary; tests assert direction-agnostic properties (monotonicity, anchor-invariance, clamping). The literal on-screen direction is verified in the Task 7 manual QA and is a one-line constant flip if inverted.

---

### Task 1: WaveformModel — cursor-anchored zoom + wheel pan geometry

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/WaveformModel.swift`
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/WaveformTests.swift`

**Interfaces:**
- Consumes: existing `samplesPerPixel`, `visibleStartSample`, `viewportWidth`, `totalSamples`, `visibleSampleCount`, `xToSample`, `sampleToX`, `clampedStart`, `clampedSamplesPerPixel`, `scrolled(toStartSample:)`, private `zoom(by:)`.
- Produces:
  - `func zoomByFactor(_ factor: Double, anchoredAtX x: CGFloat)` — multiplies `samplesPerPixel` by `factor` (clamped) while keeping the plan sample under `x` fixed.
  - `func panByPixels(_ deltaX: CGFloat)` — pans the viewport by `deltaX` pixels' worth of samples (clamped).

- [ ] **Step 1: Write the failing tests**

Append to `WaveformTests.swift` (inside `struct WaveformTests`, after the existing tests):

```swift
  // MARK: - Cursor-anchored zoom + wheel pan

  @Test func zoomByFactorKeepsSampleUnderCursorFixedZoomingIn() {
    let model = makeModel(
      totalSamples: 1_000_000, viewportWidth: 1000, samplesPerPixel: 100, start: 200_000)
    let cursorX: CGFloat = 400
    let sampleUnder = Double(model.xToSample(cursorX))
    model.zoomByFactor(0.5, anchoredAtX: cursorX)  // zoom in
    #expect(model.samplesPerPixel == 50)
    // the same sample is still drawn within a pixel of the cursor
    #expect(abs(Double(model.sampleToX(Int(sampleUnder)) - cursorX)) < 1.0)
  }

  @Test func zoomByFactorKeepsSampleUnderCursorFixedZoomingOut() {
    let model = makeModel(
      totalSamples: 10_000_000, viewportWidth: 1000, samplesPerPixel: 100, start: 500_000)
    let cursorX: CGFloat = 250
    let sampleUnder = Double(model.xToSample(cursorX))
    model.zoomByFactor(2.0, anchoredAtX: cursorX)  // zoom out
    #expect(model.samplesPerPixel == 200)
    #expect(abs(Double(model.sampleToX(Int(sampleUnder)) - cursorX)) < 1.0)
  }

  @Test func zoomByFactorClampsAtMinSamplesPerPixel() {
    let model = makeModel(
      totalSamples: 1_000_000, viewportWidth: 1000, samplesPerPixel: 16, start: 0)
    model.zoomByFactor(0.01, anchoredAtX: 500)  // far past the min (8)
    #expect(model.samplesPerPixel == 8)
  }

  @Test func zoomByFactorClampsAtFit() {
    let model = makeModel(
      totalSamples: 100_000, viewportWidth: 1000, samplesPerPixel: 90, start: 0)
    // fit spp = 100_000 / 1000 = 100
    model.zoomByFactor(100, anchoredAtX: 500)
    #expect(model.samplesPerPixel == 100)
  }

  @Test func panByPixelsClampsAtStart() {
    let model = makeModel(
      totalSamples: 1_000_000, viewportWidth: 1000, samplesPerPixel: 100, start: 5_000)
    model.panByPixels(1_000_000)  // pan hard toward the start
    #expect(model.visibleStartSample == 0)
  }

  @Test func panByPixelsClampsAtEnd() {
    let model = makeModel(
      totalSamples: 1_000_000, viewportWidth: 1000, samplesPerPixel: 100, start: 5_000)
    // visibleSampleCount = 1000*100 = 100_000; maxStart = 900_000
    model.panByPixels(-1_000_000)  // pan hard toward the end
    #expect(model.visibleStartSample == 900_000)
  }

  @Test func panByPixelsMovesByPixelsTimesSamplesPerPixel() {
    let model = makeModel(
      totalSamples: 1_000_000, viewportWidth: 1000, samplesPerPixel: 100, start: 500_000)
    model.panByPixels(-10)  // 10 px * 100 spp = 1000 samples, toward the end
    #expect(model.visibleStartSample == 501_000)
  }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd QuickInterviewEditor && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates 2>&1 | grep -Ei "error:|value of type .* has no member"`
Expected: compile failure — `WaveformModel` has no member `zoomByFactor` / `panByPixels`.

- [ ] **Step 3: Implement the two methods**

In `WaveformModel.swift`, in the `// MARK: - User Actions` section (after `dragScrolled(byPixels:)`, around line 188), add:

```swift
  /// Multiplies zoom by `factor` (clamped) while keeping the plan sample under view-x
  /// `x` pinned to `x`. Recomputes from the current invariant each call, so repeated
  /// small wheel deltas don't accumulate drift.
  func zoomByFactor(_ factor: Double, anchoredAtX x: CGFloat) {
    guard viewportWidth > 0, totalSamples > 0, factor > 0 else { return }
    let oldSamplesPerPixel = samplesPerPixel
    let sampleUnderCursor = Double(visibleStartSample) + Double(x) * oldSamplesPerPixel
    samplesPerPixel = clampedSamplesPerPixel(oldSamplesPerPixel * factor)
    visibleStartSample = clampedStart(
      Int((sampleUnderCursor - Double(x) * samplesPerPixel).rounded()))
  }

  /// Pans the viewport by `deltaX` pixels' worth of samples (clamped to the file).
  func panByPixels(_ deltaX: CGFloat) {
    scrolled(toStartSample: visibleStartSample - Int((Double(deltaX) * samplesPerPixel).rounded()))
  }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd QuickInterviewEditor && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates 2>&1 | grep -E "Test run|failed|passed" | tail -5`
Expected: `Test run with N tests … passed`.

- [ ] **Step 5: Format, lint, commit**

```bash
cd QuickInterviewEditor && make format && make lint
git add QuickInterviewEditor/Views/Pages/Editor/WaveformModel.swift QuickInterviewEditorTests/Views/Pages/Editor/WaveformTests.swift
git commit -m "feat(waveform): cursor-anchored zoom + wheel pan geometry"
```

---

### Task 2: WaveformModel — Z zoom-to-fit toggle (fit ⇄ restore)

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/WaveformModel.swift`
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/WaveformTests.swift`

**Interfaces:**
- Consumes: existing `fitSamplesPerPixel()`, `clampedSamplesPerPixel`, `clampedStart`, `visibleSampleCount`, `scrolled(toStartSample:)`, private `zoom(by:)`; new `zoomByFactor`/`panByPixels` from Task 1.
- Produces:
  - `func zoomToFitAll()` — fit the whole file, scrolled to the start.
  - `func zoomToFit(_ range: Range<Int>)` — fit `range`, centered.
  - `func zoomFitToggled(selection: Range<Int>?)` — first call stores current zoom+scroll then fits (`selection` if non-nil, else all); second consecutive call restores the stored zoom+scroll. Any manual zoom/pan in between invalidates the stored state.

- [ ] **Step 1: Write the failing tests**

Append to `WaveformTests.swift`:

```swift
  // MARK: - Z zoom-to-fit toggle

  @Test func zoomToFitAllFitsWholeFileAtStart() {
    let model = makeModel(
      totalSamples: 100_000, viewportWidth: 1000, samplesPerPixel: 20, start: 40_000)
    model.zoomToFitAll()
    #expect(model.samplesPerPixel == 100)  // 100_000 / 1000
    #expect(model.visibleStartSample == 0)
  }

  @Test func zoomToFitCentersTheRange() {
    let model = makeModel(
      totalSamples: 1_000_000, viewportWidth: 1000, samplesPerPixel: 100, start: 0)
    model.zoomToFit(400_000..<600_000)  // 200_000 wide -> spp 200; center 500_000
    #expect(model.samplesPerPixel == 200)
    // visibleSampleCount = 1000*200 = 200_000; start = 500_000 - 100_000
    #expect(model.visibleStartSample == 400_000)
  }

  @Test func zoomFitToggledFitsThenRestores() {
    let model = makeModel(
      totalSamples: 1_000_000, viewportWidth: 1000, samplesPerPixel: 50, start: 300_000)
    model.zoomFitToggled(selection: nil)          // fit all
    #expect(model.samplesPerPixel == 1000)        // 1_000_000 / 1000
    #expect(model.visibleStartSample == 0)
    model.zoomFitToggled(selection: nil)          // restore
    #expect(model.samplesPerPixel == 50)
    #expect(model.visibleStartSample == 300_000)
  }

  @Test func zoomFitToggledUsesSelectionWhenProvided() {
    let model = makeModel(
      totalSamples: 1_000_000, viewportWidth: 1000, samplesPerPixel: 50, start: 0)
    model.zoomFitToggled(selection: 400_000..<600_000)
    #expect(model.samplesPerPixel == 200)
    #expect(model.visibleStartSample == 400_000)
  }

  @Test func manualZoomBetweenTogglesInvalidatesRestore() {
    let model = makeModel(
      totalSamples: 1_000_000, viewportWidth: 1000, samplesPerPixel: 50, start: 300_000)
    model.zoomFitToggled(selection: nil)          // fit all (stores 50/300_000)
    model.zoomByFactor(0.5, anchoredAtX: 500)     // manual zoom -> invalidates restore
    let sppAfterManual = model.samplesPerPixel
    model.zoomFitToggled(selection: nil)          // must FIT again, not restore
    #expect(model.samplesPerPixel == 1000)
    #expect(model.samplesPerPixel != sppAfterManual)
  }

  @Test func manualPanBetweenTogglesInvalidatesRestore() {
    let model = makeModel(
      totalSamples: 1_000_000, viewportWidth: 1000, samplesPerPixel: 50, start: 300_000)
    model.zoomFitToggled(selection: nil)          // fit all (stores 50/300_000)
    model.panByPixels(-10)                         // manual pan -> invalidates restore
    model.zoomFitToggled(selection: nil)          // must FIT again, not restore
    #expect(model.visibleStartSample == 0)
    #expect(model.samplesPerPixel == 1000)
  }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd QuickInterviewEditor && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates 2>&1 | grep -Ei "error:|has no member" | head`
Expected: `WaveformModel` has no member `zoomToFitAll` / `zoomToFit` / `zoomFitToggled`.

- [ ] **Step 3: Implement fit + toggle, and wire invalidation**

In `WaveformModel.swift`, add a stored restore slot next to `dragAnchorStartSample` (around line 36):

```swift
  /// Zoom+scroll captured by `zoomFitToggled` so a second Z press can restore it.
  /// Cleared by any manual zoom/pan so the next Z fits fresh instead of restoring stale state.
  @ObservationIgnored private var fitRestore: (samplesPerPixel: Double, visibleStartSample: Int)?
```

Add the three methods in `// MARK: - User Actions` (after `panByPixels`):

```swift
  func zoomToFitAll() {
    guard viewportWidth > 0, totalSamples > 0 else { return }
    samplesPerPixel = clampedSamplesPerPixel(fitSamplesPerPixel())
    visibleStartSample = clampedStart(0)
  }

  func zoomToFit(_ range: Range<Int>) {
    guard viewportWidth > 0, totalSamples > 0, range.lowerBound < range.upperBound else { return }
    samplesPerPixel = clampedSamplesPerPixel(Double(range.count) / Double(viewportWidth))
    let center = range.lowerBound + range.count / 2
    visibleStartSample = clampedStart(center - visibleSampleCount / 2)
  }

  /// Logic's `Z`: fit on the first press (selection if any, else whole file), restore the
  /// prior zoom+scroll on the next consecutive press.
  func zoomFitToggled(selection: Range<Int>?) {
    guard viewportWidth > 0, totalSamples > 0 else { return }
    if let restore = fitRestore {
      samplesPerPixel = clampedSamplesPerPixel(restore.samplesPerPixel)
      visibleStartSample = clampedStart(restore.visibleStartSample)
      fitRestore = nil
      return
    }
    fitRestore = (samplesPerPixel, visibleStartSample)
    if let selection { zoomToFit(selection) } else { zoomToFitAll() }
  }
```

Wire invalidation into the manual-navigation paths so a manual move clears `fitRestore`. Add `fitRestore = nil` as the first line of `zoomByFactor` and `scrolled(toStartSample:)`, and inside the private `zoom(by:)`:

```swift
  func scrolled(toStartSample start: Int) {
    fitRestore = nil
    visibleStartSample = clampedStart(start)
  }
```

```swift
  func zoomByFactor(_ factor: Double, anchoredAtX x: CGFloat) {
    guard viewportWidth > 0, totalSamples > 0, factor > 0 else { return }
    fitRestore = nil
    // …rest unchanged…
```

```swift
  private func zoom(by factor: Double) {
    guard viewportWidth > 0, totalSamples > 0 else { return }
    fitRestore = nil
    // …rest unchanged…
```

Note: `panByPixels` already routes through `scrolled(toStartSample:)`, and `zoomInTapped`/`zoomOutTapped` route through `zoom(by:)`, so both are covered. `zoomToFit`/`zoomToFitAll` set `visibleStartSample` directly (not via `scrolled`), so the restore captured in `zoomFitToggled` survives until the next explicit toggle or manual move.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd QuickInterviewEditor && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates 2>&1 | grep -E "Test run|failed" | tail -5`
Expected: `Test run with N tests … passed`.

- [ ] **Step 5: Format, lint, commit**

```bash
cd QuickInterviewEditor && make format && make lint
git add QuickInterviewEditor/Views/Pages/Editor/WaveformModel.swift QuickInterviewEditorTests/Views/Pages/Editor/WaveformTests.swift
git commit -m "feat(waveform): Z zoom-to-fit toggle with restore"
```

---

### Task 3: TranscriptPageModel — Shift-click extend + hasSelection fix

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptPageModel.swift`
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/TranscriptSelectionTests.swift`

**Interfaces:**
- Consumes: existing `selectionAnchorID`, `selectionFocusID`, `editPlan`, `document.wordID(atUTF16Offset:)`, `selectWord(_:)`, `clearSelectionTapped()`, private `selectedWords`.
- Produces:
  - `func wordClicked(_ id: Word.ID, extending: Bool)` — the single selection entry point for both surfaces. `extending == false`: existing toggle/select. `extending == true` with a valid anchor: keep anchor, move focus. `extending == true` with no valid selection (or same word, or stale anchor): plain select.
  - `func transcriptClicked(atUTF16Offset offset: Int, extending: Bool = false)` — resolves offset → word → `wordClicked`.
  - `hasSelection` now reflects a genuinely non-empty selection.

- [ ] **Step 1: Write the failing tests**

Append to `TranscriptSelectionTests.swift` (inside `struct TranscriptSelectionTests`):

```swift
  @Test func shiftClickExtendsFromAnchorForward() {
    let model = TranscriptPageModel(editPlan: plan)
    model.wordClicked(1, extending: false)   // anchor on "one"
    model.wordClicked(3, extending: true)    // extend to "three"
    expectNoDifference(model.selectedWordIDSet, [1, 2, 3])
    expectNoDifference(model.selectionAnchorID, 1)
    expectNoDifference(model.selectionFocusID, 3)
  }

  @Test func shiftClickExtendsBackwardKeepingAnchor() {
    let model = TranscriptPageModel(editPlan: plan)
    model.wordClicked(3, extending: false)   // anchor on "three"
    model.wordClicked(1, extending: true)    // extend back to "one"
    expectNoDifference(model.selectedWordIDSet, [1, 2, 3])
    expectNoDifference(model.selectionAnchorID, 3)
  }

  @Test func shiftClickWithNoPriorSelectionPlainSelects() {
    let model = TranscriptPageModel(editPlan: plan)
    model.wordClicked(2, extending: true)    // nothing selected yet
    expectNoDifference(model.selectedWordIDSet, [2])
    expectNoDifference(model.selectionAnchorID, 2)
  }

  @Test func shiftClickSameWordStaysSingleWordNotCleared() {
    let model = TranscriptPageModel(editPlan: plan)
    model.wordClicked(2, extending: false)
    model.wordClicked(2, extending: true)    // shift-click the same word
    expectNoDifference(model.selectedWordIDSet, [2])  // does NOT toggle-clear
  }

  @Test func plainClickSameWordTogglesClear() {
    let model = TranscriptPageModel(editPlan: plan)
    model.wordClicked(2, extending: false)
    model.wordClicked(2, extending: false)   // plain re-click clears
    expectNoDifference(model.selectedWordIDSet, [])
  }

  @Test func shiftClickWithStaleAnchorPlainSelects() {
    let model = TranscriptPageModel(editPlan: plan)
    model.selectionAnchorID = 999            // id not in the plan
    model.selectionFocusID = 999
    model.wordClicked(2, extending: true)
    expectNoDifference(model.selectedWordIDSet, [2])
    expectNoDifference(model.selectionAnchorID, 2)
  }

  @Test func hasSelectionFalseWhenAnchorStale() {
    let model = TranscriptPageModel(editPlan: plan)
    model.selectionAnchorID = 999            // set but unresolvable
    model.selectionFocusID = 999
    #expect(model.hasSelection == false)
  }

  @Test func transcriptClickExtendingRoutesThroughWordClicked() {
    let model = TranscriptPageModel(editPlan: plan)
    model.transcriptClicked(atUTF16Offset: 0, extending: false)   // "one"
    model.transcriptClicked(atUTF16Offset: 10, extending: true)   // extend into "three"
    expectNoDifference(model.selectedWordIDSet, [1, 2, 3])
  }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd QuickInterviewEditor && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates 2>&1 | grep -Ei "error:|has no member" | head`
Expected: no member `wordClicked`; `transcriptClicked` extra argument `extending`.

- [ ] **Step 3: Implement wordClicked, update transcriptClicked, fix hasSelection**

In `TranscriptPageModel.swift`, replace `hasSelection` (line 86):

```swift
  var hasSelection: Bool { !selectedWords.isEmpty }
```

Replace the existing `transcriptClicked(atUTF16Offset:)` (lines 174–181) with the extend-aware version plus the shared core:

```swift
  func transcriptClicked(atUTF16Offset offset: Int, extending: Bool = false) {
    guard let id = document.wordID(atUTF16Offset: offset) else { return }
    wordClicked(id, extending: extending)
  }

  /// The single selection entry point for both the transcript and the waveform.
  /// `extending` = Shift held: keep the anchor and move the focus (contiguous run).
  func wordClicked(_ id: Word.ID, extending: Bool) {
    guard let plan = editPlan, plan.words.contains(where: { $0.id == id }) else { return }
    let anchorIsValid =
      selectionAnchorID.map { anchor in plan.words.contains { $0.id == anchor } } ?? false
    if extending, anchorIsValid {
      selectionFocusID = id  // keep anchor, move focus
    } else if extending {
      selectWord(id)  // no valid anchor -> plain select
    } else if selectionAnchorID == id, selectionFocusID == id {
      clearSelectionTapped()  // plain re-click of the sole selected word clears
    } else {
      selectWord(id)
    }
  }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd QuickInterviewEditor && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates 2>&1 | grep -E "Test run|failed" | tail -5`
Expected: `Test run with N tests … passed` (including the pre-existing `clickSelectsSingleWord` etc., which still call `transcriptClicked(atUTF16Offset:)` via the default arg).

- [ ] **Step 5: Format, lint, commit**

```bash
cd QuickInterviewEditor && make format && make lint
git add QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptPageModel.swift QuickInterviewEditorTests/TranscriptSelectionTests.swift
git commit -m "feat(transcript): shift-click extend selection + fix hasSelection on stale anchor"
```

---

### Task 4: EditorModel — scroll routing, extend-aware waveform click, key routing

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift`
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/WaveformView.swift` (one line — keep it compiling; the full swap is Task 6)
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorTests.swift`

**Interfaces:**
- Consumes: `waveform` (`zoomByFactor`, `panByPixels`, `zoomInTapped`, `zoomOutTapped`, `zoomFitToggled`, `xToSample`), `transcript` (`selectWord`, `wordClicked`, `selectedSampleRange`), private `wordID(atSample:)`.
- Produces:
  - `enum EditorKey { case zoomIn, zoomOut, zoomFit }`
  - `func waveformClicked(atX x: CGFloat, extending: Bool)` — x → sample → word → select (extend if Shift).
  - `func waveformScrolled(deltaX: CGFloat, deltaY: CGFloat, hasPreciseDeltas: Bool, optionDown: Bool, commandDown: Bool, atX x: CGFloat)` — ⌥⌘ ⇒ cursor-anchored zoom; otherwise pan.
  - `func editorKeyDown(_ key: EditorKey) -> Bool` — performs the action, returns `true` (consumed).

- [ ] **Step 1: Write the failing tests**

Append to `EditorTests.swift` (inside `struct EditorTests`, using the existing `editor(_:)` helper and `selectWords`):

```swift
  // MARK: - Waveform scroll / click / key routing

  /// The waveform's geometry (`totalSamples`) is only populated by the async audio load,
  /// which tests never run — so set it explicitly, exactly like `WaveformTests` does, or the
  /// `totalSamples > 0` guards make every zoom/pan a silent no-op.
  private func geometryReadyEditor() -> EditorModel {
    let model = editor()
    model.waveform.totalSamples = 100_000_000
    model.waveform.viewportWidth = 1000
    model.waveform.samplesPerPixel = 100
    model.waveform.visibleStartSample = 400_000
    return model
  }

  @Test func optionCommandScrollZoomsWaveform() {
    let model = geometryReadyEditor()
    let before = model.waveform.samplesPerPixel
    model.waveformScrolled(
      deltaX: 0, deltaY: 30, hasPreciseDeltas: true,
      optionDown: true, commandDown: true, atX: 500)
    #expect(model.waveform.samplesPerPixel != before)  // zoom changed
  }

  @Test func plainScrollPansWaveformNotZoom() {
    let model = geometryReadyEditor()
    let sppBefore = model.waveform.samplesPerPixel
    model.waveformScrolled(
      deltaX: 0, deltaY: 20, hasPreciseDeltas: true,
      optionDown: false, commandDown: false, atX: 500)
    #expect(model.waveform.samplesPerPixel == sppBefore)   // zoom untouched
    #expect(model.waveform.visibleStartSample != 400_000)  // panned
  }

  @Test func commandScrollPansWaveform() {
    let model = geometryReadyEditor()
    let sppBefore = model.waveform.samplesPerPixel
    model.waveformScrolled(
      deltaX: 20, deltaY: 0, hasPreciseDeltas: true,
      optionDown: false, commandDown: true, atX: 500)
    #expect(model.waveform.samplesPerPixel == sppBefore)
    #expect(model.waveform.visibleStartSample != 400_000)
  }

  @Test func waveformClickExtendingExtendsSelection() {
    let model = editor()  // default plan = Fixtures.editPlan()
    model.waveform.totalSamples = 100_000_000
    model.waveform.viewportWidth = 1000
    model.waveform.samplesPerPixel = 1
    model.waveform.visibleStartSample = 0
    // With spp 1 / start 0, view-x == plan sample, so x = startSample+1 lands inside a word.
    let words = Fixtures.editPlan().words
    let first = words[0]
    let later = words[4]
    model.waveformClicked(atX: CGFloat(first.startSample! + 1), extending: false)
    model.waveformClicked(atX: CGFloat(later.startSample! + 1), extending: true)
    #expect(model.transcript.selectedWordIDSet.count >= 2)  // extended across the run
  }

  @Test func editorKeyDownZoomFitTogglesUsingSelection() {
    let model = editor()
    model.waveform.totalSamples = 100_000_000
    model.waveform.viewportWidth = 1000
    model.waveform.samplesPerPixel = 50
    model.waveform.visibleStartSample = 0
    selectWords(model.transcript, 0, 1)  // a real, resolvable selection
    let consumed = model.editorKeyDown(.zoomFit)  // fit selection (stores 50/0)
    #expect(consumed == true)
    #expect(model.waveform.samplesPerPixel != 50)  // it fit to something
    _ = model.editorKeyDown(.zoomFit)  // restore
    #expect(model.waveform.samplesPerPixel == 50)
    #expect(model.waveform.visibleStartSample == 0)
  }

  @Test func editorKeyDownZoomInOut() {
    let model = editor()
    model.waveform.totalSamples = 100_000_000  // fit spp = 100_000; 100 is well inside range
    model.waveform.viewportWidth = 1000
    model.waveform.samplesPerPixel = 100
    model.waveform.visibleStartSample = 0
    _ = model.editorKeyDown(.zoomIn)
    #expect(model.waveform.samplesPerPixel < 100)
    let zoomedIn = model.waveform.samplesPerPixel
    _ = model.editorKeyDown(.zoomOut)
    #expect(model.waveform.samplesPerPixel > zoomedIn)
  }
```

> The click test needs fixture words carrying `startSample`/`endSample`; the fixture at `Resources/Fixtures/edit-plan.json` is real engine output and does. If the fixture has fewer than 5 words, use a smaller index for `later`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd QuickInterviewEditor && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates 2>&1 | grep -Ei "error:|has no member" | head`
Expected: no member `waveformScrolled` / `waveformClicked` / `editorKeyDown` / `EditorKey`.

- [ ] **Step 3: Implement the enum, click, scroll routing, key routing**

In `EditorModel.swift`, define the key enum near the top of the file (above the `class EditorModel` declaration, file scope):

```swift
/// The editor-global shortcuts the key monitor can deliver. PR 2 adds transport cases here.
enum EditorKey {
  case zoomIn
  case zoomOut
  case zoomFit
}
```

Replace `waveformTapped(atX:)` (lines 294–298) with the extend-aware click (keep the old name as a thin wrapper so `WaveformView` still compiles until Task 6):

```swift
  /// Waveform → transcript: a click at view-x selects the word whose audio contains that
  /// point; Shift extends the current selection to it. A click landing in a gap selects
  /// nothing and leaves the selection untouched.
  func waveformClicked(atX x: CGFloat, extending: Bool) {
    let sample = waveform.xToSample(x)
    guard let wordID = wordID(atSample: sample) else { return }
    if extending {
      transcript.wordClicked(wordID, extending: true)
    } else {
      transcript.selectWord(wordID)
    }
  }

  func waveformTapped(atX positionX: CGFloat) { waveformClicked(atX: positionX, extending: false) }
```

Add the scroll + key routing in the `// MARK: - User Actions` region (near `waveformClicked`):

```swift
  /// Wheel/trackpad on the waveform. ⌥⌘ ⇒ cursor-anchored horizontal zoom; anything else
  /// ⇒ horizontal pan (Logic maps ⌘+scroll to horizontal scroll; our single lane has no
  /// vertical axis, so a plain scroll pans too). Delta interpretation lives here, not the view.
  func waveformScrolled(
    deltaX: CGFloat, deltaY: CGFloat, hasPreciseDeltas: Bool,
    optionDown: Bool, commandDown: Bool, atX x: CGFloat
  ) {
    if optionDown, commandDown {
      waveform.zoomByFactor(
        Self.scrollZoomFactor(deltaY: deltaY, hasPreciseDeltas: hasPreciseDeltas),
        anchoredAtX: x)
    } else {
      waveform.panByPixels(
        Self.scrollPanPixels(deltaX: deltaX, deltaY: deltaY, hasPreciseDeltas: hasPreciseDeltas))
    }
  }

  func editorKeyDown(_ key: EditorKey) -> Bool {
    switch key {
    case .zoomIn: waveform.zoomInTapped()
    case .zoomOut: waveform.zoomOutTapped()
    case .zoomFit: waveform.zoomFitToggled(selection: transcript.selectedSampleRange)
    }
    return true
  }
```

Add the pure delta helpers and constants in `// MARK: - Private Helpers`:

```swift
  /// Points a line-based mouse wheel "click" is worth (trackpads report pixel-precise deltas
  /// already). Pan/zoom sensitivity constants; on-screen direction verified in QA.
  private static let pointsPerScrollLine: CGFloat = 40
  private static let pixelsPerZoomDouble = 300.0

  private static func scrollPanPixels(
    deltaX: CGFloat, deltaY: CGFloat, hasPreciseDeltas: Bool
  ) -> CGFloat {
    let primary = abs(deltaX) >= abs(deltaY) ? deltaX : deltaY
    return hasPreciseDeltas ? primary : primary * pointsPerScrollLine
  }

  private static func scrollZoomFactor(deltaY: CGFloat, hasPreciseDeltas: Bool) -> Double {
    let dy = Double(hasPreciseDeltas ? deltaY : deltaY * pointsPerScrollLine)
    // spp *= factor; scrolling "away" should zoom in (spp < 1). Flip the sign in QA if inverted.
    return pow(2.0, -dy / pixelsPerZoomDouble)
  }
```

Confirm `import Foundation` is present in `EditorModel.swift` (needed for `pow`). If not, add it.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd QuickInterviewEditor && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates 2>&1 | grep -E "Test run|failed" | tail -5`
Expected: `Test run with N tests … passed`.

- [ ] **Step 5: Format, lint, commit**

```bash
cd QuickInterviewEditor && make format && make lint
git add QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift QuickInterviewEditorTests/Views/Pages/Editor/EditorTests.swift
git commit -m "feat(editor): waveform scroll/zoom-pan + shift-click + key routing"
```

---

### Task 5: Editor-global key monitor (AppKit bridge)

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorKeyMonitor.swift`
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorView.swift`

**Interfaces:**
- Consumes: `EditorModel.editorKeyDown(_:)`, `EditorKey`.
- Produces: `struct EditorKeyMonitor: NSViewRepresentable` — installs a window-scoped `.keyDown` local monitor, maps ⌘←/⌘→/Z to `EditorKey`, forwards to the model, suppresses while a text-entry field is first responder.

This is thin AppKit plumbing (no unit test); it is verified in the Task 7 manual QA.

- [ ] **Step 1: Create the key monitor**

Create `EditorKeyMonitor.swift`:

```swift
import AppKit
import SwiftUI

/// A zero-size bridge that installs a window-scoped keyDown monitor for the editor's
/// global shortcuts (⌘←/⌘→ zoom, Z zoom-to-fit) and forwards them to `EditorModel`.
/// It consumes only those keys, only in its own window, and never while a text-entry
/// field is first responder. All behavior lives on the model; this just translates events.
struct EditorKeyMonitor: NSViewRepresentable {
  let model: EditorModel

  func makeNSView(context: Context) -> MonitorView {
    let view = MonitorView()
    view.model = model
    return view
  }

  func updateNSView(_ nsView: MonitorView, context: Context) {
    nsView.model = model
  }

  final class MonitorView: NSView {
    var model: EditorModel?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      removeMonitor()
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        self?.handle(event) ?? event
      }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
      guard let window, event.window === window else { return event }
      guard !Self.isTextEntryActive(in: window) else { return event }
      guard let key = Self.editorKey(for: event), let model else { return event }
      return model.editorKeyDown(key) ? nil : event
    }

    /// ⌘←/⌘→ ⇒ zoom out/in; plain Z ⇒ zoom-to-fit. ⌘Z (undo) and ⌥Z fall through.
    static func editorKey(for event: NSEvent) -> EditorKey? {
      let flags = event.modifierFlags
      let command = flags.contains(.command)
      switch event.keyCode {
      case 123 where command: return .zoomOut  // left arrow
      case 124 where command: return .zoomIn   // right arrow
      default: break
      }
      if !command, !flags.contains(.option),
        event.charactersIgnoringModifiers?.lowercased() == "z" {
        return .zoomFit
      }
      return nil
    }

    static func isTextEntryActive(in window: NSWindow) -> Bool {
      guard let responder = window.firstResponder else { return false }
      if let textView = responder as? NSTextView, textView.isFieldEditor { return true }
      if responder is NSTextField { return true }
      return false
    }

    private func removeMonitor() {
      if let monitor {
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
      }
    }

    deinit { removeMonitor() }
  }
}
```

- [ ] **Step 2: Wire it into the editor**

In `EditorView.swift`, attach the monitor to the top-level `HStack` (it renders nothing). Change the `.background(Color.black)` line (line 31) to add the monitor:

```swift
    .background(Color.black)
    .background(EditorKeyMonitor(model: model))
```

- [ ] **Step 3: Regenerate the project and build**

```bash
cd QuickInterviewEditor && xcodegen generate
xcodebuild build -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates 2>&1 | grep -E "BUILD SUCCEEDED|error:" | tail -5
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Run the full test suite (nothing should regress)**

Run: `cd QuickInterviewEditor && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates 2>&1 | grep -E "Test run|failed" | tail -5`
Expected: `Test run with N tests … passed`.

- [ ] **Step 5: Format, lint, commit**

```bash
cd QuickInterviewEditor && make format && make lint
git add QuickInterviewEditor/Views/Pages/Editor/EditorKeyMonitor.swift QuickInterviewEditor/Views/Pages/Editor/EditorView.swift QuickInterviewEditor.xcodeproj
git commit -m "feat(editor): window-scoped key monitor for zoom shortcuts"
```

---

### Task 6: Waveform AppKit interaction layer (scroll + click + drag)

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/WaveformInteractionView.swift`
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/WaveformView.swift`
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptTextView.swift` (wire Shift into the transcript click — the transcript half of the shift-extend feature)

**Interfaces:**
- Consumes: `EditorModel.waveformClicked(atX:extending:)`, `EditorModel.waveformScrolled(...)`, `waveform.dragScrollBegan()`, `waveform.dragScrolled(byPixels:)`, `TranscriptPageModel.transcriptClicked(atUTF16Offset:extending:)`.
- Produces: `struct WaveformInteractionLayer: NSViewRepresentable` — a transparent view over the waveform band that owns `scrollWheel` + `mouseDown/Dragged/Up` and forwards primitive facts to the model (click vs 6px-drag classification; Shift on click; modifier flags + pointer-x on scroll).

Thin AppKit plumbing (no unit test); verified in Task 7 manual QA.

- [ ] **Step 1: Create the interaction layer**

Create `WaveformInteractionView.swift`:

```swift
import AppKit
import SwiftUI

/// A transparent AppKit layer over the waveform `Canvas`. It owns all waveform mouse
/// input — scroll (zoom/pan), click (select / Shift-extend), and drag (pan) — and forwards
/// only raw facts to `EditorModel`. The `Canvas` beneath stays a pure renderer.
struct WaveformInteractionLayer: NSViewRepresentable {
  let model: EditorModel

  func makeNSView(context: Context) -> InteractionView {
    let view = InteractionView()
    view.model = model
    return view
  }

  func updateNSView(_ nsView: InteractionView, context: Context) {
    nsView.model = model
  }

  final class InteractionView: NSView {
    var model: EditorModel?
    private var dragStartX: CGFloat?
    private var didDrag = false
    private let dragThreshold: CGFloat = 6

    override var acceptsFirstResponder: Bool { false }

    /// Claim every point in the band so clicks/drags/scroll come here, not the Canvas.
    override func hitTest(_ point: NSPoint) -> NSView? { self }

    private func localX(_ event: NSEvent) -> CGFloat {
      convert(event.locationInWindow, from: nil).x
    }

    override func mouseDown(with event: NSEvent) {
      dragStartX = localX(event)
      didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
      guard let start = dragStartX else { return }
      let dx = localX(event) - start
      if !didDrag {
        guard abs(dx) >= dragThreshold else { return }
        didDrag = true
        model?.waveform.dragScrollBegan()
      }
      model?.waveform.dragScrolled(byPixels: dx)
    }

    override func mouseUp(with event: NSEvent) {
      if !didDrag {
        model?.waveformClicked(
          atX: localX(event), extending: event.modifierFlags.contains(.shift))
      }
      dragStartX = nil
      didDrag = false
    }

    override func scrollWheel(with event: NSEvent) {
      let flags = event.modifierFlags
      model?.waveformScrolled(
        deltaX: event.scrollingDeltaX,
        deltaY: event.scrollingDeltaY,
        hasPreciseDeltas: event.hasPreciseScrollingDeltas,
        optionDown: flags.contains(.option),
        commandDown: flags.contains(.command),
        atX: localX(event))
      // Consume: do NOT call super, so an enclosing ScrollView never double-scrolls.
    }
  }
}
```

- [ ] **Step 2: Swap the SwiftUI gestures for the interaction layer**

In `WaveformView.swift`:

1. Delete `@State private var isPanning = false` (line 9) and the entire `panGesture` computed property (lines 38–48).
2. Replace the band's gesture modifiers. Change lines 22–24 from:

```swift
      .contentShape(Rectangle())
      .onTapGesture(coordinateSpace: .local) { model.waveformTapped(atX: $0.x) }
      .gesture(panGesture)
```

to:

```swift
      .overlay(WaveformInteractionLayer(model: model))
```

Keep the `.onGeometryChange` that reports width. The header zoom buttons are unchanged.

3. In `EditorModel.swift`, delete the now-unused `waveformTapped(atX:)` wrapper added in Task 4 (nothing calls it anymore).

- [ ] **Step 2b: Wire Shift into the transcript click**

The waveform now passes Shift through, but the transcript's AppKit hit-tester still calls `transcriptClicked` without a modifier, so Shift-click in the transcript wouldn't extend. In `TranscriptTextView.swift`, in `HitTestingTextView.mouseUp(with:)`, change the click call to pass the Shift flag. Find:

```swift
      if !didDrag, let anchor = anchorOffset {
        coordinator.model.transcriptClicked(atUTF16Offset: anchor)
      }
```

and change it to:

```swift
      if !didDrag, let anchor = anchorOffset {
        coordinator.model.transcriptClicked(
          atUTF16Offset: anchor, extending: event.modifierFlags.contains(.shift))
      }
```

Leave the drag handlers unchanged (drag stays non-shift per the design). `mouseUp`'s `event` already carries the modifier flags at button-release, which is correct for a Shift-click.

- [ ] **Step 3: Regenerate the project and build**

```bash
cd QuickInterviewEditor && xcodegen generate
xcodebuild build -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates 2>&1 | grep -E "BUILD SUCCEEDED|error:" | tail -5
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Run the full test suite**

Run: `cd QuickInterviewEditor && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates 2>&1 | grep -E "Test run|failed" | tail -5`
Expected: `Test run with N tests … passed`.

- [ ] **Step 5: Format, lint, commit**

```bash
cd QuickInterviewEditor && make format && make lint
git add QuickInterviewEditor/Views/Pages/Editor/WaveformInteractionView.swift QuickInterviewEditor/Views/Pages/Editor/WaveformView.swift QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptTextView.swift QuickInterviewEditor.xcodeproj
git commit -m "feat(waveform): AppKit interaction layer for scroll/click/drag + transcript shift-click"
```

---

### Task 7: Manual QA + direction tuning + final gate

**Files:** none (verification only), plus possible one-line sign flips in `EditorModel.swift`.

**Goal:** Confirm the real interactions feel right in the running app, fix any inverted scroll/pan directions, and run the full gate.

- [ ] **Step 1: Launch the real build (avoid the stale-build trap)**

```bash
launchctl setenv QIE_ENGINE_REPO "$(git rev-parse --show-toplevel)"
cd QuickInterviewEditor
open "$(xcodebuild -scheme QuickInterviewEditor -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}')/QuickInterviewEditor.app"
```

Load the bundled fixture / a real clip so the editor (transcript + waveform) is visible.

- [ ] **Step 2: Walk the QA checklist**

- Shift-click in the transcript extends the selection from the anchor (both directions); plain click still toggles a single word.
- Shift-click on the waveform extends the selection to the clicked word.
- ⌥⌘ + scroll zooms the waveform, and the point under the cursor stays put. If it zooms the wrong way, flip the sign in `scrollZoomFactor` (change `-dy` to `dy`).
- ⌘ + scroll and plain scroll pan horizontally. If panning feels reversed, flip the sign in `panByPixels` (change `visibleStartSample - …` to `+`). Confirm drag-pan still matches after any flip.
- ⌘← / ⌘→ zoom out / in.
- `Z` fits the selection (or whole file if none); pressing `Z` again returns to the prior zoom; a manual zoom/pan between presses makes the next `Z` fit fresh.
- Zoom keys do NOTHING while editing a slice name (rename field focused); they work again once the field loses focus.
- The header zoom buttons still work; the playhead still tracks playback.

- [ ] **Step 3: If any sign was flipped, re-run model tests**

Run: `cd QuickInterviewEditor && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates 2>&1 | grep -E "Test run|failed" | tail -5`
Expected: still `passed` (direction-agnostic tests are unaffected; if a magnitude test needs updating, update it to match the corrected direction).

- [ ] **Step 4: Full gate + commit any tuning**

```bash
cd QuickInterviewEditor && make format && make lint
# commit only if a sign/const was changed:
git add QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift QuickInterviewEditor/Views/Pages/Editor/WaveformModel.swift
git commit -m "fix(waveform): correct scroll/zoom direction after QA" || echo "no tuning changes"
```

- [ ] **Step 5: Codex adversarial review (per project pipeline)**

Run `/codex review` then `/codex challenge` on the branch diff; fix anything surfaced (re-run if fixes are non-trivial). Then the branch is ready for the PR (stack base for PR 2).

---

## Notes for PR 2 (out of scope here)

PR 2 stacks on this branch and adds a movable main-timeline playhead + transport keys (Space / Return / `,` / `.`). It only adds `EditorKey` cases and model methods; the key monitor and interaction layer built here already route by `EditorKey` and raw facts, so no rework is needed. Keep scroll/key code ignorant of the playhead until then.
