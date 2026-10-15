# Cmd-click multi-word selection + multi-delete Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cmd-click several non-adjacent transcript words, press ⌫, and every piece is removed in one undo step with its own default crossfade.

**Architecture:** A new `EditorSelection.ranges(MultiRangeSelection)` case holds ≥2 disjoint SOURCE-sample pieces. `freeformRange` stays single-range-only, so single-range features (fine-tune, audition, edge drag, nudge, Mark as Clip, open) switch off with no per-feature code; a new `selectedRanges` feeds delete, the transcript highlight, and the waveform highlight. Delete goes through one `removeSourceRanges(_:)` funnel built on a pure `TimelineRemovals.mergedSpans` function; `removeSourceRange(_:)` becomes a one-element wrapper.

**Tech Stack:** Swift 6 / SwiftUI + AppKit (macOS), `@Observable` MV models, swift-dependencies, swift-sharing, swift-identified-collections, Swift Testing + swift-custom-dump.

**Spec:** `docs/superpowers/specs/2026-10-15-transcript-cmd-click-multi-delete-design.md`

## Global Constraints

- Before writing Swift, invoke every applicable `pfw-*` skill and list them in your task checklist: `pfw-observable-models` (EditorModel edits), `pfw-testing` + `pfw-custom-dump` (all tests), `pfw-identified-collections` (`timelineRemovals`), `pfw-modern-swiftui` (Task 5 views).
- Zero logic in views: every decision is a model property. Views only draw.
- Ranges are SOURCE samples. Word IDs are not used as selection identity.
- Gesture: **Cmd-click in the transcript only.** No Cmd-drag, no waveform additive gesture, no Ctrl-click.
- Cmd-click is **add-only**; re-clicking a selected word is a no-op. Command wins over Shift.
- Default crossfade for every new removal: `Crossfade(lengthSamples: defaultCrossfadeSamples, curve: .equalPower)` (20 ms).
- Undo labels: `"Remove Section"` for one resulting removal, `"Remove Sections"` for several.
- **Do not create new Swift files.** The `.xcodeproj` is checked in; a new file needs `xcodegen generate` and busts DerivedData. Every change below lands in an existing file.
- Do not run `xcodegen generate`.
- Tests: Swift Testing, `@MainActor struct`, camelCase names, `expectNoDifference` for value comparisons, no `Task.sleep`.
- Inner loop: `make test-fast ONLY=PlayolaInterviewEditorTests/<Suite>` from `QuickInterviewEditor/`. Before the final commit: full `make test-fast`, `make format-check`, `make lint`.
- Commits: no `Co-Authored-By` or other co-sign trailers. Never `--no-verify`.

## Review Focus

1. **Fast Cmd-clicks on two different words** arrive with `clickCount == 2`; the second word must still be added, never treated as a double-click open (Task 3 test `cmdClickWithClickCountTwoOnAnotherWordStillAdds`).
2. **Cmd-click on whitespace or punctuation between words** must leave the multi-selection intact, not clear it like a plain click does (Task 3 test `cmdClickOffAWordKeepsSelection`).
3. **Cmd-click a word the current freeform range already partly covers** is a no-op: it is already highlighted, so it counts as selected (Task 3 test `cmdClickWordPartlyInsideRangeIsNoOp`).
4. **Clear, then Undo** must restore the exact multi-selection, so `reconcileSelection` must not collapse or drop pieces (Task 1 test `undoOfClearRestoresMultiSelection`).
5. **Adding a piece does not move the playhead.** A user reviewing every "uh" keeps their place; only a fresh selection snaps the playhead, as today (Task 3 test `cmdClickAddDoesNotMovePlayhead`).

## Fixture reference (`Resources/Fixtures/edit-plan.json`, 44.1 kHz)

| Word id | Text | Source samples |
|---|---|---|
| 2 | a | `70648..<74176` |
| 3 | young | `77704..<98916` |
| 4 | Hayes | `107736..<119202` |
| 8 | a | `164228..<166874` |
| 13 | and | `232186..<235714` |

Gap between word 2 and word 3: `74176..<77704`.

---

### Task 1: Multi-range selection state

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Models/EditorSelection.swift`
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Models/TimelineRemoval.swift` (append the range-merge helper)
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel+SelectionHistory.swift` (`deleteSelectionTapped` switch ~line 21, `reconcileSelection` switch ~line 85)
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift` (`selectionAnchorSample` getter ~line 663)
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Models/TimelineRemovalTests.swift`
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorSelectionTests.swift`
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorSelectionHistoryTests.swift`

**Interfaces:**
- Produces:
  - `struct MultiRangeSelection: Equatable, Sendable { var primary: Range<Int>; var anchor: Int; var additional: [Range<Int>]; var allRanges: [Range<Int>] }`
  - `EditorSelection.ranges(MultiRangeSelection)`
  - `EditorSelection.selectedRanges: [Range<Int>]`: `[r]` for `.range`, `allRanges` for `.ranges`, `[]` otherwise
  - `EditorSelection.adding(_ piece: Range<Int>) -> EditorSelection`
  - `static EditorSelection.normalized(primary: Range<Int>, anchor: Int, pieces: [Range<Int>]) -> EditorSelection`
  - `extension Array where Element == Range<Int> { func mergingTouching() -> [Range<Int>] }`
  - `EditorModel.selectionAnchorSample` returns `multi.anchor` for `.ranges`

- [ ] **Step 1: Write the failing tests**

Append to `TimelineRemovalTests`:

```swift
  @Test func mergingTouchingSortsAndMergesOverlapAndAbutment() {
    let merged = [50..<60, 10..<20, 20..<30, 25..<40].mergingTouching()
    expectNoDifference(merged, [10..<40, 50..<60])
  }

  @Test func mergingTouchingKeepsGappedRangesApart() {
    expectNoDifference([30..<40, 10..<20].mergingTouching(), [10..<20, 30..<40])
  }
