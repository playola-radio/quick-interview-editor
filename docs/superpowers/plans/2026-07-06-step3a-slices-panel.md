# Step 3a — Slices Model + Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **Before writing any Swift code, invoke every applicable `pfw-*` skill** (see CLAUDE.md mapping) and list them in your checklist.

**Goal:** Turn the two-click transcript selection into named **slices** collected in a panel (rename, reorder, delete, play) — pure Swift, no engine change, fully tested against the committed `edit-plan.json` fixture. Export lands in Step 3b.

**Architecture:** A sample-native `Slice` value type; tight-join warnings derived from `editPlan.silences` (cut-safety, distinct from the transcript's run-together slider); a new `EditorModel` that owns the loaded editor (a `TranscriptPageModel` + the `slices`) so `SongTabModel` keeps only the transcription lifecycle; a mockable `AudioPlayerClient` that plays the **source** audio range for preview. Views stay logic-free.

**Tech Stack:** Swift 6 / SwiftUI (macOS 15), Point-Free stack (`swift-dependencies`, `swift-identified-collections`, `swift-custom-dump`, `IssueReporting`), Swift Testing, XcodeGen, AVFoundation (live playback only).

## Global Constraints

- **Build/test the app:** `cd QuickInterviewEditor && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates`.
- **After creating/renaming any file under `QuickInterviewEditor/`**, run `cd QuickInterviewEditor && xcodegen generate` before `xcodebuild`, and commit the regenerated `.xcodeproj` with the task.
- **Test target must NOT directly link `swift-dependencies`** — it gets `Dependencies` transitively via the app target + `@testable import`. Do not add it to `project.yml`'s test target (breaks `withDependencies` overrides). Test target links only `CustomDump`.
- **Value comparisons in tests** use `expectNoDifference` / `expectDifference` (CustomDump), never raw `#expect(a == b)`.
- **Never use `Task.sleep` in tests.** Actions that need awaiting are `async` and are awaited directly; use recording test doubles that resolve immediately.
- **Test naming:** camelCase, no underscores. Tests colocate next to the model.
- **Signing:** `DEVELOPMENT_TEAM: FSRSPV9N9Q` (already in `project.yml`); always `-allowProvisioningUpdates`.
- **Lint/format (CI-enforced):** `make lint` (SwiftLint `--strict`) and `make format-check` (`xcrun swift-format lint`) must be green. `.swiftlint.yml` allows 2-deep type nesting; avoid single-char locals; use `model` as the test model variable.
- **MV rule:** zero logic in views. Every string/flag/decision is a model property. Models are `@MainActor @Observable`, inherit `ViewModel`, and follow the CLAUDE.md `// MARK:` order.
- **All coordinates in samples.** Display strings (durations, timecodes) are computed on the model.
- **Out of scope (3a):** the engine `render` command, `EngineClient.renderSlices`, export/copy/reveal, `WorkspaceClient`, destination picker (all Step 3b); waveform, undo/redo, transport/zoom.

---

## Task 1: `Slice` value type, `sliceWarnings`, and timecode formatting

Pure value types + pure functions, no UI. `Slice` is sample-native; `sliceWarnings` derives tight-join flags from silence regions; the timecode helpers format sample counts for display.

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Models/Slice.swift`
- Create: `QuickInterviewEditor/QuickInterviewEditor/Models/SliceWarnings.swift`
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Models/SliceWarningsTests.swift`

**Interfaces:**
- Produces:
  - `struct Slice: Identifiable, Equatable, Codable { var id: UUID; var name: String; var startSample: Int; var endSample: Int; var wordIDs: [Word.ID]; var snippet: String; var warnings: [SliceWarning] }`
  - `enum SliceWarning: String, Equatable, Codable { case tightStart; case tightEnd }`
  - `func sliceWarnings(startSample: Int, endSample: Int, durationSamples: Int, silences: [EditPlan.Silence]) -> [SliceWarning]`
  - `func sampleTimecodeLabel(_ samples: Int, sampleRate: Int) -> String` → `"M:SS.d"` (e.g. `"0:05.9"`)
  - `func sampleDurationLabel(_ samples: Int, sampleRate: Int) -> String` → `"3.2s"`

- [ ] **Step 1: Write the failing test** — `SliceWarningsTests.swift`:

```swift
import CustomDump
import Testing
@testable import QuickInterviewEditor

struct SliceWarningsTests {
  private func silence(_ start: Int, _ end: Int) -> EditPlan.Silence {
    EditPlan.Silence(startSample: start, endSample: end)
  }

  @Test func noWarningsWhenSilenceTouchesBothCuts() {
    // silence [900,1000) ends at startSample 1000; silence [2000,2100) starts at endSample 2000
    let warnings = sliceWarnings(
      startSample: 1000, endSample: 2000, durationSamples: 5000,
      silences: [silence(900, 1000), silence(2000, 2100)])
    expectNoDifference(warnings, [])
  }

  @Test func tightStartWhenNoSilenceAtStartCut() {
    let warnings = sliceWarnings(
      startSample: 1000, endSample: 2000, durationSamples: 5000,
      silences: [silence(2000, 2100)])
    expectNoDifference(warnings, [.tightStart])
  }

  @Test func tightEndWhenNoSilenceAtEndCut() {
    let warnings = sliceWarnings(
      startSample: 1000, endSample: 2000, durationSamples: 5000,
      silences: [silence(900, 1000)])
    expectNoDifference(warnings, [.tightEnd])
  }

  @Test func bothTightWhenNoSilenceAtAll() {
    let warnings = sliceWarnings(
      startSample: 1000, endSample: 2000, durationSamples: 5000, silences: [])
    expectNoDifference(warnings, [.tightStart, .tightEnd])
  }

  @Test func overlappingSilenceCountsAsClean() {
    // silence spans across the start cut → clean start
    let warnings = sliceWarnings(
      startSample: 1000, endSample: 2000, durationSamples: 5000,
      silences: [silence(950, 1050), silence(1950, 2050)])
    expectNoDifference(warnings, [])
  }

  @Test func cutsAtFileEdgesAreClean() {
    // start at 0 (no predecessor) and end at durationSamples (no successor)
    let warnings = sliceWarnings(
      startSample: 0, endSample: 5000, durationSamples: 5000, silences: [])
    expectNoDifference(warnings, [])
  }

  @Test func timecodeAndDurationFormat() {
    expectNoDifference(sampleTimecodeLabel(44100 * 5 + 44100 * 9 / 10, sampleRate: 44100), "0:05.9")
    expectNoDifference(sampleTimecodeLabel(44100 * 65, sampleRate: 44100), "1:05.0")
    expectNoDifference(sampleDurationLabel(44100 * 3 + 4410 * 2, sampleRate: 44100), "3.2s")
  }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd QuickInterviewEditor && xcodegen generate && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates -only-testing:QuickInterviewEditorTests/SliceWarningsTests 2>&1 | tail -20`
Expected: FAIL — `Slice`/`SliceWarning`/`sliceWarnings`/formatters not found.

- [ ] **Step 3: Implement `Slice.swift`:**

```swift
import Foundation

struct Slice: Identifiable, Equatable, Codable {
  var id: UUID
  var name: String
  var startSample: Int      // inclusive
  var endSample: Int        // exclusive
  var wordIDs: [Word.ID]
  var snippet: String
  var warnings: [SliceWarning]
}

enum SliceWarning: String, Equatable, Codable {
  case tightStart
  case tightEnd
}
```

- [ ] **Step 4: Implement `SliceWarnings.swift`:**

```swift
import Foundation

/// A cut is "clean" when a detected silence region touches or overlaps the cut
/// sample. Cuts at the very start/end of the file have no neighbour to join, so
/// they are always clean. This is cut-safety, distinct from the transcript's
/// run-together (gap-slider) reading aid.
func sliceWarnings(
  startSample: Int, endSample: Int, durationSamples: Int, silences: [EditPlan.Silence]
) -> [SliceWarning] {
  var warnings: [SliceWarning] = []
  if startSample > 0, !silenceTouches(startSample, silences) { warnings.append(.tightStart) }
  if endSample < durationSamples, !silenceTouches(endSample, silences) { warnings.append(.tightEnd) }
  return warnings
}

private func silenceTouches(_ sample: Int, _ silences: [EditPlan.Silence]) -> Bool {
  silences.contains { sample >= $0.startSample && sample <= $0.endSample }
}

func sampleTimecodeLabel(_ samples: Int, sampleRate: Int) -> String {
  let totalSeconds = Double(max(0, samples)) / Double(sampleRate)
  let minutes = Int(totalSeconds) / 60
  let seconds = totalSeconds - Double(minutes * 60)
  return String(format: "%d:%04.1f", minutes, seconds)
}

func sampleDurationLabel(_ samples: Int, sampleRate: Int) -> String {
  String(format: "%.1fs", Double(max(0, samples)) / Double(sampleRate))
}
```

- [ ] **Step 5: Run to verify it passes** — same `-only-testing` command. Expected: PASS (7 tests).

- [ ] **Step 6: Lint + commit**

```bash
cd QuickInterviewEditor && make format-check && make lint && cd ..
git add QuickInterviewEditor/QuickInterviewEditor/Models/Slice.swift \
        QuickInterviewEditor/QuickInterviewEditor/Models/SliceWarnings.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/Models/SliceWarningsTests.swift \
        QuickInterviewEditor/QuickInterviewEditor.xcodeproj
git commit -m "feat(model): Slice value type + silence-derived tight-join warnings + timecode formatting"
```

---

## Task 2: `AudioPlayerClient` dependency

A `Sendable` dependency-client that plays a **source** audio sample range (play/stop only). Live impl uses AVFoundation; `testValue` fails cleanly so a forgotten override is caught, not silently a no-op.

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Core/AudioPlayerClient.swift`
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Core/AudioPlayerClientTests.swift`

**Interfaces:**
- Produces:
  - `struct AudioPlayerClient: Sendable { var play: @Sendable (URL, Range<Int>, Int) async throws -> Void; var stop: @Sendable () async -> Void }` (url, sampleRange, sampleRate)
  - `extension DependencyValues { var audioPlayer: AudioPlayerClient { get set } }`
  - `AudioPlayerClient.testValue` (both closures `reportIssue` + throw/return), `.previewValue` (no-ops), `.liveValue` (AVFoundation).
  - Reuses `EngineClientError.unimplemented(_:)` for the test-value throw.

- [ ] **Step 1: Write the failing test** — `AudioPlayerClientTests.swift`:

```swift
import Dependencies
import Foundation
import IssueReporting
import Testing
@testable import QuickInterviewEditor

struct AudioPlayerClientTests {
  @Test func testValuePlayFailsCleanlyWithoutOverride() async {
    await withKnownIssue {
      try await AudioPlayerClient.testValue.play(URL(fileURLWithPath: "/x"), 0..<10, 44100)
    }
  }

  @Test func previewValuePlayIsANoOp() async throws {
    try await AudioPlayerClient.previewValue.play(URL(fileURLWithPath: "/x"), 0..<10, 44100)
    await AudioPlayerClient.previewValue.stop()
  }
}
```

- [ ] **Step 2: Run to verify it fails** — `-only-testing:QuickInterviewEditorTests/AudioPlayerClientTests`. Expected: FAIL — type not found.

- [ ] **Step 3: Implement `AudioPlayerClient.swift`:**

```swift
import AVFoundation
import Dependencies
import Foundation
import IssueReporting

struct AudioPlayerClient: Sendable {
  /// Plays `url` from `range.lowerBound` to `range.upperBound` (samples) and
  /// returns when playback finishes or `stop()` is called.
  var play: @Sendable (URL, Range<Int>, Int) async throws -> Void
  var stop: @Sendable () async -> Void
}

extension AudioPlayerClient: DependencyKey {
  static let liveValue = AudioPlayerClient.live()
}

extension AudioPlayerClient: TestDependencyKey {
  static let testValue = AudioPlayerClient(
    play: { _, _, _ in
      reportIssue("AudioPlayerClient.play called without a test override")
      throw EngineClientError.unimplemented("AudioPlayerClient.play")
    },
    stop: { reportIssue("AudioPlayerClient.stop called without a test override") }
  )

  static let previewValue = AudioPlayerClient(play: { _, _, _ in }, stop: {})
}

extension DependencyValues {
  var audioPlayer: AudioPlayerClient {
    get { self[AudioPlayerClient.self] }
    set { self[AudioPlayerClient.self] = newValue }
  }
}

extension AudioPlayerClient {
  /// AVFoundation range playback via a shared engine + player node. Not unit
  /// tested (real audio hardware); covered by manual verification.
  static func live() -> AudioPlayerClient {
    let box = LivePlayerBox()
    return AudioPlayerClient(
      play: { url, range, _ in try box.play(url: url, range: range) },
      stop: { box.stop() }
    )
  }
}

private final class LivePlayerBox: @unchecked Sendable {
  private let engine = AVAudioEngine()
  private let node = AVAudioPlayerNode()
  private let lock = NSLock()

  func play(url: URL, range: Range<Int>) throws {
    lock.lock(); defer { lock.unlock() }
    stopLocked()
    let file = try AVAudioFile(forReading: url)
    let start = AVAudioFramePosition(max(0, range.lowerBound))
    let frames = AVAudioFrameCount(max(0, range.upperBound - range.lowerBound))
    guard frames > 0 else { return }
    if node.engine == nil { engine.attach(node) }
    engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
    if !engine.isRunning { try engine.start() }
    node.scheduleSegment(file, startingFrame: start, frameCount: frames, at: nil)
    node.play()
  }

  func stop() { lock.lock(); defer { lock.unlock() }; stopLocked() }

  private func stopLocked() {
    node.stop()
    if engine.isRunning { engine.stop() }
  }
}
```

- [ ] **Step 4: Run to verify it passes** — same `-only-testing` command. Expected: PASS (2 tests).

- [ ] **Step 5: Lint + commit**

```bash
cd QuickInterviewEditor && make format-check && make lint && cd ..
git add QuickInterviewEditor/QuickInterviewEditor/Core/AudioPlayerClient.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/Core/AudioPlayerClientTests.swift \
        QuickInterviewEditor/QuickInterviewEditor.xcodeproj
git commit -m "feat(core): AudioPlayerClient dependency (source-range play/stop; AVFoundation live)"
```

---

## Task 3: Expose ordered selection on `TranscriptPageModel`

`EditorModel.addSliceTapped()` needs the selection as an **ordered** word-ID list plus a snippet. The model already computes `selectedWords` privately; expose ordered accessors additively (existing behavior unchanged).

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptPageModel.swift`
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/TranscriptPage/TranscriptPageTests.swift`

**Interfaces:**
- Produces (on `TranscriptPageModel`):
  - `var orderedSelectedWordIDs: [Word.ID]` — selection in transcript position order (empty when no selection).
  - `var selectionSnippet: String` — selected word text joined with single spaces, trimmed (unquoted, untruncated; the `Slice` owns display truncation).

- [ ] **Step 1: Write the failing test** — append to `TranscriptPageTests.swift`:

```swift
@Test func orderedSelectionExposesIDsAndSnippet() {
  let model = TranscriptPageModel(editPlan: Fixtures.editPlan())
  let first = model.words[2].id
  let last = model.words[4].id
  model.wordTapped(first)
  model.wordTapped(last)
  expectNoDifference(model.orderedSelectedWordIDs, [model.words[2].id, model.words[3].id, model.words[4].id])
  #expect(!model.selectionSnippet.isEmpty)
  #expect(model.selectionSnippet == model.selectionSnippet.trimmingCharacters(in: .whitespaces))
}

@Test func orderedSelectionEmptyWithoutSelection() {
  let model = TranscriptPageModel(editPlan: Fixtures.editPlan())
  expectNoDifference(model.orderedSelectedWordIDs, [])
  expectNoDifference(model.selectionSnippet, "")
}
```

- [ ] **Step 2: Run to verify it fails** — `-only-testing:QuickInterviewEditorTests/TranscriptPageTests`. Expected: FAIL — accessors not found.

- [ ] **Step 3: Implement** — add to `TranscriptPageModel` (in the View Helpers MARK), reusing the existing private `selectedWords: ArraySlice<Word>`:

```swift
  var orderedSelectedWordIDs: [Word.ID] { selectedWords.map(\.id) }

  var selectionSnippet: String {
    selectedWords.map(\.text).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
  }
```

- [ ] **Step 4: Run to verify it passes** — same command. Expected: PASS (existing tests + 2 new).

- [ ] **Step 5: Lint + commit**

```bash
cd QuickInterviewEditor && make format-check && make lint && cd ..
git add QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptPageModel.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/TranscriptPage/TranscriptPageTests.swift \
        QuickInterviewEditor/QuickInterviewEditor.xcodeproj
git commit -m "feat(transcript): expose ordered selected word IDs + snippet for slicing"
```

---

## Task 4: `WordViewState.displayRole` (Step-1 fix-now)

Move the display-priority decision out of `TranscriptPageView.color(for:)` onto the model. The view maps role → color only.

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Models/RunTogether.swift`
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptPageView.swift`
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Models/RunTogetherTests.swift`

**Interfaces:**
- Produces: `enum WordDisplayRole { case selected; case runTogether; case normal }` and `var displayRole: WordDisplayRole` on `WordViewState` (`selected` wins over `runTogether` wins over `normal`).

- [ ] **Step 1: Write the failing test** — append to `RunTogetherTests.swift`:

```swift
@Test func displayRolePrioritisesSelectedThenRunTogether() {
  let selected = WordViewState(id: 1, text: "a", startSample: 0, endSample: 1,
                               isSelected: true, isRunTogether: true)
  let runTogether = WordViewState(id: 2, text: "b", startSample: 0, endSample: 1,
                                  isSelected: false, isRunTogether: true)
  let normal = WordViewState(id: 3, text: "c", startSample: 0, endSample: 1,
                             isSelected: false, isRunTogether: false)
  #expect(selected.displayRole == .selected)
  #expect(runTogether.displayRole == .runTogether)
  #expect(normal.displayRole == .normal)
}
```

- [ ] **Step 2: Run to verify it fails** — `-only-testing:QuickInterviewEditorTests/RunTogetherTests`. Expected: FAIL — `displayRole`/`WordDisplayRole` not found.

- [ ] **Step 3: Implement** — in `RunTogether.swift`, add the enum + computed property:

```swift
enum WordDisplayRole {
  case selected
  case runTogether
  case normal
}

extension WordViewState {
  var displayRole: WordDisplayRole {
    if isSelected { return .selected }
    if isRunTogether { return .runTogether }
    return .normal
  }
}
```

- [ ] **Step 4: Simplify the view** — in `TranscriptPageView.swift`, replace the boolean logic in `color(for:)` with a role switch (colors stay in the view):

```swift
  private func color(for word: WordViewState) -> Color {
    switch word.displayRole {
    case .selected: return .white
    case .runTogether: return Color(red: 0.89, green: 0.58, blue: 0.58)
    case .normal: return Color(white: 0.56)
    }
  }
```

(If the view also branches on background/selection elsewhere, leave those bindings; only the priority decision moves to the model.)

- [ ] **Step 5: Run to verify it passes** — run the full suite once: `cd QuickInterviewEditor && xcodegen generate && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates 2>&1 | tail -20`. Expected: PASS.

- [ ] **Step 6: Lint + commit**

```bash
cd QuickInterviewEditor && make format-check && make lint && cd ..
git add QuickInterviewEditor/QuickInterviewEditor/Models/RunTogether.swift \
        QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptPageView.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/Models/RunTogetherTests.swift \
        QuickInterviewEditor/QuickInterviewEditor.xcodeproj
git commit -m "refactor(transcript): move word display-priority onto WordViewState.displayRole"
```

---

## Task 5: `EditorModel` — owns transcript + slices

The loaded-editor model: builds a `TranscriptPageModel`, holds `slices`, exposes display rows, and implements add/rename/reorder/delete/play/stop. Reads selection from its `transcript`.

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift`
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorTests.swift`

**Interfaces:**
- Consumes: `TranscriptPageModel(editPlan:)`, `TranscriptPageModel.orderedSelectedWordIDs` / `.selectionSnippet` / `.selectedSampleRange`, `Slice`, `SliceWarning`, `sliceWarnings(...)`, `sampleTimecodeLabel` / `sampleDurationLabel`, `AudioPlayerClient`.
- Produces:
  - `final class EditorModel: ViewModel` with `let sourceURL: URL`, `let editPlan: EditPlan`, `var transcript: TranscriptPageModel`, `var slices: IdentifiedArrayOf<Slice>`, `var playingSliceID: Slice.ID?`.
  - `struct SliceRowState: Identifiable, Equatable { var id: Slice.ID; var name: String; var durationLabel: String; var rangeLabel: String; var snippet: String; var isTight: Bool; var warningLabel: String; var isPlaying: Bool }`
  - `var sliceRows: IdentifiedArrayOf<SliceRowState>` (recomputed on mutation).
  - View helpers: `var canAddSlice: Bool`, `var sliceCountLabel: String`, plus copy constants `addSliceLabel`, `emptyStateMessage`, `playLabel`, `stopLabel`, `deleteLabel`.
  - Actions: `func addSliceTapped()`, `func renameSlice(_ id: Slice.ID, to name: String)`, `func moveSlices(fromOffsets: IndexSet, toOffset: Int)`, `func deleteSlice(_ id: Slice.ID)`, `func playSliceTapped(_ id: Slice.ID) async`, `func stopPlaybackTapped() async`.

- [ ] **Step 1: Write the failing tests** — `EditorTests.swift`:

```swift
import CustomDump
import Dependencies
import Foundation
import IdentifiedCollections
import Testing
@testable import QuickInterviewEditor

@MainActor
struct EditorTests {
  private func editor(_ plan: EditPlan = Fixtures.editPlan()) -> EditorModel {
    EditorModel(sourceURL: URL(fileURLWithPath: "/clip.m4a"), editPlan: plan)
  }

  @Test func addSliceFromSelectionCreatesSlice() {
    let model = editor()
    model.transcript.wordTapped(model.transcript.words[0].id)
    model.transcript.wordTapped(model.transcript.words[3].id)
    model.addSliceTapped()
    expectNoDifference(model.slices.count, 1)
    let slice = model.slices[0]
    expectNoDifference(slice.name, "Slice 1")
    expectNoDifference(slice.wordIDs, Array(model.transcript.orderedSelectedWordIDs))
    #expect(slice.startSample < slice.endSample)
    #expect(!slice.snippet.isEmpty)
  }

  @Test func addSliceRejectedWithoutSelection() {
    let model = editor()
    #expect(!model.canAddSlice)
    model.addSliceTapped()
    expectNoDifference(model.slices.count, 0)
  }

  @Test func addSliceNamesSequentially() {
    let model = editor()
    model.transcript.wordTapped(model.transcript.words[0].id)
    model.transcript.wordTapped(model.transcript.words[1].id)
    model.addSliceTapped()
    model.transcript.wordTapped(model.transcript.words[2].id)
    model.transcript.wordTapped(model.transcript.words[3].id)
    model.addSliceTapped()
    expectNoDifference(model.slices.map(\.name), ["Slice 1", "Slice 2"])
  }

  @Test func renameReorderDeleteMutateSlices() {
    let model = editor()
    for pair in [(0, 1), (2, 3), (4, 5)] {
      model.transcript.wordTapped(model.transcript.words[pair.0].id)
      model.transcript.wordTapped(model.transcript.words[pair.1].id)
      model.addSliceTapped()
    }
    let firstID = model.slices[0].id
    model.renameSlice(firstID, to: "Intro")
    expectNoDifference(model.slices[id: firstID]?.name, "Intro")
    model.moveSlices(fromOffsets: IndexSet(integer: 0), toOffset: 3)
    expectNoDifference(model.slices.last?.id, firstID)
    model.deleteSlice(firstID)
    #expect(model.slices[id: firstID] == nil)
    expectNoDifference(model.slices.count, 2)
  }

  @Test func sliceRowsFormatDurationAndRange() {
    let model = editor()
    model.transcript.wordTapped(model.transcript.words[0].id)
    model.transcript.wordTapped(model.transcript.words[2].id)
    model.addSliceTapped()
    let row = model.sliceRows[0]
    #expect(row.durationLabel.hasSuffix("s"))
    #expect(row.rangeLabel.contains("–"))
    expectNoDifference(row.isPlaying, false)
  }

  @Test func sliceCountLabelPluralises() {
    let model = editor()
    expectNoDifference(model.sliceCountLabel, "0 clips")
    model.transcript.wordTapped(model.transcript.words[0].id)
    model.transcript.wordTapped(model.transcript.words[1].id)
    model.addSliceTapped()
    expectNoDifference(model.sliceCountLabel, "1 clip")
  }

  @Test func playSliceCallsAudioPlayerWithSourceRange() async {
    let recorded = LockIsolated<(URL, Range<Int>, Int)?>(nil)
    let model = editor()
    model.transcript.wordTapped(model.transcript.words[0].id)
    model.transcript.wordTapped(model.transcript.words[2].id)
    model.addSliceTapped()
    let slice = model.slices[0]
    await withDependencies {
      $0.audioPlayer.play = { url, range, rate in recorded.setValue((url, range, rate)) }
    } operation: {
      await model.playSliceTapped(slice.id)
    }
    expectNoDifference(recorded.value?.0, model.sourceURL)
    expectNoDifference(recorded.value?.1, slice.startSample..<slice.endSample)
    expectNoDifference(recorded.value?.2, model.editPlan.source.sampleRate)
    expectNoDifference(model.playingSliceID, slice.id)
  }

  @Test func stopPlaybackClearsPlayingSlice() async {
    let model = editor()
    model.transcript.wordTapped(model.transcript.words[0].id)
    model.transcript.wordTapped(model.transcript.words[1].id)
    model.addSliceTapped()
    await withDependencies {
      $0.audioPlayer.play = { _, _, _ in }
      $0.audioPlayer.stop = { }
    } operation: {
      await model.playSliceTapped(model.slices[0].id)
      await model.stopPlaybackTapped()
    }
    expectNoDifference(model.playingSliceID, nil)
  }
}
```

*Note:* `LockIsolated` comes from `Dependencies` (re-exported); `withDependencies` overrides reach the model because `EditorModel` reads `@Dependency(\.audioPlayer)` at call time.

- [ ] **Step 2: Run to verify it fails** — `xcodegen generate` then `-only-testing:QuickInterviewEditorTests/EditorTests`. Expected: FAIL — `EditorModel` not found.

- [ ] **Step 3: Implement `EditorModel.swift`:**

```swift
import Dependencies
import Foundation
import IdentifiedCollections
import IssueReporting
import Observation

@MainActor
@Observable
final class EditorModel: ViewModel {

  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.audioPlayer) var audioPlayer

  // MARK: - Initialization
  let sourceURL: URL
  let editPlan: EditPlan
  var transcript: TranscriptPageModel

  init(sourceURL: URL, editPlan: EditPlan) {
    self.sourceURL = sourceURL
    self.editPlan = editPlan
    self.transcript = TranscriptPageModel(editPlan: editPlan)
    super.init()
  }

  // MARK: - Properties
  var slices: IdentifiedArrayOf<Slice> = []
  var playingSliceID: Slice.ID?

  // MARK: - Display Text
  let addSliceLabel = "Add slice"
  let emptyStateMessage = "Select words in the transcript, then Add slice."
  let playLabel = "Play"
  let stopLabel = "Stop"
  let deleteLabel = "Delete slice"

  // MARK: - View Helpers
  var canAddSlice: Bool { transcript.selectedSampleRange != nil }

  var sliceCountLabel: String {
    "\(slices.count) \(slices.count == 1 ? "clip" : "clips")"
  }

  var sliceRows: IdentifiedArrayOf<SliceRowState> {
    let sampleRate = editPlan.source.sampleRate
    return IdentifiedArray(uniqueElements: slices.map { slice in
      SliceRowState(
        id: slice.id,
        name: slice.name,
        durationLabel: sampleDurationLabel(slice.endSample - slice.startSample, sampleRate: sampleRate),
        rangeLabel: "\(sampleTimecodeLabel(slice.startSample, sampleRate: sampleRate)) – "
          + sampleTimecodeLabel(slice.endSample, sampleRate: sampleRate),
        snippet: slice.snippet,
        isTight: !slice.warnings.isEmpty,
        warningLabel: slice.warnings.isEmpty ? "" : "Tight join — add a fade in Logic",
        isPlaying: playingSliceID == slice.id
      )
    })
  }

  // MARK: - User Actions
  func addSliceTapped() {
    guard let range = transcript.selectedSampleRange else { return }
    let wordIDs = transcript.orderedSelectedWordIDs
    guard !wordIDs.isEmpty else { return }
    let slice = Slice(
      id: UUID(),
      name: "Slice \(slices.count + 1)",
      startSample: range.lowerBound,
      endSample: range.upperBound,
      wordIDs: wordIDs,
      snippet: displaySnippet(transcript.selectionSnippet),
      warnings: sliceWarnings(
        startSample: range.lowerBound, endSample: range.upperBound,
        durationSamples: editPlan.source.durationSamples, silences: editPlan.silences)
    )
    slices.append(slice)
    transcript.clearSelectionTapped()
  }

  func renameSlice(_ id: Slice.ID, to name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    slices[id: id]?.name = trimmed
  }

  func moveSlices(fromOffsets source: IndexSet, toOffset destination: Int) {
    slices.move(fromOffsets: source, toOffset: destination)
  }

  func deleteSlice(_ id: Slice.ID) {
    if playingSliceID == id { playingSliceID = nil }
    slices.remove(id: id)
  }

  func playSliceTapped(_ id: Slice.ID) async {
    guard let slice = slices[id: id] else { return }
    playingSliceID = id
    await withErrorReporting {
      try await audioPlayer.play(sourceURL, slice.startSample..<slice.endSample, editPlan.source.sampleRate)
    }
  }

  func stopPlaybackTapped() async {
    playingSliceID = nil
    await audioPlayer.stop()
  }

  // MARK: - Private Helpers
  private func displaySnippet(_ text: String) -> String {
    let quoted = text.count > 68 ? String(text.prefix(68)) + "…" : text
    return "“\(quoted)”"
  }
}

