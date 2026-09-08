# Transcript Group Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Execute inline unless the user requests delegation.

**Goal:** Select transcript objects with one click, open them with two, select words by dragging, resolve overlaps explicitly, and make object/highlight deletion and unsaved-draft boundary edits undoable.

**Architecture:** The editor owns one typed selection; transcript rendering and hit testing consume one ordered object projection. A chronological editor history supports both document edits and transient highlight clears. Explicit editing-session targets distinguish saved clips from unsaved drafts, whose local boundary history and commit lifecycle are isolated from the document.

**Tech Stack:** Existing SwiftUI/AppKit TextKit 1, Observation, Dependencies, IdentifiedCollections, Swift Testing and CustomDump. No new dependency or document schema.

**Approved spec:** `docs/superpowers/specs/2026-09-08-transcript-group-selection-design.md`, including the user's post-review Delete/Undo decisions. The spec governs behavior; this plan translates it into code and verification.

## Execution boundaries

- Work in the current Conductor workspace and branch. Do not rename it.
- Read `CLAUDE.md`. Apply the Point-Free observable-model, SwiftUI, testing,
  custom-dump, dependency, and identified-collection skills as applicable.
- This plan does not authorize publishing, deploying, or changing the Python engine.
- Keep policy, labels, capability flags, and transitions in models. AppKit only
  translates events/geometry; SwiftUI displays model-derived values.
- Use `make test-fast ONLY=PlayolaInterviewEditorTests/<Suite>` from
  `QuickInterviewEditor/` for each red/green loop. Expected red is the named new
  behavior failing or its new API being absent, not an unrelated build failure.
- Source registration is explicit in the existing Xcode project. Register each
  new file with the appropriate existing group and target in
  `QuickInterviewEditor/PlayolaInterviewEditor.xcodeproj/project.pbxproj` before
  running its test. Do not repeatedly regenerate the project or change package
  dependencies. `project.yml` already includes the app and test directories.
- Every task ends with its focused tests passing and a commit of only that task's
  source, tests, and project-registration changes. No app code is included in
  this planning commit.

## File responsibility map

New app files (all beneath `QuickInterviewEditor/QuickInterviewEditor/`):

| File | Responsibility |
| --- | --- |
| `Models/EditorSelection.swift` | Typed identities and the single selection value |
| `Models/TranscriptObject.swift` | Full object projection and deterministic hit ordering |
| `Models/EditorHistory.swift` | Chronological document/selection change entries |
| `Models/ClipEditTarget.swift` | Saved versus unsaved session identity and commit outcome |
| `Views/Pages/Editor/EditorModel+TranscriptSelection.swift` | Object actions, selection resolution and sidebar reveal |
| `Views/Pages/Editor/EditorModel+SelectionHistory.swift` | Delete/Clear, history application and keyboard policy |
| `Views/Pages/Editor/EditorModel+DraftEditing.swift` | Draft initialization, validation and atomic commit |
| `Views/Pages/TranscriptPage/TranscriptPointerGesture.swift` | Testable press/click/drag classification |
| `Views/Pages/TranscriptPage/TranscriptOverlapModel.swift` | Chooser rows, preview and selection intents |
| `Views/Pages/TranscriptPage/TranscriptOverlapView.swift` | Accessible chooser presentation |

Modify the existing transcript models, renderer/layout manager, editor view/model,
clip/suggestion panels, key monitors, mark bar, edit-sheet model/view,
`BoundaryInset.swift`, `FineTuneModel.swift`, and `Views/Commands/EditUndoCommands.swift`.
Tests mirror these responsibilities. Preserve the existing generic
`Models/UndoStack.swift` for local range history and its other users.

## Task 1: Establish one typed selection and complete object projection

**Files:** Create `Models/EditorSelection.swift`, `Models/TranscriptObject.swift`;
modify `Views/Pages/Editor/EditorModel.swift`, create
`Views/Pages/Editor/EditorModel+TranscriptSelection.swift`;
test `QuickInterviewEditor/QuickInterviewEditorTests/Models/TranscriptObjectTests.swift`
and `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorGroupSelectionTests.swift`.
App file paths use the prefix in the responsibility map.

- [ ] Add these foundation types, registering both source files and tests:

```swift
import Foundation

enum TranscriptObjectID: Hashable, Sendable {
  case clip(UUID)
  case suggestion(UUID)
}

enum EditorSelection: Equatable, Sendable {
  case none
  case object(TranscriptObjectID)
  case range(Range<Int>, anchor: Int)
  case seam(UUID)

  var objectID: TranscriptObjectID? {
    guard case .object(let id) = self else { return nil }
    return id
  }

  var freeformRange: Range<Int>? {
    guard case .range(let range, _) = self else { return nil }
    return range
  }
}

struct TranscriptObject: Equatable, Identifiable, Sendable {
  let id: TranscriptObjectID
  let name: String
  let range: Range<Int>
  let wordIDs: Set<Word.ID>
  let colorIndex: Int
}

func foregroundObjects(
  _ objects: [TranscriptObject], selected: TranscriptObjectID?
) -> [TranscriptObject] {
  guard let selected else { return objects }
  return objects.filter { $0.id == selected }
    + objects.filter { $0.id != selected }
}

func objectsCovering(
  _ wordID: Word.ID, objects: [TranscriptObject], selected: TranscriptObjectID?
) -> [TranscriptObject] {
  foregroundObjects(objects, selected: selected).filter { $0.wordIDs.contains(wordID) }
}
```

