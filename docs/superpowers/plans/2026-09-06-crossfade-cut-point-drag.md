# Crossfade Cut-Point Drag Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user fine-tune where each side of a crossfade join lands — dragging (or nudging) the left and right cut points independently, into or out of the crossfade, without changing the crossfade length.

**Architecture:** A cut-point move edits ONE bound of `TimelineRemoval.removedRange` with the crossfade length pinned — the same audio pipeline that already renders removals + fades handles the moved cut with zero renderer/fade-math change. Interaction mirrors the proven crossfade-*stretch* pattern (transient draft → view-only preview repaint → single commit on mouse-up; document untouched mid-drag). A new AppKit overlay layer above the stretch layer claims only ⌥-modified hits in narrow zones adjacent to each bowtie; keyboard nudges reuse the existing 10 ms constant.

**Tech Stack:** Swift 6 / SwiftUI (macOS), MV with `@Observable` models, `swift-dependencies`, `swift-sharing`, `swift-identified-collections`, `swift-custom-dump`, Swift Testing, AppKit `NSViewRepresentable` overlay layers.

**Spec:** `docs/superpowers/specs/2026-09-06-crossfade-cut-point-drag-design.md` (committed; the plan argues from it — read both).

## Global Constraints

- **Move `removedRange` bounds, never `centerOffsetSamples`.** `Crossfade.centerOffsetSamples` and `curveAmount` are stored-but-inert (DSP deferred); this feature does not touch them.
- **Crossfade length is fixed** across a cut-point move. Freeze the **effective** (clamped) fade length — `TimelineSeam.crossfadeLength` — not the stored `Crossfade.lengthSamples`, so an overlong stored length can't silently re-grow when handle becomes available.
- **Preserve `TimelineRemoval.id`** on a bound-move — do NOT route through `removeSourceRange` (it merges + mints a fresh UUID, breaking selection/undo/restore identity).
- **All coordinates are `Int` samples.** Source samples for `removedRange`/cut points; edited samples for viewport math. Sample rate lives at `editPlan.source.sampleRate` (44100 in the fixture); ms→samples = `Int((ms / 1000 * Double(sampleRate)).rounded())`.
- **Every side-effect stays behind the model.** Views hold zero logic; the AppKit layer reports x + edge only. Behavior is tested on `EditorModel`, never the view.
- **Mutations funnel through `mutateDocument`** (undo/dirty tracking) and are **blocked while `isExporting`**.
- **Invoke the relevant `pfw-*` skills before writing Swift**: `pfw-observable-models` (EditorModel), `pfw-testing` + `pfw-custom-dump` (`expectNoDifference`, no `Task.sleep`), `pfw-modern-swiftui` (the overlay layer + wiring), `pfw-identified-collections` (`timelineRemovals[id:]`). List them in each task's checklist.

---

## File Structure

**New files**
- `QuickInterviewEditor/QuickInterviewEditor/Models/CrossfadeCutPointDraft.swift` — the `RemovalBoundary` enum + `CrossfadeCutPointDraft` transient drag-state struct. Value types only (Task 1).
- `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/SeamCutPointHandleLayer.swift` — the AppKit overlay layer that claims ⌥-drags in the outside zones adjacent to each bowtie (Task 4). (Kept in its own file rather than appended to `WaveformLaneView.swift`, which already holds four overlay layers.)
- `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorCrossfadeCutPointTests.swift` — the model-level Swift Testing suite (Tasks 2, 3, 5).

**Modified files**
- `QuickInterviewEditor/QuickInterviewEditor/Models/EditedWaveformAdapter.swift` — add `previewCutPoint(timeline:visibleStart:)` beside `previewStretch` (Task 3).
- `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift` — the draft property, clamp helper, commit funnel, drag lifecycle, preview-timeline builder, `EditorKey` cases, nudge routing (Tasks 2, 3, 5).
- `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/WaveformLaneView.swift` — mount the new overlay above `SeamStretchHandleLayer`, add its five defaulted callback params (Task 4).
- `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/WaveformView.swift` — wire the five new lane callbacks to model methods (Task 4).
- `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorKeyMonitor.swift` — map ⌥/⌥⇧+arrows to the new `EditorKey` cases (Task 5).

---

## Geometry reference (read before Tasks 3–4)

For a removal `[cL, cR)` with effective fade length `L`, on the EDITED axis the bowtie spans `[editedCrossfadeStart, editedCrossfadeStart + L)`:
- `leadingHandleX` ↔ `editedCrossfadeStart` — left-source `cL − L`, right-source `cR`.
- `trailingHandleX` ↔ `editedCrossfadeStart + L` — left-source `cL`, right-source `cR + L`.

The **outside** (un-overlapped kept) audio:
- **Left of `leadingHandleX`** = left kept segment (ends at `cL`). Its zone moves **cL** → `RemovalBoundary.lower`.
- **Right of `trailingHandleX`** = right kept segment (begins at `cR`). Its zone moves **cR** → `RemovalBoundary.upper`.

Within a kept segment, edited samples advance 1:1 with source samples, so an edited-sample delta equals a source-sample delta — the drag math needs no `editedToSource` call. Per the spec's worked example ("⌥-drags the left waveform **inward** → cL becomes 98000"), an inward (toward-bowtie) drag moves the cut to remove **more** of that side. With `delta = editedNow − editedAtStart` (positive = rightward), the unified rule for both edges is:

```
newBound = committedBound − delta
```

- Left zone, drag right (`delta > 0`) → `cL` decreases (earlier) ✓ matches worked example.
- Right zone, drag left (`delta < 0`) → `cR` increases (removes more right) ✓ symmetric.

> **UX sign is the one genuinely uncertain bit.** The tests below pin `newBound = committed − delta` to the spec's worked example. Task 4 includes a manual-QA step to confirm the drag *feels* right in Logic terms; if it feels inverted, it is a single-sign flip caught by flipping the tests.

---

### Task 1: `RemovalBoundary` + `CrossfadeCutPointDraft`

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Models/CrossfadeCutPointDraft.swift`
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorCrossfadeCutPointTests.swift`

**Interfaces:**
- Produces:
  - `enum RemovalBoundary: Equatable { case lower, upper }`
  - `struct CrossfadeCutPointDraft: Equatable` with fields: `id: UUID`, `edge: RemovalBoundary`, `committedRange: Range<Int>`, `draftedRange: Range<Int>`, `frozenCrossfadeLength: Int`, `dragStartEditedSample: Int`, `frozenVisibleStart: Int`, `frozenSamplesPerPixel: Double`.

