# Slice Detail Edit Modal — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Point-Free Workflow is mandatory.** Before writing code in ANY task, invoke every applicable `pfw-*` skill and list them in your checklist: `pfw-observable-models` (the `EditSliceModel`), `pfw-dependencies` (closures / injected clients), `pfw-testing` + `pfw-custom-dump` (all tests — use `expectNoDifference` / `expectDifference`, never raw `#expect(a == b)` for values), `pfw-modern-swiftui` (`EditSliceView` + `.sheet(item:)`), `pfw-sharing` (`@Shared` in tests declared locally), `pfw-identified-collections` (`IdentifiedArrayOf<Slice>`), `pfw-case-paths` (asserting `TransportContext` / `FineTuneModel.Target` cases).

**Goal:** Re-add sample-accurate slice boundary editing as a focused `.sheet` modal (slice-only waveform + transcript + the two zoomed Cut-in/Cut-out insets) so the main editor never reflows.

**Architecture:** A new `EditSliceModel` composes the existing (still-present) `FineTuneModel` for one slice, sources its waveform via a provider closure over `EditorModel.waveform` (so no audio reload), renders a slice-scoped `TranscriptPageModel` built from a filtered `EditPlan`, and delegates commit + the one global transport back to `EditorModel` via injected closures (same style as `CutSuggestionsPageModel.onAcceptSlice`). Presented via `.sheet(item: $model.editSlice)`.

**Tech Stack:** SwiftUI (AppKit for the existing waveform/transcript renderers), Point-Free `swift-dependencies` / `swift-sharing` / `swift-identified-collections` / `swift-custom-dump`, Swift Testing. XcodeGen-generated Xcode project.

**Spec:** `docs/superpowers/specs/2026-08-18-slice-detail-edit-modal-design.md`

## Global Constraints

- **MV + `@Observable`, zero logic in views.** Every string/flag/derived value lives on the model. Views only lay out and forward user actions. (`CLAUDE.md`)
- **Model structure:** `// MARK:` sections in order — Dependencies, Shared State, Initialization, Properties, View Helpers, User Actions, Private Helpers. Action methods named after the user action (`saveTapped`, not `commit`). No comments unless the code is not self-explanatory. Do not use `self` when not needed.
- **All coordinates are canonical PLAN samples.** Slice bounds: `startSample` inclusive, `endSample` exclusive.
- **Tests:** Swift Testing, colocated `…Tests.swift` in the same folder as the model. `@Shared` declared **locally inside each test** with an initial value. Mock dependencies via `withDependencies { … }`. **Never** `Task.sleep`. Value comparisons via `expectNoDifference` / `expectDifference`. Test-model variable is named `model`.
- **Test target must NOT directly link `Dependencies`/`DependenciesTestSupport`** — it gets them transitively. Direct linking causes silent `withDependencies` failures (double `@TaskLocal`). Only `CustomDump` is linked to the test target.
- **Build/test:** `cd QuickInterviewEditor && xcodegen generate` after adding files, then `bundle exec fastlane mac test` (or `xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates`). Swift Testing success is the `Test run with N tests … passed` line, not `Executed 0 tests`. Lint: `make lint` (in `QuickInterviewEditor/`). Format: `make format-check`.
- **Reuse, do not rewrite:** `FineTuneModel`, `FineTuneGeometry`, `FineTuneView`/`BoundaryInset`, `WaveformModel.columns(in:pixelWidth:)`, `TranscriptPageModel`/`TranscriptPageView`/`TranscriptTextView`, and the transport stack are all reused unchanged.

---

## Reference — existing APIs this plan consumes (verified)