The input order to `foregroundObjects` is saved clips in document array order,
then pending suggestions in document array order. Projection calculates colors
before foreground promotion. IDs are type-tagged because acceptance reuses UUIDs.

- [ ] Add this first failing behavior test, then run
  `make test-fast ONLY=PlayolaInterviewEditorTests/TranscriptObjectTests`:

```swift
import CustomDump
import Foundation
import Testing
@testable import PlayolaInterviewEditor

struct TranscriptObjectTests {
  @Test func identicalRangesKeepBothCandidatesAndPromoteChosenObject() {
    let sharedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let clip = TranscriptObject(
      id: .clip(sharedID), name: "Clip", range: 100..<500,
      wordIDs: [2, 3, 4], colorIndex: 0)
    let suggestion = TranscriptObject(
      id: .suggestion(sharedID), name: "Suggestion", range: 100..<500,
      wordIDs: [2, 3, 4], colorIndex: 1)
    expectNoDifference(
      objectsCovering(3, objects: [clip, suggestion], selected: suggestion.id),
      [suggestion, clip])
    expectNoDifference(
      objectsCovering(9, objects: [clip, suggestion], selected: nil), [])
  }
}
```

Write the test before the helper implementation so the new API is initially red.

- [ ] Make `EditorModel.selection` the stored value. Derive the existing
  `audioSelection`/`selectedSourceRange` facade from `.range` or the current
  object's resolved range. Derive the anchor from the freeform anchor or object's
  start. Existing setters must go through the freeform/clear funnel rather than
  create a second store. Likewise route seam selection through `.seam`.
  Do not retain three independent writable selection representations.
- [ ] Add `selectTranscriptObject(_ id: TranscriptObjectID)` to resolve the object
  against the live document, select its identity, invalidate stale word anchors,
  and issue reveal requests. Missing objects leave the selection unchanged.
  Clip ranges come from actual slice bounds, and their word sets from
  `wordIDs(anyOverlap:words:)`. Resolve every suggestion word; invalid partial
  matches cannot silently narrow the range. Reuse existing acceptance validation
  and `sourceRange(coveringWords:_:)` policy as appropriate without accepting.
- [ ] Gate `fineTuneTarget` and pending `fineTuneSessionKey.selection` on
  `selection.freeformRange`. Selecting an object must not create a pending draft.
  Keep existing saved-clip edit sessions explicitly owned by their opening path.
  Drive row active state from `selection.objectID`, not ambient `activeSliceID`.
- [ ] Add model tests for actual padded clip bounds, an overlapping edge word,
  missing object IDs, same-ID clip/suggestion disambiguation, and selection
  surviving `syncEditSession()`. Change existing selection tests intentionally
  where they assert the removed re-click-to-clear behavior.
- [ ] Run `EditorGroupSelectionTests`, `EditorSelectionTests`,
  `EditorSeamSelectionTests`, `EditorFineTuneTests`, and `TranscriptObjectTests`.
  Commit: `feat: model transcript object selection explicitly`.

## Task 2: Introduce history entries that can clear highlights without editing documents

**Files:** Create `Models/EditorHistory.swift`,
`Views/Pages/Editor/EditorModel+SelectionHistory.swift`; modify
`Views/Pages/Editor/EditorModel.swift` and `Views/Commands/EditUndoCommands.swift`.
Tests: `QuickInterviewEditor/QuickInterviewEditorTests/Models/EditorHistoryTests.swift`,
`QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorSelectionHistoryTests.swift`,
existing `EditorDocumentMutationTests.swift`, `EditorSuggestionFlowTests.swift`,
and `Commands/EditUndoCommandsTests.swift`.

- [ ] Add the generic entry history below. Preserve the 30-entry limit and do
  not persist it. A document entry may additionally carry the selection change
  associated with a deletion; an ordinary document edit carries no selection.

```swift
struct HistoryChange<Value: Equatable>: Equatable {
  var before: Value
  var after: Value
}

struct EditorHistory<Document: Equatable, Selection: Equatable> {
  struct Entry: Equatable {
    var document: HistoryChange<Document>?
    var selection: HistoryChange<Selection>?
    var label: String
  }

  private(set) var undo: [Entry] = []
  private(set) var redo: [Entry] = []
  let limit: Int

  init(limit: Int = 30) {
    precondition(limit >= 0)
    self.limit = limit
  }

  var canUndo: Bool { !undo.isEmpty }
  var canRedo: Bool { !redo.isEmpty }

  mutating func record(_ entry: Entry) {
    let documentChanged = entry.document.map { $0.before != $0.after } ?? false
    let selectionChanged = entry.selection.map { $0.before != $0.after } ?? false
    guard documentChanged || selectionChanged else { return }
    undo.append(entry)
    trimUndo()
    redo.removeAll()
  }

  mutating func undoEntry() -> Entry? {
    guard let entry = undo.popLast() else { return nil }
    redo.append(entry)
    return entry
  }

  mutating func redoEntry() -> Entry? {
    guard let entry = redo.popLast() else { return nil }
    undo.append(entry)
    trimUndo()
    return entry
  }

  mutating func rebase(_ transform: (inout Document) -> Void) {
    for index in undo.indices {
      if var change = undo[index].document {
        transform(&change.before)
        transform(&change.after)
        undo[index].document = change
      }
    }
    for index in redo.indices {
      if var change = redo[index].document {
        transform(&change.before)
        transform(&change.after)
        redo[index].document = change
      }
    }
  }

  private mutating func trimUndo() {
    if undo.count > limit { undo.removeFirst(undo.count - limit) }
  }
}
```