```

Append to `EditorSelectionTests`:

```swift
  // MARK: - Multi-range selection

  @Test func addingDisjointPieceToRangeMakesRanges() {
    let selection = EditorSelection.range(70648..<74176, anchor: 70648).adding(164228..<166874)
    expectNoDifference(
      selection,
      .ranges(
        MultiRangeSelection(primary: 70648..<74176, anchor: 70648, additional: [164228..<166874])))
  }

  @Test func addingOverlappingPieceIsNoOp() {
    let start = EditorSelection.range(70648..<119202, anchor: 70648)
    expectNoDifference(start.adding(107736..<119202), start)
  }

  @Test func addingAbuttingPieceMergesAndDemotesToRange() {
    let selection = EditorSelection.range(74176..<77704, anchor: 74176).adding(70648..<74176)
    expectNoDifference(selection, .range(70648..<77704, anchor: 70648))
  }

  @Test func addingPieceThatBridgesTwoPiecesKeepsPrimaryIdentity() {
    let multi = EditorSelection.ranges(
      MultiRangeSelection(primary: 100..<200, anchor: 200, additional: [300..<400, 900..<950]))
    expectNoDifference(
      multi.adding(200..<300),
      .ranges(MultiRangeSelection(primary: 100..<400, anchor: 100, additional: [900..<950])))
  }

  @Test func addingFromNonRangeSelectionIsNoOp() {
    expectNoDifference(EditorSelection.none.adding(10..<20), .none)
    expectNoDifference(EditorSelection.seam(Fixtures.uuid(1)).adding(10..<20), .seam(Fixtures.uuid(1)))
  }

  @Test func selectedRangesListsEveryPieceInOrder() {
    let multi = EditorSelection.ranges(
      MultiRangeSelection(primary: 500..<600, anchor: 500, additional: [100..<200]))
    expectNoDifference(multi.selectedRanges, [100..<200, 500..<600])
    expectNoDifference(EditorSelection.range(1..<2, anchor: 1).selectedRanges, [1..<2])
    expectNoDifference(EditorSelection.none.selectedRanges, [])
  }

  @Test func freeformRangeIsNilForMultiSelection() {
    let multi = EditorSelection.ranges(
      MultiRangeSelection(primary: 500..<600, anchor: 500, additional: [100..<200]))
    #expect(multi.freeformRange == nil)
  }

  @Test func selectionAnchorSampleReadsMultiAnchor() {
    let model = editor()
    model.selection = .ranges(
      MultiRangeSelection(primary: 70648..<74176, anchor: 74176, additional: [164228..<166874]))
    expectNoDifference(model.selectionAnchorSample, 74176)
  }
```

Append to `EditorSelectionHistoryTests`:

```swift
  @Test func undoOfClearRestoresMultiSelection() async {
    let model = editor()
    let multi = EditorSelection.ranges(
      MultiRangeSelection(primary: 70648..<74176, anchor: 70648, additional: [164228..<166874]))
    model.selection = multi
    model.clearSelectionTapped()
    expectNoDifference(model.selection, .none)
    await model.undoTapped()
    expectNoDifference(model.selection, multi)
  }
```

- [ ] **Step 2: Run tests to verify they fail**

Run (from `QuickInterviewEditor/`): `make test-fast ONLY=PlayolaInterviewEditorTests/EditorSelectionTests`
Expected: build FAILS with "type 'EditorSelection' has no member 'ranges'" / "cannot find 'MultiRangeSelection' in scope".

- [ ] **Step 3: Implement**

Replace the enum in `Models/EditorSelection.swift` (keep `TranscriptObjectID` and `SidebarReveal` as they are):

```swift
enum EditorSelection: Equatable, Sendable {
  case none
  case object(TranscriptObjectID)
  case range(Range<Int>, anchor: Int)
  /// Cmd-click pieces. Always ≥ 2 disjoint, non-abutting pieces; one piece is a `.range`.
  case ranges(MultiRangeSelection)
  case seam(UUID)

  var objectID: TranscriptObjectID? {
    guard case .object(let id) = self else { return nil }
    return id
  }

  /// Single-range only — nil for `.ranges`, so single-range features (fine-tune, audition, edge
  /// drag, nudge, Mark as Clip, open) stay unavailable for a multi-selection.
  var freeformRange: Range<Int>? {
    guard case .range(let range, _) = self else { return nil }
    return range
  }

  var selectedRanges: [Range<Int>] {
    switch self {
    case .range(let range, _): return [range]
    case .ranges(let multi): return multi.allRanges
    case .none, .object, .seam: return []
    }
  }

  /// Cmd-click: adds `piece` to a `.range`/`.ranges` selection. Add-only — a piece overlapping a
  /// selected piece is a no-op. Other selections are returned unchanged.
  func adding(_ piece: Range<Int>) -> EditorSelection {
    let primary: Range<Int>
    let anchor: Int
    let others: [Range<Int>]
    switch self {
    case .range(let range, let rangeAnchor):
      (primary, anchor, others) = (range, rangeAnchor, [])
    case .ranges(let multi):
      (primary, anchor, others) = (multi.primary, multi.anchor, multi.additional)
    case .none, .object, .seam:
      return self
    }
    guard !piece.isEmpty, !([primary] + others).contains(where: { $0.overlaps(piece) }) else {
      return self
    }
    return Self.normalized(primary: primary, anchor: anchor, pieces: others + [piece])
  }

  /// Merges touching pieces (`pieces` may include `primary`). The merged piece holding `primary`
  /// stays primary and the anchor snaps to its nearest edge; a single piece demotes to `.range`.
  static func normalized(primary: Range<Int>, anchor: Int, pieces: [Range<Int>]) -> EditorSelection
  {
    let merged = ([primary] + pieces).mergingTouching()
    let newPrimary = merged.first { $0.contains(primary.lowerBound) } ?? primary
    let snappedAnchor: Int
    if anchor <= newPrimary.lowerBound {
      snappedAnchor = newPrimary.lowerBound
    } else if anchor >= newPrimary.upperBound {
      snappedAnchor = newPrimary.upperBound
    } else {
      snappedAnchor =
        anchor - newPrimary.lowerBound <= newPrimary.upperBound - anchor
        ? newPrimary.lowerBound : newPrimary.upperBound
    }
    let additional = merged.filter { $0 != newPrimary }
    guard !additional.isEmpty else { return .range(newPrimary, anchor: snappedAnchor) }
    return .ranges(
      MultiRangeSelection(primary: newPrimary, anchor: snappedAnchor, additional: additional))
  }
}

struct MultiRangeSelection: Equatable, Sendable {
  /// The piece the Shift-extend anchor belongs to.
  var primary: Range<Int>
  var anchor: Int
  /// Sorted, disjoint, and non-abutting with `primary`.
  var additional: [Range<Int>]

