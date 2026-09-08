# Transcript Resize Handles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user resize the current selection, a pending cut suggestion, or a clip by dragging its start/end edge across words in the transcript, with a `<>` cursor on hover and whole-word snapping.

**Architecture:** A transparent AppKit overlay inside the transcript's document view owns the resize cursor and edge hit-testing; the `Coordinator` (which owns the TextKit stack) computes edge-rect geometry; `EditorModel` owns the resize state machine and all mutation; `TranscriptPageModel` only forwards gestures. Selection resizes live (`audioSelection` is plain `@Observable`); clips and suggestions draft during the drag and commit once through `mutateDocument` (one undo entry). The document is never touched mid-drag — the moving container is a draft-driven preview.

**Tech Stack:** Swift, SwiftUI + AppKit (`NSViewRepresentable`, TextKit 1), Point-Free `swift-dependencies` / `swift-sharing` / `swift-identified-collections`, Swift Testing + `swift-custom-dump`.

**Spec:** `docs/superpowers/specs/2026-09-07-transcript-resize-handles-design.md`

## Global Constraints

- **Zero logic in views.** All decisions live on the model; the AppKit overlay/coordinator forward events and render, they do not decide behavior.
- **Never mutate document state (`slices`, `cutSuggestions`) per `mouseDragged`.** Clip/suggestion drags update only a draft; commit once on mouse-up via `mutateDocument`/`mutateSlices` (single undo entry). Selection (`audioSelection`, not undo-tracked) may update live, consistent with existing transcript drag-to-select.
- **Value comparisons in tests use `expectNoDifference` / `expectDifference`** from `swift-custom-dump`, not raw `#expect(a == b)`.
- **Swift Testing**, `@MainActor struct …Tests`, `@Test`, camelCase test names, no `Task.sleep`.
- **Invoke the relevant `pfw-*` skills before writing code** (`pfw-observable-models`, `pfw-testing`, `pfw-custom-dump`, `pfw-identified-collections`, `pfw-case-paths` for the identity enum, `pfw-modern-swiftui`). List them in your checklist.
- **Interface parity with Logic Pro:** hover resize cursor is `NSCursor.resizeLeftRight`.
- **Test target:** `QuickInterviewEditorTests`. Fast loop: `make test-fast` in `QuickInterviewEditor/` (focus with `ONLY=QuickInterviewEditorTests/<Suite>`). Do NOT run `xcodegen generate` between runs. Run `make format` + `make lint` before the final commit.
- **Word IDs are not guaranteed unique** — resolve edges by transcript position (index into `document.wordRanges` / `editPlan.words` order), then carry IDs.

---

## File Structure

**New files:**
- `QuickInterviewEditor/QuickInterviewEditor/Models/TranscriptResize.swift` — the value types (`TranscriptResizeEdge`, `TranscriptResizeItemIdentity`, `TranscriptResizeItem`, `TranscriptResizeHandleZone`, `TranscriptResizeDraft`) and the pure word-math (`TranscriptResizeMath`).
- `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptResizeHandleOverlayView.swift` — the transparent `NSView` overlay (cursor + hit-test + drag lifecycle).
- Test files mirroring the source tree (see each task).

**Modified files:**
- `Views/Pages/Editor/EditorModel.swift` — `transcriptResizeItems`, the resize state machine, `updatedSuggestion`, `sourceRange(coveringWordIDs:)`, draft-aware `clipBands`.
- `Views/Pages/TranscriptPage/TranscriptPageModel.swift` — `resizeItems` + the four forwarding closures + `resizeDraft` mirror for preview containers.
- `Views/Pages/TranscriptPage/TranscriptTextView.swift` — attach the overlay in `makeNSView`, pass `resizeItems` through `apply`, add zone geometry + lenient word hit-test on the `Coordinator`.
- `Views/Pages/Editor/EditorView.swift` — push `transcriptResizeItems` into the transcript and wire the four closures.

---

## Task 1: Resize value types + pure word-math

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Models/TranscriptResize.swift`
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Models/TranscriptResizeMathTests.swift`

**Interfaces:**
- Consumes: `Word.ID`, `Slice.ID` (`UUID`), `CutSuggestion.ID` (`UUID`).
- Produces:
  - `enum TranscriptResizeEdge: Equatable, Sendable { case start, end }`
  - `enum TranscriptResizeItemIdentity: Equatable, Hashable, Sendable { case selection; case clip(Slice.ID); case suggestion(CutSuggestion.ID) }` with `var priority: Int` (selection 3, clip 2, suggestion 1).
  - `struct TranscriptResizeItem: Equatable, Sendable { var identity; var wordIDs: [Word.ID]  // transcript order }`
  - `struct TranscriptResizeHandleZone: Equatable { var identity; var edge; var rect: CGRect; var priority: Int }`
  - `struct TranscriptResizeDraft: Equatable, Sendable { var identity; var edge; var originalWordIDs: [Word.ID]; var draftedWordIDs: [Word.ID] }`
  - `enum TranscriptResizeMath { static func resized(itemWordIDs: [Word.ID], edge: TranscriptResizeEdge, toTargetWord target: Word.ID, transcriptOrder: [Word.ID]) -> [Word.ID]? }`

The math resolves the item's occupied span as `[firstIndex, lastIndex]` in `transcriptOrder` (min/max of the item's word positions). For `.start`, the new start index is `target`'s position clamped to `0...lastIndex`; result = `transcriptOrder[newStart...lastIndex]`. For `.end`, the new end index is clamped to `firstIndex...(transcriptOrder.count - 1)`; result = `transcriptOrder[firstIndex...newEnd]`. Returns `nil` if the item is empty, the target isn't in `transcriptOrder`, or any item word isn't in `transcriptOrder`. Min-one-word and no-cross fall out of the clamps (equality allowed, crossing not).

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import CustomDump
@testable import QuickInterviewEditor

@MainActor
struct TranscriptResizeMathTests {
  // Words a,b,c,d,e in transcript order.
  let order: [Word.ID] = ["a", "b", "c", "d", "e"]