- [ ] Establish this red/green test before implementing that type:

```swift
import CustomDump
import Testing
@testable import PlayolaInterviewEditor

struct EditorHistoryTests {
  @Test func highlightClearInterleavesWithoutContainingADocumentSnapshot() throws {
    var history = EditorHistory<Int, EditorSelection>()
    let selection = EditorSelection.range(100..<300, anchor: 300)
    history.record(.init(
      document: .init(before: 1, after: 2), selection: nil, label: "Edit"))
    history.record(.init(
      document: nil, selection: .init(before: selection, after: .none),
      label: "Clear Selection"))
    history.rebase { $0 += 10 }
    let clear = try #require(history.undoEntry())
    expectNoDifference(clear.document, nil)
    expectNoDifference(clear.selection?.before, selection)
    let edit = try #require(history.undoEntry())
    expectNoDifference(edit.document, .init(before: 11, after: 12))
    expectNoDifference(history.redoEntry(), edit)
    expectNoDifference(history.redoEntry(), clear)
  }
}
```

- [ ] Replace the editor's `documentUndo` with
  `history: EditorHistory<EditorDocumentState, EditorSelection>`. Update every
  record/rebase/undo/redo consumer, including suggestion-title coalescing and its
  tests. Do not change the document sink or serialized state.
- [ ] Add a main-actor history application method accepting an entry and direction.
  Apply `document.before/after` through `restore` only if a document change exists
  and differs from live state; apply `selection.before/after` only when present.
  Reconcile missing object/seam identities and stale range bounds afterward.
  A pure selection entry never calls `restore`, document callbacks, or playback
  reconciliation; restoring its highlight does not seek or stop playback.
- [ ] Coalesce object deletion + deselection inside one helper around
  `mutateDocument`, adding an optional selection change to its recorded entry.
  Maintain background rebase on both before/after document snapshots. Keep
  existing save/export/unsaved-saved-clip guards on document Undo/Redo.
- [ ] Route Edit menu labels/enabled state and keyboard actions through the editor
  history methods. Task 7 adds the draft-local routing before document guards;
  editable text fields retain their native history. Keep keyboard and menu
  invocation consistent rather than patching the sheet key monitor alone.
- [ ] Test limit eviction, no-op records, new-action Redo invalidation, background
  rebase across clear entries, restoration of reversed anchors, and zero
  `onDocumentStateChanged` calls for highlight-only history. Include a sequence
  rename → clear highlight → undo clear → undo rename → redo rename → redo clear.
- [ ] Run the new history suites and existing document/suggestion/menu suites.
  Commit: `feat: make highlight deletion undoable without changing the document`.

## Task 3: Apply Delete, arrow, Escape, and explicit Remove Section policies