struct SliceRowState: Identifiable, Equatable {
  var id: Slice.ID
  var name: String
  var durationLabel: String
  var rangeLabel: String
  var snippet: String
  var isTight: Bool
  var warningLabel: String
  var isPlaying: Bool
}
```

- [ ] **Step 4: Run to verify it passes** — same `-only-testing` command. Expected: PASS (8 tests).

- [ ] **Step 5: Lint + commit**

```bash
cd QuickInterviewEditor && make format-check && make lint && cd ..
git add QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorTests.swift \
        QuickInterviewEditor/QuickInterviewEditor.xcodeproj
git commit -m "feat(editor): EditorModel owns transcript + slices (add/rename/reorder/delete/play)"
```

---

## Task 6: `SongTabModel` holds an `EditorModel`

Swap the loaded-state child from `TranscriptPageModel?` to `EditorModel?` so the tab owns transcription lifecycle only and the editor owns the loaded page. Inherit dependencies so the tab's test-overridden `audioPlayer` reaches the editor.

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/SongTab/SongTabModel.swift`
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/SongTab/SongTabTests.swift`

**Interfaces:**
- Produces: `SongTabModel.editor: EditorModel?` (replaces `transcript`); on `.completed`, builds `EditorModel(sourceURL: sourceURL, editPlan: plan)` via `withDependencies(from: self)`; `phase = .loaded`.

- [ ] **Step 1: Update the existing test** — in `SongTabTests.swift`, change the loaded-state assertion from `model.transcript?.words.count` to the editor's transcript:

```swift
  @Test func progressThenCompletedWalksToLoaded() async {
    let plan = Fixtures.editPlan()
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/clip.m4a"))
    await withDependencies {
      $0.engine.transcribe = { [self] _ in
        stream([.progress(.init(phase: .transcribing, message: "Transcribing")),
                .completed(plan)])
      }
    } operation: {
      await model.startTranscription()
    }
    #expect(model.isLoaded)
    expectNoDifference(model.editor?.transcript.words.count, 122)
  }