  var allRanges: [Range<Int>] {
    (additional + [primary]).sorted { $0.lowerBound < $1.lowerBound }
  }
}
```

Append to `Models/TimelineRemoval.swift`:

```swift
extension Array where Element == Range<Int> {
  /// Sorted by lower bound, with overlapping or abutting ranges merged.
  func mergingTouching() -> [Range<Int>] {
    var merged: [Range<Int>] = []
    for range in sorted(by: { $0.lowerBound < $1.lowerBound }) {
      if let last = merged.last, range.lowerBound <= last.upperBound {
        merged[merged.count - 1] = last.lowerBound..<Swift.max(last.upperBound, range.upperBound)
      } else {
        merged.append(range)
      }
    }
    return merged
  }
}
```

In `EditorModel+SelectionHistory.swift`, `deleteSelectionTapped`, change `case .range:` to:

```swift
    case .range, .ranges:
      await removeSelectedSectionTapped()
```

In `reconcileSelection`, add after the `.range` case:

```swift
    case .ranges(let multi):
      let source = 0..<editPlan.source.durationSamples
      let primary = multi.primary.clamped(to: source)
      guard !primary.isEmpty else {
        clearSelection()
        return
      }
      selection = EditorSelection.normalized(
        primary: primary, anchor: multi.anchor,
        pieces: multi.additional.map { $0.clamped(to: source) }.filter { !$0.isEmpty })
```

In `EditorModel.swift`, replace the `selectionAnchorSample` getter body:

```swift
    get {
      switch selection {
      case .range(_, let anchor): return anchor
      case .ranges(let multi): return multi.anchor
      case .none, .object, .seam: return selectedTranscriptObject?.range.lowerBound
      }
    }
```

(Leave the setter as is: it only writes `.range`.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test-fast ONLY=PlayolaInterviewEditorTests/EditorSelectionTests`, then `ONLY=PlayolaInterviewEditorTests/TimelineRemovalTests`, then `ONLY=PlayolaInterviewEditorTests/EditorSelectionHistoryTests`
Expected: all PASS. The build surfaces any other exhaustive `switch` over `EditorSelection`; handle each one explicitly (none are known beyond the two above; `openSelectionTapped` has `default: return`).

- [ ] **Step 5: Commit**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Models QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor QuickInterviewEditor/QuickInterviewEditorTests
git commit -m "feature: add multi-piece selection state for Cmd-click"
```

---

### Task 2: Remove every selected piece in one undo step

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Models/TimelineRemoval.swift` (`TimelineRemovals`)
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift` (Timeline Removals section ~lines 2615–2685)
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Models/TimelineRemovalTests.swift`
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorSelectionHistoryTests.swift`

**Interfaces:**
- Consumes: `EditorSelection.selectedRanges`, `.ranges(MultiRangeSelection)`, `[Range<Int>].mergingTouching()` (Task 1)
- Produces:
  - `static TimelineRemovals.mergedSpans(removing: [Range<Int>], existing: [TimelineRemoval]) -> (spans: [Range<Int>], absorbedIDs: Set<TimelineRemoval.ID>)`
  - `EditorModel.removeSourceRanges(_ ranges: [Range<Int>]) async`
  - `EditorModel.removeSourceRange(_:)` unchanged signature (now a wrapper)
  - `canRemoveSelectedSection` true for `.ranges`

- [ ] **Step 1: Write the failing tests**

Append to `TimelineRemovalTests`:

```swift
  // MARK: - mergedSpans

  @Test func mergedSpansKeepsDisjointPiecesSeparate() {
    let plan = TimelineRemovals.mergedSpans(removing: [500..<600, 100..<200], existing: [])
    expectNoDifference(plan.spans, [100..<200, 500..<600])
    expectNoDifference(plan.absorbedIDs, [])
  }

  @Test func mergedSpansMergesAbuttingPieces() {
    let plan = TimelineRemovals.mergedSpans(removing: [100..<200, 200..<300], existing: [])
    expectNoDifference(plan.spans, [100..<300])
  }

  @Test func mergedSpansAbsorbsStrictlyOverlappingRemoval() {
    let plan = TimelineRemovals.mergedSpans(
      removing: [450..<550], existing: [removal(500, 600, id: 9)])
    expectNoDifference(plan.spans, [450..<600])
    expectNoDifference(plan.absorbedIDs, [removal(500, 600, id: 9).id])
  }

  @Test func mergedSpansLeavesAbuttingRemovalAlone() {
    let plan = TimelineRemovals.mergedSpans(
      removing: [400..<500], existing: [removal(500, 600, id: 9)])
    expectNoDifference(plan.spans, [400..<500])
    expectNoDifference(plan.absorbedIDs, [])
  }

  @Test func mergedSpansRemovalBridgingTwoPiecesYieldsOneSpan() {
    let plan = TimelineRemovals.mergedSpans(
      removing: [50..<150, 250..<350], existing: [removal(100, 300, id: 4)])
    expectNoDifference(plan.spans, [50..<350])
    expectNoDifference(plan.absorbedIDs, [removal(100, 300, id: 4).id])
  }

  @Test func mergedSpansDropsEmptyPieces() {
    let plan = TimelineRemovals.mergedSpans(removing: [100..<100, 300..<400], existing: [])
    expectNoDifference(plan.spans, [300..<400])
  }