**Files:** Modify `Views/Pages/Editor/EditorModel+SelectionHistory.swift`,
`EditorModel.swift`, `EditorKeyMonitor.swift`, `MarkClipBarView.swift`,
`WaveformView.swift`, and `WaveformLaneView.swift` in the same Editor folder.
Tests: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorSelectionHistoryTests.swift`,
`EditorKeyMonitorTests.swift`, `EditorRemovalTests.swift`, `EditorSeamSelectionTests.swift`.

- [ ] Add `deleteSelectionTapped() async`. Switch on `selection`: clip deletes its
  slice; suggestion removes its record from `documentCutSuggestions`; range records a pure
  clear entry; seam uses the current restore action; none does nothing. Capture
  identity before awaiting playback reconciliation so a newer selection cannot
  be deleted by a stale continuation.
- [ ] Make `clearSelectionTapped()` record a pure selection clear for any active
  selection. Keep lower-level `clearSelection()` non-recording for transitions,
  Escape, deletion internals, and background clicks. Never double-record Delete.
- [ ] Separate physical Delete from the existing `.removeSection` command. Add
  `.deleteSelection` to `EditorKey`; map key code 51 to it. The saved-sheet key
  monitor explicitly maps this to its current scoped removal/restore action.
  Main editor maps it to `deleteSelectionTapped`. Draft sheets consume it without
  mutating the parent document. Preserve explicit Remove Section and its guards.
- [ ] Gate `nudgeSelection` and waveform edge-drag availability on a freeform
  selection. Consume object arrow nudges without mutating or falling through to
  another pane. Shift-click/drag still transitions an object to freeform. Preserve
  Command-arrow zoom and Option-arrow seam commands.
- [ ] Add model-driven bottom-bar Open/Edit for all selection types, type-specific
  actions from the spec, and Remove Section only on a freeform range. Keep layout
  height fixed. Maintain the existing Mark shortcut for freeform ranges only.
- [ ] Test the central safety behavior with this model test (helper APIs are
  introduced by Tasks 1–3):

```swift
@Test func deleteHighlightPreservesAudioAndUndoRestoresRange() async {
  let model = EditorModel(
    sourceURL: URL(fileURLWithPath: "/clip.m4a"),
    canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: Fixtures.editPlan())
  model.selectSourceRange(70_648..<119_202, snapPlayhead: false)
  let before = model.documentState
  let selected = model.selection
  var writes = 0
  model.onDocumentStateChanged = { _ in writes += 1 }
  await model.deleteSelectionTapped()
  expectNoDifference(model.selection, .none)
  expectNoDifference(model.documentState, before)
  expectNoDifference(writes, 0)
  await model.undoTapped()
  expectNoDifference(model.selection, selected)
  expectNoDifference(model.documentState, before)
  expectNoDifference(writes, 0)
  await model.redoTapped()
  expectNoDifference(model.selection, .none)
}
```

- [ ] Add equivalent clip and suggestion tests that verify one history entry,
  restored object selection, unchanged timeline removals, accepted-origin status
  preservation, and no accidental source-audio removal. Update old tests that
  assert main Delete removes the range; retain tests for explicit Remove Section.
- [ ] Test field-editor/chooser/sheet precedence and that one Escape cannot both
  close an overlay and clear the underlying selection.
- [ ] Run the named suites and `EditorSelectionTests`. Commit:
  `feat: route deletion and keyboard actions by selection kind`.

## Task 4: Preserve full overlap geometry and wire click-versus-drag events

**Files:** Create `Views/Pages/TranscriptPage/TranscriptPointerGesture.swift`;
modify `TranscriptTextView.swift`, `TranscriptPageModel.swift`,
`ClipContainerLayoutManager.swift`, `TranscriptPageView.swift` in that folder;
modify `Models/TranscriptClipBand.swift` and `EditorModel+TranscriptSelection.swift`.
Tests: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/TranscriptPage/TranscriptPointerGestureTests.swift`,
`TranscriptClipContainersTests.swift`, plus `TranscriptSelectionTests.swift` and
`Models/TranscriptClipStyleTests.swift` under the test root.

- [ ] Keep full word sets in `clipBands`; never subtract clip words from suggestions.
  Build contiguous containers independently for each object, retaining its typed
  ID, base color, kind, and active/preview emphasis. Split at paragraph boundaries
  while retaining identity. Render all runs back-to-front; resolve foreground
  text color and hit priority from that exact same ordering.
- [ ] Add a testable pointer classifier with the following complete core. The
  AppKit bridge creates one instance per text view and forwards the resulting
  actions to the model; it does not decide which object wins.

```swift
import CoreGraphics

struct TranscriptPointerGesture {
  enum Result: Equatable {
    case click(count: Int)
    case dragEnded
    case none
  }

  private var origin: CGPoint?
  private(set) var isDragging = false

  mutating func began(at point: CGPoint) {
    origin = point
    isDragging = false
  }

  mutating func moved(to point: CGPoint) -> Bool {
    guard let origin, !isDragging else { return false }
    let deltaX = point.x - origin.x
    let deltaY = point.y - origin.y
    guard deltaX * deltaX + deltaY * deltaY >= 16 else { return false }
    isDragging = true
    return true
  }

  mutating func ended(clickCount: Int) -> Result {
    defer { origin = nil; isDragging = false }
    guard origin != nil else { return .none }
    return isDragging ? .dragEnded : .click(count: clickCount)
  }

  mutating func cancelled() {
    origin = nil
    isDragging = false
  }
}
```

- [ ] Write the threshold regression first and run it red/green:

```swift
@Test func jitterRemainsAClickAndRealDragNeverOpens() {
  var gesture = TranscriptPointerGesture()
  gesture.began(at: .zero)
  expectNoDifference(gesture.moved(to: CGPoint(x: 2, y: 1)), false)
  expectNoDifference(gesture.ended(clickCount: 2), .click(count: 2))
  gesture.began(at: .zero)
  expectNoDifference(gesture.moved(to: CGPoint(x: 4, y: 0)), true)
  expectNoDifference(gesture.ended(clickCount: 2), .dragEnded)
}
```

- [ ] On first threshold crossing, begin the word drag at the original mouse-down
  offset, then extend to the current offset. Do not mutate selection during
  mouse-down. On non-drag mouse-up forward offset, modifiers, click count and
  hit geometry. Classify background geometrically: paragraph gaps/margins cannot
  inherit the nearest word; spaces inside drawn groups may select those groups.
  Use window/view coordinates for the 4-point threshold so scrolling does not
  create a spurious drag. Cancel tracking on view removal or lost interaction.
- [ ] First-click model resolution: Shift range intent wins; otherwise preserve
  active freeform/object when hit, else choose the foremost candidate, else choose
  the word, else clear. Retain the first click's resolved target and timestamp
  through the system double-click interval. Open it once on click count 2 only
  if still valid and no intervening selection-changing gesture occurred. Ignore
  count >2 for opening; a fresh count-1 sequence replaces the capture.
- [ ] Add a main-editor-only interaction capability so scoped sheet transcripts
  keep word selection and do not recursively open draft editors.