**Skills checklist:** `pfw-testing`, `pfw-custom-dump`.

- [ ] **Step 1: Write the failing test**

Add to a new file `EditorCrossfadeCutPointTests.swift`:

```swift
import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
import IdentifiedCollections
@_spi(Internals) import Sharing
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct EditorCrossfadeCutPointTests {

  // MARK: - Draft value type

  @Test func draftIsEquatableByValue() {
    let a = CrossfadeCutPointDraft(
      id: Fixtures.uuid(1), edge: .lower, committedRange: 48_000..<96_000,
      draftedRange: 46_000..<96_000, frozenCrossfadeLength: 600,
      dragStartEditedSample: 20_000, frozenVisibleStart: 0, frozenSamplesPerPixel: 200)
    var b = a
    b.draftedRange = 46_000..<96_000
    expectNoDifference(a, b)
    b.edge = .upper
    #expect(a != b)
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd QuickInterviewEditor && make test-fast ONLY=PlayolaInterviewEditorTests/EditorCrossfadeCutPointTests`
Expected: FAIL — `cannot find 'CrossfadeCutPointDraft' in scope` / `RemovalBoundary`.

- [ ] **Step 3: Write minimal implementation**

`CrossfadeCutPointDraft.swift`:

```swift
import Foundation

/// Which bound of a `TimelineRemoval.removedRange` a cut-point drag/nudge moves. `.lower` is the
/// left cut `cL` (grabbed via the outside audio left of the bowtie); `.upper` is the right cut `cR`
/// (grabbed via the outside audio right of the bowtie). Distinct from `CrossfadeEdge` (leading/
/// trailing bowtie edges, which drive length) because on the edited axis the overlap inverts the
/// mapping — `cL` sits at the trailing edge, `cR` at the leading edge — so a dedicated,
/// unambiguous type keeps the removal-bound intent clear.
enum RemovalBoundary: Equatable {
  case lower
  case upper
}

/// Transient view-state for an in-progress crossfade cut-point drag: the moving bound, the committed
/// and drafted removal ranges, the frozen EFFECTIVE fade length (pinned across the move), and the
/// viewport geometry frozen at drag begin. Mirrors `CrossfadeStretchDraft`: the document is untouched
/// mid-drag (only the adapter's preview timeline reflows); the single commit lands on mouse-up. Drag
/// math maps x → edited sample against the FROZEN viewport so the live reflow (which shifts content
/// under the pointer) can't feed back on itself.
struct CrossfadeCutPointDraft: Equatable {
  var id: UUID
  var edge: RemovalBoundary
  var committedRange: Range<Int>
  var draftedRange: Range<Int>
  var frozenCrossfadeLength: Int
  var dragStartEditedSample: Int
  var frozenVisibleStart: Int
  var frozenSamplesPerPixel: Double
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd QuickInterviewEditor && make test-fast ONLY=PlayolaInterviewEditorTests/EditorCrossfadeCutPointTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Models/CrossfadeCutPointDraft.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorCrossfadeCutPointTests.swift
git commit -m "feat: add CrossfadeCutPointDraft + RemovalBoundary value types"
```

---

### Task 2: Clamp helper + commit funnel

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift` (add near `updateCrossfade`, ~line 1870)
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorCrossfadeCutPointTests.swift`

**Interfaces:**
- Consumes: `mutateDocument(_:)`, `timelineRemovals` (`IdentifiedArrayOf<TimelineRemoval>`), `editedTimeline` (`EditedTimeline`), `editPlan.source.durationSamples`, `isExporting`. `RemovalBoundary` (Task 1).
- Produces:
  - `func updateRemovalRange(id: TimelineRemoval.ID, removedRange: Range<Int>, freezingCrossfadeLength length: Int)`
  - `func clampedRemovalRange(id: TimelineRemoval.ID, proposed: Range<Int>, frozenLength: Int) -> Range<Int>` (internal so tests can exercise the clamp directly)

**Skills checklist:** `pfw-observable-models`, `pfw-identified-collections`, `pfw-testing`, `pfw-custom-dump`.

The clamp (from the spec, computed against the committed, normalized `editedTimeline`, which is stable mid-drag because the document is untouched):

```
r = removals[i]; [cL, cR) = r.removedRange ; F = frozenLength (effective)
prevUpper = i>0 ? removals[i-1].removedRange.upperBound : 0
nextLower = i+1<count ? removals[i+1].removedRange.lowerBound : sourceDuration
prevF = i>0 ? seams[i-1].crossfadeLength : 0
nextF = i+1<count ? seams[i+1].crossfadeLength : 0
newCL = clamp(proposedCL, lower: prevUpper + prevF + F, upper: cR - 1)
newCR = clamp(proposedCR, lower: cL + 1,                upper: nextLower - F - nextF)
```

- [ ] **Step 1: Write the failing tests**