- `Slice` (`Models/Slice.swift`): `struct Slice: Identifiable, Equatable, Codable { var id: UUID; var name: String; var startSample: Int; var endSample: Int; var wordIDs: [Word.ID]; var snippet: String; var warnings: [SliceWarning] }`. `Word.ID == Int` (`EditPlan.Word.id: Int`).
- `EditPlan` (`Models/EditPlan.swift`): `struct EditPlan: Codable, Equatable { var schemaVersion: Int; var source: Source; var words: [Word]; var silences: [Silence]; var segments: [Segment]; var transcriptSegments: [TranscriptSegment]? = nil }`. `Source` has `sampleRate: Int`, `durationSamples: Int`.
- `FineTuneModel` (`Views/Pages/Editor/FineTuneModel.swift`): `init(sampleRate:durationSamples:silences:)`; `enum Target { case pendingSelection; case slice(Slice.ID) }`; `func begin(target:range:)`, `markCommitted(_:)`, `resetDraft()`, `clear()`, `dragCutIn(toInsetX:)`, `dragCutOut(toInsetX:)`, `nudgeCutIn(byMs:)`, `nudgeCutOut(byMs:)`; `var draftRange: Range<Int>?`, `committedRange: Range<Int>?`, `hasUnsavedChange: Bool`, `cutInWindow`/`cutOutWindow: Range<Int>?`, `let insetWidthPixels: CGFloat = 252`; display text `cutInLabel`, `cutOutLabel`, `helperText`, `commitLabel`, `cancelLabel`, `nudgeBackLabel`, `nudgeForwardLabel`, `previewEditLabel`, `previewStopLabel`, time readouts, warning/safe-zone spans.
- `WaveformModel` (`Views/Pages/Editor/WaveformModel.swift`): `func columns(in window: Range<Int>, pixelWidth: CGFloat) -> [WaveformColumn]` (renders an arbitrary sample window at fixed pixel width off the loaded pyramid; does not touch the main viewport).
- `TranscriptPageModel` (`Views/Pages/TranscriptPage/TranscriptPageModel.swift`): `convenience init(editPlan: EditPlan)`; drives `TranscriptPageView`. `func playheadChanged(sample:isPlaying:)` moves current-word/scroll.
- `EditorModel` (`Views/Pages/Editor/EditorModel.swift`): `let editPlan: EditPlan`; `var waveform: WaveformModel`; `var slices: IdentifiedArrayOf<Slice>`; `func mutateSlices(_:)` (undo-tracked funnel); `private func updatedSlice(_ slice:to range:) -> Slice` (recomputes `wordIDs` via `wordIDs(overlapping:words:)`, snippet, warnings); `func wordIDs(overlapping:words:)`; `private func beginTransportPlayback(range:context:)`; `func transportPauseTapped()`, `transportStopTapped()`; `var transportPhase`, `var transportContext: TransportContext`, `var playheadSample: Int?`; `func observePlayback()` position loop (~line 376). `enum TransportContext { case free; case slice(Slice.ID); case draftPreview; case audition(AuditionMode) }` (~line 1539).
- Sheet precedent: `.sheet(item: $model.keyEntry) { SettingsView(model: $0) }` (`CutSuggestionsPageView.swift`), backed by an optional `@Observable` child model.

---

## Task 1: EditorModel — reusable `commitSliceEdit` + `.sliceEdit` transport context

Foundation the modal commits and previews through. Pure refactor + additive enum case; no behavior change to existing flows.

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift` (`commitEditTapped` ~1169-1189, `TransportContext` ~1539, its `isSlice`/`followsTranscript` helpers)
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorSliceCommitTests.swift` (new; match the existing test folder layout used by `EditorFineTuneTests.swift`)

**Interfaces:**
- Produces: `func commitSliceEdit(id: Slice.ID, range: Range<Int>)` on `EditorModel` — recomputes the slice's `wordIDs`/snippet/warnings for `range` and records exactly one undo entry. `TransportContext.sliceEdit` case.

- [ ] **Step 1: Write the failing test**

Create `EditorSliceCommitTests.swift`:

```swift
import CustomDump
import Testing

@testable import QuickInterviewEditor

@MainActor
struct EditorSliceCommitTests {
  @Test func commitSliceEditMovesBoundariesAndRecomputesWords() {
    let model = EditorModel.testModel()          // fixture-backed editor (see helper below)
    let original = model.slices.elements[0]
    let newRange = (original.startSample + 4_000)..<(original.endSample)

    model.commitSliceEdit(id: original.id, range: newRange)

    let updated = model.slices[id: original.id]
    #expect(updated?.startSample == newRange.lowerBound)
    #expect(updated?.endSample == newRange.upperBound)
    // wordIDs recomputed from the range, not left at the old set:
    expectNoDifference(
      updated?.wordIDs, model.wordIDs(overlapping: newRange, words: model.editPlan.words))
  }

  @Test func commitSliceEditRecordsExactlyOneUndoEntry() {
    let model = EditorModel.testModel()
    let slice = model.slices.elements[0]
    let depthBefore = model.sliceUndo.undoDepth   // add a read-only depth accessor if absent

    model.commitSliceEdit(id: slice.id, range: slice.startSample..<(slice.endSample - 2_000))

    #expect(model.sliceUndo.undoDepth == depthBefore + 1)
  }
}
```

If `EditorModel.testModel()` / `sliceUndo.undoDepth` don't exist yet, add them minimally in this step: a static test helper that builds an `EditorModel` from the bundled `edit-plan.json` fixture with one seeded slice (mirror how `EditorFineTuneTests` constructs its model — reuse that helper if present rather than duplicating), and a read-only `var undoDepth: Int` on `UndoStack`.