- [ ] Test identical, nested, partial, three-way and cross-paragraph overlaps;
  padded boundary words; active freeform precedence; fully hidden suggestions;
  re-click preservation; shift extension; invalidated double-click capture;
  constant color on foreground promotion; and document changes between clicks.
- [ ] Run the named transcript/style suites and `EditorGroupSelectionTests`.
  Commit: `feat: select and open transcript groups with stable hit targets`.

## Task 5: Add the overlap chooser and synchronize both sidebars

**Files:** Create `Views/Pages/TranscriptPage/TranscriptOverlapModel.swift` and
`TranscriptOverlapView.swift`; modify the transcript view/renderer from Task 4,
`Views/Pages/Editor/EditorModel+TranscriptSelection.swift`, `SlicesPanelView.swift`,
`EditorView.swift`, and `Views/Pages/CutSuggestions/CutSuggestionsPageModel.swift`
and `CutSuggestionsPageView.swift`. Add reveal data to `Models/EditorSelection.swift`.
Tests: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/TranscriptPage/TranscriptOverlapTests.swift`
and `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorObjectRevealTests.swift`.

- [ ] Introduce a tokenized reveal value and keep a counter per editor:

```swift
struct SidebarReveal: Equatable {
  let objectID: TranscriptObjectID
  let token: Int
}
```

Every request increments the token, including the same object requested twice.
Pass the relevant request to each sidebar. Both panels handle changes and initial
mounting, use explicit object IDs on rows, and scroll the selected row into view.

- [ ] Define `TranscriptOverlapModel` as an observable model with full candidate
  rows, current selected ID, optional preview ID, and callbacks for selection and
  dismissal. A row exposes type label, resolved duration, title, selected flag,
  and accessibility label. Its candidates come from `objectsCovering` at the
  clicked word, not from visible containers or clipped runs. Filter invalidated
  candidates whenever the editor projection changes.
- [ ] Expose the overlay control only for two or more object candidates at the hit.
  Anchor it beside the clicked line within the viewport; avoid covering the clicked
  word and keep text metrics fixed. Present an `NSPopover` containing the SwiftUI
  chooser through the AppKit coordinator, using the model to decide visibility
  and selection. Close it on scroll/zoom if its anchor leaves the viewport; keep
  the selected object. Hover/focus preview is separate draw-only state.
- [ ] Selecting a row calls `selectTranscriptObject`, clears preview, closes the
  chooser, and reveals the sidebar card. Escape only dismisses. Disable underlying
  Delete/arrows while the chooser has focus; provide keyboard traversal/activation.
- [ ] Update sidebar card selection surfaces to call the same object-selection
  path. A sidebar origin also reveals the transcript and frames the waveform;
  a transcript origin keeps transcript scroll/zoom and only pans waveform as
  needed. Re-clicking unchanged selection issues a sidebar reveal without any
  `snapPlayhead` call. A changed selection keeps existing stop/place-cursor policy.
- [ ] Clips ↔ Suggestions switches retain width 302; Both remains Both at width
  604. A filtered-out clip switches the clip filter to All. Selecting a hidden
  pending suggestion from its sidebar enables suggestion bands. Selecting a
  historical accepted/rejected row resolves its existing clip or falls back to a
  freeform word range without creating a new object.
- [ ] Move the whole-card double-tap onto the dedicated selection surface.
  Task 6 connects suggestion double-click/Open to its draft-open action.
  Fields and control clusters must not inherit that gesture.
- [ ] Test each overlap combination with candidate count/order, stable selected
  identity after repeated clicks, preview clearing on dismiss, invalidated rows,
  identical-range promotion, freeform precedence, and hidden suggestion overlays.
  Test token changes on repeated reveal, filter correction, panel-width stability,
  historical suggestion fallback, and unchanged-selection playback preservation.
- [ ] Run the new suites plus `EditorRevealTests`, `TranscriptRevealTests`,
  `EditorTransportTests`, and `CutSuggestionsPageTests`.
  Commit: `feat: reveal selected objects and choose overlapping alternatives`.

## Task 6: Generalize the editor sheet to explicit saved and draft targets

**Files:** Create `Models/ClipEditTarget.swift` and
`Views/Pages/Editor/EditorModel+DraftEditing.swift`; modify
`Views/Pages/Editor/EditSlice/EditSliceModel.swift`, `EditSliceView.swift`,
`SliceEditKeyMonitor.swift`, `Views/Pages/Editor/EditorView.swift`,
and `EditorModel.swift`.
Tests: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditSlice/ClipDraftTests.swift`,
existing `EditSliceTests.swift`, `EditorEditSlicePresentationTests.swift`,
`SliceEditKeyMonitorTests.swift`.

- [ ] Introduce these target/outcome types. Snapshot the original suggestion to
  validate a draft against regeneration; the freeform ID is allocated once with
  `@Dependency(\.uuid)` when opening, so repeat Save cannot create another clip.