```

(Update any other `SongTabTests` reference to `model.transcript` → `model.editor?.transcript`.)

- [ ] **Step 2: Run to verify it fails** — `xcodegen generate` then `-only-testing:QuickInterviewEditorTests/SongTabTests`. Expected: FAIL — `editor` not a member / `transcript` gone.

- [ ] **Step 3: Implement** — in `SongTabModel.swift`, replace the `transcript` property and its assignment:

```swift
  // MARK: - Properties
  var phase: Phase = .queued
  var editor: EditorModel?
  @ObservationIgnored private var task: Task<Void, Never>?
```

and in `startTranscription()`'s `.completed` handler:

```swift
        case let .completed(plan):
          editor = withDependencies(from: self) {
            EditorModel(sourceURL: sourceURL, editPlan: plan)
          }
          phase = .loaded
```

Also clear it on (re)start where `transcript = nil` was: replace with `editor = nil`.

- [ ] **Step 4: Run to verify it passes** — same command. Expected: PASS.

- [ ] **Step 5: Lint + commit**

```bash
cd QuickInterviewEditor && make format-check && make lint && cd ..
git add QuickInterviewEditor/QuickInterviewEditor/Views/Pages/SongTab/SongTabModel.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/SongTab/SongTabTests.swift \
        QuickInterviewEditor/QuickInterviewEditor.xcodeproj