```

Append to `EditorSelectionHistoryTests`:

```swift
  // MARK: - Multi-piece delete

  private func selectWordsTwoAndEight(_ model: EditorModel) {
    model.selection = .ranges(
      MultiRangeSelection(primary: 70648..<74176, anchor: 70648, additional: [164228..<166874]))
  }

  @Test func deletingMultiSelectionRemovesEachPieceWithDefaultCrossfade() async {
    let model = editor()
    selectWordsTwoAndEight(model)
    #expect(model.canRemoveSelectedSection)
    await model.deleteSelectionTapped()
    expectNoDifference(
      model.timelineRemovals.map(\.removedRange), [70648..<74176, 164228..<166874])
    expectNoDifference(
      model.timelineRemovals.map(\.crossfade),
      Array(
        repeating: Crossfade(lengthSamples: model.defaultCrossfadeSamples, curve: .equalPower),
        count: 2))
    expectNoDifference(model.selection, .none)
    expectNoDifference(model.removedWordIDs, [2, 8])
  }

  @Test func deletingMultiSelectionIsOneUndoStep() async {
    let model = editor()
    selectWordsTwoAndEight(model)
    let before = model.documentState
    var writes = 0
    model.onDocumentStateChanged = { _ in writes += 1 }
    await model.deleteSelectionTapped()
    expectNoDifference(model.history.undo.last?.label, "Remove Sections")
    expectNoDifference(writes, 1)
    await model.undoTapped()
    expectNoDifference(model.documentState, before)
    expectNoDifference(model.selection, .none)
    await model.redoTapped()
    expectNoDifference(
      model.timelineRemovals.map(\.removedRange), [70648..<74176, 164228..<166874])
  }

  @Test func deletingMultiSelectionKeepsUntouchedRemovalIdentity() async {
    let model = editor()
    let untouched = TimelineRemoval(
      id: Fixtures.uuid(7), removedRange: 300_000..<310_000,
      crossfade: Crossfade(lengthSamples: 999, curve: .linear))
    model.mutateDocument { $0.timelineRemovals.append(untouched) }
    selectWordsTwoAndEight(model)
    await model.deleteSelectionTapped()
    expectNoDifference(model.timelineRemovals[id: untouched.id], untouched)
    expectNoDifference(model.timelineRemovals.count, 3)
  }

  @Test func deletingMultiSelectionAbsorbsOverlappedRemoval() async {
    let model = editor()
    model.mutateDocument {
      $0.timelineRemovals.append(
        TimelineRemoval(
          id: Fixtures.uuid(7), removedRange: 165_000..<170_000,
          crossfade: Crossfade(lengthSamples: 999, curve: .linear)))
    }
    selectWordsTwoAndEight(model)
    await model.deleteSelectionTapped()
    expectNoDifference(
      model.timelineRemovals.map(\.removedRange), [70648..<74176, 164228..<170_000])
    #expect(model.timelineRemovals[id: Fixtures.uuid(7)] == nil)
  }

  @Test func deletingMultiSelectionIsBlockedWhileExporting() async {
    let model = editor()
    selectWordsTwoAndEight(model)
    model.exportPhase = .exporting(current: 0, total: 1)
    #expect(!model.canRemoveSelectedSection)
    await model.deleteSelectionTapped()
    #expect(model.timelineRemovals.isEmpty)
  }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test-fast ONLY=PlayolaInterviewEditorTests/TimelineRemovalTests`
Expected: build FAILS with "type 'TimelineRemovals' has no member 'mergedSpans'".

- [ ] **Step 3: Implement**

Add to `enum TimelineRemovals` in `Models/TimelineRemoval.swift`:

```swift
  /// The removal spans for selected SOURCE pieces: touching pieces merge, then each absorbs every
  /// existing removal it strictly overlaps (abutting removals stay separate). One existing removal
  /// can bridge two pieces into one span.
  static func mergedSpans(
    removing ranges: [Range<Int>], existing: [TimelineRemoval]
  ) -> (spans: [Range<Int>], absorbedIDs: Set<TimelineRemoval.ID>) {
    var absorbedIDs: Set<TimelineRemoval.ID> = []
    let extended = ranges.filter { !$0.isEmpty }.mergingTouching().map { piece in
      let absorbed = existing.filter { $0.removedRange.overlaps(piece) }
      absorbedIDs.formUnion(absorbed.map(\.id))
      return absorbed.reduce(piece) { hull, removal in
        min(hull.lowerBound, removal.removedRange.lowerBound)
          ..< max(hull.upperBound, removal.removedRange.upperBound)
      }
    }
    return (extended.mergingTouching(), absorbedIDs)
  }