```swift
import Foundation

enum ClipEditTarget: Equatable, Sendable {
  case savedClip(UUID)
  case suggestionDraft(CutSuggestion)
  case freeformDraft(UUID)

  var isDraft: Bool {
    switch self {
    case .savedClip: false
    case .suggestionDraft, .freeformDraft: true
    }
  }

  var resultingClipID: UUID {
    switch self {
    case .savedClip(let id), .freeformDraft(let id): id
    case .suggestionDraft(let suggestion): suggestion.id
    }
  }
}

enum ClipEditCommitResult: Equatable {
  case committed
  case failed(String)
}
```

- [ ] Add `EditSliceModel.init(target:title:range:editPlan:)` and retain the current
  `init(slice:editPlan:)` as a convenience for saved clips. Initialize the scoped
  transcript from words overlapping the range. Keep a session-local model identity
  for `.sheet(item:)`, distinct from the resulting clip's document ID.
  The saved initializer retains saved editing-complete state; drafts hide it.
- [ ] Replace `onCommit: (Range<Int>) -> Void` with a result-bearing callback:
  `(Range<Int>) -> ClipEditCommitResult`. Default to a visible unavailable error,
  never success. Update saved-clip wiring/tests to return `.committed` only after
  the existing update succeeds. Keep `errorMessage` and `invalidationMessage`
  observable on the sheet model.
- [ ] Add `canCommitRange` validation for valid file bounds and at least one
  overlapping word; preserve boundary movement clamps. Set `canSave` to
  valid-and-not-invalidated for drafts, and changed-and-valid for saved clips.
  Use the following Save control flow, with `didCommit` initially false:

```swift
func saveTapped() {
  guard !didCommit, canSave, let range = fineTune.draftRange else { return }
  switch onCommit(range) {
  case .committed:
    didCommit = true
    errorMessage = nil
    onDismiss()
  case .failed(let message):
    errorMessage = message
  }
}
```

- [ ] Add the first draft regression before the model changes:

```swift
@Test func unchangedDraftCanSaveAndFailedCommitKeepsItOpen() {
  let id = Fixtures.uuid(91)
  let model = EditSliceModel(
    target: .freeformDraft(id), title: "New clip", range: 70_648..<119_202,
    editPlan: Fixtures.editPlan())
  var dismissed = false
  model.onDismiss = { dismissed = true }
  model.onCommit = { _ in .failed("Suggestion changed. Reopen it to continue.") }
  #expect(model.canSave)
  model.saveTapped()
  expectNoDifference(dismissed, false)
  expectNoDifference(model.fineTune.draftRange, 70_648..<119_202)
  expectNoDifference(model.errorMessage, "Suggestion changed. Reopen it to continue.")
  model.onCommit = { _ in .committed }
  model.saveTapped()
  expectNoDifference(dismissed, true)
}
```

- [ ] Add `openSelectionTapped()` in the editor. Saved objects use the existing
  guarded clip editor; suggestions and freeform selections create draft sessions.
  Resolve historical rows before opening. Apply configured boundary offsets once
  before constructing drafts, never saved-clip sessions. Reuse waveform data and
  existing transport handoff. Do not recursively wire sheet transcript Open.
- [ ] Add model capabilities for global mutation controls. Drafts omit/remove
  callbacks for timeline deletion/restore, seam stretching/cut-point dragging,
  and editing-complete. Enforce these capabilities in model actions as well as
  view visibility and key/context-menu routes. Draft waveform playback still
  reads the current edited timeline and previews the draft's final boundaries.
- [ ] Show invalidation/error messages in the sheet. An invalidated draft keeps
  its boundary values/history, disables commit, and never binds to another target.
  Show the spec's save/cancel-current-edit message when opening is blocked by an
  existing unsaved saved-clip session.
- [ ] Run new draft tests plus the existing saved-sheet presentation, playback,
  removal and cut-point suites to preserve their existing capabilities.
  Commit: `feat: open suggestions and selections as unsaved clip drafts`.

## Task 7: Give drafts local boundary Undo/Redo and commit exact previewed bounds

**Files:** Modify `Views/Pages/Editor/EditorModel+DraftEditing.swift`,
`EditSlice/EditSliceModel.swift`, `EditSlice/EditSliceView.swift`,
`EditSlice/SliceEditKeyMonitor.swift`, `BoundaryInset.swift`, `FineTuneView.swift`,
`FineTuneModel.swift`, `EditorModel.swift`, and `Views/Commands/EditUndoCommands.swift`.
Tests: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditSlice/ClipDraftHistoryTests.swift`,
`QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorDraftCommitTests.swift`,
`EditorClipOffsetTests.swift`, `EditorSuggestionFlowTests.swift`, and menu/key tests.

- [ ] Give draft sessions `UndoStack<Range<Int>>` and an optional boundary-gesture
  starting range. Add model actions `boundaryDragBegan()`, `boundaryDragEnded()`,
  `undoBoundaryTapped()`, and `redoBoundaryTapped()`; use the following history core:

```swift
func boundaryDragBegan() {
  guard target.isDraft, boundaryGestureStart == nil else { return }
  boundaryGestureStart = fineTune.draftRange
}

func boundaryDragEnded() {
  defer { boundaryGestureStart = nil }
  guard target.isDraft, let before = boundaryGestureStart,
    let after = fineTune.draftRange else { return }
  boundaryHistory.record(before: before, after: after)
}