Add these helper methods and tests to `EditorCrossfadeCutPointTests.swift` (mirror the stretch suite's private helpers):

```swift
  // MARK: - Helpers

  private func editor(fingerprint: String) -> EditorModel {
    EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL,
      editPlan: Fixtures.editPlan(), sourceFingerprint: fingerprint)
  }

  @discardableResult
  private func addRemoval(
    _ model: EditorModel, id: UUID = Fixtures.uuid(1),
    range: Range<Int> = 48_000..<96_000, length: Int = 600
  ) -> UUID {
    model.mutateDocument { doc in
      doc.timelineRemovals.append(
        TimelineRemoval(
          id: id, removedRange: range,
          crossfade: Crossfade(lengthSamples: length, curve: .equalPower)))
    }
    return id
  }

  private func primeGeometry(_ model: EditorModel) {
    model.editedWaveform.viewportWidth = 1000
    model.editedWaveform.samplesPerPixel = 200
    model.editedWaveform.visibleStartSample = 0
  }

  private func withStorage(_ body: () -> Void) {
    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
    } operation: {
      body()
    }
  }

  // MARK: - Commit funnel

  @Test func updateRemovalRangeMovesBoundAndFreezesLengthPreservingID() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-commit")
      let id = addRemoval(model, range: 48_000..<96_000, length: 600)

      model.updateRemovalRange(id: id, removedRange: 46_000..<96_000, freezingCrossfadeLength: 600)

      expectNoDifference(model.timelineRemovals[id: id]?.removedRange, 46_000..<96_000)
      expectNoDifference(model.timelineRemovals[id: id]?.crossfade.lengthSamples, 600)
      #expect(model.timelineRemovals[id: id]?.id == id)  // identity preserved
    }
  }

  @Test func updateRemovalRangeIsBlockedWhileExporting() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-export-guard")
      let id = addRemoval(model, range: 48_000..<96_000, length: 600)
      model.exportPhase = .exporting(current: 0, total: 1)  // isExporting is computed off exportPhase

      model.updateRemovalRange(id: id, removedRange: 46_000..<96_000, freezingCrossfadeLength: 600)

      expectNoDifference(model.timelineRemovals[id: id]?.removedRange, 48_000..<96_000)
    }
  }

  // MARK: - Clamp

  @Test func clampLowerCannotCrossTheRightCut() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-clamp-lower-cross")
      let id = addRemoval(model, range: 48_000..<96_000, length: 600)

      // Propose cL past cR: pinned to cR - 1.
      let clamped = model.clampedRemovalRange(
        id: id, proposed: 200_000..<96_000, frozenLength: 600)

      expectNoDifference(clamped, 95_999..<96_000)
    }
  }

  @Test func clampUpperRespectsNeighborRemovalAndItsFade() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-clamp-upper-neighbor")
      let id = addRemoval(model, id: Fixtures.uuid(1), range: 48_000..<96_000, length: 600)
      // Neighbor removal to the right, fade 400: cR upper bound = 150_000 - 600 - 400 = 149_000.
      addRemoval(model, id: Fixtures.uuid(2), range: 150_000..<200_000, length: 400)

      let clamped = model.clampedRemovalRange(
        id: id, proposed: 48_000..<300_000, frozenLength: 600)

      expectNoDifference(clamped, 48_000..<149_000)
    }
  }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd QuickInterviewEditor && make test-fast ONLY=PlayolaInterviewEditorTests/EditorCrossfadeCutPointTests`
Expected: FAIL — `value of type 'EditorModel' has no member 'updateRemovalRange' / 'clampedRemovalRange'`.

- [ ] **Step 3: Write minimal implementation**

Add to `EditorModel.swift`, immediately after `updateCrossfade(id:_:)` (~line 1875):

```swift
  /// Commits a cut-point move as one undo step: writes the moved `removedRange` AND pins the fade to
  /// the frozen EFFECTIVE `length`, so a stored-overlong `lengthSamples` can't silently re-grow once
  /// the moved bound frees up handle. Preserves the removal's `id` (does NOT route through
  /// `removeSourceRange`, which mints a new UUID). Guarded mid-export like `updateCrossfade`.
  func updateRemovalRange(
    id: TimelineRemoval.ID, removedRange: Range<Int>, freezingCrossfadeLength length: Int
  ) {
    guard !isExporting, timelineRemovals[id: id] != nil else { return }
    mutateDocument { doc in
      doc.timelineRemovals[id: id]?.removedRange = removedRange
      doc.timelineRemovals[id: id]?.crossfade.lengthSamples = length
    }
  }

  /// Clamps a proposed `removedRange` for a cut-point move so it stays non-empty, never crosses the
  /// other cut, and never overlaps or starves a neighbor removal's fade. Reads the COMMITTED,
  /// normalized `editedTimeline` (unchanged mid-drag): `removals`/`seams` there carry the effective
  /// (clamped) fade lengths. `frozenLength` is the moving seam's own effective length, pinned at drag
  /// begin. Only the moving edge changes; the other is held. Returns the committed range unchanged if
  /// the removal isn't found (defensive; unreachable in normal flow).
  func clampedRemovalRange(
    id: TimelineRemoval.ID, proposed: Range<Int>, frozenLength: Int
  ) -> Range<Int> {
    let timeline = editedTimeline
    guard let index = timeline.removals.firstIndex(where: { $0.id == id }) else { return proposed }
    let removals = timeline.removals
    let seams = timeline.seams
    let cL = removals[index].removedRange.lowerBound
    let cR = removals[index].removedRange.upperBound
    let prevUpper = index > 0 ? removals[index - 1].removedRange.upperBound : 0
    let nextLower =
      index + 1 < removals.count
      ? removals[index + 1].removedRange.lowerBound : editPlan.source.durationSamples
    let prevF = index > 0 ? seams[index - 1].crossfadeLength : 0
    let nextF = index + 1 < seams.count ? seams[index + 1].crossfadeLength : 0

    if proposed.lowerBound != cL {
      let newCL = min(max(proposed.lowerBound, prevUpper + prevF + frozenLength), cR - 1)
      return newCL..<cR
    }
    let newCR = max(min(proposed.upperBound, nextLower - frozenLength - nextF), cL + 1)
    return cL..<newCR
  }
```

> Note: the clamp keys off which bound moved (`proposed.lowerBound != cL` → lower edge). Callers move exactly one bound, so this is unambiguous.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd QuickInterviewEditor && make test-fast ONLY=PlayolaInterviewEditorTests/EditorCrossfadeCutPointTests`
Expected: PASS (all Task 1 + Task 2 tests).

- [ ] **Step 5: Commit**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorCrossfadeCutPointTests.swift
git commit -m "feat: add cut-point clamp + updateRemovalRange commit funnel"
```

---

### Task 3: Drag lifecycle + preview

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Models/EditedWaveformAdapter.swift` (add beside `previewStretch`, ~line 116)
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift` (add after the crossfade-stretch section, ~line 1999)
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorCrossfadeCutPointTests.swift`

**Interfaces:**
- Consumes: `CrossfadeCutPointDraft`, `RemovalBoundary` (Task 1); `updateRemovalRange`, `clampedRemovalRange` (Task 2); `stopPlaybackForTimelineEdit()`, `selectSeam(_:)`, `editedTimeline`, `editedWaveform`, `timelineRemovals`, `editPlan.source.durationSamples`, `WaveformViewport.xToSample(_:visibleStartSample:samplesPerPixel:)`.
- Produces:
  - `EditedWaveformAdapter.previewCutPoint(timeline: EditedTimeline, visibleStart: Int)`
  - `EditorModel.crossfadeCutPointDraft: CrossfadeCutPointDraft?`
  - `EditorModel.crossfadeCutPointDragBegan(id: TimelineRemoval.ID, edge: RemovalBoundary, atX: CGFloat)`
  - `EditorModel.crossfadeCutPointDragged(toX: CGFloat)`
  - `EditorModel.crossfadeCutPointDragEnded()`
  - `EditorModel.crossfadeCutPointDragCancelled()`

**Skills checklist:** `pfw-observable-models`, `pfw-testing`, `pfw-custom-dump`.

- [ ] **Step 1: Write the failing tests**

Add to `EditorCrossfadeCutPointTests.swift`:

```swift
  // MARK: - Drag lifecycle

  @Test func draggingLeftCutInwardMovesLowerBoundWithoutTouchingDocument() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-drag-left-preview")
      primeGeometry(model)  // spp 200 → 10px = 2000 samples
      let id = addRemoval(model, range: 48_000..<96_000, length: 600)

      model.crossfadeCutPointDragBegan(id: id, edge: .lower, atX: 100)
      model.crossfadeCutPointDragged(toX: 110)  // +10px rightward → delta +2000

      // Draft reflects cL - delta = 46_000; document still committed.
      expectNoDifference(model.crossfadeCutPointDraft?.draftedRange, 46_000..<96_000)
      expectNoDifference(model.timelineRemovals[id: id]?.removedRange, 48_000..<96_000)
    }
  }

  @Test func endingLeftDragCommitsMovedCutUndoably() async {
    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
    } operation: {
      let model = editor(fingerprint: "fp-cut-drag-left-commit")
      model.editedWaveform.viewportWidth = 1000
      model.editedWaveform.samplesPerPixel = 200
      model.editedWaveform.visibleStartSample = 0
      model.mutateDocument { doc in
        doc.timelineRemovals.append(
          TimelineRemoval(
            id: Fixtures.uuid(1), removedRange: 48_000..<96_000,
            crossfade: Crossfade(lengthSamples: 600, curve: .equalPower)))
      }

      model.crossfadeCutPointDragBegan(id: Fixtures.uuid(1), edge: .lower, atX: 100)
      model.crossfadeCutPointDragged(toX: 110)
      model.crossfadeCutPointDragEnded()

      expectNoDifference(model.crossfadeCutPointDraft, nil)
      expectNoDifference(model.timelineRemovals[id: Fixtures.uuid(1)]?.removedRange, 46_000..<96_000)
      expectNoDifference(
        model.timelineRemovals[id: Fixtures.uuid(1)]?.crossfade.lengthSamples, 600)  // length fixed
      #expect(model.canUndo)

      await model.undoTapped()
      expectNoDifference(model.timelineRemovals[id: Fixtures.uuid(1)]?.removedRange, 48_000..<96_000)
    }
  }

  @Test func draggingRightCutInwardMovesUpperBound() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-drag-right")
      primeGeometry(model)
      let id = addRemoval(model, range: 48_000..<96_000, length: 600)

      model.crossfadeCutPointDragBegan(id: id, edge: .upper, atX: 300)
      model.crossfadeCutPointDragged(toX: 290)  // -10px leftward → delta -2000 → cR + 2000

      expectNoDifference(model.crossfadeCutPointDraft?.draftedRange, 48_000..<98_000)
    }
  }

  @Test func cancellingDragRestoresCommittedTimelineAndDropsDraft() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-drag-cancel")
      primeGeometry(model)
      let id = addRemoval(model, range: 48_000..<96_000, length: 600)

      model.crossfadeCutPointDragBegan(id: id, edge: .lower, atX: 100)
      model.crossfadeCutPointDragged(toX: 110)
      model.crossfadeCutPointDragCancelled()

      expectNoDifference(model.crossfadeCutPointDraft, nil)
      expectNoDifference(model.timelineRemovals[id: id]?.removedRange, 48_000..<96_000)
    }
  }

  @Test func draggingSelectsTheSeam() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-drag-selects")
      primeGeometry(model)
      let id = addRemoval(model, range: 48_000..<96_000, length: 600)

      model.crossfadeCutPointDragBegan(id: id, edge: .lower, atX: 100)

      expectNoDifference(model.selectedSeamID, id)
    }
  }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd QuickInterviewEditor && make test-fast ONLY=PlayolaInterviewEditorTests/EditorCrossfadeCutPointTests`
Expected: FAIL — no member `crossfadeCutPointDragBegan` etc.

- [ ] **Step 3a: Add the adapter preview method**

In `EditedWaveformAdapter.swift`, immediately after `previewStretch(timeline:targetVisibleStart:)` (~line 116):

```swift
  /// Installs a live cut-point-move preview: renders `previewTimeline` (one removal's `removedRange`
  /// moved, its fade length frozen) at the drag's frozen viewport. Sibling to `previewStretch`, but
  /// with NO viewport shift — a cut move slides downstream content past a fixed left edge rather than
  /// growing a seam about a center, so holding `visibleStart` keeps the reflow legible. The document
  /// stays untouched; only this adapter timeline reflows until commit.
  func previewCutPoint(timeline previewTimeline: EditedTimeline, visibleStart: Int) {
    timeline = previewTimeline
    visibleStartSample = clampedStart(visibleStart)
  }