git commit -m "refactor(tab): SongTabModel holds EditorModel as its loaded child"
```

---

## Task 7: Views — `SlicesPanelView`, `EditorView`, wire `SongTabView`

Render the slices panel and compose the editor. Zero logic in views: all copy/flags from the model. Build succeeds and the full suite passes (views untested by design).

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/SlicesPanelView.swift`
- Create: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorView.swift`
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/SongTab/SongTabView.swift`

**Interfaces:**
- Consumes: `EditorModel`, `EditorModel.sliceRows`, `EditorModel.transcript`, all `EditorModel` actions.

- [ ] **Step 1: `SlicesPanelView.swift`** — a list bound to `model.sliceRows`; the Add-slice control and (in 3b) export live in the header. Reorder via `.onMove`; rename via a `TextField` bound through the model. No Export controls in 3a.

```swift
import SwiftUI

struct SlicesPanelView: View {
  @Bindable var model: EditorModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("SLICES").font(.system(size: 11, weight: .semibold))
          .kerning(1).foregroundStyle(Color(white: 0.44))
        Text(model.sliceCountLabel).font(.system(size: 11))
          .foregroundStyle(Color(white: 0.34))
        Spacer()
        Button(model.addSliceLabel) { model.addSliceTapped() }
          .disabled(!model.canAddSlice)
      }
      if model.sliceRows.isEmpty {
        Text(model.emptyStateMessage)
          .font(.system(size: 12)).foregroundStyle(Color(white: 0.5))
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        List {
          ForEach(model.sliceRows) { row in
            SliceCard(model: model, row: row)
          }
          .onMove { model.moveSlices(fromOffsets: $0, toOffset: $1) }
          .onDelete { indexSet in
            for index in indexSet { model.deleteSlice(model.sliceRows[index].id) }
          }
        }
        .listStyle(.plain)
      }
    }
    .padding(12)
  }
}

private struct SliceCard: View {
  @Bindable var model: EditorModel
  let row: SliceRowState

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        TextField("", text: Binding(
          get: { row.name },
          set: { model.renameSlice(row.id, to: $0) }))
        .textFieldStyle(.plain).font(.system(size: 14, weight: .semibold))
        Spacer()
        Text(row.durationLabel).font(.system(size: 11))
          .foregroundStyle(Color(white: 0.54))
      }
      Text(row.rangeLabel).font(.system(size: 11).monospacedDigit())
        .foregroundStyle(Color(white: 0.44))
      Text(row.snippet).font(.system(size: 12.5))
        .foregroundStyle(Color(white: 0.6)).lineLimit(2)
      if row.isTight {
        Text(row.warningLabel).font(.system(size: 11))
          .foregroundStyle(Color(red: 0.89, green: 0.58, blue: 0.58))
      }
      HStack(spacing: 8) {
        Button(row.isPlaying ? model.stopLabel : model.playLabel) {
          Task {
            if row.isPlaying { await model.stopPlaybackTapped() }
            else { await model.playSliceTapped(row.id) }
          }
        }
        Button { model.deleteSlice(row.id) } label: { Image(systemName: "xmark") }
          .buttonStyle(.plain).accessibilityLabel(model.deleteLabel)
      }
    }
    .padding(12)
    .background(Color(white: 0.08))
    .clipShape(RoundedRectangle(cornerRadius: 11))
  }
}
```