func undoBoundaryTapped() {
  guard target.isDraft, let current = fineTune.draftRange,
    let restored = boundaryHistory.undo(current: current) else { return }
  fineTune.restoreDraftRange(restored)
}

func redoBoundaryTapped() {
  guard target.isDraft, let current = fineTune.draftRange,
    let restored = boundaryHistory.redo(current: current) else { return }
  fineTune.restoreDraftRange(restored)
}
```

Add `FineTuneModel.restoreDraftRange(_:)` to restore previously validated local
samples without changing `committedRange`, inset anchors, or invoking document
callbacks. Store history only for ranges produced by the same session's validated
boundary editor. If the source invalidates, history remains inspectable but
commit stays disabled; it must not clamp silently into a new source.

- [ ] Add `onDragBegan`/`onDragEnded` callbacks to `BoundaryInset`. Its changed
  callback calls `onDragBegan` idempotently then `onDrag`; ended calls
  `onDragEnded`. Default lifecycle closures are no-ops for the dormant
  `FineTuneView` so its behavior is preserved. A cancelled drag restores the
  captured starting range and records nothing. Add a cancellation route for view
  disappearance/lost gesture so a stale begin range cannot absorb later nudges.
- [ ] Wrap each draft nudge in one before/after range record. No-op clamps do
  not add history. On local undo/redo stop/reconcile active draft preview through
  existing scoped transport hooks before changing boundaries; stale asynchronous
  stop continuations must not overwrite a newer playback action.
- [ ] Route both menu and keyboard Undo/Redo to local history for draft targets,
  consuming empty history. Saved-clip targets retain their current routing.
  Keep text-field undo native. Add tests that local history never calls parent
  `onUndo`, `onRedo`, or `onDocumentStateChanged`.
- [ ] For draft commit, revalidate file bounds, nonempty word membership, source
  identity and live target status synchronously on the main actor before mutation.
  For suggestions, require the current suggestion still pending with the opening
  word IDs/provenance, then call the existing `acceptCutSuggestion` validator on
  the original suggestion. Map `.stale/.invalid` to the existing message helpers.
  Use its successful original candidate only for validated identity/name; rebuild
  the final clip from the user's final range:

```swift
let finalSlice = buildSlice(
  id: target.resultingClipID,
  name: title,
  range: finalRange,
  wordIDs: wordIDs(anyOverlap: finalRange, words: editPlan.words),
  plan: editPlan)
```

Here `target`, `title`, and `finalRange` are the explicit session inputs to
`commitDraft(target:title:range:) -> ClipEditCommitResult`, introduced in
`EditorModel+DraftEditing.swift`. Validate the original candidate separately;
do not compare the edited clip's membership to the original suggestion's words.

- [ ] Insert `finalSlice` and accept its suggestion in one `mutateDocument`
  transaction. For a freeform draft insert one clip using the preallocated ID.
  Do not call the current `appendNewClip` or `acceptCutSuggestion(slice:id:)`
  insertion helpers, which apply offsets. Share their persistence/selection
  helpers only after extracting an explicit exact-bounds insertion path. Leave
  immediate Mark/Accept offset behavior unchanged. Duplicate commit attempts
  produce no second clip/history step. Select and reveal the committed clip.
- [ ] Add tests: one drag with many updates is one undo; two nudges are two;
  undo/redo retains committed inset anchors; unchanged drafts save; save failures
  keep range/history/sheet; cancel and invalidation leave the document unchanged;
  nonzero offsets apply once; edited suggestion membership may differ; stale,
  rejected, missing and replaced candidates cannot commit; accept/create each
  undo and redo atomically. Test previewed samples equal saved samples exactly.
- [ ] Run `ClipDraftHistoryTests`, `EditorDraftCommitTests`, `EditorClipOffsetTests`,
  `EditorSuggestionFlowTests`, `SliceEditKeyMonitorTests`, `EditUndoCommandsTests`,
  and existing `FineTuneTests`. Commit:
  `feat: isolate draft undo and save exact previewed clip boundaries`.

## Task 8: Reconcile identity, history, and transport across document changes

**Files:** Modify `Views/Pages/Editor/EditorModel.swift`, its three new extensions,
`Views/Pages/TranscriptPage/TranscriptOverlapModel.swift`, and
`Views/Pages/Editor/EditSlice/EditSliceModel.swift`.
Tests: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorGroupSelectionTests.swift`,
`EditorSelectionHistoryTests.swift`, `EditorDraftCommitTests.swift`,
`EditorDocumentMutationTests.swift`, `EditorTransportTests.swift`, and
`Project/ProjectHydrationTests.swift` under the same test root.

- [ ] Reconcile selected identity and chooser state after every document mutation
  and history restore, including non-undoable background suggestion production.
  Promote a selected accepted suggestion to its resulting clip; clear missing
  objects; keep rejected/accepted-without-clip rows historical. Recompute an
  object's range from live bounds; never infer its identity from equal ranges.
- [ ] Invalidate open drafts when their source identity or originating suggestion
  no longer matches. Preserve local adjustments and provide an explicit reason.
  Stop invalidated draft playback using existing generation-safe handoff methods.
  Cancel pending double-click captures for invalidated targets. Dismiss empty
  choosers without switching to an unrelated candidate.