```

- [ ] **Step 3b: Add the model draft property + lifecycle**

In `EditorModel.swift`, add the property beside the other transient drag drafts (near `crossfadeStretchDraft`):

```swift
  /// Transient cut-point drag state; non-nil only during an active ⌥-drag. Like `crossfadeStretchDraft`
  /// it is plain @Observable view state, never in the undo stack.
  var crossfadeCutPointDraft: CrossfadeCutPointDraft?
```

Add the lifecycle after the crossfade-stretch section (~line 1999):

```swift
  // MARK: - Crossfade cut-point drag (⌥-drag the outside waveform)

  /// Begins a cut-point drag of seam `id`'s `edge`: selects the seam, stops playback (the edited axis
  /// reflows under the transport), and seeds the draft with the committed range, the seam's EFFECTIVE
  /// fade length (pinned), and the viewport geometry + press position frozen for stable drag math. A
  /// no-op mid-export (the commit would refuse, so the lane must not preview a discarded reflow) or for
  /// an unknown removal / one with no derivable seam.
  func crossfadeCutPointDragBegan(
    id: TimelineRemoval.ID, edge: RemovalBoundary, atX posX: CGFloat
  ) {
    guard !isExporting, let removal = timelineRemovals[id: id],
      let seam = editedWaveform.timeline.seams.first(where: { $0.id == id })
    else { return }
    stopPlaybackForTimelineEdit()
    selectSeam(id)
    let dragStartEdited = WaveformViewport.xToSample(
      posX, visibleStartSample: editedWaveform.visibleStartSample,
      samplesPerPixel: editedWaveform.samplesPerPixel)
    crossfadeCutPointDraft = CrossfadeCutPointDraft(
      id: id, edge: edge, committedRange: removal.removedRange, draftedRange: removal.removedRange,
      frozenCrossfadeLength: seam.crossfadeLength, dragStartEditedSample: dragStartEdited,
      frozenVisibleStart: editedWaveform.visibleStartSample,
      frozenSamplesPerPixel: editedWaveform.samplesPerPixel)
  }

  /// A cut-point drag to view-x: map x → edited sample against the FROZEN viewport, derive the source
  /// delta (1:1 with edited samples in the kept outside zone), apply it to the moving bound
  /// (`committed − delta`), clamp against the committed timeline, hold it as the draft, and reflow the
  /// preview timeline live. The document stays untouched — commit is on release.
  func crossfadeCutPointDragged(toX posX: CGFloat) {
    guard var draft = crossfadeCutPointDraft else { return }
    let editedNow = WaveformViewport.xToSample(
      posX, visibleStartSample: draft.frozenVisibleStart,
      samplesPerPixel: draft.frozenSamplesPerPixel)
    let delta = editedNow - draft.dragStartEditedSample
    // Build a CONSTRUCTIBLE range: Swift traps on a `Range` literal whose lowerBound exceeds its
    // upperBound, and a large drag can push the moving cut past the fixed one. Cap the moving bound
    // against the opposite bound here (min/max); `clampedRemovalRange` then applies the real
    // neighbor-aware clamp and the non-empty (`cR-1` / `cL+1`) guarantee.
    let proposed: Range<Int>
    switch draft.edge {
    case .lower:
      let proposedCL = min(draft.committedRange.lowerBound - delta, draft.committedRange.upperBound)
      proposed = proposedCL..<draft.committedRange.upperBound
    case .upper:
      let proposedCR = max(draft.committedRange.upperBound - delta, draft.committedRange.lowerBound)
      proposed = draft.committedRange.lowerBound..<proposedCR
    }
    let clamped = clampedRemovalRange(
      id: draft.id, proposed: proposed, frozenLength: draft.frozenCrossfadeLength)
    draft.draftedRange = clamped
    crossfadeCutPointDraft = draft
    let preview = previewCutPointTimeline(
      id: draft.id, removedRange: clamped, length: draft.frozenCrossfadeLength)
    editedWaveform.previewCutPoint(timeline: preview, visibleStart: draft.frozenVisibleStart)
  }

  /// The edited timeline as it will render with removal `id`'s range set to `removedRange` and its
  /// fade pinned to `length` — built exactly the way the commit builds it, so releasing repositions
  /// nothing. Falls back to the committed timeline for an unknown id.
  private func previewCutPointTimeline(
    id: TimelineRemoval.ID, removedRange: Range<Int>, length: Int
  ) -> EditedTimeline {
    var removals = Array(timelineRemovals)
    guard let index = removals.firstIndex(where: { $0.id == id }) else { return editedTimeline }
    removals[index].removedRange = removedRange
    removals[index].crossfade.lengthSamples = length
    return EditedTimeline(
      sourceDurationSamples: editPlan.source.durationSamples, removals: removals)
  }

  /// Release: rewind the adapter to the committed timeline (so `syncEditedTimeline`'s equality guard
  /// can't short-circuit the reconciliation the live preview would otherwise have masked), then commit
  /// the drafted range once. A drag that netted no range change pushes no entry. A no-op if no drag is
  /// live or the removal vanished mid-drag.
  func crossfadeCutPointDragEnded() {
    guard let draft = crossfadeCutPointDraft else { return }
    crossfadeCutPointDraft = nil
    editedWaveform.timeline = editedTimeline
    guard let removal = timelineRemovals[id: draft.id],
      draft.draftedRange != removal.removedRange
    else { return }
    updateRemovalRange(
      id: draft.id, removedRange: draft.draftedRange,
      freezingCrossfadeLength: draft.frozenCrossfadeLength)
  }

  /// Aborts an in-flight cut-point drag without committing: drops the draft and restores the committed
  /// timeline/viewport the live preview replaced. For a drag torn down before mouse-up (sheet
  /// dismissed, tab switched, lane removed). A no-op if no drag is live.
  func crossfadeCutPointDragCancelled() {
    guard let draft = crossfadeCutPointDraft else { return }
    crossfadeCutPointDraft = nil
    editedWaveform.timeline = editedTimeline
    editedWaveform.visibleStartSample = draft.frozenVisibleStart
    editedWaveform.samplesPerPixel = draft.frozenSamplesPerPixel
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd QuickInterviewEditor && make test-fast ONLY=PlayolaInterviewEditorTests/EditorCrossfadeCutPointTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Models/EditedWaveformAdapter.swift \
        QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorCrossfadeCutPointTests.swift
git commit -m "feat: crossfade cut-point drag lifecycle with view-only preview"
```

---

### Task 4: ⌥-drag overlay layer + wiring

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/SeamCutPointHandleLayer.swift`
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/WaveformLaneView.swift` (add params ~line 86; mount overlay ~line 118, after the `SeamStretchHandleLayer` overlay)
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/WaveformView.swift` (wire callbacks ~line 31)

**Interfaces:**
- Consumes: `SeamOverlay` (`id`, `leadingHandleX`, `trailingHandleX`), `WaveformLaneDriving`, `RemovalBoundary` (Task 1), and the Task 3 model methods.
- Produces on `WaveformLaneView`: `onCutPointDragBegan: (UUID, RemovalBoundary, CGFloat) -> Void`, `onCutPointDragged: (CGFloat) -> Void`, `onCutPointDragEnded: () -> Void`, `onCutPointDragCancelled: () -> Void`, `onCutPointSelect: (UUID) -> Void` (all defaulted no-ops so the slice-edit sheet compiles unchanged).

**Skills checklist:** `pfw-modern-swiftui`.

> **No unit test.** This repo does not unit-test AppKit overlay layers (`SeamStretchHandleLayer` has none); its behavior is fully covered by the Task 3 model tests. Verification here is a clean build + a manual smoke test.

> **Design note (reconciles the spec):** the spec text says "zones adjacent to the *selected* bowtie," but the approved interaction is **auto-select-then-drag in one motion** (works whether or not already selected). So zones exist for **every** seam (like the stretch handles), and the layer claims **only ⌥-modified hits** — reading `NSEvent.modifierFlags` in `hitTest` (which runs at mouse-down routing time), matching "modifier read once at mouse-down." A plain (non-⌥) drag falls straight through to the stretch/marquee layers.

- [ ] **Step 1: Create the overlay layer**

`SeamCutPointHandleLayer.swift`:

```swift
import AppKit
import SwiftUI

/// Claims ⌥-drags in the narrow OUTSIDE zones adjacent to each bowtie — left of `leadingHandleX`
/// (moves the left cut `cL`) and right of `trailingHandleX` (moves the right cut `cR`) — to move that
/// removal's cut point without changing the fade length. Sits ABOVE `SeamStretchHandleLayer`, but
/// claims ONLY ⌥-modified hits (read via `NSEvent.modifierFlags` in `hitTest`, i.e. at mouse-down),
/// so a plain drag on a bowtie edge still stretches length and every non-⌥ mouse-down falls through.
/// Auto-selects the seam on drag-begin (a ⌥-click with no drag just selects). Mirrors the
/// stretch layer's draft→preview→commit gesture handling.
private struct SeamCutPointHandleLayer: NSViewRepresentable {
  let seams: [SeamOverlay]
  let waveform: any WaveformLaneDriving
  let onDragBegan: (UUID, RemovalBoundary, CGFloat) -> Void
  let onDragged: (CGFloat) -> Void
  let onDragEnded: () -> Void
  let onDragCancelled: () -> Void
  let onSelect: (UUID) -> Void

  func makeNSView(context: Context) -> HandleView {
    let view = HandleView()
    apply(to: view)
    return view
  }

  func updateNSView(_ nsView: HandleView, context: Context) { apply(to: nsView) }

  private func apply(to view: HandleView) {
    view.seams = seams
    view.waveform = waveform
    view.onDragBegan = onDragBegan
    view.onDragged = onDragged
    view.onDragEnded = onDragEnded
    view.onDragCancelled = onDragCancelled
    view.onSelect = onSelect
  }

  final class HandleView: NSView {
    var seams: [SeamOverlay] = []
    var waveform: (any WaveformLaneDriving)?
    var onDragBegan: ((UUID, RemovalBoundary, CGFloat) -> Void)?
    var onDragged: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    var onDragCancelled: (() -> Void)?
    var onSelect: ((UUID) -> Void)?

    /// Width of an outside grab zone flanking each bowtie edge.
    private let zoneWidth: CGFloat = 12
    /// Minimum travel before a grab becomes a drag, so a ⌥-click never opens a draft / no-op undo.
    private let dragThreshold: CGFloat = 6
    private var active: (id: UUID, edge: RemovalBoundary)?
    private var downX: CGFloat?
    private var didDrag = false

    override var acceptsFirstResponder: Bool { false }

    /// Claim only ⌥-modified hits landing in an outside zone. `NSEvent.modifierFlags` reads the
    /// CURRENT flags — at mouse-down routing time — so the modifier is captured once at press; a
    /// non-⌥ mouse-down returns nil and falls through to the stretch/marquee layers beneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
      guard NSEvent.modifierFlags.contains(.option) else { return nil }
      let local = convert(point, from: superview)
      guard bounds.contains(local) else { return nil }
      return zone(nearestToX: local.x) != nil ? self : nil
    }

    /// The outside zone whose bowtie edge is nearest `x`: left of a seam's `leadingHandleX` moves
    /// `cL` (`.lower`), right of its `trailingHandleX` moves `cR` (`.upper`). Nil when no zone covers
    /// `x`. Off-screen handles (nil) are skipped.
    private func zone(nearestToX posX: CGFloat) -> (id: UUID, edge: RemovalBoundary)? {
      var best: (target: (id: UUID, edge: RemovalBoundary), distance: CGFloat)?
      for seam in seams {
        if let lead = seam.leadingHandleX, posX >= lead - zoneWidth, posX < lead {
          let distance = lead - posX
          if best == nil || distance < best!.distance { best = ((seam.id, .lower), distance) }
        }
        if let trail = seam.trailingHandleX, posX > trail, posX <= trail + zoneWidth {
          let distance = posX - trail
          if best == nil || distance < best!.distance { best = ((seam.id, .upper), distance) }
        }
      }
      return best?.target
    }

    private func localX(_ event: NSEvent) -> CGFloat {
      convert(event.locationInWindow, from: nil).x
    }

    override func mouseDown(with event: NSEvent) {
      let posX = localX(event)
      active = zone(nearestToX: posX)
      downX = posX
      didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
      guard let active, let downX else { return }
      let currentX = localX(event)
      if !didDrag {
        guard abs(currentX - downX) >= dragThreshold else { return }
        didDrag = true
        onDragBegan?(active.id, active.edge, downX)  // seed drag math from the press position
      }
      onDragged?(currentX)
    }

    override func mouseUp(with event: NSEvent) {
      if didDrag {
        onDragEnded?()
      } else if let active {
        // A ⌥-click that never crossed the threshold selects the seam without seeking.
        onSelect?(active.id)
      }
      active = nil
      downX = nil
      didDrag = false
    }

    /// Torn down mid-drag (sheet dismissed, tab switched, lane removed): mouse-up never arrives, so
    /// cancel to avoid stranding the preview timeline + stale draft.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
      super.viewWillMove(toWindow: newWindow)
      if newWindow == nil, didDrag {
        onDragCancelled?()
        active = nil
        downX = nil
        didDrag = false
      }
    }

    /// Forward ⌘-scroll zoom / plain-scroll pan through, exactly like the stretch layer, so the grab
    /// zones don't swallow the gesture.
    override func scrollWheel(with event: NSEvent) {
      let flags = event.modifierFlags
      waveform?.scrolled(
        deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
        hasPreciseDeltas: event.hasPreciseScrollingDeltas,
        optionDown: flags.contains(.option), commandDown: flags.contains(.command),
        atX: localX(event))
    }
  }
}
```

- [ ] **Step 2: Add the lane params and mount the overlay**

In `WaveformLaneView.swift`, after the `onSeamStretchCancelled` declaration (~line 86), add:

```swift
  /// Cut-point ⌥-drag on the outside audio flanking a bowtie: moves the left/right cut without
  /// changing fade length. Default no-ops so call sites without cut-point editing (the slice-edit
  /// sheet) compile unchanged.
  var onCutPointDragBegan: (UUID, RemovalBoundary, CGFloat) -> Void = { _, _, _ in }
  var onCutPointDragged: (CGFloat) -> Void = { _ in }
  var onCutPointDragEnded: () -> Void = {}
  var onCutPointDragCancelled: () -> Void = {}
  var onCutPointSelect: (UUID) -> Void = { _ in }
```

Then in `body`, immediately after the `.overlay(SeamStretchHandleLayer(...))` block (~line 118) and before the `WaveformEdgeHandleLayer` overlay, add:

```swift
      // Sits ABOVE the seam-stretch handles: claims ONLY ⌥-modified hits in the outside zones flanking
      // each bowtie, so ⌥-drag moves a cut point while a plain drag on the bowtie edge still stretches
      // length and every non-⌥ mouse-down falls through.
      .overlay(
        SeamCutPointHandleLayer(
          seams: seams,
          waveform: waveform,
          onDragBegan: onCutPointDragBegan,
          onDragged: onCutPointDragged,
          onDragEnded: onCutPointDragEnded,
          onDragCancelled: onCutPointDragCancelled,
          onSelect: onCutPointSelect)
      )
```

- [ ] **Step 3: Wire the callbacks in WaveformView**

In `WaveformView.swift`, inside the `WaveformLaneView(...)` call, after `onSeamStretchCancelled:` (~line 31), add:

```swift
        onCutPointDragBegan: { model.crossfadeCutPointDragBegan(id: $0, edge: $1, atX: $2) },
        onCutPointDragged: { model.crossfadeCutPointDragged(toX: $0) },
        onCutPointDragEnded: { model.crossfadeCutPointDragEnded() },
        onCutPointDragCancelled: { model.crossfadeCutPointDragCancelled() },
        onCutPointSelect: { model.selectSeam($0) },
```

- [ ] **Step 4: Build and run the full suite**

Run: `cd QuickInterviewEditor && make test-fast`
Expected: PASS (compiles clean; all suites green, including Tasks 1–3).

- [ ] **Step 5: Manual smoke test (Logic parity)**

Launch the app, delete a segment to create a crossfade, then:
1. ⌥-drag the waveform just left of the bowtie → the left cut moves; fade length visibly unchanged; releasing commits (one undo step).
2. ⌥-drag just right of the bowtie → the right cut moves.
3. Confirm the drag **direction feels right** (inward = removes more of that side). If inverted, flip the sign in `crossfadeCutPointDragged` (`committed − delta` → `committed + delta`) and update the Task 3 tests' expected ranges to match.
4. A plain (no-⌥) drag on the bowtie edge still stretches length; ⌘-scroll still zooms over the zones; play/pause and ruler click-to-seek still work with a seam selected.

- [ ] **Step 6: Commit**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/SeamCutPointHandleLayer.swift \
        QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/WaveformLaneView.swift \
        QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/WaveformView.swift
git commit -m "feat: ⌥-drag overlay layer for crossfade cut points"
```

---

### Task 5: Keyboard nudge (⌥/⌥⇧ + arrows)

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift` (`EditorKey` enum ~line 9; `editorKeyDown` switch ~line 1419; add `nudgeSeamCut`)
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorKeyMonitor.swift` (`arrowKey(forKeyCode:modifiers:)` ~line 90)
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorCrossfadeCutPointTests.swift`

**Interfaces:**
- Consumes: `selectedSeamID`, `timelineRemovals`, `editedWaveform.timeline.seams`, `updateRemovalRange`, `clampedRemovalRange` (Task 2), `editPlan.source.sampleRate`, `fineTune.nudgeMs` (10.0), `RemovalBoundary`, `editorKeyDown(_:)`.
- Produces: `EditorKey` cases `.nudgeLeftCutEarlier`, `.nudgeLeftCutLater`, `.nudgeRightCutEarlier`, `.nudgeRightCutLater`; routing in `editorKeyDown`; `EditorModel.nudgeSeamCut(edge:byMs:) -> Bool`.

Key map (spec table): `⌥←`/`⌥→` = left cut earlier/later; `⌥⇧←`/`⌥⇧→` = right cut earlier/later. These modifier combos are currently unclaimed.

**Skills checklist:** `pfw-observable-models`, `pfw-testing`, `pfw-custom-dump`.

- [ ] **Step 1: Write the failing tests**

Add to `EditorCrossfadeCutPointTests.swift`:

```swift
  // MARK: - Keyboard nudge

  @Test func nudgeMovesLeftCutBy10msWhenSeamSelected() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-nudge-left")
      let id = addRemoval(model, range: 48_000..<96_000, length: 600)
      model.selectSeam(id)

      _ = model.editorKeyDown(.nudgeLeftCutEarlier)  // 10ms @ 44100 = 441 samples earlier

      expectNoDifference(model.timelineRemovals[id: id]?.removedRange, 47_559..<96_000)
    }
  }

  @Test func nudgeMovesRightCutBy10msWhenSeamSelected() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-nudge-right")
      let id = addRemoval(model, range: 48_000..<96_000, length: 600)
      model.selectSeam(id)

      _ = model.editorKeyDown(.nudgeRightCutLater)  // cR + 441

      expectNoDifference(model.timelineRemovals[id: id]?.removedRange, 48_000..<96_441)
    }
  }

  @Test func nudgeIsANoOpWithNoSeamSelected() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-nudge-noseam")
      let id = addRemoval(model, range: 48_000..<96_000, length: 600)

      let consumed = model.editorKeyDown(.nudgeLeftCutEarlier)

      #expect(consumed == false)
      expectNoDifference(model.timelineRemovals[id: id]?.removedRange, 48_000..<96_000)
    }
  }
```

Add to `EditorKeyMonitor` tests (in the existing `EditorKeyMonitorTests.swift` if present; otherwise assert the mapping inline here by calling the internal `arrowKey`). If `EditorKeyMonitor.Coordinator.arrowKey` is `private`, cover the mapping via the model-facing test above and add this key-map test only if the monitor already exposes a test seam. Otherwise skip — the model tests above prove routing.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd QuickInterviewEditor && make test-fast ONLY=PlayolaInterviewEditorTests/EditorCrossfadeCutPointTests`
Expected: FAIL — `type 'EditorKey' has no member 'nudgeLeftCutEarlier'`.

- [ ] **Step 3a: Add the EditorKey cases**

In `EditorModel.swift`, in the `EditorKey` enum (~line 26, before `case escape` or after it), add:

```swift
  /// Nudge a SELECTED crossfade seam's cut points by `FineTuneModel.nudgeMs`: ⌥←/→ move the left
  /// cut (`cL`) earlier/later, ⌥⇧←/→ move the right cut (`cR`). Consumed only when a seam is
  /// selected, so they fall through otherwise.
  case nudgeLeftCutEarlier
  case nudgeLeftCutLater
  case nudgeRightCutEarlier
  case nudgeRightCutLater
```

- [ ] **Step 3b: Route them in `editorKeyDown` + add the handler**

In `editorKeyDown(_:)` (~line 1419), add a case to the switch (before the closing `}` / `return true`):

```swift
    case .nudgeLeftCutEarlier: return nudgeSeamCut(edge: .lower, byMs: -fineTune.nudgeMs)
    case .nudgeLeftCutLater: return nudgeSeamCut(edge: .lower, byMs: fineTune.nudgeMs)
    case .nudgeRightCutEarlier: return nudgeSeamCut(edge: .upper, byMs: -fineTune.nudgeMs)
    case .nudgeRightCutLater: return nudgeSeamCut(edge: .upper, byMs: fineTune.nudgeMs)
