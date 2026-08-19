# Freeform Waveform Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Also invoke the relevant `pfw-*` skills before writing Swift (this repo mandates them): `pfw-observable-models`, `pfw-identified-collections`, `pfw-sharing`, `pfw-testing`, `pfw-custom-dump`, `pfw-modern-swiftui`. List them in your checklist.

**Goal:** Invert the selection source of truth so a freeform `Range<Int>` in **source samples** (`EditorModel.audioSelection`) *is* the selection; words become a pure affordance (an input entry point + a derived readout) and hold zero selection state.

**Architecture:** Facade-first, incremental migration. Add `audioSelection` to `EditorModel` as plain `@Observable` (not `@Shared`, not undoable), expose a `selectedSourceRange` facade, switch every reader to it while it's still seeded from the transcript, then flip the writers (waveform marquee/click write the range directly; the transcript emits word intents that convert to a range), add edge-handle drag + 10 ms nudge via a new value-type `BoundaryRangeEditor`, and finally derive all transcript display (highlight/strikethrough/clip bands) from the range and delete the transcript's selection-truth properties. Every step compiles and keeps tests green.

**Tech Stack:** Swift 6, SwiftUI + AppKit (macOS), `@Observable` MV models, swift-dependencies, swift-sharing (`@Shared(.fileStorage)`), swift-identified-collections, Swift Testing, swift-custom-dump. Build/test via `make` in `QuickInterviewEditor/`.

**Spec:** `docs/superpowers/specs/2026-08-19-freeform-waveform-selection-design.md` — read it in full before starting. The plan argues from the spec; both travel together. The spec's **Merged-baseline note** records that this is validated against `main` at #51 + #52, and that #52 (vertical amplitude zoom) is orthogonal — the only carry-over is that `WaveformLaneDriving` now requires an `amplitudeScale` member.

## Global Constraints

- **Coordinates are SAMPLES**, never seconds, in all new model code. `audioSelection` is canonical in **SOURCE** samples always; convert to edited/view coordinates only at the `EditedWaveformAdapter` boundary. Name variables `sourceSample` / `editedSample`; never a bare `sample`.
- **`EditPlan` is immutable engine input** — never mutate it.
- **Selection is ephemeral UI state.** `audioSelection` is a plain `@Observable var`, **not** `@Shared`, and **never** enters the undo stack (`mutateDocument`). Only committed slices/removals are undoable/persisted.
- **The transcript is never the source of truth.** It emits word intents on input and renders derived sets pushed in from `EditorModel`; it must never observe-and-rewrite the selection (this single rule prevents feedback loops).
- **No snapping the selection range back to word edges — ever.** Marquee/edge-drag set the exact dragged `[start, end)` in source samples.
- **Zero logic in views.** Every display value / decision is a computed property on a model. Views bind to model properties and call model methods only.
- **Value comparisons in tests use `expectNoDifference` / `expectDifference`**, not raw `#expect(a == b)`.
- **No `Task.sleep` in tests.** Use synchronous assertions / immediate test doubles / `ImmediateClock`.
- **Commit messages:** conventional prefixes (`feat:`, `test:`, `refactor:`). **Do NOT add any `Co-Authored-By` trailer.**
- **Before each commit run:** `cd QuickInterviewEditor && make format && make lint`. Before finishing a task run `make test`.
- Build/test commands (verbatim, run from `QuickInterviewEditor/`): `make test` (fastlane scan), `make lint` (swiftlint --strict), `make format` (swift-format -i), `make format-check`, `make generate` (xcodegen — run after adding new files so the `.xcodeproj` picks them up).

**IMPORTANT — new files must be registered:** this project generates its Xcode project from `project.yml` via XcodeGen. After creating any new `.swift` file, run `make generate` before `make test`, or the file will not be compiled.

---

## Ground-truth reference (current signatures — verbatim, verified on this branch)