- [ ] **Step 2: Run the test, verify it fails**

Run: `cd QuickInterviewEditor && xcodegen generate && bundle exec fastlane mac test`
Expected: FAIL — `commitSliceEdit` / `.sliceEdit` undefined (compile error is a valid red).

- [ ] **Step 3: Extract `commitSliceEdit` and call it from `commitEditTapped`**

In `EditorModel.swift`, add:

```swift
func commitSliceEdit(id: Slice.ID, range: Range<Int>) {
  guard slices[id: id] != nil else { return }
  mutateSlices { slices in
    if let slice = slices[id: id] { slices[id: id] = updatedSlice(slice, to: range) }
  }
}
```

Replace the `.slice(let id)` arm of `commitEditTapped` (the `mutateSlices { … updatedSlice … }` block) with `commitSliceEdit(id: id, range: draft)` followed by the existing `fineTune.markCommitted(draft)`.

- [ ] **Step 4: Add the `.sliceEdit` transport context**

In `enum TransportContext`, add `case sliceEdit`. Give it the same treatment as `.draftPreview` in the computed helpers: `isSlice` returns `false` for it (no slice-row highlight), and `followsTranscript` returns `false` (the main transcript must not move while the modal previews). Update any exhaustive `switch` the compiler flags.

- [ ] **Step 5: Run tests, verify pass**

Run: `cd QuickInterviewEditor && bundle exec fastlane mac test`
Expected: PASS (new tests green; existing `EditorFineTuneTests` still green).

- [ ] **Step 6: Lint + commit**

```bash
cd QuickInterviewEditor && make lint && make format-check
git add QuickInterviewEditor
git commit -m "feat(editor): extract commitSliceEdit + add .sliceEdit transport context"
```

---

## Task 2: `EditSliceModel` — session lifecycle (open / draft / save / cancel)

The model core: composes `FineTuneModel`, exposes save/cancel gated on unsaved changes, commits via an injected closure.

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditSlice/EditSliceModel.swift`
- Test: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditSlice/EditSliceTests.swift`

**Interfaces:**
- Consumes: `FineTuneModel`, `EditPlan`, `Slice`.
- Produces: `final class EditSliceModel: ViewModel, Identifiable`. Init `init(slice: Slice, editPlan: EditPlan)`. Closures (default no-ops, set by parent): `var onCommit: (Range<Int>) -> Void`, `var onDismiss: () -> Void`. Properties: `let sliceID: Slice.ID`, `let fineTune: FineTuneModel`, `var title: String`. Actions: `func saveTapped()`, `func cancelTapped()`, drag/nudge forwarders. View helpers: `var canSave: Bool`, display text.

- [ ] **Step 1: Write the failing tests**

Create `EditSlice/EditSliceTests.swift`:

```swift
import CustomDump
import Testing

@testable import QuickInterviewEditor

@MainActor
struct EditSliceTests {
  private func makeModel() -> (EditSliceModel, EditPlan, Slice) {
    let plan = EditPlan.fixture                       // bundled edit-plan.json (see helper note)
    let slice = Slice(
      id: UUID(0), name: "Slice 1",
      startSample: 10_000, endSample: 40_000,
      wordIDs: [], snippet: "", warnings: [])
    return (EditSliceModel(slice: slice, editPlan: plan), plan, slice)
  }

  @Test func openingBeginsSessionOnCommittedRange() {
    let (model, _, slice) = makeModel()
    #expect(model.fineTune.committedRange == slice.startSample..<slice.endSample)
    #expect(model.fineTune.draftRange == slice.startSample..<slice.endSample)
    #expect(model.canSave == false)               // no change yet
  }

  @Test func draggingMutatesDraftOnly_savingCommitsOnce() {
    let (model, _, _) = makeModel()
    var committed: [Range<Int>] = []
    model.onCommit = { committed.append($0) }

    model.fineTune.nudgeCutIn(byMs: 10)           // move the draft
    #expect(model.canSave == true)
    let draft = model.fineTune.draftRange

    model.saveTapped()

    expectNoDifference(committed, [draft].compactMap { $0 })
  }

  @Test func cancelDoesNotCommit_andDismisses() {
    let (model, _, _) = makeModel()
    var committed = 0
    var dismissed = 0
    model.onCommit = { _ in committed += 1 }
    model.onDismiss = { dismissed += 1 }

    model.fineTune.nudgeCutOut(byMs: -10)
    model.cancelTapped()

    #expect(committed == 0)
    #expect(dismissed == 1)
  }
}
```