```

Add the handler near `nudgeSelection` (~line 1456):

```swift
  /// Nudges one cut of the SELECTED crossfade seam by a signed millisecond delta, freezing the fade
  /// length and clamping like a drag. Falls through unconsumed (`false`) when no seam is selected, so
  /// the key still reaches whatever else might handle it. A clamped no-op still consumes the key
  /// (a selected seam owns the ⌥-arrow).
  private func nudgeSeamCut(edge: RemovalBoundary, byMs ms: Double) -> Bool {
    guard let id = selectedSeamID, let removal = timelineRemovals[id: id],
      let seam = editedWaveform.timeline.seams.first(where: { $0.id == id })
    else { return false }
    let delta = Int((ms / 1000 * Double(editPlan.source.sampleRate)).rounded())
    // Constructible range (see Task 3): a nudge on a removal shorter than the nudge distance could
    // otherwise invert the `Range` literal and trap. Cap the moving bound against the opposite one;
    // `clampedRemovalRange` applies the real clamp.
    let proposed: Range<Int>
    switch edge {
    case .lower:
      let proposedCL = min(removal.removedRange.lowerBound + delta, removal.removedRange.upperBound)
      proposed = proposedCL..<removal.removedRange.upperBound
    case .upper:
      let proposedCR = max(removal.removedRange.upperBound + delta, removal.removedRange.lowerBound)
      proposed = removal.removedRange.lowerBound..<proposedCR
    }
    let clamped = clampedRemovalRange(
      id: id, proposed: proposed, frozenLength: seam.crossfadeLength)
    guard clamped != removal.removedRange else { return true }
    updateRemovalRange(
      id: id, removedRange: clamped, freezingCrossfadeLength: seam.crossfadeLength)
    return true
  }