- [ ] **Step 2: `EditorView.swift`** — compose transcript + slices panel:

```swift
import SwiftUI

struct EditorView: View {
  @Bindable var model: EditorModel

  var body: some View {
    HStack(spacing: 0) {
      TranscriptPageView(model: model.transcript)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      SlicesPanelView(model: model)
        .frame(width: 302)
    }
    .background(Color.black)
  }
}
```

- [ ] **Step 3: Wire `SongTabView.swift`** — in the `.loaded` case, render `EditorView` from the editor instead of `TranscriptPageView`:

```swift
    case .loaded:
      if let editor = model.editor { EditorView(model: editor) }
```

- [ ] **Step 4: Build + full suite**

Run: `cd QuickInterviewEditor && xcodegen generate && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates 2>&1 | tail -30`
Expected: build succeeds; all suites pass (Swift). Views untested by design.

- [ ] **Step 5: Lint + commit**

```bash
cd QuickInterviewEditor && make format-check && make lint && cd ..
git add QuickInterviewEditor/QuickInterviewEditor/Views QuickInterviewEditor/QuickInterviewEditor.xcodeproj
git commit -m "feat(ui): slices panel + editor composition (transcript + slices)"
```

---

## Task 8: Manual verification + docs

Verify the panel end to end in the running app and record follow-ups.