```

In `EditorModel.swift`, delete `private var pendingRemovalSourceRange` (its only readers are the two members rewritten below) and replace `canRemoveSelectedSection`, `removeSelectedSectionTapped`, and `removeSourceRange` with:

```swift
  /// Drives ⌫ enablement and the Remove Section menu item for one range or several Cmd-clicked
  /// pieces. Blocked while an export is in flight — an in-progress export is rendering the un-cut
  /// canonical audio, so adding a removal mid-export would leave the finished AIFF stale.
  var canRemoveSelectedSection: Bool {
    !isExporting && selection.selectedRanges.contains { canRemove(sourceRange: $0) }
  }

  /// Turns every selected piece into a `TimelineRemoval` with the default 20 ms equal-power
  /// crossfade, then clears the selection and the fine-tune session.
  func removeSelectedSectionTapped() async {
    await removeSourceRanges(selection.selectedRanges)
  }

  /// One-range form of `removeSourceRanges`, used by the Edit-Slice modal's Remove.
  func removeSourceRange(_ range: Range<Int>) async {
    await removeSourceRanges([range])
  }

  /// Removes SOURCE pieces in ONE undo step. Touching pieces merge; each piece absorbs the existing
  /// removals it strictly overlaps (Item ①: an absorbed removal's crossfade was internal to audio
  /// that stays removed). Each resulting span becomes one removal with the default crossfade;
  /// untouched removals keep their IDs and crossfades. `normalize` runs only as a validation
  /// backstop. A no-op while exporting or when no piece is removable.
  func removeSourceRanges(_ ranges: [Range<Int>]) async {
    let source = 0..<editPlan.source.durationSamples
    let pieces = ranges.map { $0.clamped(to: source) }.filter { canRemove(sourceRange: $0) }
    guard !isExporting, !pieces.isEmpty else { return }
    let plan = TimelineRemovals.mergedSpans(removing: pieces, existing: Array(timelineRemovals))
    let removals = plan.spans.map {
      TimelineRemoval(
        id: UUID(), removedRange: $0,
        crossfade: Crossfade(lengthSamples: defaultCrossfadeSamples, curve: .equalPower))
    }
    mutateDocument(label: removals.count == 1 ? "Remove Section" : "Remove Sections") { doc in
      for id in plan.absorbedIDs { doc.timelineRemovals.remove(id: id) }
      doc.timelineRemovals.append(contentsOf: removals)
      doc.timelineRemovals = IdentifiedArray(
        uniqueElements: TimelineRemovals.normalize(Array(doc.timelineRemovals))
          ?? Array(doc.timelineRemovals))
    }
    transcript.clearSelectionTapped()
    fineTune.clear()
    await reconcilePlayback()
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run, one at a time: `make test-fast ONLY=PlayolaInterviewEditorTests/TimelineRemovalTests`, `ONLY=PlayolaInterviewEditorTests/EditorSelectionHistoryTests`, `ONLY=PlayolaInterviewEditorTests/EditorRemovalTests`, `ONLY=PlayolaInterviewEditorTests/EditorExportRemovalTests`, `ONLY=PlayolaInterviewEditorTests/EditorCrossfadeStretchTests`, `ONLY=PlayolaInterviewEditorTests/EditorEditSlicePresentationTests`, `ONLY=PlayolaInterviewEditorTests/EditSliceTests`, `ONLY=PlayolaInterviewEditorTests/DraftEditingTests` (every suite that calls `removeSourceRange` or `onRemoveSection`).
Expected: all PASS, including the existing single-range removal tests unchanged (touched-area regression rule).

- [ ] **Step 5: Commit**

```bash
git add QuickInterviewEditor/QuickInterviewEditor QuickInterviewEditor/QuickInterviewEditorTests
git commit -m "feature: remove every Cmd-clicked piece in one undo step"
```

---

### Task 3: Cmd-click routing

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptPointerGesture.swift` (`TranscriptClick`)
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptPageModel.swift` (`transcriptClicked(atUTF16Offset:...)` ~line 353)
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel+TranscriptSelection.swift` (`transcriptClicked(_:)` ~line 158)
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift` (add `addWordToSelection` right after `selectWord` ~line 765)
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorGroupSelectionTests.swift`

**Interfaces:**
- Consumes: `EditorSelection.adding(_:)`, `.ranges`, `selectionAnchorSample` reading the multi anchor (Task 1)
- Produces:
  - `TranscriptClick.additive: Bool` (defaults `false`)
  - `TranscriptPageModel.transcriptClicked(atUTF16Offset:extending:additive:clickCount:timestamp:doubleClickInterval:)` with `additive: Bool = false`
  - `EditorModel.addWordToSelection(_ id: Word.ID)`

- [ ] **Step 1: Write the failing tests**

In `EditorGroupSelectionTests`, replace the `click` helper with one that takes `additive`:

```swift
  private func click(
    _ model: EditorModel, word: Int = 3, count: Int = 1, extending: Bool = false,
    additive: Bool = false, time: Double = 1
  ) {
    let offset = model.transcript.document.wordRanges.first { $0.wordID == word }!.range.location
    model.transcript.transcriptClicked(
      atUTF16Offset: offset, extending: extending, additive: additive, clickCount: count,
      timestamp: time, doubleClickInterval: 0.5)
  }

  private func cmdClick(_ model: EditorModel, word: Int, count: Int = 1, time: Double = 1) {
    click(model, word: word, count: count, additive: true, time: time)
  }

  private let wordsTwoAndEight = EditorSelection.ranges(
    MultiRangeSelection(primary: 70648..<74176, anchor: 70648, additional: [164228..<166874]))
```

Append the tests:

```swift
  // MARK: - Cmd-click

  @Test func cmdClickFromNoSelectionStartsSingleWordRange() {
    let model = editor()
    cmdClick(model, word: 2)
    expectNoDifference(model.selection, .range(70648..<74176, anchor: 70648))
  }

  @Test func cmdClickAddsDisjointWord() {
    let model = editor()
    click(model, word: 2)
    cmdClick(model, word: 8, time: 3)
    expectNoDifference(model.selection, wordsTwoAndEight)
  }

  @Test func cmdClickKeepsDraggedRangeAsPrimary() {
    let model = editor()
    model.transcript.selectWords(anchorID: 2, focusID: 4)
    cmdClick(model, word: 13, time: 3)
    expectNoDifference(
      model.selection,
      .ranges(
        MultiRangeSelection(primary: 70648..<119202, anchor: 70648, additional: [232186..<235714])))
  }

  @Test func cmdClickSelectedWordIsNoOp() {
    let model = editor()
    click(model, word: 2)
    cmdClick(model, word: 8, time: 3)
    cmdClick(model, word: 8, time: 5)
    expectNoDifference(model.selection, wordsTwoAndEight)
  }

  @Test func cmdClickWordPartlyInsideRangeIsNoOp() {
    let model = editor()
    model.selectSourceRange(70648..<110_000, snapPlayhead: false, origin: .transcript)
    let before = model.selection
    cmdClick(model, word: 4, time: 3)
    expectNoDifference(model.selection, before)
  }

  @Test func cmdClickFullyRemovedWordIsNoOp() {
    let model = editor()
    model.mutateDocument {
      $0.timelineRemovals.append(
        TimelineRemoval(
          id: Fixtures.uuid(7), removedRange: 164_000..<167_000,
          crossfade: Crossfade(lengthSamples: 48, curve: .equalPower)))
    }
    click(model, word: 2)
    cmdClick(model, word: 8, time: 3)
    expectNoDifference(model.selection, .range(70648..<74176, anchor: 70648))
  }

  @Test func cmdClickPartlyRemovedWordIsAdded() {
    let model = editor()
    model.mutateDocument {
      $0.timelineRemovals.append(
        TimelineRemoval(
          id: Fixtures.uuid(7), removedRange: 160_000..<165_000,
          crossfade: Crossfade(lengthSamples: 48, curve: .equalPower)))
    }
    click(model, word: 2)
    cmdClick(model, word: 8, time: 3)
    expectNoDifference(model.selection, wordsTwoAndEight)
  }

  @Test func cmdClickFromObjectStartsFreshWordRange() {
    let model = editor()
    let candidate = suggestion(model)
    model.documentCutSuggestions = [candidate]
    model.selectTranscriptObject(.suggestion(candidate.id))
    cmdClick(model, word: 8)
    expectNoDifference(model.selection, .range(164228..<166874, anchor: 164228))
  }

  @Test func cmdClickFromSeamStartsFreshWordRange() {
    let model = editor()
    model.mutateDocument {
      $0.timelineRemovals.append(
        TimelineRemoval(
          id: Fixtures.uuid(7), removedRange: 300_000..<310_000,
          crossfade: Crossfade(lengthSamples: 48, curve: .equalPower)))
    }
    model.selectSeam(Fixtures.uuid(7))
    cmdClick(model, word: 2)
    expectNoDifference(model.selection, .range(70648..<74176, anchor: 70648))
  }

  @Test func cmdShiftClickActsAdditive() {
    let model = editor()
    click(model, word: 2)
    click(model, word: 8, extending: true, additive: true, time: 3)
    expectNoDifference(model.selection, wordsTwoAndEight)
  }

  @Test func cmdDoubleClickNeverOpens() {
    let model = editor()
    cmdClick(model, word: 2, time: 1)
    cmdClick(model, word: 2, count: 2, time: 1.2)
    #expect(model.editSlice == nil)
    expectNoDifference(model.selection, .range(70648..<74176, anchor: 70648))
  }

  @Test func cmdClickWithClickCountTwoOnAnotherWordStillAdds() {
    let model = editor()
    click(model, word: 2, time: 1)
    cmdClick(model, word: 8, count: 2, time: 1.2)
    expectNoDifference(model.selection, wordsTwoAndEight)
  }

  @Test func cmdClickOffAWordKeepsSelection() {
    let model = editor()
    model.selection = wordsTwoAndEight
    model.transcript.transcriptClicked(
      atUTF16Offset: nil, additive: true, clickCount: 1, timestamp: 3, doubleClickInterval: 0.5)
    expectNoDifference(model.selection, wordsTwoAndEight)
  }

  @Test func cmdClickAddDoesNotMovePlayhead() {
    let model = editor()
    click(model, word: 2)
    let playhead = model.playheadSourceSample
    cmdClick(model, word: 8, time: 3)
    expectNoDifference(model.playheadSourceSample, playhead)
  }

  @Test func plainClickCollapsesMultiSelection() {
    let model = editor()
    model.selection = wordsTwoAndEight
    click(model, word: 13, time: 3)
    expectNoDifference(model.selection, .range(232186..<235714, anchor: 232186))
  }

  @Test func shiftClickCollapsesAndExtendsFromPrimaryAnchor() {
    let model = editor()
    model.selection = wordsTwoAndEight
    click(model, word: 13, extending: true, time: 3)
    expectNoDifference(model.selection, .range(70648..<235714, anchor: 70648))
  }

  @Test func dragCollapsesMultiSelection() {
    let model = editor()
    model.selection = wordsTwoAndEight
    let offset = model.transcript.document.wordRanges.first { $0.wordID == 13 }!.range.location
    #expect(model.transcript.transcriptDragBegan(atUTF16Offset: offset))
    expectNoDifference(model.selection, .range(232186..<235714, anchor: 232186))
  }

  @Test func waveformSelectionReplacesMultiSelection() {
    let model = editor()
    model.selection = wordsTwoAndEight
    model.selectSourceRange(300_000..<310_000, snapPlayhead: false)
    expectNoDifference(model.selection.freeformRange, 300_000..<310_000)
  }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test-fast ONLY=PlayolaInterviewEditorTests/EditorGroupSelectionTests`
Expected: build FAILS with "extra argument 'additive' in call".

- [ ] **Step 3: Implement**

`TranscriptPointerGesture.swift`, add the last stored property of `TranscriptClick`:

```swift
struct TranscriptClick {
  let wordID: Word.ID?
  let extending: Bool
  let count: Int
  let timestamp: TimeInterval
  let doubleClickInterval: TimeInterval
  var utf16Offset: Int?
  /// Command held at mouse-down: add the word as another selected piece.
  var additive = false
}
```

`TranscriptPageModel.swift`, `transcriptClicked(atUTF16Offset:...)`: add the parameter after `extending` and forward it. The non-group fallback (no `onGroupClick`) ignores it.

```swift
  func transcriptClicked(
    atUTF16Offset offset: Int?, extending: Bool = false, additive: Bool = false,
    clickCount: Int = 1, timestamp: TimeInterval = 0, doubleClickInterval: TimeInterval = 0.5
  ) {
    let id = offset.flatMap { document.wordID(atUTF16Offset: $0) }
    if let onGroupClick {
      onGroupClick(
        TranscriptClick(
          wordID: id, extending: extending, count: clickCount,
          timestamp: timestamp, doubleClickInterval: doubleClickInterval, utf16Offset: offset,
          additive: additive))
      return
    }
    guard let id else {
      clearSelectionTapped()
      return
    }
    wordClicked(id, extending: extending)
  }
```

`EditorModel+TranscriptSelection.swift`, at the top of `transcriptClicked(_:)` (before the `click.count == 2` check), add the additive branch:

```swift
  func transcriptClicked(_ click: TranscriptClick) {
    if click.additive {
      // Cmd-click only ever adds a word: it never opens (any click count) and a miss never clears.
      transcript.clickCapture = nil
      transcript.overlapClick = nil
      defer { reconcileTranscriptOverlap() }
      guard let wordID = click.wordID,
        click.utf16Offset.map({ transcript.document.containsWord(atUTF16Offset: $0) }) ?? true
      else { return }
      addWordToSelection(wordID)
      return
    }
    if click.count == 2 {
    // ... rest unchanged
```

`EditorModel.swift`, right after `selectWord(_:extending:)`:

```swift
  /// Cmd-click: adds the word as another selected piece without moving the playhead. From a clip,
  /// suggestion, seam, or empty selection it starts a fresh single-word range instead. A fully
  /// removed word is ignored.
  func addWordToSelection(_ id: Word.ID) {
    guard !removedWordIDs.contains(id), let wordRange = sourceRange(ofWord: id) else { return }
    switch selection {
    case .range, .ranges:
      selection = selection.adding(
        wordRange.clamped(to: 0..<editPlan.source.durationSamples))
    case .none, .object, .seam:
      selectWord(id, extending: false)
    }
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run, one at a time: `make test-fast ONLY=PlayolaInterviewEditorTests/EditorGroupSelectionTests`, `ONLY=PlayolaInterviewEditorTests/TranscriptSelectionTests`, `ONLY=PlayolaInterviewEditorTests/EditorSelectionTests`, `ONLY=PlayolaInterviewEditorTests/EditorSeamSelectionTests`, `ONLY=PlayolaInterviewEditorTests/EditorAreaSelectTests`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add QuickInterviewEditor/QuickInterviewEditor QuickInterviewEditor/QuickInterviewEditorTests
git commit -m "feature: Cmd-click adds transcript words to the selection"
```

---

### Task 4: Gate single-range features and expose highlight data

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift`: `activeEditingRange` (~632), `fineTuneTarget` (~786), `selectedWordIDs` (~871), `shouldShowRemoveSectionControl` (~1211), `selectionSummary` (~1227); add `waveformMultiSelectionRanges` after `waveformHighlightSpan` (~880)
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorSelectionTests.swift`

**Interfaces:**
- Consumes: `.ranges`, `selectedRanges` (Task 1)
- Produces: `EditorModel.waveformMultiSelectionRanges: [Range<Int>]` (Task 5 binds it)

- [ ] **Step 1: Write the failing tests**

Append to `EditorSelectionTests`:

```swift
  // MARK: - Multi-selection gating

  private let wordsTwoAndEight = EditorSelection.ranges(
    MultiRangeSelection(primary: 70648..<74176, anchor: 70648, additional: [164228..<166874]))

  @Test func multiSelectionDisablesSingleRangeFeatures() {
    let model = editor()
    model.selection = wordsTwoAndEight
    #expect(!model.canAddSlice)
    #expect(!model.canOpenSelection)
    #expect(!model.canEditSelectionEdges)
    #expect(!model.canAudition)
    #expect(model.fineTuneTarget == nil)
  }

  @Test func multiSelectionOffersRemoval() {
    let model = editor()
    model.selection = wordsTwoAndEight
    #expect(model.canRemoveSelectedSection)
    #expect(model.shouldShowRemoveSectionControl)
  }

  @Test func multiSelectionIgnoresStaleFineTuneDraft() {
    let model = editor()
    model.selectSourceRange(70648..<74176, snapPlayhead: false, origin: .transcript)
    model.syncEditSession()
    model.selection = wordsTwoAndEight
    #expect(model.activeEditingRange == nil)
    model.syncEditSession()
    #expect(model.fineTune.target == nil)
  }

  @Test func multiSelectionNudgeIsNoOp() {
    let model = editor()
    model.selection = wordsTwoAndEight
    model.selectionNudged(.start, byMs: 10)
    expectNoDifference(model.selection, wordsTwoAndEight)
  }

  @Test func multiSelectionHighlightsEveryPieceInTranscript() {
    let model = editor()
    model.selection = wordsTwoAndEight
    expectNoDifference(model.selectedWordIDs, [2, 8])
  }

  @Test func multiSelectionSummaryCountsWordsAcrossPieces() {
    let model = editor()
    model.selection = wordsTwoAndEight
    expectNoDifference(model.selectionSummary, "2 words selected")
  }

  @Test func waveformMultiSelectionRangesListEveryPiece() {
    let model = editor()
    model.selection = wordsTwoAndEight
    expectNoDifference(model.waveformMultiSelectionRanges, [70648..<74176, 164228..<166874])
    model.selection = .range(70648..<74176, anchor: 70648)
    expectNoDifference(model.waveformMultiSelectionRanges, [])
  }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test-fast ONLY=PlayolaInterviewEditorTests/EditorSelectionTests`
Expected: build FAILS with "value of type 'EditorModel' has no member 'waveformMultiSelectionRanges'". After adding a stub, `multiSelectionIgnoresStaleFineTuneDraft`, `multiSelectionOffersRemoval` (control), `multiSelectionHighlightsEveryPieceInTranscript`, and `multiSelectionSummaryCountsWordsAcrossPieces` FAIL.

- [ ] **Step 3: Implement**

`activeEditingRange`:

```swift
  var activeEditingRange: Range<Int>? {
    // A multi-selection has no single editable range: never fall back to a stale fine-tune draft
    // or the active slice. Its pieces are drawn from `waveformMultiSelectionRanges`.
    if case .ranges = selection { return marqueePreview }
    return marqueePreview ?? fineTune.draftRange ?? activeOrSelectedRange
  }
```

`fineTuneTarget`, add a first line:

```swift
  var fineTuneTarget: FineTuneModel.Target? {
    if case .ranges = selection { return nil }
    if selection.freeformRange != nil { return .pendingSelection }
    if let activeSliceID { return .slice(activeSliceID) }
    return nil
  }
```

`selectedWordIDs`:

```swift
  var selectedWordIDs: Set<Word.ID> {
    Set(selection.selectedRanges.flatMap { wordIDs(anyOverlap: $0, words: editPlan.words) })
  }
```

`shouldShowRemoveSectionControl`:

```swift
  var shouldShowRemoveSectionControl: Bool { !selection.selectedRanges.isEmpty }
```

`selectionSummary`:

```swift
  var selectionSummary: String {
    if selectedSeamID != nil { return crossfadeSelectedSummary }
    let ranges = audioSelection.map { [$0] } ?? selection.selectedRanges
    guard !ranges.isEmpty else { return "No selection" }
    let count = Set(ranges.flatMap { wordIDs(anyOverlap: $0, words: editPlan.words) }).count
    return "\(count) word\(count == 1 ? "" : "s") selected"
  }
```

After `waveformHighlightSpan`:

```swift
  /// Every piece of a Cmd-click multi-selection, drawn as plain (non-interactive) waveform fills.
  /// Empty for a single range (it keeps the interactive `activeEditingRange` highlight) and while a
  /// marquee is live (the marquee is replacing the selection).
  var waveformMultiSelectionRanges: [Range<Int>] {
    guard marqueePreview == nil, case .ranges(let multi) = selection else { return [] }
    return multi.allRanges
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run, one at a time: `make test-fast ONLY=PlayolaInterviewEditorTests/EditorSelectionTests`, `ONLY=PlayolaInterviewEditorTests/EditorFineTuneTests`, `ONLY=PlayolaInterviewEditorTests/EditorAuditionTests`, `ONLY=PlayolaInterviewEditorTests/WaveformTests`, `ONLY=PlayolaInterviewEditorTests/EditorAreaSelectTests`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add QuickInterviewEditor/QuickInterviewEditor QuickInterviewEditor/QuickInterviewEditorTests
git commit -m "feature: limit a multi-word selection to removal and highlight every piece"
```

---

### Task 5: AppKit Command plumbing, waveform multi-highlight, docs

No unit tests: these are view-only renderers and raw-event forwarders (the decisions they feed are covered by Tasks 3–4). Verification is the full suite plus the manual checklist.

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptTextView.swift` (`HitTestingTextView` ~lines 604–690)
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptResizeHandleOverlayView.swift` (`mouseUp` ~line 78)
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/WaveformLaneView.swift`
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/WaveformView.swift`
- Modify: `docs/superpowers/specs/2026-08-04-transcript-textkit-zoom-scroll-design.md` (line 57)
- Modify: `docs/superpowers/specs/2026-09-08-transcript-group-selection-design.md` (gesture table, lines 57–73)

**Interfaces:**
- Consumes: `TranscriptPageModel.transcriptClicked(atUTF16Offset:extending:additive:...)` (Task 3), `EditorModel.waveformMultiSelectionRanges` (Task 4)
- Produces: `WaveformLaneView.additionalHighlightRanges: [Range<Int>] = []`

- [ ] **Step 1: `HitTestingTextView`: Command at mouse-down adds, and blocks drag**

Add a stored flag next to `beganWordDrag`:

```swift
  private var additiveClick = false
```

In `mouseDown`, after `beganWordDrag = false`:

```swift
    additiveClick = event.modifierFlags.contains(.command)
```

In `mouseDragged`, after `_ = pointer.moved(to: event.locationInWindow)`:

```swift
    guard !additiveClick else { return }
```

In `mouseUp`, reset the flag in the `defer` (`additiveClick = false`) and forward it:

```swift
    case .click(let count):
      coordinator.model.transcriptClicked(
        atUTF16Offset: anchorOffset, extending: event.modifierFlags.contains(.shift),
        additive: additiveClick, clickCount: count, timestamp: event.timestamp,
        doubleClickInterval: NSEvent.doubleClickInterval)
```

In `cancelPointerTracking()`, add `additiveClick = false`.

- [ ] **Step 2: `TranscriptResizeHandleOverlayView.mouseUp` forwards Command**

```swift
      coordinator.model.transcriptClicked(
        atUTF16Offset: offset, extending: event.modifierFlags.contains(.shift),
        additive: event.modifierFlags.contains(.command),
        clickCount: event.clickCount, timestamp: event.timestamp,
        doubleClickInterval: NSEvent.doubleClickInterval)
```

- [ ] **Step 3: `WaveformLaneView` draws extra highlight pieces**

(Spec §3.4 named this `highlightRanges` + `interactiveHighlightRange`. The plan keeps the existing `highlightRange` as the interactive one and adds a defaulted extra list, so `EditSliceView` needs no change. Same behavior, smaller diff.)

Add right after `var seams: [SeamOverlay] = []`:

```swift
  /// Extra non-interactive highlight fills (a Cmd-click multi-selection's pieces). No edge handles
  /// or audition buttons attach to these. Defaults to `[]` so the slice-edit sheet compiles unchanged.
  var additionalHighlightRanges: [Range<Int>] = []
```

In `body`, after `let highlight = ...`:

```swift
    let highlightSpans = ([highlightRange].compactMap { $0 } + additionalHighlightRanges)
      .compactMap { waveform.laneSpan(forSource: $0) }
```

Change `content(highlight: highlight)` to `content(highlightSpans: highlightSpans)`, and the function:

```swift
  @ViewBuilder private func content(highlightSpans: [WaveformSpan]) -> some View {
    if waveform.showsLoading {
      centeredMessage(waveform.loadingMessage)
    } else if waveform.showsEmpty {
      centeredMessage(waveform.emptyMessage)
    } else {
      ZStack(alignment: .leading) {
        WaveformHighlight(spans: highlightSpans)
        WaveformCanvas(waveform: waveform)
        SeamBowtieOverlay(seams: seams)
        WaveformPlayhead(waveform: waveform, playhead: playhead)
      }
    }
  }
```

Replace `WaveformHighlight`:

```swift
private struct WaveformHighlight: View {
  let spans: [WaveformSpan]

  private let highlightColor = Color.white.opacity(0.14)

  var body: some View {
    if !spans.isEmpty {
      Canvas { context, size in
        for span in spans {
          context.fill(
            Path(CGRect(x: span.positionX, y: 0, width: span.width, height: size.height)),
            with: .color(highlightColor))
        }
      }
    }
  }
}
```

The audition overlay keeps using `highlight` (the single interactive range), and the edge-handle layer keeps using `highlightRange`. Both are nil for a multi-selection, because `activeEditingRange` is nil there.

- [ ] **Step 4: `WaveformView` binds the pieces**

Immediately after `seams: model.seamOverlays,`:

```swift
        additionalHighlightRanges: model.waveformMultiSelectionRanges,
```

- [ ] **Step 5: Update the superseded docs**

`2026-08-04-transcript-textkit-zoom-scroll-design.md` line 57, replace with:

```markdown
- ~~No non-contiguous multi-word selection is introduced.~~ Superseded 2026-10-15: Cmd-click adds
  non-adjacent words as separate pieces for removal (see
  `2026-10-15-transcript-cmd-click-multi-delete-design.md`).
```

`2026-09-08-transcript-group-selection-design.md` gesture table: insert after the "Shift-click a word" row:

```markdown
| Cmd-click a word | Add it as another selected piece (add-only; ignored if already selected or fully removed). From a clip, suggestion, or seam, start a fresh single-word selection. Never opens; Cmd-drag does nothing |
```

and after the "Delete with a freeform highlight" row:

```markdown
| Delete with several Cmd-clicked pieces | Remove every piece in one undo step, one default crossfade per resulting piece |
```

- [ ] **Step 6: Full verification**

From `QuickInterviewEditor/`:
Run: `make test-fast`. Expected: whole suite PASS.
Run: `make format`, then `make format-check` and `make lint`. Expected: no findings.

- [ ] **Step 7: Manual QA (build and run the app on a real project)**

1. Cmd-click three separate "uh"s. All three show highlighted in the transcript and as three fills on the waveform. No edge handles or audition buttons appear.
2. Press ⌫. All three are struck through, with one crossfade bowtie each. The Edit menu says "Undo Remove Sections".
3. ⌘Z. The audio comes back and nothing is selected. ⌘⇧Z removes all three again.
4. Cmd-click quickly on two neighboring words. Both get added and nothing opens.
5. Cmd-drag across words. No drag selection starts.
6. Shift-click after a multi-selection. It collapses to one range running from the first piece's anchor.
7. Cmd-click a struck-through word. Nothing happens.
8. Cmd-click on a word under a selection resize handle. It adds that word (the overlay forwards Command).

- [ ] **Step 8: Commit**

```bash
git add QuickInterviewEditor/QuickInterviewEditor docs/superpowers/specs
git commit -m "feature: Cmd-click in the transcript and highlight every piece on the waveform"
```

---

## After all tasks

Per the user's pipeline (not part of the task list):
1. Codex **review**, then **challenge** and the **Excess Audit** concurrently on the branch diff. Then one combined fix wave.
2. Create the PR via `codex exec`, with a jargon-free `feature:` title. Then run fix-review.
3. Delete this plan file when the feature ships (CLAUDE.md "Remove file when all stages are done").