```

> Sign: `⌥←` (left cut earlier) passes `-nudgeMs` → `cL + (-441)` = earlier ✓. `⌥⇧→` (right cut later) passes `+nudgeMs` → `cR + 441` = later ✓. (Note the nudge applies the delta directly to the bound — no `− delta` inversion — because the key names already encode direction.)

- [ ] **Step 3c: Map the keys in EditorKeyMonitor**

In `EditorKeyMonitor.swift`, in `arrowKey(forKeyCode:modifiers:)` (~line 90), add before `default`:

```swift
      case 123 where modifiers == .option: return .nudgeLeftCutEarlier  // ⌥←
      case 124 where modifiers == .option: return .nudgeLeftCutLater  // ⌥→
      case 123 where modifiers == [.option, .shift]: return .nudgeRightCutEarlier  // ⌥⇧←
      case 124 where modifiers == [.option, .shift]: return .nudgeRightCutLater  // ⌥⇧→
```

(The `relevant` mask at line 68 already includes `.option` and `.shift`, so these combos reach `arrowKey`.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd QuickInterviewEditor && make test-fast`
Expected: PASS (full suite green).

- [ ] **Step 5: Commit**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift \
        QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorKeyMonitor.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorCrossfadeCutPointTests.swift
git commit -m "feat: ⌥/⌥⇧+arrow nudge for crossfade cut points"
```

---

## Pre-PR verification

- [ ] `cd QuickInterviewEditor && make test-fast` — full suite green.
- [ ] `cd QuickInterviewEditor && make format-check && make lint` — clean.
- [ ] `cd QuickInterviewEditor && make test` (fastlane / CI parity) once before pushing.
- [ ] Manual QA per Task 4 Step 5, plus: undo/redo keeps the seam selected (id stable); a moved cut that would starve a neighbor's fade clamps instead of overlapping; export still blocked mid-drag.
- [ ] Per CLAUDE.md Architect-with-Codex pipeline: run the `codex` skill **review** then **challenge** mode on the final diff (this touches real audio-model logic — above the triviality threshold). Fix everything surfaced; re-run if fixes were non-trivial.

## Self-Review (completed by plan author)

**Spec coverage:**
- Move `removedRange` bounds, length fixed → Tasks 2–3 (`updateRemovalRange` writes range + frozen length). ✓
- `centerOffsetSamples` untouched → never referenced. ✓
- Select-first via `selectedSeamID`, transport unaffected → Task 3 auto-selects; no transport layer touched (Task 4 note). ✓
- ⌥-drag narrow zones above stretch layer, ⌥ read at mouse-down, auto-select-then-drag → Task 4. ✓
- Nudge ±10 ms, ⌥←/→ = left, ⌥⇧←/→ = right, before `nudgeSelection` fallback (separate `EditorKey` cases, no ordering conflict) → Task 5. ✓
- Draft/preview/commit trio, preserve id, freeze effective length, clamp against neighbor effective fades, rewind before commit, frozen viewport geometry, stop playback, block export → Tasks 2–3. ✓
- Correctness traps (never infer cR from sourceCut; no zero-length/inverted range via clamp `cR-1`/`cL+1`; cancel restores) → clamp + cancel path. ✓

**Deviation flagged:** spec says zones adjacent to the *selected* bowtie, but the approved auto-select-then-drag requires all-seam zones gated by ⌥ (Task 4 design note). The drag-direction sign is pinned to the spec's worked example and re-verified manually in Task 4 Step 5.

**Type consistency:** `RemovalBoundary` (`.lower`/`.upper`) used identically across Tasks 1–5; `updateRemovalRange(id:removedRange:freezingCrossfadeLength:)` and `clampedRemovalRange(id:proposed:frozenLength:)` signatures match every call site; `crossfadeCutPointDraft` field names match their reads in Task 3. ✓