Note on fixtures: reuse the existing `EditPlan.fixture` / edit-plan.json loader the current tests use (search the test target for how `EditorFineTuneTests` obtains a plan). If no `EditPlan.fixture` exists, add a tiny test helper that decodes the bundled `Resources/Fixtures/edit-plan.json`. Do not invent plan data inline.

- [ ] **Step 2: Run tests, verify they fail**

Run: `cd QuickInterviewEditor && xcodegen generate && bundle exec fastlane mac test`
Expected: FAIL — `EditSliceModel` undefined.

- [ ] **Step 3: Implement `EditSliceModel` (lifecycle only)**

```swift
import Foundation
import Observation

@MainActor
@Observable
final class EditSliceModel: ViewModel, Identifiable {

  // MARK: - Initialization
  let sliceID: Slice.ID
  let fineTune: FineTuneModel

  init(slice: Slice, editPlan: EditPlan) {
    sliceID = slice.id
    title = slice.name
    fineTune = FineTuneModel(
      sampleRate: editPlan.source.sampleRate,
      durationSamples: editPlan.source.durationSamples,
      silences: editPlan.silences)
    super.init()
    fineTune.begin(target: .slice(slice.id), range: slice.startSample..<slice.endSample)
  }

  // MARK: - Properties
  let title: String
  var onCommit: (Range<Int>) -> Void = { _ in }
  var onDismiss: () -> Void = {}

  // MARK: - Display Text
  let saveLabel = "Save cut"
  let cancelLabel = "Cancel"

  // MARK: - View Helpers
  var canSave: Bool { fineTune.hasUnsavedChange }

  // MARK: - User Actions
  func saveTapped() {
    guard let draft = fineTune.draftRange, fineTune.hasUnsavedChange else {
      onDismiss()
      return
    }
    onCommit(draft)
    onDismiss()
  }

  func cancelTapped() {
    fineTune.resetDraft()
    onDismiss()
  }

  func cutInDragged(toInsetX x: CGFloat) { fineTune.dragCutIn(toInsetX: x) }
  func cutOutDragged(toInsetX x: CGFloat) { fineTune.dragCutOut(toInsetX: x) }
  func cutInNudged(byMs ms: Double) { fineTune.nudgeCutIn(byMs: ms) }
  func cutOutNudged(byMs ms: Double) { fineTune.nudgeCutOut(byMs: ms) }
}
```

(Do NOT implement `id` — `Identifiable` uses synthesized object identity per `pfw-observable-models`.)

- [ ] **Step 4: Run tests, verify pass**

Run: `cd QuickInterviewEditor && bundle exec fastlane mac test`
Expected: PASS.

- [ ] **Step 5: Lint + commit**

```bash
cd QuickInterviewEditor && make lint && make format-check
git add QuickInterviewEditor
git commit -m "feat(editor): EditSliceModel session lifecycle (draft/save/cancel)"
```

---

## Task 3: `EditSliceModel` — scoped waveform columns + scoped transcript

Adds the slice-only overview waveform (edge-to-edge, fixed committed window), the two inset column providers, and the slice-scoped transcript.

**Files:**
- Modify: `EditSlice/EditSliceModel.swift`
- Modify: `EditSlice/EditSliceTests.swift`

**Interfaces:**
- Consumes: `WaveformColumn`, `WaveformModel.columns(in:pixelWidth:)` (via injected provider), `TranscriptPageModel`.
- Produces: `var columnsProvider: (Range<Int>, CGFloat) -> [WaveformColumn]`; `let transcript: TranscriptPageModel`; `var overviewWindow: Range<Int>`; `func overviewColumns(pixelWidth: CGFloat) -> [WaveformColumn]`; `func cutInColumns() -> [WaveformColumn]`; `func cutOutColumns() -> [WaveformColumn]`.

- [ ] **Step 1: Write the failing tests**

Add to `EditSliceTests.swift`:

```swift
@Test func scopedTranscriptContainsExactlyTheSliceWords() {
  let plan = EditPlan.fixture
  let sliceWordIDs = Array(plan.words.prefix(3).map(\.id))
  let slice = Slice(
    id: UUID(1), name: "S", startSample: 0, endSample: 20_000,
    wordIDs: sliceWordIDs, snippet: "", warnings: [])
  let model = EditSliceModel(slice: slice, editPlan: plan)

  expectNoDifference(
    model.transcript.document.wordRanges.map(\.wordID), sliceWordIDs)
}

@Test func overviewWindowIsTheCommittedSliceRange() {
  let plan = EditPlan.fixture
  let slice = Slice(
    id: UUID(2), name: "S", startSample: 5_000, endSample: 25_000,
    wordIDs: [], snippet: "", warnings: [])
  let model = EditSliceModel(slice: slice, editPlan: plan)
  #expect(model.overviewWindow == 5_000..<25_000)
}

@Test func overviewColumnsAskTheProviderForTheOverviewWindow() {
  let plan = EditPlan.fixture
  let slice = Slice(
    id: UUID(3), name: "S", startSample: 5_000, endSample: 25_000,
    wordIDs: [], snippet: "", warnings: [])
  let model = EditSliceModel(slice: slice, editPlan: plan)
  var asked: [Range<Int>] = []
  model.columnsProvider = { window, _ in asked.append(window); return [] }

  _ = model.overviewColumns(pixelWidth: 600)

  expectNoDifference(asked, [5_000..<25_000])
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `cd QuickInterviewEditor && bundle exec fastlane mac test`
Expected: FAIL — `columnsProvider`/`transcript`/`overviewWindow` undefined.

- [ ] **Step 3: Implement the scoped providers**

In `EditSliceModel`, capture the committed range and build the scoped transcript in `init` (after `super.init()`):

```swift
// MARK: - Properties  (add)
let overviewWindow: Range<Int>
let transcript: TranscriptPageModel
var columnsProvider: (Range<Int>, CGFloat) -> [WaveformColumn] = { _, _ in [] }
```

In `init`, before `fineTune.begin(...)`:

```swift
overviewWindow = slice.startSample..<slice.endSample
let idSet = Set(slice.wordIDs)
let scopedWords = editPlan.words.filter { idSet.contains($0.id) }
let scopedPlan = EditPlan(
  schemaVersion: editPlan.schemaVersion,
  source: editPlan.source,
  words: scopedWords,
  silences: editPlan.silences,
  segments: editPlan.segments,
  transcriptSegments: editPlan.transcriptSegments)