  @Test func startEdgeGrowsLeftToTargetWord() {
    let result = TranscriptResizeMath.resized(
      itemWordIDs: ["c", "d"], edge: .start, toTargetWord: "a", transcriptOrder: order)
    expectNoDifference(result, ["a", "b", "c", "d"])
  }

  @Test func startEdgeShrinksRightButCannotCrossEnd() {
    // Dragging the start past the end pins it to the end word (min one word).
    let result = TranscriptResizeMath.resized(
      itemWordIDs: ["b", "c", "d"], edge: .start, toTargetWord: "e", transcriptOrder: order)
    expectNoDifference(result, ["d"])
  }

  @Test func endEdgeGrowsRightToTargetWord() {
    let result = TranscriptResizeMath.resized(
      itemWordIDs: ["b", "c"], edge: .end, toTargetWord: "e", transcriptOrder: order)
    expectNoDifference(result, ["b", "c", "d", "e"])
  }

  @Test func endEdgeShrinksLeftButCannotCrossStart() {
    let result = TranscriptResizeMath.resized(
      itemWordIDs: ["b", "c", "d"], edge: .end, toTargetWord: "a", transcriptOrder: order)
    expectNoDifference(result, ["b"])
  }

  @Test func targetNotInOrderReturnsNil() {
    let result = TranscriptResizeMath.resized(
      itemWordIDs: ["b", "c"], edge: .end, toTargetWord: "z", transcriptOrder: order)
    expectNoDifference(result, nil)
  }

  @Test func emptyItemReturnsNil() {
    let result = TranscriptResizeMath.resized(
      itemWordIDs: [], edge: .start, toTargetWord: "a", transcriptOrder: order)
    expectNoDifference(result, nil)
  }