- [ ] Ensure history selection restoration updates highlights/reveals but does
  not trigger ordinary selection-change playback policy for a pure highlight
  clear. A shared model method should identify whether a transition places the
  cursor, rather than relying only on `EditorView.onChange(audioSelection)`.
  Include selection origin/revision in deferred work so equal-range objects and
  later user actions cannot be confused.
- [ ] Update all direct range writers: waveform click/marquee, edge adjustment,
  transcript click/drag/Shift, sidebar reveal, explicit Clear, seam select, and
  history restore. Each chooses a selection kind deliberately and reconciles
  stale transcript anchors. Preserve waveform marquee's single placement on
  release and generation checks for concurrent playback actions.
- [ ] Test two editors sharing the same plan with independent selections/history;
  delete selected clip during playback; background regeneration while chooser
  or draft is open; undo accept back to pending; delete an accepted clip without
  reactivating its suggestion; pure highlight undo during playback; source change;
  and stale first-click capture followed by a different equal-range object.
- [ ] Run the named suites plus `EditorAreaSelectTests`, `EditorEditedCursorTests`,
  `EditorSlicePlaybackTests`, and `EditorEditSlicePresentationTests`.
  Commit: `fix: reconcile transcript selection across edits and playback`.

## Task 9: Complete integration and verify the native interaction

**Files:** Only fixes justified by the preceding tests/manual checks; add focused
regressions to their owning suites. Record results in
`.context/transcript-selection-verification.md`.

- [ ] Run each new focused suite after its owning task. At integration, run:

```sh
make test-fast
make format-check
make lint
```

Working directory: `QuickInterviewEditor/`. Expected: full Swift suite passes;
format/lint commands exit 0. If formatting changes are required, run `make format`,
inspect the diff for unrelated churn, and rerun checks affected by the edits.
If pushing later, run repository-required `make test` for CI parity before push.
No Python changes are expected, so do not run engine tests without a relevant change.

- [ ] Build/run the native app and prepare a local project with two overlapping
  clips, an identical-range suggestion, a nested suggestion, and a freeform range
  covering all of them. Use fixture data; do not spend API calls regenerating
  suggestions simply to exercise interaction.
- [ ] Verify these sequences in the main transcript and sidebar:
  1. Click A → card A revealed; double-click → editor A.
  2. Choose hidden B → B fully foreground; double-click overlap → editor B.
  3. Select B in sidebar → double-click transcript overlap → editor B.
  4. Re-click B after scrolling its card away → card reveals again, audio unchanged.
  5. Drag inside B → freeform range; Delete → highlight clears; Undo → exact range.
  6. Delete clip/suggestion → object disappears from transcript and sidebar; Undo restores and
     selects it; Redo removes it; timeline audio remains intact.
  7. Arrow/Shift-arrow on objects does nothing; arrows on freeform ranges nudge.
  8. Explicit Remove Section still edits timeline audio and remains undoable.
  9. Double-click suggestion/freeform → draft; undo boundary drag; redo; save
     unchanged or edited; validate final range and single document undo entry.
  10. Rename-field double-click selects text; buttons and title fields never open
      an unintended editor. Keyboard/menu Undo reach the same active owner.
- [ ] Check wrapping, inter-word spaces, empty margins, paragraph gaps, font zoom,
  pointer jitter, chooser hover, keyboard traversal and VoiceOver labels. Confirm
  panel switching does not move text during a double-click. Check native drag
  cancellation and Escape precedence. Check current-word highlighting remains
  legible with selected/previewed groups.
- [ ] Verify draft controls cannot change global removals through buttons, menus,
  shortcuts, context menus or seam handles. Existing saved-clip editing must retain
  those capabilities and its existing cancellation semantics.
- [ ] Inspect `git diff origin/main...` and the worktree diff for accidental
  document-schema, Python, persistence or dependency changes. Confirm new files
  are registered in Xcode and all changes remain within the approved feature.
- [ ] Commit final verified fixes, record exact commands/results and any manual
  limitations, and report completion. Do not claim native verification if the
  app could not be launched or interacted with.

## Plan self-review and coverage

| Requirement | Tasks |
| --- | --- |
| One selection identity and exact range | 1, 4, 8 |
| Stable single/double-click; drag selects | 4, 9 |
| Full overlaps, selected foreground, chooser | 1, 4, 5 |
| Sidebar scroll, filters, hidden suggestions | 5, 8 |
| Delete object/highlight with Undo | 2, 3, 8 |
| Object arrows inert; explicit audio removal | 3, 9 |
| Draft initialization, unchanged Save, visible errors | 6, 7 |
| Draft-local Undo and safe Cancel | 2, 6, 7 |
| Preview equals saved boundaries | 7 |
| Stale target and asynchronous lifecycle | 4, 6, 8 |
| Keyboard, menus, accessibility, text field precedence | 2, 3, 5, 7, 9 |
| Existing saved editor and transport behavior | 6, 8, 9 |
| No document schema/persistence changes | 1, 2, 8, 9 |

Implementation is sequential: identity precedes history/keyboard and rendering;
those precede the chooser and draft integration; reconciliation and native
verification finish the feature. Model decisions are tested without rendering;
real AppKit double-click timing and hit geometry also receive native verification.