transcript = TranscriptPageModel(editPlan: scopedPlan)
```

(Set stored `let`s before `super.init()` per Swift init rules; reorder as the compiler requires. `TranscriptPageModel(editPlan:)` is safe to build here — its `convenience init` does not touch the engine.)

View helpers:

```swift
// MARK: - View Helpers  (add)
func overviewColumns(pixelWidth: CGFloat) -> [WaveformColumn] {
  columnsProvider(overviewWindow, pixelWidth)
}
func cutInColumns() -> [WaveformColumn] {
  fineTune.cutInWindow.map { columnsProvider($0, fineTune.insetWidthPixels) } ?? []
}
func cutOutColumns() -> [WaveformColumn] {
  fineTune.cutOutWindow.map { columnsProvider($0, fineTune.insetWidthPixels) } ?? []
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `cd QuickInterviewEditor && bundle exec fastlane mac test`
Expected: PASS. (If `document.wordRanges`/`wordID` names differ, align the assertion to the real `TranscriptDocument` API — see `TranscriptPageModel`.)

- [ ] **Step 5: Lint + commit**

```bash
cd QuickInterviewEditor && make lint && make format-check
git add QuickInterviewEditor
git commit -m "feat(editor): EditSliceModel scoped waveform + slice transcript"
```

---

## Task 4: `EditSliceModel` — transport (play / pause / stop / seek + playhead)

Full transport scoped to the slice, delegated to the one global transport via closures, with a playhead the parent pushes in.

**Files:**
- Modify: `EditSlice/EditSliceModel.swift`
- Modify: `EditSlice/EditSliceTests.swift`

**Interfaces:**
- Produces: closures `var onPlay: (Range<Int>) async -> Void`, `var onPause: () async -> Void`, `var onStop: () async -> Void`, `var onSeek: (Int) async -> Void`; state `var isPlaying: Bool`, `var playheadSample: Int?`; `func updatePlayback(sample: Int?, isPlaying: Bool)`; actions `func playPauseTapped() async`, `func stopTapped() async`, `func seekTapped(toSample: Int) async`; helpers `var playPauseLabel: String`, `var playButtonSystemImage: String`.

- [ ] **Step 1: Write the failing tests**

Add to `EditSliceTests.swift`:

```swift
@Test func playTappedPlaysTheDraftRange() async {
  let (model, _, slice) = makeModel()
  var played: [Range<Int>] = []
  model.onPlay = { played.append($0) }

  await model.playPauseTapped()

  expectNoDifference(played, [slice.startSample..<slice.endSample])
}

@Test func playTappedUsesTheLiveDraftAfterNudging() async {
  let (model, _, _) = makeModel()
  var played: [Range<Int>] = []
  model.onPlay = { played.append($0) }
  model.fineTune.nudgeCutIn(byMs: 20)
  let draft = model.fineTune.draftRange

  await model.playPauseTapped()

  expectNoDifference(played, [draft].compactMap { $0 })
}

@Test func playTappedWhilePlayingPauses() async {
  let (model, _, _) = makeModel()
  var pauses = 0
  model.onPause = { pauses += 1 }
  model.updatePlayback(sample: 12_000, isPlaying: true)

  await model.playPauseTapped()

  #expect(pauses == 1)
}

@Test func updatePlaybackReflectsPlayheadAndDrivesScopedTranscript() {
  let (model, _, _) = makeModel()
  model.updatePlayback(sample: 15_000, isPlaying: true)
  #expect(model.playheadSample == 15_000)
  #expect(model.isPlaying == true)
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `cd QuickInterviewEditor && bundle exec fastlane mac test`
Expected: FAIL — transport members undefined.

- [ ] **Step 3: Implement transport**

Add to `EditSliceModel`:

```swift
// MARK: - Properties  (add)
var onPlay: (Range<Int>) async -> Void = { _ in }
var onPause: () async -> Void = {}
var onStop: () async -> Void = {}
var onSeek: (Int) async -> Void = { _ in }
var isPlaying = false
var playheadSample: Int?

// MARK: - View Helpers  (add)
var playPauseLabel: String { isPlaying ? "Pause" : "Play" }
var playButtonSystemImage: String { isPlaying ? "pause.fill" : "play.fill" }

// MARK: - User Actions  (add)
func playPauseTapped() async {
  if isPlaying {
    await onPause()
  } else if let range = fineTune.draftRange ?? fineTune.committedRange {
    await onPlay(range)
  }
}
func stopTapped() async { await onStop() }
func seekTapped(toSample sample: Int) async { await onSeek(sample) }

/// Called by EditorModel's position loop while `.sliceEdit` is the transport context.
func updatePlayback(sample: Int?, isPlaying: Bool) {
  playheadSample = sample
  self.isPlaying = isPlaying
  transcript.playheadChanged(sample: sample, isPlaying: isPlaying)
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `cd QuickInterviewEditor && bundle exec fastlane mac test`
Expected: PASS.

- [ ] **Step 5: Lint + commit**

```bash
cd QuickInterviewEditor && make lint && make format-check
git add QuickInterviewEditor
git commit -m "feat(editor): EditSliceModel transport (play/pause/stop/seek + playhead)"
```

---

## Task 5: `EditorModel` — present the modal + wire commit / transport / playhead

Connects `EditSliceModel` to the editor: builds and presents it, wires every closure to real editor behavior, and pushes the playhead in during `.sliceEdit` playback.

**Files:**
- Modify: `EditorModel.swift` (add `editSlice` state + `editSliceTapped`; extend `observePlayback` to push into `editSlice`)
- Test: `EditorSliceCommitTests.swift` (extend) or a new `EditorEditSlicePresentationTests.swift`

**Interfaces:**
- Produces: `var editSlice: EditSliceModel?` on `EditorModel`; `func editSliceTapped(_ id: Slice.ID)`.

- [ ] **Step 1: Write the failing tests**

Add:

```swift
@Test func editSliceTappedPresentsModelForThatSlice() {
  let model = EditorModel.testModel()
  let slice = model.slices.elements[0]

  model.editSliceTapped(slice.id)

  #expect(model.editSlice?.sliceID == slice.id)
  #expect(model.editSlice?.fineTune.committedRange == slice.startSample..<slice.endSample)
}

@Test func modalSaveCommitsThroughEditorAndDismisses() {
  let model = EditorModel.testModel()
  let slice = model.slices.elements[0]
  model.editSliceTapped(slice.id)
  let child = model.editSlice!

  child.fineTune.nudgeCutIn(byMs: 30)
  let draft = child.fineTune.draftRange!
  child.saveTapped()

  #expect(model.slices[id: slice.id]?.startSample == draft.lowerBound)
  #expect(model.editSlice == nil)                 // dismissed
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `cd QuickInterviewEditor && bundle exec fastlane mac test`
Expected: FAIL — `editSlice`/`editSliceTapped` undefined.

- [ ] **Step 3: Implement presentation + wiring**

In `EditorModel`, add a property near the other child models:

```swift
var editSlice: EditSliceModel?
```

Add the action (place in a `// MARK: - User Actions` region near `sliceRevealTapped`):

```swift
func editSliceTapped(_ id: Slice.ID) {
  guard let slice = slices[id: id], !fineTune.hasUnsavedChange else { return }
  let child = EditSliceModel(slice: slice, editPlan: editPlan)
  child.columnsProvider = { [weak self] window, width in
    self?.waveform.columns(in: window, pixelWidth: width) ?? []
  }
  child.onCommit = { [weak self] range in self?.commitSliceEdit(id: id, range: range) }
  child.onPlay = { [weak self] range in
    await self?.beginTransportPlayback(range: range, context: .sliceEdit)
  }
  child.onPause = { [weak self] in await self?.transportPauseTapped() }
  child.onStop = { [weak self] in await self?.transportStopTapped() }
  child.onSeek = { [weak self] sample in
    await self?.beginTransportPlayback(range: sample..<(sample + 1), context: .sliceEdit)
  }
  child.onDismiss = { [weak self] in
    Task { await self?.transportStopTapped() }
    self?.editSlice = nil
  }
  editSlice = child
}
```

(If `beginTransportPlayback` is `private`, either relax it to internal or add a thin internal wrapper `func playRange(_:context:)` — do NOT duplicate its body. `onSeek`'s 1-sample range is a placeholder "move the cursor here"; if the transport exposes a dedicated seek/cursor API, call that instead and update the test accordingly.)

Extend `observePlayback` — inside the `if position.isPlaying { … }` branch, after `playheadSample = position.sample`, push into the modal when it owns playback:

```swift
if case .sliceEdit = transportContext {
  editSlice?.updatePlayback(sample: position.sample, isPlaying: true)
}
```

And in the `else if transportContext.followsTranscript { … }` sibling (false-tick path), add a parallel branch so the modal reflects a stop: `if case .sliceEdit = transportContext { editSlice?.updatePlayback(sample: playheadSample, isPlaying: false) }`.

- [ ] **Step 4: Run tests, verify pass**

Run: `cd QuickInterviewEditor && bundle exec fastlane mac test`
Expected: PASS.

- [ ] **Step 5: Lint + commit**

```bash
cd QuickInterviewEditor && make lint && make format-check
git add QuickInterviewEditor
git commit -m "feat(editor): present EditSlice modal and wire commit/transport/playhead"
```

---

## Task 6: `EditSliceView` — the sheet (visuals only)

Pure SwiftUI. Reuses `FineTuneView`/`BoundaryInset` for the insets, `TranscriptPageView` for the scoped transcript, and a waveform band for the overview. No unit test (the view holds no logic); verified by build + manual QA.

**Files:**
- Create: `EditSlice/EditSliceView.swift`
- Modify: the editor view that owns the sheet — `Views/Pages/Editor/EditorView.swift` (add `.sheet(item:)`)

- [ ] **Step 1: Build the view**

Invoke `pfw-modern-swiftui` first. Structure (mirror the main window's vertical order — transcript on top, waveform below — then insets + transport + Save/Cancel):

```swift
import SwiftUI

struct EditSliceView: View {
  @State var model: EditSliceModel      // or `let` per pfw-modern-swiftui guidance for reference types

  var body: some View {
    VStack(spacing: 12) {
      Text(model.title).font(.headline)

      TranscriptPageView(model: model.transcript)
        .frame(minHeight: 160)

      Divider()

      // Overview slice waveform band, edge-to-edge. Reuse the main waveform's
      // canvas/silhouette drawing driven by `model.overviewColumns(pixelWidth:)`
      // and `model.playheadSample`; click-to-seek → `Task { await model.seekTapped(toSample:) }`.
      SliceOverviewWaveform(model: model)
        .frame(height: 120)

      // The two zoomed edge insets — reuse FineTuneView (or BoundaryInset) bound to
      // `model.fineTune`, `model.cutInColumns()`, `model.cutOutColumns()`, forwarding
      // drag/nudge to `model.cutInDragged`/`cutOutDragged`/`cutInNudged`/`cutOutNudged`.
      FineTuneInsets(model: model)

      HStack {
        Button {
          Task { await model.playPauseTapped() }
        } label: { Image(systemName: model.playButtonSystemImage) }
        Button("Stop") { Task { await model.stopTapped() } }
        Spacer()
        Button(model.cancelLabel) { model.cancelTapped() }
        Button(model.saveLabel) { model.saveTapped() }
          .keyboardShortcut(.defaultAction)
          .disabled(!model.canSave)
      }
    }
    .padding()
    .frame(minWidth: 720, minHeight: 560)
  }
}
```

`SliceOverviewWaveform` and `FineTuneInsets` are small private subviews (or reuse `FineTuneView`/`BoundaryInset`/the main `WaveformCanvas` directly if their inputs already match). Keep them dumb — every value from `model`. If reusing `FineTuneView` wholesale is awkward because it assumed `EditorModel`, extract the shared `BoundaryInset` rendering into a subview that takes plain inputs (columns, line X, spans, labels) so both the old pane and this modal bind to it — a targeted refactor, not a rewrite.

- [ ] **Step 2: Present it from the editor view**

In `EditorView.swift`, add to the editor's root:

```swift
.sheet(item: $model.editSlice) { EditSliceView(model: $0) }
```

- [ ] **Step 3: Regenerate + build**

Run: `cd QuickInterviewEditor && xcodegen generate && bundle exec fastlane mac test`
Expected: builds and all tests pass.

- [ ] **Step 4: Lint + commit**

```bash
cd QuickInterviewEditor && make lint && make format-check
git add QuickInterviewEditor
git commit -m "feat(editor): EditSliceView sheet (waveform + transcript + insets + transport)"
```

---

## Task 7: `SlicesPanelView` — Edit button + double-click entry points

Both open the modal via `editSliceTapped(id)`.

**Files:**
- Modify: `Views/Pages/Editor/SlicesPanelView.swift` (the `SliceCard`)

- [ ] **Step 1: Add the entry points**

On each `SliceCard`, add an "Edit" button (label from a model-provided string — add `let editSliceLabel = "Edit"` on `EditorModel` rather than hardcoding) calling `model.editSliceTapped(slice.id)`, and a double-click gesture on the card:

```swift
.simultaneousGesture(TapGesture(count: 2).onEnded { model.editSliceTapped(slice.id) })
```

Remove the deferred-"Edit cuts" marker comment (lines ~127-129) now that the entry point exists again.

- [ ] **Step 2: Regenerate + build + verify**

Run: `cd QuickInterviewEditor && xcodegen generate && bundle exec fastlane mac test`
Expected: green. (Behavior is covered by Task 5's model tests; this is view wiring.)

- [ ] **Step 3: Lint + commit**

```bash
cd QuickInterviewEditor && make lint && make format-check
git add QuickInterviewEditor
git commit -m "feat(editor): open EditSlice modal from slice card (button + double-click)"
```

---

## Task 8: Full green + manual QA pass

**Files:** none (verification only)

- [ ] **Step 1: Regenerate, full test, lint, format**

```bash
cd QuickInterviewEditor && xcodegen generate
bundle exec fastlane mac test
make lint && make format-check
```
Expected: `Test run with N tests … passed`, no lint/format issues.

- [ ] **Step 2: Manual QA (main surface must never move)**

Launch the dev app (per the build memo: `launchctl setenv QIE_ENGINE_REPO "$(git rev-parse --show-toplevel)"` then `open "$(xcodebuild -scheme QuickInterviewEditor -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}')/QuickInterviewEditor.app"`). Verify:
  - Opening/closing the modal (Edit button AND double-click) does not shift the main waveform/transcript at all.
  - Overview waveform shows the slice edge-to-edge; the two insets drag + nudge (±10 ms), snap to silence, redden on tight cuts.
  - Play/Pause/Stop plays the slice; the playhead tracks in the overview and the scoped transcript highlights the current word.
  - Save moves the slice's boundaries (row range/duration update) and is a single undo; Cancel discards. Save disabled until a change.

- [ ] **Step 3: Adversarial review (per CLAUDE.md pipeline)**

This is real product logic across several files → run the Codex adversarial pass: `codex` skill review mode then challenge mode on the branch diff. Fix anything surfaced; re-run if fixes were non-trivial.

- [ ] **Step 4: Final commit if QA fixes were needed**, then hand off to `/ship`.

---

## Self-Review (completed by plan author)

- **Spec coverage:** overview waveform + transcript + insets (Tasks 3, 6); both open paths (Task 7); edge-to-edge overview (Task 3, `overviewWindow`); full transport (Task 4); commit reuses `updatedSlice`/undo (Task 1); `.sheet(item:)` (Task 6); `TransportContext.sliceEdit` (Task 1); draft-only-until-Save + no per-frame word recompute (Tasks 2/4 test the draft-only invariant; the transcript is built once in Task 3). Out-of-scope items are not implemented. ✅
- **Placeholder scan:** every code step has real code; the two soft spots (private `beginTransportPlayback` visibility; exact `TranscriptDocument`/seek API names) are called out with a concrete fallback, not left vague. ✅
- **Type consistency:** `commitSliceEdit(id:range:)`, `editSliceTapped(_:)`, `columnsProvider`, `overviewColumns(pixelWidth:)`, `updatePlayback(sample:isPlaying:)`, `onCommit/onPlay/onPause/onStop/onSeek/onDismiss` are used identically across tasks. `Word.ID == Int`, `Slice` fields, and `FineTuneModel`/`WaveformModel` signatures match the verified reference section. ✅