- [ ] **Step 1: Manual run (record in the PR).** With a working `.venv` (or `QIE_ENGINE_REPO`), run the app, transcribe a short clip, select words, Add slice, rename/reorder/delete, and Play a slice (hear the source range). Confirm a tight-join slice shows the warning line.

- [ ] **Step 2: Update follow-ups** — in `docs/superpowers/STEP1-FOLLOWUPS.md`, mark the `displayRole` view-polish item **done in 3a** (Task 4). Note any new 3a follow-ups (e.g. natural-end playback auto-clear deferred).

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/STEP1-FOLLOWUPS.md
git commit -m "docs: mark displayRole follow-up resolved in Step 3a"
```

---

## Self-Review (completed by plan author)

**Spec coverage (3a portion):**
- `Slice` sample-native value type → Task 1. ✅
- Tight-join warnings from `editPlan.silences` → Task 1 (`sliceWarnings`), integrated in Task 5. ✅
- Transcript red slider untouched (reading aid) → nothing changes it; Task 4 only refactors where the priority decision lives. ✅
- `EditorModel` owns transcript + slices; `TranscriptPageModel` stays pure (no callbacks) → Tasks 3/5/6. ✅
- Panel: create/rename/reorder/delete/play, no dead export controls → Tasks 5/7. ✅
- `AudioPlayerClient` plays the source range (play/stop only) → Tasks 2/5. ✅
- Fix-now `displayRole` → Task 4. ✅
- Sample-native display strings computed on the model → Tasks 1/5 (`SliceRowState`). ✅

**Placeholder scan:** every code step shows complete code; the one non-unit-tested unit (`AudioPlayerClient.live`) is written out in full and flagged for manual verification (Task 8).

**Type consistency:** `Slice`/`SliceWarning`/`sliceWarnings` signatures match across Tasks 1/5; `orderedSelectedWordIDs`/`selectionSnippet` defined in Task 3 and consumed in Task 5; `SongTabModel.editor` defined in Task 6 and consumed in Task 7; `SliceRowState` fields match between Task 5 impl and the Task 7 view; `AudioPlayerClient.play` arity `(URL, Range<Int>, Int)` identical in Tasks 2/5/7.

**Deferred to 3b (recorded):** engine `render`, `EngineClient.renderSlices`, export/copy/reveal, `WorkspaceClient`, destination picker, per-slice Export + "Export all" buttons, `EditorModel.exportPhase`/`destinationURL`/`presentedAlert`.