  @Test func identityPriorityOrder() {
    expectNoDifference(TranscriptResizeItemIdentity.selection.priority, 3)
    expectNoDifference(TranscriptResizeItemIdentity.clip(UUID()).priority, 2)
    expectNoDifference(TranscriptResizeItemIdentity.suggestion(UUID()).priority, 1)
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test-fast ONLY=QuickInterviewEditorTests/TranscriptResizeMathTests`
Expected: FAIL — types/`TranscriptResizeMath` not defined.

- [ ] **Step 3: Implement `TranscriptResize.swift`**

```swift
import Foundation

enum TranscriptResizeEdge: Equatable, Sendable { case start, end }

enum TranscriptResizeItemIdentity: Equatable, Hashable, Sendable {
  case selection
  case clip(Slice.ID)
  case suggestion(CutSuggestion.ID)

  /// D2 priority: Selection > Clip > Suggestion.
  var priority: Int {
    switch self {
    case .selection: 3
    case .clip: 2
    case .suggestion: 1
    }
  }
}

/// The semantic (non-occluded) span of a resizable item, in transcript order.
struct TranscriptResizeItem: Equatable, Sendable {
  var identity: TranscriptResizeItemIdentity
  var wordIDs: [Word.ID]
}

/// A grab zone published by the coordinator to the overlay.
struct TranscriptResizeHandleZone: Equatable {
  var identity: TranscriptResizeItemIdentity
  var edge: TranscriptResizeEdge
  var rect: CGRect
  var priority: Int
}

/// In-flight resize. Non-nil only for the duration of a drag; the document is
/// untouched while it lives.
struct TranscriptResizeDraft: Equatable, Sendable {
  var identity: TranscriptResizeItemIdentity
  var edge: TranscriptResizeEdge
  var originalWordIDs: [Word.ID]
  var draftedWordIDs: [Word.ID]
}

enum TranscriptResizeMath {
  /// New contiguous word run after dragging `edge` to `target`. Whole-word snap,
  /// min one word, cannot cross the opposite edge. `nil` when inputs are invalid.
  static func resized(
    itemWordIDs: [Word.ID],
    edge: TranscriptResizeEdge,
    toTargetWord target: Word.ID,
    transcriptOrder: [Word.ID]
  ) -> [Word.ID]? {
    guard !itemWordIDs.isEmpty else { return nil }
    var position: [Word.ID: Int] = [:]
    for (i, id) in transcriptOrder.enumerated() where position[id] == nil { position[id] = i }
    guard let targetIndex = position[target] else { return nil }
    let itemIndices = itemWordIDs.compactMap { position[$0] }
    guard itemIndices.count == itemWordIDs.count,
      let first = itemIndices.min(), let last = itemIndices.max()
    else { return nil }

    let lo: Int
    let hi: Int
    switch edge {
    case .start:
      lo = min(max(targetIndex, 0), last)
      hi = last
    case .end:
      lo = first
      hi = max(min(targetIndex, transcriptOrder.count - 1), first)
    }
    return Array(transcriptOrder[lo...hi])
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test-fast ONLY=QuickInterviewEditorTests/TranscriptResizeMathTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Models/TranscriptResize.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/Models/TranscriptResizeMathTests.swift
git commit -m "feat: transcript resize value types + word-math"
```

---

## Task 2: `transcriptResizeItems` on the model + `sourceRange(coveringWordIDs:)`

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift`
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/TranscriptResizeItemsTests.swift`

**Interfaces:**
- Consumes: `editPlan.words` (each `Word` has `id`, `startSample: Int?`, `endSample: Int?`), `slices`, `documentCutSuggestions.pending`, `audioSelection`, existing `selectedWordIDs`.
- Produces on `EditorModel`:
  - `var transcriptResizeItems: [TranscriptResizeItem]` — computed, draft-aware (Task 5/6 make it reflect an active draft; this task returns the committed items). Selection item (if any) first, then one item per clip, then one per pending suggestion. **Suggestion items carry their FULL `wordIDs`, not the occluded `clipBands` version.** All `wordIDs` ordered by `editPlan.words` order.
  - `private func sourceRange(coveringWordIDs ids: [Word.ID]) -> Range<Int>?` — min `startSample` / max `endSample` over the given words; `nil` if empty or any bound missing/invalid.
  - `private func transcriptOrder() -> [Word.ID]` — `editPlan.words.map(\.id)` (helper reused by the state machine).

Note the existing helpers to mirror (both `private`): `sourceRange(ofWord:)` (`EditorModel.swift:586`) and `sourceRange(coveringWords:_:)` (`:593`). Add the array variant next to them.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import CustomDump
import IdentifiedCollections
@testable import QuickInterviewEditor

@MainActor
struct TranscriptResizeItemsTests {
  @Test func itemsIncludeSelectionClipsAndFullSuggestionRanges() {
    let model = EditorModel.testModel(/* fixture with words w0..w5 */)
    // Arrange: a clip over w0,w1; a pending suggestion over w1,w2,w3 (w1 also in clip).
    // Select w4,w5 via the source range.
    // ...set up via model helpers/fixtures...

    let items = model.transcriptResizeItems
    // Suggestion keeps w1 even though the clip claims it (semantic, not drawn).
    let suggestion = items.first { if case .suggestion = $0.identity { return true }; return false }
    expectNoDifference(suggestion?.wordIDs, ["w1", "w2", "w3"])
    // Selection present with its covered words.
    let selection = items.first { $0.identity == .selection }
    expectNoDifference(selection?.wordIDs, ["w4", "w5"])
  }

  @Test func noSelectionMeansNoSelectionItem() {
    let model = EditorModel.testModel(/* fixture, no selection */)
    expectNoDifference(model.transcriptResizeItems.contains { $0.identity == .selection }, false)
  }
}
```

> Use the existing editor-model fixture/factory the sibling tests use (see `TranscriptClipContainersTests.swift` and `TranscriptSelectionTests.swift` for how they build an `EditorModel` with an `editPlan` and add slices/suggestions). Match that setup; do not invent a new fixture harness.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test-fast ONLY=QuickInterviewEditorTests/TranscriptResizeItemsTests`
Expected: FAIL — `transcriptResizeItems` not defined.

- [ ] **Step 3: Implement on `EditorModel`**

```swift
// MARK: - Transcript resize items

/// Semantic (non-occluded) resizable spans for the transcript overlay.
/// Draft-aware substitution is added in the clip/suggestion resize tasks.
var transcriptResizeItems: [TranscriptResizeItem] {
  let order = transcriptOrder()
  func ordered(_ ids: some Sequence<Word.ID>) -> [Word.ID] {
    let set = Set(ids)
    return order.filter(set.contains)
  }
  var items: [TranscriptResizeItem] = []
  if !selectedWordIDs.isEmpty {
    items.append(.init(identity: .selection, wordIDs: ordered(selectedWordIDs)))
  }
  for slice in slices {
    items.append(.init(identity: .clip(slice.id), wordIDs: ordered(slice.wordIDs)))
  }
  for suggestion in documentCutSuggestions.pending {
    items.append(.init(identity: .suggestion(suggestion.id), wordIDs: ordered(suggestion.wordIDs)))
  }
  return applyingResizeDraft(to: items)   // added in Task 5; identity function until then
}

private func transcriptOrder() -> [Word.ID] { editPlan.words.map(\.id) }

private func sourceRange(coveringWordIDs ids: [Word.ID]) -> Range<Int>? {
  let set = Set(ids)
  let words = editPlan.words.filter { set.contains($0.id) }
  guard !words.isEmpty else { return nil }
  let starts = words.compactMap(\.startSample)
  let ends = words.compactMap(\.endSample)
  guard let lo = starts.min(), let hi = ends.max(), lo < hi else { return nil }
  return lo..<hi
}
```

Add a temporary identity pass-through so this compiles before Task 5:

```swift
// Replaced by the draft-aware version in Task 5.
private func applyingResizeDraft(to items: [TranscriptResizeItem]) -> [TranscriptResizeItem] {
  items
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test-fast ONLY=QuickInterviewEditorTests/TranscriptResizeItemsTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/TranscriptResizeItemsTests.swift
git commit -m "feat: derive transcript resize items on EditorModel"
```

---

## Task 3: Coordinator edge geometry + lenient word hit-test (cursor only)

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptPageModel.swift`
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptTextView.swift`
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorView.swift`

**Interfaces:**
- Consumes: `TranscriptResizeItem`, `TranscriptResizeHandleZone`, `document.wordRanges`, `layoutManager.boundingRect(forGlyphRange:in:)`, `Coordinator.range(for:)`.
- Produces:
  - `TranscriptPageModel.resizeItems: [TranscriptResizeItem]` (pushed in like `clipBands`).
  - `Coordinator.resizeZones() -> [TranscriptResizeHandleZone]` — start/end rects for every item's true first/last word, in document-view coordinates.
  - `Coordinator.resizeHandle(at point: NSPoint) -> (TranscriptResizeItemIdentity, TranscriptResizeEdge)?` — D2 resolution: zones containing the point, sorted by `priority` desc, tie-broken by nearest edge-x, then deterministic identity order.
  - `Coordinator.wordIDForResize(at point: NSPoint) -> Word.ID?` — lenient hit-test that resolves the nearest word on the pointer's line even when x is outside the used line rect.

This task adds geometry + cursor. The overlay view (Task 4) consumes it. To get the cursor visible now, add a minimal `NSTrackingArea`-based cursor to the overlay in Task 4; here we only build/verify geometry (unit-test the pure parts of resolution where practical; geometry against TextKit is manual-verified).

**Grab tolerance constant:** `enum TranscriptResizeMetrics { static let grabTolerance: CGFloat = 6; static let dragThreshold: CGFloat = 6 }` — put it in `TranscriptResize.swift`.

- [ ] **Step 1: Add `resizeItems` to `TranscriptPageModel`**

```swift
// MARK: - Properties  (near clipBands / highlightedWordIDs, ~L135)
var resizeItems: [TranscriptResizeItem] = []
```

- [ ] **Step 2: Pass `resizeItems` through the representable**

In `TranscriptTextView` add a stored `let resizeItems: [TranscriptResizeItem]` (constructed in `TranscriptPageView` from `model.resizeItems`), thread it into `apply(...)` (extend the signature), and have the `Coordinator` cache the latest value:

```swift
// Coordinator
private var resizeItems: [TranscriptResizeItem] = []
// inside apply(...): self.resizeItems = resizeItems  (add param)
```

- [ ] **Step 3: Implement zone geometry on the Coordinator**

```swift
func resizeZones() -> [TranscriptResizeHandleZone] {
  guard let layoutManager = textView?.layoutManager,
    let textContainer = textView?.textContainer
  else { return [] }
  let inset = textView?.textContainerInset ?? .zero
  var zones: [TranscriptResizeHandleZone] = []
  for item in resizeItems {
    guard let first = item.wordIDs.first, let last = item.wordIDs.last,
      let firstRange = range(for: first), let lastRange = range(for: last)
    else { continue }
    func zone(_ nsRange: NSRange, _ edge: TranscriptResizeEdge) -> TranscriptResizeHandleZone? {
      let glyphRange = layoutManager.glyphRange(forCharacterRange: nsRange, actualCharacterRange: nil)
      var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
      rect.origin.x += inset.width
      rect.origin.y += inset.height
      let edgeX = edge == .start ? rect.minX : rect.maxX
      let grab = CGRect(
        x: edgeX - TranscriptResizeMetrics.grabTolerance, y: rect.minY,
        width: TranscriptResizeMetrics.grabTolerance * 2, height: rect.height)
      return TranscriptResizeHandleZone(
        identity: item.identity, edge: edge, rect: grab, priority: item.identity.priority)
    }
    if let z = zone(firstRange, .start) { zones.append(z) }
    if let z = zone(lastRange, .end) { zones.append(z) }
  }
  return zones
}

func resizeHandle(at point: NSPoint) -> (TranscriptResizeItemIdentity, TranscriptResizeEdge)? {
  let hits = resizeZones().filter { $0.rect.contains(point) }
  guard !hits.isEmpty else { return nil }
  let best = hits.sorted { a, b in
    if a.priority != b.priority { return a.priority > b.priority }
    func dx(_ z: TranscriptResizeHandleZone) -> CGFloat { abs(point.x - z.rect.midX) }
    if dx(a) != dx(b) { return dx(a) < dx(b) }
    return "\(a.identity)\(a.edge)" < "\(b.identity)\(b.edge)"
  }.first!
  return (best.identity, best.edge)
}
```

- [ ] **Step 4: Implement the lenient word hit-test**

Model it on the existing `utf16Offset(at:)` (`TranscriptTextView.swift:413`) but drop the "point inside used line rect" rejection, clamping x into the line fragment before resolving the character index; then map offset → `Word.ID` via `model.document.wordID(atUTF16Offset:)`:

```swift
func wordIDForResize(at point: NSPoint) -> Word.ID? {
  guard let layoutManager = textView?.layoutManager,
    let textContainer = textView?.textContainer
  else { return nil }
  let inset = textView?.textContainerInset ?? .zero
  let local = NSPoint(x: point.x - inset.width, y: point.y - inset.height)
  let glyphIndex = layoutManager.glyphIndex(for: local, in: textContainer)
  var lineRange = NSRange()
  let lineRect = layoutManager.lineFragmentUsedRect(
    forGlyphAt: glyphIndex, effectiveRange: &lineRange)
  let clampedX = min(max(local.x, lineRect.minX), lineRect.maxX - 0.5)
  let clamped = NSPoint(x: clampedX, y: lineRect.midY)
  let idx = layoutManager.glyphIndex(for: clamped, in: textContainer)
  let charIndex = layoutManager.characterIndexForGlyph(at: idx)
  return model.document.wordID(atUTF16Offset: charIndex)
}
```

- [ ] **Step 5: Push `transcriptResizeItems` into the transcript**

In `EditorView.swift`, next to the `clipBands` push (`:67`):

```swift
.onChange(of: model.transcriptResizeItems, initial: true) { _, items in
  model.transcript.resizeItems = items
}
```

- [ ] **Step 6: Build to verify it compiles**

Run: `make test-fast ONLY=QuickInterviewEditorTests/TranscriptResizeMathTests`
(Reuses the warm build; confirms the new coordinator/model code compiles. No behavior test yet — the overlay lands in Task 4.)
Expected: PASS (compiles; existing test still green).

- [ ] **Step 7: Commit**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Models/TranscriptResize.swift \
        QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptTextView.swift \
        QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptPageModel.swift \
        QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorView.swift
git commit -m "feat: transcript resize edge geometry + lenient word hit-test"
```

---

## Task 4: Overlay view — cursor + hit-test + drag lifecycle (no-op callbacks)

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptResizeHandleOverlayView.swift`
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptTextView.swift` (attach overlay in `makeNSView`)
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptPageModel.swift` (the four forwarding closures)

**Interfaces:**
- Consumes: `Coordinator.resizeHandle(at:)`, `Coordinator.wordIDForResize(at:)`, `TranscriptResizeMetrics`.
- Produces on `TranscriptPageModel`:
  - `@ObservationIgnored var onTranscriptResizeBegan: ((TranscriptResizeItemIdentity, TranscriptResizeEdge) -> Void)?`
  - `@ObservationIgnored var onTranscriptResizeDragged: ((Word.ID) -> Void)?`
  - `@ObservationIgnored var onTranscriptResizeEnded: (() -> Void)?`
  - `@ObservationIgnored var onTranscriptResizeCancelled: (() -> Void)?`
  - `func transcriptResizeBegan(_ id: TranscriptResizeItemIdentity, _ edge: TranscriptResizeEdge)` / `transcriptResizeDragged(toWord: Word.ID)` / `transcriptResizeEnded()` / `transcriptResizeCancelled()` — thin methods the overlay calls that fan out to the closures (mirrors `transcriptDragBegan` → `onSelectionIntent`).

- [ ] **Step 1: Add the forwarding closures + methods to `TranscriptPageModel`**

```swift
// MARK: - User Actions  (near transcriptDragBegan, ~L386)
@ObservationIgnored var onTranscriptResizeBegan: ((TranscriptResizeItemIdentity, TranscriptResizeEdge) -> Void)?
@ObservationIgnored var onTranscriptResizeDragged: ((Word.ID) -> Void)?
@ObservationIgnored var onTranscriptResizeEnded: (() -> Void)?
@ObservationIgnored var onTranscriptResizeCancelled: (() -> Void)?

func transcriptResizeBegan(_ id: TranscriptResizeItemIdentity, _ edge: TranscriptResizeEdge) {
  onTranscriptResizeBegan?(id, edge)
}
func transcriptResizeDragged(toWord id: Word.ID) { onTranscriptResizeDragged?(id) }
func transcriptResizeEnded() { onTranscriptResizeEnded?() }
func transcriptResizeCancelled() { onTranscriptResizeCancelled?() }
```

- [ ] **Step 2: Implement the overlay view**

```swift
import AppKit

/// Transparent overlay inside the transcript document view. Owns the resize
/// cursor and edge hit-testing; forwards drags to the model. Returns nil from
/// `hitTest` outside a grab zone so word-select underneath keeps working.
final class TranscriptResizeHandleOverlayView: NSView {
  weak var coordinator: TranscriptTextView.Coordinator?

  private var activeHandle: (TranscriptResizeItemIdentity, TranscriptResizeEdge)?
  private var downPoint: NSPoint?
  private var didBeginResize = false
  private var trackingArea: NSTrackingArea?

  override var isFlipped: Bool { true }  // match NSTextView's flipped coords

  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    return coordinator?.resizeHandle(at: local) == nil ? nil : self
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.cursorUpdate, .mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    trackingArea = area
  }

  override func cursorUpdate(with event: NSEvent) { setCursor(for: event) }
  override func mouseMoved(with event: NSEvent) { setCursor(for: event) }
  override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

  private func setCursor(for event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    if coordinator?.resizeHandle(at: p) != nil { NSCursor.resizeLeftRight.set() }
    else { NSCursor.arrow.set() }
  }

  override func mouseDown(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    activeHandle = coordinator?.resizeHandle(at: p)
    downPoint = p
    didBeginResize = false
  }

  override func mouseDragged(with event: NSEvent) {
    guard let handle = activeHandle, let down = downPoint, let coordinator else { return }
    let p = convert(event.locationInWindow, from: nil)
    if !didBeginResize {
      guard abs(p.x - down.x) >= TranscriptResizeMetrics.dragThreshold else { return }
      didBeginResize = true
      coordinator.model.transcriptResizeBegan(handle.0, handle.1)
    }
    if let wordID = coordinator.wordIDForResize(at: p) {
      coordinator.model.transcriptResizeDragged(toWord: wordID)
    }
  }

  override func mouseUp(with event: NSEvent) {
    if didBeginResize { coordinator?.model.transcriptResizeEnded() }
    activeHandle = nil
    downPoint = nil
    didBeginResize = false
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    if newWindow == nil, didBeginResize {
      coordinator?.model.transcriptResizeCancelled()
      didBeginResize = false
      activeHandle = nil
    }
  }
}
```

- [ ] **Step 3: Attach the overlay in `makeNSView`**

After `scroll.documentView = textView` and coordinator wiring, add the overlay as a subview of `textView`:

```swift
let overlay = TranscriptResizeHandleOverlayView(frame: textView.bounds)
overlay.coordinator = context.coordinator
overlay.autoresizingMask = [.width, .height]
textView.addSubview(overlay)
context.coordinator.resizeOverlay = overlay
```

Add `weak var resizeOverlay: TranscriptResizeHandleOverlayView?` to the Coordinator.

- [ ] **Step 4: Manual verification**

Build & run the app (`/run` or Xcode). Load a project with a selection, a clip, and a suggestion. Verify:
- Hovering near a start/end edge shows the `<>` cursor; elsewhere the arrow.
- Click+drag inside a 6pt edge zone does NOT change selection yet (callbacks are still no-ops — confirm no crash, no console errors).
- Click+drag on a normal word still selects words (the overlay didn't steal it).

- [ ] **Step 5: Commit**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptResizeHandleOverlayView.swift \
        QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptTextView.swift \
        QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptPageModel.swift
git commit -m "feat: transcript resize overlay (cursor + hit-test + drag lifecycle)"
```

---

## Task 5: Selection resize (Pattern A) + clip resize (Pattern B)

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift`
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorView.swift` (wire the closures)
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptPageModel.swift` (draft mirror for preview — see Step 4)
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/TranscriptResizeTests.swift`

**Interfaces:**
- Consumes: `TranscriptResizeDraft`, `TranscriptResizeMath.resized`, `sourceRange(coveringWordIDs:)`, `selectSourceRange`, `mutateSlices`, `updatedSlice`, `selectionEditingEdge`.
- Produces on `EditorModel`:
  - `var transcriptResizeDraft: TranscriptResizeDraft?`
  - `func transcriptResizeBegan(_ identity:, _ edge:)` / `transcriptResizeDragged(toWord:)` / `transcriptResizeEnded()` / `transcriptResizeCancelled()` — the state machine (selection + clip here; suggestion in Task 6).
  - Replace the Task 2 placeholder `applyingResizeDraft(to:)` with the real draft-aware substitution.

**State machine behavior:**
- `began`: find the item's committed `wordIDs` from `transcriptResizeItems`; set `transcriptResizeDraft`; for `.selection` set `selectionEditingEdge` (so transport-snap backs off); for clip stop transport if needed (mirror `crossfadeStretchBegan`).
- `dragged(toWord:)`: `TranscriptResizeMath.resized(...)` over `transcriptOrder()`; store into `draft.draftedWordIDs`. For `.selection`, convert to a source range and update `audioSelection` **live** via `selectSourceRange(range, snapPlayhead: false, origin: .transcript)` with the opposite edge held as anchor. For `.clip`, only update the draft (preview flows through the draft-aware `clipBands`/`transcriptResizeItems`).
- `ended`: for `.clip`, derive the source range from the drafted words and commit once: `mutateSlices { $0[id: id] = updatedSlice($0[id: id]!, to: range) }` (no-op if unchanged). For `.selection`, nothing to commit (already live). Clear draft + `selectionEditingEdge`.
- `cancelled`: for `.clip`, drop the draft (document was never touched). For `.selection`, restore `audioSelection` to `draft.originalWordIDs`' range. Clear draft + `selectionEditingEdge`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import CustomDump
import IdentifiedCollections
@testable import QuickInterviewEditor

@MainActor
struct TranscriptResizeTests {

  @Test func selectionResizeStartUpdatesSelectionLive() {
    let model = EditorModel.testModel(/* words w0..w5 */)
    // select w2,w3 first (via source range helper the sibling tests use)
    model.transcriptResizeBegan(.selection, .start)
    model.transcriptResizeDragged(toWord: "w0")
    // audioSelection now covers w0..w3
    expectNoDifference(model.selectedWordIDs, ["w0", "w1", "w2", "w3"])
    model.transcriptResizeEnded()
    expectNoDifference(model.transcriptResizeDraft, nil)
  }

  @Test func clipResizeDoesNotTouchSlicesUntilMouseUp() {
    let model = EditorModel.testModel(/* words + one clip over w1,w2 */)
    let clipID = model.slices.first!.id
    let before = model.slices
    model.transcriptResizeBegan(.clip(clipID), .end)
    model.transcriptResizeDragged(toWord: "w4")
    // Document untouched mid-drag:
    expectNoDifference(model.slices, before)
    // Preview reflects the draft:
    let previewed = model.transcriptResizeItems.first { $0.identity == .clip(clipID) }
    expectNoDifference(previewed?.wordIDs, ["w1", "w2", "w3", "w4"])
  }

  @Test func clipResizeCommitsOnceOnEnd() {
    let model = EditorModel.testModel(/* words + one clip over w1,w2 */)
    let clipID = model.slices.first!.id
    model.transcriptResizeBegan(.clip(clipID), .end)
    model.transcriptResizeDragged(toWord: "w4")
    model.transcriptResizeEnded()
    expectNoDifference(model.slices[id: clipID]?.wordIDs, ["w1", "w2", "w3", "w4"])
    // one undo entry restores the original:
    model.undo()   // use the model's existing undo entry point
    expectNoDifference(model.slices[id: clipID]?.wordIDs, ["w1", "w2"])
  }

  @Test func clipResizeCancelledDropsDraft() {
    let model = EditorModel.testModel(/* words + one clip over w1,w2 */)
    let clipID = model.slices.first!.id
    let before = model.slices
    model.transcriptResizeBegan(.clip(clipID), .end)
    model.transcriptResizeDragged(toWord: "w4")
    model.transcriptResizeCancelled()
    expectNoDifference(model.slices, before)
    expectNoDifference(model.transcriptResizeDraft, nil)
  }
}
```

> Check the exact undo entry point (search `documentUndo` / an `undo()`-style method in `EditorModel.swift`) and the exact test factory used by `TranscriptSelectionTests`/`TranscriptClipContainersTests`. Match them.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test-fast ONLY=QuickInterviewEditorTests/TranscriptResizeTests`
Expected: FAIL — state-machine methods not defined.

- [ ] **Step 3: Implement the state machine (selection + clip)**

```swift
// MARK: - Transcript resize state machine
var transcriptResizeDraft: TranscriptResizeDraft?

func transcriptResizeBegan(_ identity: TranscriptResizeItemIdentity, _ edge: TranscriptResizeEdge) {
  guard let item = transcriptResizeItems.first(where: { $0.identity == identity }) else { return }
  transcriptResizeDraft = TranscriptResizeDraft(
    identity: identity, edge: edge,
    originalWordIDs: item.wordIDs, draftedWordIDs: item.wordIDs)
  if case .selection = identity { selectionEditingEdge = edge }
}

func transcriptResizeDragged(toWord id: Word.ID) {
  guard var draft = transcriptResizeDraft,
    let newWords = TranscriptResizeMath.resized(
      itemWordIDs: draft.originalWordIDs, edge: draft.edge,
      toTargetWord: id, transcriptOrder: transcriptOrder())
  else { return }
  draft.draftedWordIDs = newWords
  transcriptResizeDraft = draft
  if case .selection = draft.identity, let range = sourceRange(coveringWordIDs: newWords) {
    selectSourceRange(range, snapPlayhead: false, origin: .transcript)
  }
  // clip/suggestion: preview flows through draft-aware transcriptResizeItems/clipBands.
}

func transcriptResizeEnded() {
  defer { transcriptResizeDraft = nil; selectionEditingEdge = nil }
  guard let draft = transcriptResizeDraft else { return }
  switch draft.identity {
  case .selection:
    break  // already applied live
  case .clip(let id):
    guard let range = sourceRange(coveringWordIDs: draft.draftedWordIDs),
      let current = slices[id: id]
    else { return }
    mutateSlices { $0[id: id] = updatedSlice(current, to: range) }
  case .suggestion:
    break  // implemented in Task 6
  }
}

func transcriptResizeCancelled() {
  defer { transcriptResizeDraft = nil; selectionEditingEdge = nil }
  guard let draft = transcriptResizeDraft else { return }
  if case .selection = draft.identity,
    let range = sourceRange(coveringWordIDs: draft.originalWordIDs) {
    selectSourceRange(range, snapPlayhead: false, origin: .transcript)
  }
  // clip/suggestion: document never touched, nothing to restore.
}
```

- [ ] **Step 4: Make `transcriptResizeItems`/`clipBands` draft-aware**

Replace the Task 2 placeholder:

```swift
private func applyingResizeDraft(to items: [TranscriptResizeItem]) -> [TranscriptResizeItem] {
  guard let draft = transcriptResizeDraft, draft.identity != .selection else { return items }
  return items.map { item in
    guard item.identity == draft.identity else { return item }
    return TranscriptResizeItem(identity: item.identity, wordIDs: draft.draftedWordIDs)
  }
}
```

And make `clipBands` substitute drafted words for the active clip/suggestion so the drawn container previews. In the `clipBands` builder, after assembling `approved`/`suggested`, map the matching band's `wordIDs` to `transcriptResizeDraft?.draftedWordIDs` when identity matches (only for `.clip`/`.suggestion`). Keep the occlusion logic for the non-dragged bands.

> `clipBands` and `transcriptResizeItems` are both computed, so `EditorView`'s `onChange(of: model.clipBands)` / `onChange(of: model.transcriptResizeItems)` re-fire whenever `transcriptResizeDraft` changes — the preview updates without any per-drag document mutation.

- [ ] **Step 5: Wire the closures in `EditorView`**

Next to the `onSelectionIntent` wiring pattern (closures set in `EditorModel` init at `:116`, OR in `EditorView` — match where `onSelectionIntent` is assigned; per the extract it's in `EditorModel`'s init block). Add to that same block:

```swift
transcript.onTranscriptResizeBegan = { [weak self] id, edge in
  self?.transcriptResizeBegan(id, edge)
}
transcript.onTranscriptResizeDragged = { [weak self] wordID in
  self?.transcriptResizeDragged(toWord: wordID)
}
transcript.onTranscriptResizeEnded = { [weak self] in self?.transcriptResizeEnded() }
transcript.onTranscriptResizeCancelled = { [weak self] in self?.transcriptResizeCancelled() }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `make test-fast ONLY=QuickInterviewEditorTests/TranscriptResizeTests`
Expected: PASS.

- [ ] **Step 7: Manual verification**

Run the app: drag a selection edge across words (highlight follows live); drag a clip edge (container previews live, commits on release, one Cmd-Z restores it).

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: selection + clip resize via transcript edge drag"
```

---

## Task 6: Suggestion resize (Pattern B) + `updatedSuggestion`

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift`
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/TranscriptResizeSuggestionTests.swift`

**Interfaces:**
- Consumes: `CutSuggestion`, `documentCutSuggestions`, `mutateDocument`, `sourceRange(coveringWordIDs:)`, `editPlan.source.sampleRate`.
- Produces on `EditorModel`:
  - `private func updatedSuggestion(_ suggestion: CutSuggestion, toWordIDs ids: [Word.ID]) -> CutSuggestion` — sets `wordIDs`, `startSample`, `endSample`, `startSec`, `endSec`, `durationSec` from the **exact** drafted words (not audio overlap). Seconds = samples / `sampleRate`.
  - the `.suggestion(id)` branch in `transcriptResizeEnded()`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import CustomDump
import IdentifiedCollections
@testable import QuickInterviewEditor

@MainActor
struct TranscriptResizeSuggestionTests {
  @Test func suggestionResizeCommitsOnceAndDerivesSamplesFromWords() {
    let model = EditorModel.testModel(/* words w0..w5, one pending suggestion over w1,w2 */)
    let id = model.documentCutSuggestions.first!.id
    model.transcriptResizeBegan(.suggestion(id), .end)
    model.transcriptResizeDragged(toWord: "w4")
    // untouched mid-drag
    expectNoDifference(model.documentCutSuggestions[id: id]?.wordIDs, ["w1", "w2"])
    model.transcriptResizeEnded()
    expectNoDifference(model.documentCutSuggestions[id: id]?.wordIDs, ["w1", "w2", "w3", "w4"])
    // samples equal exact first/last word bounds (from the fixture)
    // expectNoDifference(model.documentCutSuggestions[id: id]?.startSample, <w1.startSample>)
    // expectNoDifference(model.documentCutSuggestions[id: id]?.endSample, <w4.endSample>)
    model.undo()
    expectNoDifference(model.documentCutSuggestions[id: id]?.wordIDs, ["w1", "w2"])
  }

  @Test func acceptedSuggestionIsNotResizable() {
    let model = EditorModel.testModel(/* one accepted suggestion */)
    let id = model.documentCutSuggestions.first!.id
    model.transcriptResizeBegan(.suggestion(id), .end)   // not in transcriptResizeItems
    expectNoDifference(model.transcriptResizeDraft, nil)
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test-fast ONLY=QuickInterviewEditorTests/TranscriptResizeSuggestionTests`
Expected: FAIL.

- [ ] **Step 3: Implement `updatedSuggestion` + the commit branch**

```swift
private func updatedSuggestion(
  _ suggestion: CutSuggestion, toWordIDs ids: [Word.ID]
) -> CutSuggestion {
  var updated = suggestion
  updated.wordIDs = ids
  if let range = sourceRange(coveringWordIDs: ids) {
    let rate = Double(editPlan.source.sampleRate)
    updated.startSample = range.lowerBound
    updated.endSample = range.upperBound
    updated.startSec = Double(range.lowerBound) / rate
    updated.endSec = Double(range.upperBound) / rate
    updated.durationSec = Double(range.count) / rate
  }
  return updated
}
```

In `transcriptResizeEnded()` replace the suggestion `break` with:

```swift
case .suggestion(let id):
  guard let current = documentCutSuggestions[id: id], current.isPending else { return }
  let updated = updatedSuggestion(current, toWordIDs: draft.draftedWordIDs)
  guard updated != current else { return }
  mutateDocument { $0.cutSuggestions[id: id] = updated }
```

(`transcriptResizeItems` already lists only `.pending` suggestions, so `began` on an accepted/rejected one finds no item and leaves the draft `nil` — the second test passes for free.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test-fast ONLY=QuickInterviewEditorTests/TranscriptResizeSuggestionTests`
Expected: PASS.

- [ ] **Step 5: Manual verification**

Run the app: drag a suggestion (amber, dashed) edge — it previews live and commits once on release; Cmd-Z restores it; accepted/rejected suggestions have no handles.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: suggestion resize via transcript edge drag"
```

---

## Task 7: Teardown-cancellation regression coverage + polish

**Files:**
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/TranscriptResizeTeardownTests.swift`
- Modify (only if a gap surfaces): the files above.

**Interfaces:** Consumes the full state machine from Tasks 5–6.

- [ ] **Step 1: Write the regression tests**

```swift
import Testing
import CustomDump
import IdentifiedCollections
@testable import QuickInterviewEditor

@MainActor
struct TranscriptResizeTeardownTests {
  @Test func cancelDuringClipDragLeavesDocumentAndDraftClean() {
    let model = EditorModel.testModel(/* one clip over w1,w2 */)
    let clipID = model.slices.first!.id
    let before = model.slices
    model.transcriptResizeBegan(.clip(clipID), .end)
    model.transcriptResizeDragged(toWord: "w4")
    model.transcriptResizeCancelled()  // simulates viewWillMove(toWindow: nil) mid-drag
    expectNoDifference(model.slices, before)
    expectNoDifference(model.transcriptResizeDraft, nil)
    // A subsequent normal commit still works (state machine not wedged):
    model.transcriptResizeBegan(.clip(clipID), .end)
    model.transcriptResizeDragged(toWord: "w3")
    model.transcriptResizeEnded()
    expectNoDifference(model.slices[id: clipID]?.wordIDs, ["w1", "w2", "w3"])
  }

  @Test func cancelDuringSelectionDragRestoresOriginalSelection() {
    let model = EditorModel.testModel(/* select w2,w3 */)
    model.transcriptResizeBegan(.selection, .start)
    model.transcriptResizeDragged(toWord: "w0")
    model.transcriptResizeCancelled()
    expectNoDifference(model.selectedWordIDs, ["w2", "w3"])
    expectNoDifference(model.selectionEditingEdge, nil)
  }

  @Test func draggedWithNoActiveDraftIsNoop() {
    let model = EditorModel.testModel()
    model.transcriptResizeDragged(toWord: "w1")   // no began
    expectNoDifference(model.transcriptResizeDraft, nil)
  }

  @Test func minOneWordEnforcedThroughStateMachine() {
    let model = EditorModel.testModel(/* clip over w2,w3 */)
    let clipID = model.slices.first!.id
    model.transcriptResizeBegan(.clip(clipID), .start)
    model.transcriptResizeDragged(toWord: "w5")   // start dragged past end
    model.transcriptResizeEnded()
    expectNoDifference(model.slices[id: clipID]?.wordIDs, ["w3"])
  }
}
```

- [ ] **Step 2: Run to verify they fail (or pass, if already covered)**

Run: `make test-fast ONLY=QuickInterviewEditorTests/TranscriptResizeTeardownTests`
Expected: any failure points at a real gap in Tasks 5–6 — fix it in the state machine, don't weaken the test.

- [ ] **Step 3: Fix any surfaced gaps, re-run until green**

Run: `make test-fast ONLY=QuickInterviewEditorTests/TranscriptResizeTeardownTests`
Expected: PASS.

- [ ] **Step 4: Full suite + format + lint**

```bash
cd QuickInterviewEditor && make test-fast && make format && make lint
```
Expected: green; no format/lint diffs left unstaged.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "test: transcript resize teardown + min-word regression coverage"
```

---

## Self-Review (completed during authoring)

- **Spec coverage:** overlay/cursor (Task 4) ✓; geometry across wrapped lines via `boundingRect(forGlyphRange:in:)` first/last word only (Task 3) ✓; D1 word-snap (Task 1 + state machine) ✓; D2 priority resolution (Task 3 `resizeHandle`) ✓; D3 undoable suggestion resize (Task 6) ✓; selection Pattern A / clip+suggestion Pattern B (Task 5–6) ✓; semantic-vs-drawn (Task 2 keeps full suggestion `wordIDs`; Task 5 draft-aware `clipBands` for preview) ✓; teardown cancel (Task 7) ✓; `updatedSuggestion` new mutator (Task 6) ✓.
- **Placeholder scan:** fixture bodies are marked `/* … */` where they depend on the repo's existing editor-model test factory — the executor must use the real factory from `TranscriptSelectionTests`/`TranscriptClipContainersTests` (called out in Task 2/5). No `TODO`/`TBD`/"add error handling" left.
- **Type consistency:** `TranscriptResizeItemIdentity`, `TranscriptResizeEdge`, `TranscriptResizeDraft`, `transcriptResizeItems`, `transcriptResizeDraft`, `resizeItems`, `updatedSuggestion(_:toWordIDs:)`, `sourceRange(coveringWordIDs:)`, the four `onTranscriptResize*` closures, and `resizeHandle(at:)`/`wordIDForResize(at:)`/`resizeZones()` names are used identically across tasks.

## Open items for the executor to verify against the live code (cheap, do first)

1. The exact undo entry point on `EditorModel` (the tests call `model.undo()` — confirm the real method name; search `documentUndo`).
2. The editor-model test factory used by sibling suites (how they seed `editPlan`, add a `Slice`, add a pending `CutSuggestion`, and set a selection) — reuse it verbatim; fill the `/* … */` fixture bodies from it.
3. Whether the `onSelectionIntent` closure block lives in `EditorModel.init` (per the extract, `:116`) or in `EditorView` — wire the four resize closures in the same place.
4. `Word.startSample`/`endSample` optionality (they're `Int?`) — `sourceRange(coveringWordIDs:)` already `compactMap`s; confirm the fixture words have non-nil bounds.
5. That adding a subview to the `NSTextView` document view doesn't interfere with `ClipContainerLayoutManager` drawing (it draws into the text view; the overlay is transparent and above it — verify visually in Task 4).