Everything below is real code on `briankeane/freeform-waveform-selection` (off `main` at #52). Do not re-derive; trust these.

**`EditorModel.swift`** (`QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/`)
- `52 var transcript: TranscriptPageModel` · `53 var waveform: WaveformModel` · `58 var editedWaveform: EditedWaveformAdapter` · `59 var fineTune: FineTuneModel`
- `239 var activeSliceRange: Range<Int>?` · `245 var activeOrSelectedRange: Range<Int>? { transcript.selectedSampleRange ?? activeSliceRange }`
- `249 var activeEditingRange: Range<Int>? { fineTune.draftRange ?? activeOrSelectedRange }`
- `304 var highlightedSampleRange: Range<Int>? { transcript.selectedSampleRange }`
- `317 var removedWordIDs: Set<Word.ID> { Set(timelineRemovals.flatMap { wordIDs(overlapping: $0.removedRange, words: editPlan.words) }) }`
- `374 var canAddSlice: Bool { transcript.selectedSampleRange != nil && !fineTune.hasUnsavedChange }`
- `564 func waveformClicked(atX positionX: CGFloat, extending: Bool)`
- `587 func waveformAreaSelectBegan(atX startX: CGFloat, extending: Bool)` · `604 func waveformAreaSelectChanged(toX positionX: CGFloat)` · `618 func waveformAreaSelectEnded(toX positionX: CGFloat)`
- `643 private func updateMarqueeSelection()` · `653 private func marqueeAnchorFocus() -> (anchor: Word.ID, focus: Word.ID)?` · `671 private func commitMarqueePlayhead()`
- `763 func editorKeyDown(_ key: EditorKey) -> Bool` · `790 private func nudgePendingRemoval(_ key: EditorKey) -> Bool`
- `808 func mutateDocument(_ body: (inout EditorDocumentState) -> Void)` · `823 func mutateSlices(_ body: (inout IdentifiedArrayOf<Slice>) -> Void)`
- `887 func revealSelectionAcrossPanes()` · `894 func zoomWaveformToSelection()`
- `980 func addSliceTapped()` (uses `transcript.selectedSampleRange` + `transcript.orderedSelectedWordIDs`)
- `1027 private var isPendingRemovalSessionCurrent: Bool` · `1035 private var pendingRemovalSourceRange: Range<Int>?` · `1041 func canRemove(sourceRange range: Range<Int>) -> Bool` · `1049 var canRemoveSelectedSection: Bool` · `1059 func removeSelectedSectionTapped() async`
- `1379 func transportSelectionChanged(_ newRange: Range<Int>?, cursorToken: Int) async`
- `9 enum EditorKey { … .zoomIn/.zoomOut/.zoomFit/.speedUp/.speedDown/.removeSection/.nudgeCutInEarlier/.nudgeCutInLater/.nudgeCutOutEarlier/.nudgeCutOutLater }`
- Transport-snap wiring lives in **`EditorView.swift`** as `.onChange(of: transcript.selectedSampleRange)` → `transportSelectionChanged`.

**`TranscriptPageModel.swift`** (`Views/Pages/TranscriptPage/`)
- `91 var selectionAnchorID: Word.ID?` · `92 var selectionFocusID: Word.ID?`
- `145 var selectedSampleRange: Range<Int>?` (getter derives from first/last selected word samples)
- `171 var orderedSelectedWordIDs: [Word.ID]` · `177 var selectedWordIDSet: Set<Word.ID>`
- `120 var removedWordIDs: Set<Word.ID> = []` (stored; strikethrough set, pushed in by EditorModel)
- `114 var clipBands: [TranscriptClipBand] = []` (`didSet { recomputeClipContainers() }`)
- `301 func clearSelectionTapped()` · `308 func selectWord(_ id: Word.ID)` · `316 @discardableResult 317 func selectWords(anchorID: Word.ID, focusID: Word.ID) -> Bool`
- `472 private var selectedWords: ArraySlice<Word>` (position-based backing slice)

**`FineTuneGeometry.swift`** (`Models/`) — **free functions we reuse** (already extracted, not methods):
- `4 enum SliceEdge: Equatable { case start; case end }`
- `12 struct BoundaryConstraints: Equatable { var window: ClosedRange<Int>; var durationSamples: Int; var minDurationSamples: Int }`
- `24 func legalBoundaryRange(moving edge: SliceEdge, opposite: Int, constraints: BoundaryConstraints) -> ClosedRange<Int>`
- `51 func clampedBoundary(_ proposed: Int, moving edge: SliceEdge, opposite: Int, constraints: BoundaryConstraints) -> Int`
- `64 func nearestSilenceEdge(sample: Int, thresholdSamples: Int, silences: [EditPlan.Silence], legalRange: ClosedRange<Int>) -> Int?`
- `87 func wordIDs(overlapping range: Range<Int>, words: [Word]) -> [Word.ID]` — **MIDPOINT membership** (word's midpoint in range). Do NOT use this for the new predicates.

**`FineTuneModel.swift`** (`Views/Pages/Editor/`) — the math we're mirroring:
- `42 let snapThresholdMs = 40.0` · `43 let nudgeMs = 10.0` · `44 let minSliceMs = 50.0` · `73 private var minDurationSamples: Int { samples(forMs: minSliceMs) }`
- `25 let sampleRate: Int` · `26 let durationSamples: Int` · `27 let silences: [EditPlan.Silence]`
- `193 private func samples(forMs ms: Double) -> Int { Int((ms / 1000 * Double(sampleRate)).rounded()) }`
- `183 func nudgeCutIn(byMs:)` → `moveStart(to: draftRange.lowerBound + samples(forMs: deltaMs), snap: false)` · `187 func nudgeCutOut(byMs:)` → `moveEnd(to: draftRange.upperBound + samples(forMs: deltaMs), snap: false)`
- `moveStart`/`moveEnd` build `BoundaryConstraints(window: window.lowerBound...window.upperBound, durationSamples:, minDurationSamples:)`, call `clampedBoundary`, then (snap only) `nearestSilenceEdge`. FineTune's `window` is the magnified inset; **the primary selection has no inset → window is the whole file `0...durationSamples`.**

**`EditedWaveformAdapter.swift`** (`Models/`)
- `160 func xToSourceSample(_ posX: CGFloat) -> Int` · `167 func sourceSampleToX(_ sourceSample: Int, bias: MappingBias = .nearest) -> CGFloat?`
- `118 func span(forSource sourceRange: Range<Int>, startBias: MappingBias = .leftEdge, endBias: MappingBias = .rightEdge) -> WaveformSpan?` · `333 func laneSpan(forSource sourceRange: Range<Int>) -> WaveformSpan?`
- `41 var editedDurationSamples: Int` · `hasUsableGeometry` / `viewportWidth` used by the marquee. `MappingBias` (in `EditedTimeline.swift`): `.leftEdge`, `.rightEdge`, `.nearest`, `.nilInsideRemoval`.

**`WaveformLaneView.swift`** (`Views/Pages/Editor/`)
- `11 protocol WaveformLaneDriving: AnyObject` requirements: `showsLoading/showsEmpty/loadingMessage/emptyMessage`, **`amplitudeScale: CGFloat`** (#52), `viewportResized(width:)`, `visibleColumns() -> [WaveformColumn]`, `laneSpan(forSource:) -> WaveformSpan?`, `lanePlayheadX(forSource:) -> CGFloat?`, `scrolled(deltaX:deltaY:hasPreciseDeltas:optionDown:commandDown:atX:)`.
- `WaveformLaneView` params (lines 44-57): `waveform`, `playhead: () -> Int?`, `highlightRange: Range<Int>?`, `onRulerMove`, `onBodyClick: (CGFloat, Bool) -> Void`, `onAreaSelectBegan: (CGFloat, Bool) -> Void`, `onAreaSelectChanged: (CGFloat) -> Void`, `onAreaSelectEnded: (CGFloat) -> Void`, `seams: [WaveformSpan]`, `auditionOverlay`.
- `WaveformInteractionLayer` (288-293) exposes those same click/marquee closures; `InteractionView` fires `onAreaSelectBegan` past a 6pt drag threshold, else `onBodyClick` on mouseUp. The `Bool` is `event.modifierFlags.contains(.shift)`. All x are local view x.

**`EditorKeyMonitor.swift`** (`Views/Pages/Editor/`)
- `arrowKey(forKeyCode:modifiers:)` maps `123 →.nudgeCutInEarlier` (←), `124 →.nudgeCutInLater` (→), `123+shift →.nudgeCutOutEarlier` (⇧←), `124+shift →.nudgeCutOutLater` (⇧→); dispatched via `model.editorKeyDown(key)`.

---

## File Structure

**Create:**
- `QuickInterviewEditor/QuickInterviewEditor/Models/SelectionEdge.swift` — `enum SelectionEdge { case start, end }` (the selection's own edge type; kept distinct from `SliceEdge` so the two domains stay decoupled).
- `QuickInterviewEditor/QuickInterviewEditor/Models/WordRangePredicates.swift` — `wordIDs(fullyContainedIn:words:)` and `wordIDs(anyOverlap:words:)` (the spec's exact strikethrough/overlap predicates; distinct from the midpoint `wordIDs(overlapping:)`).
- `QuickInterviewEditor/QuickInterviewEditor/Models/BoundaryRangeEditor.swift` — value type wrapping the `FineTuneGeometry` edge math for the whole-file (no-inset) primary-selection case.
- `QuickInterviewEditor/QuickInterviewEditorTests/Models/WordRangePredicatesTests.swift`
- `QuickInterviewEditor/QuickInterviewEditorTests/Models/BoundaryRangeEditorTests.swift`
- `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorSelectionTests.swift` — the freeform-selection flow suite (marquee exactness, word-seed, edge-drag, nudge, downstream wiring).

**Modify:**
- `Views/Pages/Editor/EditorModel.swift` — add `audioSelection` + facade + selection API; migrate readers; flip writers; edge-drag/nudge; derived-set pushes; retire the nudge-via-fineTune stopgap.
- `Views/Pages/TranscriptPage/TranscriptPageModel.swift` — demote selection-truth properties to text-drag-gesture-internal; render only pushed-in derived sets.
- `Views/Pages/Editor/EditorView.swift` — `.onChange` observes `audioSelection`; pass selection-highlight set + edge-drag callbacks down.
- `Views/Pages/Editor/WaveformLaneView.swift` — add edge-handle hit-zones + `onEdgeDrag*` callbacks (additive; keeps existing marquee/click/seams/amplitude paths).
- `Views/Pages/Editor/EditorKeyMonitor.swift` — arrow keys stay the same cases; `editorKeyDown` reroutes them to the primary selection.
- `QuickInterviewEditorTests/Views/Pages/Editor/EditorAreaSelectTests.swift` & `EditorRemovalTests.swift` — update expectations to the freeform (exact-range) behavior.

---

## Task 1: `SelectionEdge` + word-range predicate helpers

**Files:**
- Create: `Models/SelectionEdge.swift`, `Models/WordRangePredicates.swift`
- Test: `QuickInterviewEditorTests/Models/WordRangePredicatesTests.swift`

**Interfaces:**
- Produces:
  - `enum SelectionEdge: Equatable { case start; case end }`
  - `func wordIDs(fullyContainedIn range: Range<Int>, words: [Word]) -> [Word.ID]` — strikethrough predicate: `range.lowerBound <= word.startSample && word.endSample <= range.upperBound`.
  - `func wordIDs(anyOverlap range: Range<Int>, words: [Word]) -> [Word.ID]` — highlight + clip-membership predicate: `word.startSample < range.upperBound && word.endSample > range.lowerBound`.
  - Both skip words missing sample bounds or with a non-positive span; return in `words` (transcript) order.

- [ ] **Step 1: Write the failing test**

```swift
import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

struct WordRangePredicatesTests {
  private func word(_ id: Int, _ start: Int, _ end: Int) -> Word {
    Word(id: id, text: "w\(id)", start: 0, end: 0, startSample: start, endSample: end)
  }

  private let words = [
    // id: [start, end)
    // 1:[0,100) 2:[100,200) 3:[200,300)
  ]

  @Test func fullyContainedRequiresBothEdgesInside() {
    let ws = [word(1, 0, 100), word(2, 100, 200), word(3, 200, 300)]
    // Removal [100,200) fully contains only word 2.
    expectNoDifference(wordIDs(fullyContainedIn: 100..<200, words: ws), [2])
  }

  @Test func fullyContainedIsInclusiveOnBothBounds() {
    let ws = [word(2, 100, 200)]
    // Touching exactly: start == lower, end == upper → contained.
    expectNoDifference(wordIDs(fullyContainedIn: 100..<200, words: ws), [2])
    // One sample short on either side → not contained.
    expectNoDifference(wordIDs(fullyContainedIn: 101..<200, words: ws), [])
    expectNoDifference(wordIDs(fullyContainedIn: 100..<199, words: ws), [])
  }

  @Test func overlapIsAnyIntersection() {
    let ws = [word(1, 0, 100), word(2, 100, 200), word(3, 200, 300)]
    // [150,250) overlaps words 2 and 3, not 1.
    expectNoDifference(wordIDs(anyOverlap: 150..<250, words: ws), [2, 3])
  }

  @Test func overlapIsHalfOpenAtEdges() {
    let ws = [word(1, 0, 100), word(2, 100, 200)]
    // A range that ends exactly at word 2's start does NOT overlap it (half-open).
    expectNoDifference(wordIDs(anyOverlap: 0..<100, words: ws), [1])
    // A range starting one sample before word 2's end overlaps it.
    expectNoDifference(wordIDs(anyOverlap: 199..<400, words: ws), [2])
  }

  @Test func skipsWordsMissingOrDegenerateBounds() {
    let ws = [
      Word(id: 9, text: "x", start: 0, end: 0, startSample: nil, endSample: nil),
      word(5, 100, 100),  // zero-span
      word(6, 100, 200),
    ]
    expectNoDifference(wordIDs(anyOverlap: 0..<1000, words: ws), [6])
    expectNoDifference(wordIDs(fullyContainedIn: 0..<1000, words: ws), [6])
  }
}
```

> Verify the `Word` initializer parameter labels against `EditPlan.Word` (`Models/EditPlan.swift` line 34) before running; adjust the `word(...)` helper if the real initializer differs (e.g. extra fields). `Word.ID` is `Int`.

- [ ] **Step 2: Run test to verify it fails** — `cd QuickInterviewEditor && make generate && make test`. Expected: compile failure (functions/enum not defined).

- [ ] **Step 3: Write minimal implementation**

`Models/SelectionEdge.swift`:
```swift
import Foundation

/// Which edge of the freeform audio selection an edit gesture is moving. Kept
/// separate from `SliceEdge` (fine-tune) so the two domains stay decoupled.
enum SelectionEdge: Equatable {
  case start
  case end
}
```

`Models/WordRangePredicates.swift`:
```swift
import Foundation

/// Word IDs whose ENTIRE `[startSample, endSample)` lies inside `range` — the spec's
/// strikethrough predicate ("no audio of this word survives the removal"). Inclusive on
/// both bounds: a word touching the removal edges exactly is still fully contained.
/// Words missing sample bounds or with a non-positive span are skipped. Transcript order.
func wordIDs(fullyContainedIn range: Range<Int>, words: [Word]) -> [Word.ID] {
  words.compactMap { word in
    guard let start = word.startSample, let end = word.endSample, start < end else { return nil }
    return (range.lowerBound <= start && end <= range.upperBound) ? word.id : nil
  }
}

/// Word IDs whose audio intersects `range` at all — the spec's highlight / clip-membership
/// predicate ("is any of this word still heard?"). Half-open: a range abutting a word's edge
/// does not overlap it. Words missing sample bounds or with a non-positive span are skipped.
func wordIDs(anyOverlap range: Range<Int>, words: [Word]) -> [Word.ID] {
  words.compactMap { word in
    guard let start = word.startSample, let end = word.endSample, start < end else { return nil }
    return (start < range.upperBound && end > range.lowerBound) ? word.id : nil
  }
}
```

- [ ] **Step 4: Run tests to verify they pass** — `make test`. Expected: PASS.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: add SelectionEdge + fully-contained/overlap word predicates"`

---

## Task 2: `BoundaryRangeEditor` value type

**Files:**
- Create: `Models/BoundaryRangeEditor.swift`
- Test: `QuickInterviewEditorTests/Models/BoundaryRangeEditorTests.swift`

**Interfaces:**
- Consumes: `SliceEdge`, `BoundaryConstraints`, `clampedBoundary`, `nearestSilenceEdge` (from `FineTuneGeometry.swift`).
- Produces:
  ```swift
  struct BoundaryRangeEditor: Equatable {
    var fileDurationSamples: Int
    var sampleRate: Int
    var minDurationSamples: Int
    var snapThresholdSamples: Int
    var silences: [EditPlan.Silence]
    func moveStart(of range: Range<Int>, to sourceSample: Int, snap: Bool) -> Range<Int>
    func moveEnd(of range: Range<Int>, to sourceSample: Int, snap: Bool) -> Range<Int>
    func nudgeStart(of range: Range<Int>, byMs: Double) -> Range<Int>
    func nudgeEnd(of range: Range<Int>, byMs: Double) -> Range<Int>
  }
  ```
- **Behavior:** identical clamp/min-duration math to `FineTuneModel`, but with the whole file as the window (`0...fileDurationSamples`). `snap: true` snaps to the nearest silence edge within threshold; `snap: false` (the primary-selection default) does raw clamp only. Nudges are `snap: false` and mirror `FineTuneModel.nudgeCutIn/nudgeCutOut` (`samples(forMs:)` rounding).

- [ ] **Step 1: Write the failing test**

```swift
import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

struct BoundaryRangeEditorTests {
  private func editor(
    duration: Int = 48_000, rate: Int = 48_000, minDur: Int = 2_400,
    threshold: Int = 1_920, silences: [EditPlan.Silence] = []
  ) -> BoundaryRangeEditor {
    BoundaryRangeEditor(
      fileDurationSamples: duration, sampleRate: rate, minDurationSamples: minDur,
      snapThresholdSamples: threshold, silences: silences)
  }

  @Test func moveStartClampsToFileFloor() {
    let e = editor()
    expectNoDifference(e.moveStart(of: 1_000..<10_000, to: -500, snap: false), 0..<10_000)
  }

  @Test func moveStartRespectsMinDurationAgainstOppositeEdge() {
    let e = editor(minDur: 2_400)
    // Trying to push start within < minDur of the fixed end (10_000) clamps to end - minDur.
    expectNoDifference(e.moveStart(of: 1_000..<10_000, to: 9_999, snap: false), 7_600..<10_000)
  }

  @Test func moveEndClampsToFileCeiling() {
    let e = editor(duration: 48_000)
    expectNoDifference(e.moveEnd(of: 1_000..<10_000, to: 60_000, snap: false), 1_000..<48_000)
  }

  @Test func moveEndRespectsMinDurationAgainstOppositeEdge() {
    let e = editor(minDur: 2_400)
    expectNoDifference(e.moveEnd(of: 1_000..<10_000, to: 1_001, snap: false), 1_000..<3_400)
  }

  @Test func nudgeStartMatchesTenMsRounding() {
    let e = editor(rate: 48_000)  // 10 ms = 480 samples
    expectNoDifference(e.nudgeStart(of: 1_000..<10_000, byMs: -10), 520..<10_000)
    expectNoDifference(e.nudgeStart(of: 1_000..<10_000, byMs: 10), 1_480..<10_000)
  }

  @Test func nudgeEndMatchesTenMsRounding() {
    let e = editor(rate: 48_000)
    expectNoDifference(e.nudgeEnd(of: 1_000..<10_000, byMs: 10), 1_000..<10_480)
    expectNoDifference(e.nudgeEnd(of: 1_000..<10_000, byMs: -10), 1_000..<9_520)
  }

  @Test func snapTrueSnapsToNearbySilenceEdge() {
    // A silence edge at 5_050 within threshold of a moveEnd target 5_000 → snaps to 5_050.
    let e = editor(threshold: 1_920, silences: [EditPlan.Silence(startSample: 5_050, endSample: 6_000)])
    expectNoDifference(e.moveEnd(of: 1_000..<9_000, to: 5_000, snap: true), 1_000..<5_050)
    // snap:false leaves the raw target.
    expectNoDifference(e.moveEnd(of: 1_000..<9_000, to: 5_000, snap: false), 1_000..<5_000)
  }
}
```

> Confirm `EditPlan.Silence`'s initializer labels (`Models/EditPlan.swift`) and adjust the silence literal if needed. Recompute the exact expected samples from the real `minDurationSamples` if the constructor clamps differently; the point is regression parity with the shipped nudge math, so if a number is off, match it to what `clampedBoundary`/`legalBoundaryRange` actually produce rather than "fixing" the helper.

- [ ] **Step 2: Run test to verify it fails** — `make generate && make test`. Expected: compile failure.

- [ ] **Step 3: Write minimal implementation** (`Models/BoundaryRangeEditor.swift`)

```swift
import Foundation

/// The raw two-boundary edge math for the freeform audio selection, mirroring
/// `FineTuneModel`'s clamp/min-duration/snap behavior but with the WHOLE FILE as the
/// window (the primary selection has no magnified inset). Extracted as a value type so the
/// selection path reuses the mechanics without inheriting `FineTuneModel`'s
/// session/target/audition state machine (see spec §5). `snap:false` is the primary path.
struct BoundaryRangeEditor: Equatable {
  var fileDurationSamples: Int
  var sampleRate: Int
  var minDurationSamples: Int
  var snapThresholdSamples: Int
  var silences: [EditPlan.Silence]

  private var constraints: BoundaryConstraints {
    BoundaryConstraints(
      window: 0...fileDurationSamples, durationSamples: fileDurationSamples,
      minDurationSamples: minDurationSamples)
  }

  func moveStart(of range: Range<Int>, to sourceSample: Int, snap: Bool) -> Range<Int> {
    let resolved = resolve(sourceSample, moving: .start, opposite: range.upperBound, snap: snap)
    return resolved..<range.upperBound
  }

  func moveEnd(of range: Range<Int>, to sourceSample: Int, snap: Bool) -> Range<Int> {
    let resolved = resolve(sourceSample, moving: .end, opposite: range.lowerBound, snap: snap)
    return range.lowerBound..<resolved
  }

  func nudgeStart(of range: Range<Int>, byMs deltaMs: Double) -> Range<Int> {
    moveStart(of: range, to: range.lowerBound + samples(forMs: deltaMs), snap: false)
  }

  func nudgeEnd(of range: Range<Int>, byMs deltaMs: Double) -> Range<Int> {
    moveEnd(of: range, to: range.upperBound + samples(forMs: deltaMs), snap: false)
  }

  private func resolve(_ proposed: Int, moving edge: SliceEdge, opposite: Int, snap: Bool) -> Int {
    let limits = constraints
    let clamped = clampedBoundary(proposed, moving: edge, opposite: opposite, constraints: limits)
    guard snap else { return clamped }
    let legal = legalBoundaryRange(moving: edge, opposite: opposite, constraints: limits)
    return nearestSilenceEdge(
      sample: clamped, thresholdSamples: snapThresholdSamples, silences: silences, legalRange: legal)
      ?? clamped
  }

  private func samples(forMs ms: Double) -> Int {
    Int((ms / 1000 * Double(sampleRate)).rounded())
  }
}
```

- [ ] **Step 4: Run tests to verify they pass** — `make test`.
- [ ] **Step 5: Commit** — `git commit -am "feat: BoundaryRangeEditor — shared edge math for freeform selection"`

---

## Task 3: `EditorModel.audioSelection` + `selectedSourceRange` facade (seeded)

Spec §6 step 1. Add the source of truth and the read facade; keep it seeded from the transcript so nothing observable changes yet. No readers switch in this task.

**Files:** Modify `EditorModel.swift`; Modify `EditorView.swift`; Test `EditorSelectionTests.swift` (create).

**Interfaces:**
- Produces on `EditorModel`:
  ```swift
  var audioSelection: Range<Int>?          // SOURCE samples — the coming single source of truth
  var selectionAnchorSample: Int?          // fixed edge during marquee/extend (set in Task 6)
  var selectionEditingEdge: SelectionEdge? // set while edge-dragging (Task 8)
  var selectedSourceRange: Range<Int>? { audioSelection }
  func seedSelectionFromTranscript()       // audioSelection = transcript.selectedSampleRange
  ```

- [ ] **Step 1: Write the failing test** (`EditorSelectionTests.swift`)

```swift
import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

@MainActor
struct EditorSelectionTests {
  @Test func seedMirrorsTranscriptSelectionIntoAudioSelection() {
    let model = EditorModel.testModel(.fixture)   // existing test factory (see EditorAreaSelectTests)
    model.transcript.selectWords(anchorID: firstWordID(model), focusID: firstWordID(model))
    model.seedSelectionFromTranscript()
    expectNoDifference(model.selectedSourceRange, model.transcript.selectedSampleRange)
  }
}

// Reuse whatever fixture/first-word helpers EditorAreaSelectTests already uses; do not invent a
// new fixture. `firstWordID` = model.editPlan.words.first!.id.
```

> Match the existing test-model construction used in `EditorAreaSelectTests.swift` / `EditorRemovalTests.swift` verbatim (same `withDependencies`, same fixture). Do not introduce a new factory.

- [ ] **Step 2: Run test to verify it fails** — `make test`. Expected: `audioSelection` / `seedSelectionFromTranscript` undefined.

- [ ] **Step 3: Write minimal implementation** — in `EditorModel.swift`, add a `// MARK: - Selection (source samples — the single source of truth)` section near the other range vars (after line 249):

```swift
// MARK: - Selection (source samples — the single source of truth)
/// The freeform selected range in SOURCE samples. Plain @Observable — not @Shared, not in the
/// undo stack. During migration it is SEEDED from the transcript selection; later tasks flip the
/// writers so this becomes authoritative and the transcript derives from it.
var audioSelection: Range<Int>?
/// The fixed edge held during a marquee / shift-extend (set in Task 6).
var selectionAnchorSample: Int?
/// The edge currently being drag-edited (set in Task 8).
var selectionEditingEdge: SelectionEdge?

/// Read facade every downstream reader migrates onto (spec §6). Backed by `audioSelection`.
var selectedSourceRange: Range<Int>? { audioSelection }

/// Migration seam (step 1): keep `audioSelection` mirrored from the transcript selection until
/// the writers flip (Task 6/7). Called from `EditorView`'s selection `onChange`.
func seedSelectionFromTranscript() {
  audioSelection = transcript.selectedSampleRange
}
```

In `EditorView.swift`, in the existing `.onChange(of: transcript.selectedSampleRange)` (the one that calls `transportSelectionChanged`), add `model.seedSelectionFromTranscript()` as the first line of the closure so the seed stays current.

- [ ] **Step 4: Run tests to verify they pass** — `make test`.
- [ ] **Step 5: Commit** — `git commit -am "feat: add EditorModel.audioSelection + selectedSourceRange facade (seeded)"`

---

## Task 4: Switch range readers to the facade (display cluster)

Spec §6 step 2 (part a). Point the pure display/range readers at `selectedSourceRange`. Still seed-backed, so behavior is identical — assert that.

**Files:** Modify `EditorModel.swift`; Test add to `EditorSelectionTests.swift`.

- [ ] **Step 1: Write the failing/guard test** — a regression test locking behavior before AND after the swap (it passes before too; it exists so a later task can't silently change it):

```swift
@Test func activeAndHighlightRangesReadTheFacade() {
  let model = EditorModel.testModel(.fixture)
  model.transcript.selectWords(anchorID: firstWordID(model), focusID: lastSelectableWordID(model))
  model.seedSelectionFromTranscript()
  expectNoDifference(model.highlightedSampleRange, model.selectedSourceRange)
  expectNoDifference(model.activeOrSelectedRange, model.selectedSourceRange ?? model.activeSliceRange)
}
```

- [ ] **Step 2: Run test to verify current state** — `make test` (passes today; it's a guard). Note it green.

- [ ] **Step 3: Make the edits** — replace `transcript.selectedSampleRange` with `selectedSourceRange` at these read sites:
  - `245 activeOrSelectedRange` → `{ selectedSourceRange ?? activeSliceRange }`
  - `304 highlightedSampleRange` → `{ selectedSourceRange }`
  - `767 editorKeyDown .zoomFit` → `editedWaveform.zoomFitToggled(sourceSelection: selectedSourceRange)`
  - `671 commitMarqueePlayhead` → `guard let range = selectedSourceRange else { return }`
  - (Leave `activeEditingRange` at 249 as-is; it composes `fineTune.draftRange ?? activeOrSelectedRange`, and `activeOrSelectedRange` now reads the facade.)

- [ ] **Step 4: Run tests to verify they pass** — `make test`. All green (seed keeps values identical).
- [ ] **Step 5: Commit** — `git commit -am "refactor: read selection display range from selectedSourceRange facade"`

---

## Task 5: Switch add/remove/zoom/transport readers to the facade

Spec §6 step 2 (part b). The gating + action readers.

**Files:** Modify `EditorModel.swift`; Test add to `EditorSelectionTests.swift`.

- [ ] **Step 1: Write the guard test**

```swift
@Test func canAddAndCanRemoveReadTheFacade() {
  let model = EditorModel.testModel(.fixture)
  model.transcript.selectWords(anchorID: firstWordID(model), focusID: lastSelectableWordID(model))
  model.seedSelectionFromTranscript()
  #expect(model.canAddSlice)
  #expect(model.canRemoveSelectedSection)
}
```

- [ ] **Step 2: Run test** — `make test` (green today).

- [ ] **Step 3: Make the edits**
  - `374 canAddSlice` → `{ selectedSourceRange != nil && !fineTune.hasUnsavedChange }`
  - `894 zoomWaveformToSelection` → `guard let range = selectedSourceRange else { return }`
  - `980 addSliceTapped` → `guard canAddSlice, let range = selectedSourceRange else { return }`. Keep the wordIDs source as-is for now (`transcript.orderedSelectedWordIDs`); the overlap-derivation change lands in Task 9.
  - `1035 pendingRemovalSourceRange` → `isPendingRemovalSessionCurrent ? fineTune.draftRange : selectedSourceRange`
  - The `EditorView` transport `onChange` already seeds + calls `transportSelectionChanged`; leave `transportSelectionChanged` reading its `newRange` argument. (Task 8 re-points the `onChange` at `audioSelection`.)

- [ ] **Step 4: Run tests to verify they pass** — `make test`.
- [ ] **Step 5: Commit** — `git commit -am "refactor: read add/remove/zoom gates from selectedSourceRange facade"`

---

## Task 6: Flip the waveform writers to freeform (marquee + click set the exact range)

Spec §6 step 3. The waveform now writes `audioSelection` directly in exact source samples — **no word snap**. `marqueeAnchorFocus()` word-resolution is deleted.

**Files:** Modify `EditorModel.swift`; Test add to `EditorSelectionTests.swift` + update `EditorAreaSelectTests.swift`.

**Interfaces:**
- Produces: `func selectSourceRange(_ range: Range<Int>, snapPlayhead: Bool)` on `EditorModel`.
- The marquee/click handlers keep their existing signatures (called from the view) but now mutate `audioSelection`.

- [ ] **Step 1: Write the failing test** — the headline acceptance criterion (exact range, no word snap):

```swift
@Test func marqueeSelectsExactDraggedSourceRangeNotWordEdges() {
  let model = EditorModel.testModel(.fixture)
  model.editedWaveform.viewportResized(width: 1000)   // give geometry
  // Drag from source sample A to B that begins/ends MID-WORD.
  let a = midWordSample(model, wordIndex: 1)
  let b = midWordSample(model, wordIndex: 3)
  model.beginMarqueeAtSource(a); model.endMarqueeAtSource(b)   // test seam → see helper note
  expectNoDifference(model.audioSelection, min(a, b)..<max(a, b))
}
```

> The gesture handlers take view-x, not samples. For a deterministic model test, add small `@_spi(Testing)` helpers on `EditorModel` — `func beginMarqueeAtSource(_:)` / `func endMarqueeAtSource(_:)` — that convert the source sample to x via `editedWaveform.sourceSampleToX(_, bias: .nearest)` and call the real `waveformAreaSelectBegan/Ended`. Follow the existing `@_spi` test-helper pattern used elsewhere in this codebase (grep for `@_spi(Testing)`); if the project uses a different seam for geometry-dependent tests, match it. If exact x↔sample round-tripping is lossy at the fixture's zoom, assert `abs(lowerBound - min(a,b)) <= 1` rather than exact — but the range must NOT collapse to word edges.

- [ ] **Step 2: Run test to verify it fails** — `make test`. Expected: fails (marquee still resolves to word edges).

- [ ] **Step 3: Make the edits**

Add the direct setter:
```swift
/// Sets the freeform selection to an exact SOURCE range and (optionally) snaps the playhead to
/// its start. Empty/degenerate → clears. This is the single write path the waveform uses.
func selectSourceRange(_ range: Range<Int>, snapPlayhead: Bool) {
  guard range.lowerBound < range.upperBound else { audioSelection = nil; return }
  audioSelection = range
  if snapPlayhead {
    stopTransportForRuler()
    playheadSample = range.lowerBound
    cursorMoveGeneration &+= 1
  }
}
```

Rewrite the marquee internals to compute an exact source range from the drag instead of resolving words:
```swift
// Replaces marqueeAnchorFocus() + updateMarqueeSelection() word resolution.
private func marqueeSourceRange() -> Range<Int>? {
  guard let drag = areaSelectDrag else { return nil }
  let fixed = drag.existingAnchorSample ?? drag.anchorSample
  let clampedX = min(max(0, drag.currentX), editedWaveform.viewportWidth)
  let focus = clampedSample(editedWaveform.xToSourceSample(clampedX))
  let lower = min(fixed, focus)
  let upper = max(max(fixed, focus), lower + 1)
  return lower..<upper
}

private func updateMarqueeSelection() {
  audioSelection = marqueeSourceRange()   // live, exact, no word snap
}
```

- `waveformAreaSelectBegan`: keep the geometry guard + generation bump; for shift-extend, seed `existingAnchorSample` from `selectionAnchorSample ?? audioSelection?.lowerBound` (drop the `transcript.selectionAnchorID` word lookup). Set `selectionAnchorSample` to the fixed edge.
- `waveformAreaSelectEnded`: `let range = marqueeSourceRange()`; clear the drag/flags/generation as today; then `if let range { selectSourceRange(range, snapPlayhead: true); revealSourceRange(range) } else { clearSelection() }`. (Use `transcript.revealSelection` for now if `revealSourceRange` isn't added until Task 10 — but prefer adding `revealSourceRange` here; see Task 10's signature and pull it forward if convenient.)
- `waveformClicked`: `let sample = editedWaveform.xToSourceSample(positionX)`; if `extending`, `selectSourceRange((min/max of sample and current anchor), snapPlayhead: false)`; else set a zero-width intent that resolves to the containing word's range **only as a convenience** — the spec keeps click seeding a word span acceptable, but the *stored* selection must be the exact word range, not a snap of a drag. Simplest correct: on a plain click, select the containing word's exact `[startSample,endSample)` via `wordID(atSample:)` → look up the word's sample range → `selectSourceRange(_, snapPlayhead: true)`. A click in a gap → `clearSelection()`.
- Add `func clearSelection() { audioSelection = nil; selectionAnchorSample = nil; selectionEditingEdge = nil }`.
- **Delete** `marqueeAnchorFocus()`. Keep `wordID(atSample:)` (click still uses it).

- [ ] **Step 4: Update `EditorAreaSelectTests.swift`** — its assertions currently expect word-snapped ranges/IDs. Change them to assert the exact dragged source range (and clearing on a silence drag). Keep the auto-scroll tests. Run `make test`.
- [ ] **Step 5: Commit** — `git commit -am "feat: waveform marquee/click write exact freeform audioSelection (no word snap)"`

---

## Task 7: Flip the transcript to emit intents (stop seeding)

Spec §6 step 4. Text selection now *seeds* `audioSelection` through `EditorModel`; the seed-from-transcript mirror is removed.

**Files:** Modify `EditorModel.swift`, `TranscriptPageModel.swift`, `EditorView.swift`; Test add to `EditorSelectionTests.swift`.

**Interfaces:**
- Produces on `EditorModel`:
  ```swift
  func selectWords(anchorID: Word.ID, focusID: Word.ID)   // word span → source range → audioSelection
  func selectWord(_ id: Word.ID, extending: Bool)
  ```

- [ ] **Step 1: Write the failing test**

```swift
@Test func selectingWordsSeedsAudioSelectionWithCoveredSpan() {
  let model = EditorModel.testModel(.fixture)
  let a = model.editPlan.words[1].id
  let b = model.editPlan.words[3].id
  model.selectWords(anchorID: a, focusID: b)
  let expected = model.editPlan.words[1].startSample!..<model.editPlan.words[3].endSample!
  expectNoDifference(model.audioSelection, expected)
}
```

- [ ] **Step 2: Run test to verify it fails** — `make test`.

- [ ] **Step 3: Make the edits**
  - Add to `EditorModel`:
    ```swift
    /// Text-view intent: a word span becomes an exact source range (first word's start →
    /// last word's end, ordered by transcript position) and seeds the freeform selection.
    func selectWords(anchorID: Word.ID, focusID: Word.ID) {
      guard let range = sourceRange(coveringWords: anchorID, focusID) else { return }
      selectSourceRange(range, snapPlayhead: true)
    }
    func selectWord(_ id: Word.ID, extending: Bool) {
      if extending, let anchor = selectionAnchorSample ?? audioSelection?.lowerBound,
        let wordRange = sourceRange(ofWord: id) {
        selectSourceRange(min(anchor, wordRange.lowerBound)..<max(anchor, wordRange.upperBound),
          snapPlayhead: false)
      } else if let wordRange = sourceRange(ofWord: id) {
        selectionAnchorSample = wordRange.lowerBound
        selectSourceRange(wordRange, snapPlayhead: true)
      }
    }
    ```
    plus private `sourceRange(coveringWords:_:)` (min start / max end by transcript position, using `editPlan.words`) and `sourceRange(ofWord:)` helpers.
  - `TranscriptPageModel`: its text click/drag handlers stop mutating `selectionAnchorID/selectionFocusID` as truth; instead they resolve the gesture's word IDs and call a closure/delegate into `EditorModel.selectWords/selectWord`. Wire this as a callback the `EditorModel` sets on its child `transcript` at init (mirror how other child→parent intents are wired here; grep for existing closure callbacks on `transcript`). Keep an *internal* anchor for the in-progress text drag only.
  - `EditorView.swift`: **remove** `model.seedSelectionFromTranscript()` from the selection `onChange` (the transcript no longer owns truth). Leave the `transportSelectionChanged` call for now.
  - Delete `seedSelectionFromTranscript()` from `EditorModel` (nothing calls it now).

- [ ] **Step 4: Run tests to verify they pass** — `make test`. Update any transcript test that asserted selection truth on `TranscriptPageModel`.
- [ ] **Step 5: Commit** — `git commit -am "feat: transcript emits word-selection intents into audioSelection (stop seeding)"`

---

## Task 8: Edge-handle drag + nudge on the primary selection

Spec §6 step 5. Add drag-to-any-sample edge handles and reroute the 10 ms arrow nudges to the selection; retire the `nudgePendingRemoval` fine-tune stopgap.

**Files:** Modify `EditorModel.swift`, `WaveformLaneView.swift`, `EditorView.swift`, `EditorKeyMonitor.swift`/`editorKeyDown`; Test add to `EditorSelectionTests.swift`.

**Interfaces:**
- Produces on `EditorModel`:
  ```swift
  var boundaryEditor: BoundaryRangeEditor { get }   // built from editPlan (duration/rate/silences)
  func selectionEdgeDragBegan(_ edge: SelectionEdge)
  func selectionEdgeDragged(_ edge: SelectionEdge, toX: CGFloat)
  func selectionNudged(_ edge: SelectionEdge, byMs: Double)
  ```

- [ ] **Step 1: Write the failing tests**

```swift
@Test func nudgingStartEdgeMovesOnlyThatEdgeByTenMs() {
  let model = EditorModel.testModel(.fixture)
  model.selectSourceRange(10_000..<40_000, snapPlayhead: false)
  model.selectionNudged(.start, byMs: -10)
  let expected = model.boundaryEditor.nudgeStart(of: 10_000..<40_000, byMs: -10)
  expectNoDifference(model.audioSelection, expected)
}

@Test func nudgingEndEdgeLeavesStartFixed() {
  let model = EditorModel.testModel(.fixture)
  model.selectSourceRange(10_000..<40_000, snapPlayhead: false)
  model.selectionNudged(.end, byMs: 10)
  #expect(model.audioSelection?.lowerBound == 10_000)
  #expect(model.audioSelection!.upperBound > 40_000)
}

@Test func edgeDragMovesOnlyDraggedEdgeToSample() {
  let model = EditorModel.testModel(.fixture)
  model.editedWaveform.viewportResized(width: 1000)
  model.selectSourceRange(10_000..<40_000, snapPlayhead: false)
  let target = 25_000
  model.selectionEdgeDragBegan(.start)
  model.selectionEdgeDraggedToSource(.start, target)   // @_spi test seam (x↔sample as Task 6)
  #expect(model.audioSelection?.upperBound == 40_000)
  #expect(abs((model.audioSelection?.lowerBound ?? 0) - target) <= 1)
}
```

- [ ] **Step 2: Run tests to verify they fail** — `make test`.

- [ ] **Step 3: Make the edits**
  - `EditorModel`:
    ```swift
    var boundaryEditor: BoundaryRangeEditor {
      BoundaryRangeEditor(
        fileDurationSamples: editPlan.source.durationSamples, sampleRate: editPlan.source.sampleRate,
        minDurationSamples: Int(fineTune.minSliceMs / 1000 * Double(editPlan.source.sampleRate)),
        snapThresholdSamples: Int(fineTune.snapThresholdMs / 1000 * Double(editPlan.source.sampleRate)),
        silences: editPlan.silences)
    }
    func selectionEdgeDragBegan(_ edge: SelectionEdge) { selectionEditingEdge = edge }
    func selectionEdgeDragged(_ edge: SelectionEdge, toX x: CGFloat) {
      guard let range = audioSelection else { return }
      let sample = clampedSample(editedWaveform.xToSourceSample(x))
      let moved = edge == .start
        ? boundaryEditor.moveStart(of: range, to: sample, snap: false)
        : boundaryEditor.moveEnd(of: range, to: sample, snap: false)
      audioSelection = moved
    }
    func selectionNudged(_ edge: SelectionEdge, byMs ms: Double) {
      guard let range = audioSelection else { return }
      audioSelection = edge == .start
        ? boundaryEditor.nudgeStart(of: range, byMs: ms)
        : boundaryEditor.nudgeEnd(of: range, byMs: ms)
    }
    ```
    (Add the `@_spi(Testing)` `selectionEdgeDraggedToSource(_:_:)` seam mirroring Task 6.)
  - `editorKeyDown` (line 776-777): replace the `.nudgeCut…` case body with direct selection nudges and **delete** `nudgePendingRemoval`, `isPendingRemovalSessionCurrent`, and the `fineTune.draftRange` branch of `pendingRemovalSourceRange` (it becomes just `selectedSourceRange`):
    ```swift
    case .nudgeCutInEarlier: return nudgeSelection(.start, byMs: -fineTune.nudgeMs)
    case .nudgeCutInLater:   return nudgeSelection(.start, byMs: fineTune.nudgeMs)
    case .nudgeCutOutEarlier: return nudgeSelection(.end, byMs: -fineTune.nudgeMs)
    case .nudgeCutOutLater:   return nudgeSelection(.end, byMs: fineTune.nudgeMs)
    ```
    ```swift
    private func nudgeSelection(_ edge: SelectionEdge, byMs ms: Double) -> Bool {
      guard audioSelection != nil else { return false }   // fall through so a slice row can handle it
      selectionNudged(edge, byMs: ms)
      return true
    }
    ```
    Update `pendingRemovalSourceRange` → `{ selectedSourceRange }` and delete the now-unused `isPendingRemovalSessionCurrent`. Keep `removeSelectedSectionTapped` building the removal from `pendingRemovalSourceRange`.
  - `WaveformLaneView.swift`: add left/right edge hit-zones (a few pt wide, from the `highlightRange`→`laneSpan` rect) with an `NSView` that fires new `onEdgeDragBegan: (SelectionEdge) -> Void` / `onEdgeDragged: (SelectionEdge, CGFloat) -> Void` / `onEdgeDragEnded` closures. These are ADDITIVE and confined to the handle zones; a mouse-down outside them falls through to the existing marquee/click layer. (No interaction with #52's amplitude button — it lives in the toolbar, not the lane.)
  - `EditorView.swift`: pass the new closures → `model.selectionEdgeDragBegan/Dragged`. Re-point the selection `.onChange` at `audioSelection` (not `transcript.selectedSampleRange`) so transport-snap tracks the real truth.

- [ ] **Step 4: Run tests to verify they pass** — `make test`. Update `EditorRemovalTests.swift` if it exercised the nudge-via-fineTune stopgap (it should now nudge `audioSelection`).
- [ ] **Step 5: Commit** — `git commit -am "feat: edge-handle drag + 10ms nudge on freeform selection; retire fine-tune nudge stopgap"`

---

## Task 9: Derive transcript rendering from `audioSelection`

Spec §6 step 6 + the predicate corrections. Strikethrough → **fully contained**; highlight → **overlap**; clip `wordIDs` → **overlap at commit**.

**Files:** Modify `EditorModel.swift`, `TranscriptPageModel.swift`, `EditorView.swift`; Test add to `EditorSelectionTests.swift`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func strikethroughIsOnlyFullyRemovedWords() async {
  let model = EditorModel.testModel(.fixture)
  // Remove a range that fully covers word[2] but only clips word[1] and word[3].
  let r = model.editPlan.words[2].startSample!..<model.editPlan.words[2].endSample!
  model.selectSourceRange(r, snapPlayhead: false)
  await model.removeSelectedSectionTapped()
  #expect(model.removedWordIDs == Set([model.editPlan.words[2].id]))
}

@Test func addSliceWordIDsAreOverlapDerivedAtCommit() {
  let model = EditorModel.testModel(.fixture)
  // Selection that clips the edges of word[1] and word[3] but is anchored mid-word.
  let range = midWordSample(model, 1)..<midWordSample(model, 3)
  model.selectSourceRange(range, snapPlayhead: false)
  model.addSliceTapped()
  let expected = wordIDs(anyOverlap: range, words: model.editPlan.words)
  expectNoDifference(model.slices.last?.wordIDs, expected)
}
```

- [ ] **Step 2: Run tests to verify they fail** — `make test` (current `removedWordIDs` is midpoint-based; `addSliceTapped` uses `orderedSelectedWordIDs`).

- [ ] **Step 3: Make the edits**
  - `EditorModel.removedWordIDs` (317): `Set(timelineRemovals.flatMap { wordIDs(fullyContainedIn: $0.removedRange, words: editPlan.words) })`. Update the doc comment (drop the "midpoint" wording).
  - `EditorModel.addSliceTapped` (980): derive `let wordIDs = wordIDs(anyOverlap: range, words: editPlan.words)` and `snippet: displaySnippet(sliceSnippet(for: wordIDs, words: editPlan.words))` (use the free `sliceSnippet`, not `transcript.selectionSnippet`).
  - Add a derived **selection-highlight set** on `EditorModel`: `var selectedWordIDs: Set<Word.ID> { audioSelection.map { Set(wordIDs(anyOverlap: $0, words: editPlan.words)) } ?? [] }`, and push it into `TranscriptPageModel` for the text highlight (the transcript renders this pushed-in set rather than computing from its own selection). Wire via the same `didSet`/push pattern `removedWordIDs`/`clipBands` already use.
  - `EditorView.swift`: pass `model.selectedWordIDs` and `model.removedWordIDs` into the transcript view as the render inputs (they may already be threaded for `removedWordIDs`; add the highlight set alongside).

- [ ] **Step 4: Run tests to verify they pass** — `make test`. Update transcript render tests to feed the pushed-in sets.
- [ ] **Step 5: Commit** — `git commit -am "feat: derive transcript strikethrough/highlight/clip membership from audioSelection"`

---

## Task 10: Demote the transcript's selection-truth properties

Spec §6 step 7. Remove selection ownership from `TranscriptPageModel`'s editor-facing API and repurpose reveal.

**Files:** Modify `TranscriptPageModel.swift`, `EditorModel.swift`, `EditorView.swift`; Test cleanup across suites.

**Interfaces:**
- Produces on `EditorModel`: `func revealSourceRange(_ range: Range<Int>)` — scroll the transcript to the first word overlapping `range`, then `zoomWaveformToSelection()`.

- [ ] **Step 1: Write the failing test**

```swift
@Test func revealSourceRangeScrollsToFirstOverlappingWord() {
  let model = EditorModel.testModel(.fixture)
  let range = model.editPlan.words[4].startSample!..<model.editPlan.words[4].endSample!
  model.revealSourceRange(range)
  #expect(model.transcript.lastRevealedWordID == model.editPlan.words[4].id)  // or the existing reveal hook
}
```

> Match whatever observable the transcript already exposes for "revealed to word X" (grep `reveal` in `TranscriptPageModel`); if reveal is fire-and-forget, assert via a spy closure instead. Do not invent a property that doesn't exist.

- [ ] **Step 2: Run test to verify it fails** — `make test`.

- [ ] **Step 3: Make the edits**
  - Add `EditorModel.revealSourceRange(_:)`; route `revealSelectionAcrossPanes`, `waveformAreaSelectEnded`, `revealWords`, `cutSuggestionSelected`, `sliceRevealTapped` through it (they compute a source range and call `revealSourceRange`). `revealWords` becomes: map wordIDs → min start/max end source range → `selectSourceRange(range, snapPlayhead: true)` + `revealSourceRange(range)`.
  - `TranscriptPageModel`: delete/`private`-ize `selectedSampleRange`, `orderedSelectedWordIDs`, `selectedWordIDSet`, `selectionAnchorID`, `selectionFocusID` from the editor-facing surface. Any residue needed for the in-progress text-drag gesture stays `private`. `selectWords/selectWord/clearSelectionTapped` either move to intent-callbacks (Task 7) or become gesture-internal.
  - Remove the last `transcript.selectedSampleRange` reads in `EditorModel` (`fineTuneTarget` 255, `fineTuneSessionKey` 282 — repoint at `selectedSourceRange`, or delete if the pending-selection fine-tune session is fully retired by Task 8; verify the fine-tune modal for existing slices still works).
  - `EditorView.swift`: the selection `onChange` now observes `audioSelection` only; remove any remaining `transcript.selectedSampleRange` observers.

- [ ] **Step 4: Run tests to verify they pass** — `make test`. Delete/rewrite transcript tests asserting the removed public selection API. Confirm `EditedWaveformAdapter` / `WaveformModel` / slice-edit-modal suites stay green (source-purity preserved).
- [ ] **Step 5: Commit** — `git commit -am "refactor: demote transcript selection truth; reveal by source range"`

---

## Final steps (after Task 10)

- [ ] `make format-check && make lint && make test` all green.
- [ ] **Codex adversarial pass on the full diff** (repo pipeline): `codex` skill review mode (pass/fail gate) then challenge mode. Fix everything surfaced; re-run if fixes were non-trivial. Focus Codex on: the x↔sample round-trip near a collapsed seam (`xToSourceSample` discontinuity), the intent-callback wiring (no transcript observe-and-rewrite feedback loop), and predicate off-by-ones.
- [ ] Open the PR against `main`. Invoke `/fix-review` once as the final step; re-run after any push. Do NOT trigger a CodeRabbit/Greptile re-review when the confidence score ≥ 4/5.
- [ ] Final report: what shipped, decisions made, anything uncertain, and human-only manual-GUI-verification items (marquee exactness, edge-handle drag feel, strikethrough only on fully-removed words, seam-crossing edge-drag) — the headless env can't run the app.

---

## Self-Review (author's pass against the spec)

**Spec coverage:** §2 locked decisions → decisions 1/2 (Tasks 3/6/7/8), 3 strikethrough-contained (Task 9), 4 clip-overlap (Task 9). §3.1 truth vars (Task 3). §3.2 interface (Tasks 3/6/7/8). §3.3 derived table + off-by-one (Tasks 1/9). §3.4 source-canonical (all — conversions only at adapter boundary). §3.5 `BoundaryRangeEditor` (Task 2). §5 don't-promote-FineTuneModel (Task 8 retires the stopgap). §6 seven steps → Tasks 3-10 one-to-one. §7 edge cases: overlap gate reused (Task 8 keeps `canRemove`), seam discontinuity (Task 6/8 tests + Codex), no feedback loop (Task 7 callback direction), clip overlap-at-commit (Task 9), undo deferral (never touched `mutateDocument` for selection), empty→clear (Task 6 `selectSourceRange` guard). §8 testing (each task's tests). §9 out-of-scope respected (no crossfade audio, no sub-word text striping, no cross-seam affordance).

**Placeholder scan:** the two `@_spi(Testing)` geometry seams (Tasks 6/8) and the reveal-observable (Task 10) are marked "match the existing pattern / grep first" rather than invented — deliberate, because those hooks already exist in this codebase in a specific form the executor must mirror, and guessing a name would be the worse failure. Every predicate, edge-math, and reader-swap step is concrete.

**Type consistency:** `SelectionEdge` (Task 1) used verbatim in Tasks 3/8. `BoundaryRangeEditor` signature (Task 2) matches call sites (Task 8). `wordIDs(fullyContainedIn:)`/`wordIDs(anyOverlap:)` (Task 1) match uses (Task 9). `selectedSourceRange` facade name identical across Tasks 3-10. `selectSourceRange(_:snapPlayhead:)` identical in Tasks 6/7/8/10.

**Known risk to flag at execution:** Task 6's plain-click behavior (select the containing word's exact range) is a judgment call within the spec's "click seeds a word span is acceptable" latitude — if the reviewer prefers click to set a zero-width caret instead, that's a small, contained change. Raise it at the Task 6 review gate.
