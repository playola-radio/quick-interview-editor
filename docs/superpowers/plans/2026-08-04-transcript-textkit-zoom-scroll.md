# TextKit Transcript with Zoom + Scroll — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the transcript's non-lazy per-word SwiftUI rendering with a single TextKit-backed `NSTextView`, add persisted text zoom and vertical scroll, and fix large-file sluggishness — all while keeping every decision in the `@Observable` model.

**Architecture:** `TranscriptPageModel` owns the whole transcript document: the plain text, a word→UTF-16 range map, contiguous selection, run-together state, zoom, follow-mode, and slider debounce. A new `TranscriptTextView: NSViewRepresentable` (TextKit 1) is a dumb renderer: it converts mouse points to UTF-16 offsets, applies incremental attribute diffs to `NSTextStorage`, and reports scroll events back to the model. Selection changes mutate only the affected word ranges; the attributed string is never rebuilt per interaction.

**Tech Stack:** SwiftUI + AppKit (`NSTextView`/`NSScrollView`/`NSLayoutManager`, TextKit 1), Point-Free `swift-dependencies` (`@Dependency(\.continuousClock)`), `swift-sharing` (`@Shared(.appStorage)`), `swift-identified-collections`, Swift Testing + `swift-custom-dump`.

## Global Constraints

- **PFW skills are mandatory before writing code.** Each task lists which `pfw-*` skills to invoke; invoke them first.
- **Zero logic in views.** The `NSViewRepresentable` is a dumb renderer. It may convert a point to a UTF-16 offset (rendering plumbing) but must never decide which *word* that is — it calls the model, which owns the range map.
- **Tests never construct the `NSViewRepresentable`.** All behavior is tested on `TranscriptPageModel` (and `EditorModel` where wired).
- **Value comparisons in tests use `expectNoDifference` / `expectDifference`**, not raw `#expect(a == b)`.
- **Test naming:** camelCase, no underscores.
- **NEVER `Task.sleep` in tests.** Use `@Dependency(\.continuousClock)` with a test clock.
- **Selection is contiguous.** Anchor/focus → one `selectedSampleRange`. Never introduce non-contiguous selection.
- **Build/test command (headless):** `cd QuickInterviewEditor && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates` (or `make test` in `QuickInterviewEditor/`). NOT `swift test`. Success = the `Test run with N tests … passed` line.
- **Test target must NOT directly link `Dependencies`/`DependenciesTestSupport`** (double-`@TaskLocal` gotcha) — it gets them transitively via `@testable import QuickInterviewEditor`.
- **Font:** default transcript size stays **17pt**; zoom bounds **11–36pt**; step **2pt**.
- **All new `@Observable` model properties on `TranscriptPageModel`** follow the existing `// MARK:` section order.

---

### Task 1: Transcript text + word→UTF-16 range map

Build the plain transcript string and an ordered word→`NSRange` map, plus offset→word lookup. This is the foundation the renderer and selection use. Purely additive — the existing `words`/`recomputeWords` path stays untouched.

**PFW skills first:** `pfw-observable-models`, `pfw-testing`, `pfw-custom-dump`.

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Models/TranscriptDocument.swift`
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptPageModel.swift`
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/TranscriptDocumentTests.swift`

**Interfaces:**
- Produces:
  - `struct TranscriptWordRange: Equatable { let wordID: Word.ID; let range: NSRange }`
  - `struct TranscriptDocument: Equatable { let text: String; let wordRanges: [TranscriptWordRange]; func wordID(atUTF16Offset:) -> Word.ID?; init(words: [Word]) }`
  - On the model: `var document: TranscriptDocument` (rebuilt only when the plan changes), `var plainTranscriptText: String { document.text }`.

- [ ] **Step 1: Write the failing test** — `TranscriptDocumentTests.swift`

```swift
import Testing
import CustomDump
@testable import QuickInterviewEditor

@MainActor
struct TranscriptDocumentTests {
  private func word(_ id: Int, _ text: String) -> Word {
    Word(id: id, text: text, start: 0, end: nil, startSample: nil, endSample: nil)
  }

  @Test func buildsSpaceJoinedTextAndUTF16Ranges() {
    let doc = TranscriptDocument(words: [word(1, "Hello"), word(2, "world")])
    expectNoDifference(doc.text, "Hello world")
    expectNoDifference(
      doc.wordRanges,
      [
        TranscriptWordRange(wordID: 1, range: NSRange(location: 0, length: 5)),
        TranscriptWordRange(wordID: 2, range: NSRange(location: 6, length: 5)),
      ])
  }

  @Test func offsetInsideWordResolvesToThatWord() {
    let doc = TranscriptDocument(words: [word(1, "Hello"), word(2, "world")])
    expectNoDifference(doc.wordID(atUTF16Offset: 0), 1)
    expectNoDifference(doc.wordID(atUTF16Offset: 4), 1)
    expectNoDifference(doc.wordID(atUTF16Offset: 6), 2)
  }

  @Test func offsetOnSeparatorResolvesToPrecedingWord() {
    let doc = TranscriptDocument(words: [word(1, "Hello"), word(2, "world")])
    expectNoDifference(doc.wordID(atUTF16Offset: 5), 1)  // the space
  }

  @Test func offsetPastEndResolvesToLastWord() {
    let doc = TranscriptDocument(words: [word(1, "Hello"), word(2, "world")])
    expectNoDifference(doc.wordID(atUTF16Offset: 999), 2)
  }

  @Test func emptyWordsProducesEmptyDocument() {
    let doc = TranscriptDocument(words: [])
    expectNoDifference(doc.text, "")
    expectNoDifference(doc.wordRanges, [])
    expectNoDifference(doc.wordID(atUTF16Offset: 0), nil)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd QuickInterviewEditor && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates`
Expected: FAIL — `TranscriptDocument` is undefined.

- [ ] **Step 3: Implement `TranscriptDocument`** — `Models/TranscriptDocument.swift`

```swift
import Foundation

struct TranscriptWordRange: Equatable {
  let wordID: Word.ID
  let range: NSRange
}

/// The transcript as one string plus a word → UTF-16 range map. Built once from the
/// plan's words (space-joined). Offsets use UTF-16 because that is what TextKit hit
/// testing returns; keeping the map in UTF-16 avoids String.Index conversions.
struct TranscriptDocument: Equatable {
  let text: String
  let wordRanges: [TranscriptWordRange]

  init(words: [Word]) {
    var pieces: [String] = []
    var ranges: [TranscriptWordRange] = []
    var location = 0
    for (index, word) in words.enumerated() {
      if index > 0 { location += 1 }  // the joining space
      let length = (word.text as NSString).length
      ranges.append(TranscriptWordRange(wordID: word.id, range: NSRange(location: location, length: length)))
      location += length
      pieces.append(word.text)
    }
    self.text = pieces.joined(separator: " ")
    self.wordRanges = ranges
  }

  /// The word an offset lands in, or the nearest preceding word when the offset is on a
  /// separator or past the end. Nil only when there are no words.
  func wordID(atUTF16Offset offset: Int) -> Word.ID? {
    guard !wordRanges.isEmpty else { return nil }
    var candidate: Word.ID?
    for entry in wordRanges {
      if NSLocationInRange(offset, entry.range) { return entry.wordID }
      if entry.range.location <= offset { candidate = entry.wordID } else { break }
    }
    return candidate ?? wordRanges.first?.wordID
  }
}
```

- [ ] **Step 4: Wire `document` onto the model** — in `TranscriptPageModel.swift`

Add to `// MARK: - Properties`:

```swift
  var document = TranscriptDocument(words: [])
  var plainTranscriptText: String { document.text }
```

In `recomputeWords()`, after the `guard let plan` line, rebuild the document only from the plan (it does not depend on selection/sensitivity):

```swift
    document = TranscriptDocument(words: plan.words)
```

(Place it right after `guard let plan = editPlan else { words = []; return }` returns a plan — i.e. the first line inside the body once `plan` is bound.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd QuickInterviewEditor && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Models/TranscriptDocument.swift \
        QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptPageModel.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/TranscriptDocumentTests.swift
git commit -m "feat(transcript): add TranscriptDocument text + UTF-16 word range map"
```

---

### Task 2: Offset-based contiguous selection

Add click/drag selection driven by UTF-16 offsets, mapped to the existing anchor/focus model. This is what the renderer will call. The existing `wordTapped(_:)`/`selectWord(_:)` stay (waveform sync still uses `selectWord`); the FlowLayout's `wordTapped` is removed in Task 8.

**PFW skills first:** `pfw-observable-models`, `pfw-testing`, `pfw-custom-dump`.

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptPageModel.swift`
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/TranscriptSelectionTests.swift`

**Interfaces:**
- Consumes: `document.wordID(atUTF16Offset:)`, existing `selectionAnchorID`/`selectionFocusID`/`selectedSampleRange`.
- Produces on the model: `func transcriptClicked(atUTF16Offset: Int)`, `func transcriptDragBegan(atUTF16Offset: Int)`, `func transcriptDragged(toUTF16Offset: Int)`, `func transcriptDragEnded()`, and `var selectedWordIDSet: Set<Word.ID>` (public, for the renderer's diff).

- [ ] **Step 1: Write the failing test** — `TranscriptSelectionTests.swift`

```swift
import Testing
import CustomDump
@testable import QuickInterviewEditor

@MainActor
struct TranscriptSelectionTests {
  private var plan: EditPlan {
    EditPlan(
      schemaVersion: 1,
      source: .init(path: "", sampleRate: 1000, channels: 1, durationSamples: 10_000),
      words: [
        Word(id: 1, text: "one", start: 0, end: 0.5, startSample: 0, endSample: 500),
        Word(id: 2, text: "two", start: 0.5, end: 1.0, startSample: 500, endSample: 1000),
        Word(id: 3, text: "three", start: 1.0, end: 1.5, startSample: 1000, endSample: 1500),
      ], silences: [], segments: [])
  }
  // text: "one two three"; ranges: one=0..3, two=4..7, three=8..13

  @Test func clickSelectsSingleWord() {
    let model = TranscriptPageModel(editPlan: plan)
    model.transcriptClicked(atUTF16Offset: 5)  // inside "two"
    expectNoDifference(model.selectedWordIDSet, [2])
    expectNoDifference(model.selectedSampleRange, 500..<1000)
  }

  @Test func clickingSoleSelectedWordClearsIt() {
    let model = TranscriptPageModel(editPlan: plan)
    model.transcriptClicked(atUTF16Offset: 5)
    model.transcriptClicked(atUTF16Offset: 5)
    expectNoDifference(model.selectedWordIDSet, [])
    expectNoDifference(model.selectedSampleRange, nil)
  }

  @Test func dragPaintsContiguousRun() {
    let model = TranscriptPageModel(editPlan: plan)
    model.transcriptDragBegan(atUTF16Offset: 0)   // "one"
    model.transcriptDragged(toUTF16Offset: 10)    // into "three"
    expectNoDifference(model.selectedWordIDSet, [1, 2, 3])
    expectNoDifference(model.selectedSampleRange, 0..<1500)
  }

  @Test func dragBackwardStaysContiguous() {
    let model = TranscriptPageModel(editPlan: plan)
    model.transcriptDragBegan(atUTF16Offset: 10)  // "three"
    model.transcriptDragged(toUTF16Offset: 0)     // back to "one"
    expectNoDifference(model.selectedWordIDSet, [1, 2, 3])
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd QuickInterviewEditor && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates`
Expected: FAIL — the `transcript*` methods and `selectedWordIDSet` don't exist.

- [ ] **Step 3: Implement the selection methods** — in `TranscriptPageModel.swift`

Add to `// MARK: - View Helpers`:

```swift
  /// Public selection set for the renderer to diff (the private `selectedWordIDs` stays internal).
  var selectedWordIDSet: Set<Word.ID> { selectedWordIDs }
```

Add to `// MARK: - User Actions`:

```swift
  func transcriptClicked(atUTF16Offset offset: Int) {
    guard let id = document.wordID(atUTF16Offset: offset) else { return }
    if selectionAnchorID == id, selectionFocusID == id {
      clearSelectionTapped()
    } else {
      selectWord(id)
    }
  }

  func transcriptDragBegan(atUTF16Offset offset: Int) {
    guard let id = document.wordID(atUTF16Offset: offset) else { return }
    selectionAnchorID = id
    selectionFocusID = id
    recomputeWords()
  }

  func transcriptDragged(toUTF16Offset offset: Int) {
    guard let id = document.wordID(atUTF16Offset: offset) else { return }
    selectionFocusID = id
    recomputeWords()
  }

  func transcriptDragEnded() {}
```

(`selectWord` and `clearSelectionTapped` already exist and call `recomputeWords()`.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd QuickInterviewEditor && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptPageModel.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/TranscriptSelectionTests.swift
git commit -m "feat(transcript): offset-based click/drag contiguous selection"
```

---

### Task 3: Persisted text zoom state

Add `fontSize` with zoom in/out/reset/clamp, persisted app-wide via `@Shared(.appStorage)`.

**PFW skills first:** `pfw-sharing` (exact `@Shared(.appStorage)` + test-isolation pattern), `pfw-observable-models`, `pfw-testing`, `pfw-custom-dump`.

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptPageModel.swift`
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/TranscriptZoomTests.swift`

**Interfaces:**
- Produces on the model: `@Shared @ObservationIgnored var fontSize: Double` (default 17), `let minFontSize = 11.0`, `let maxFontSize = 36.0`, `let fontStep = 2.0`, `var canZoomIn: Bool`, `var canZoomOut: Bool`, `func zoomInTapped()`, `func zoomOutTapped()`, `func zoomResetTapped()`, `func zoomChanged(_ size: Double)`.

- [ ] **Step 1: Write the failing test** — `TranscriptZoomTests.swift`

> Invoke `pfw-sharing` first and use its documented `.appStorage` test-isolation approach (an ephemeral `UserDefaults` via `withDependencies { $0.defaultAppStorage = … }`) so persisted zoom does not bleed between tests. The assertions below are the contract; wrap each in the isolation the skill prescribes.

```swift
import Dependencies
import Sharing
import Testing
import CustomDump
@testable import QuickInterviewEditor

@MainActor
struct TranscriptZoomTests {
  @Test func defaultFontSizeIs17() {
    withDependencies { $0.defaultAppStorage = UserDefaults(suiteName: "zoom-default")! } operation: {
      let model = TranscriptPageModel(editPlan: .fixture)
      expectNoDifference(model.fontSize, 17)
    }
  }

  @Test func zoomInAndOutStepBy2AndClamp() {
    withDependencies { $0.defaultAppStorage = UserDefaults(suiteName: "zoom-step-\(UUID())")! } operation: {
      let model = TranscriptPageModel(editPlan: .fixture)
      model.zoomInTapped()
      expectNoDifference(model.fontSize, 19)
      for _ in 0..<20 { model.zoomInTapped() }
      expectNoDifference(model.fontSize, model.maxFontSize)   // clamped at 36
      expectNoDifference(model.canZoomIn, false)
      for _ in 0..<40 { model.zoomOutTapped() }
      expectNoDifference(model.fontSize, model.minFontSize)   // clamped at 11
      expectNoDifference(model.canZoomOut, false)
    }
  }

  @Test func zoomResetReturnsTo17() {
    withDependencies { $0.defaultAppStorage = UserDefaults(suiteName: "zoom-reset-\(UUID())")! } operation: {
      let model = TranscriptPageModel(editPlan: .fixture)
      model.zoomInTapped()
      model.zoomResetTapped()
      expectNoDifference(model.fontSize, 17)
    }
  }

  @Test func zoomChangedClampsToBounds() {
    withDependencies { $0.defaultAppStorage = UserDefaults(suiteName: "zoom-clamp-\(UUID())")! } operation: {
      let model = TranscriptPageModel(editPlan: .fixture)
      model.zoomChanged(100)
      expectNoDifference(model.fontSize, model.maxFontSize)
      model.zoomChanged(1)
      expectNoDifference(model.fontSize, model.minFontSize)
    }
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd QuickInterviewEditor && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates`
Expected: FAIL — zoom API missing.

- [ ] **Step 3: Implement zoom** — in `TranscriptPageModel.swift`

Add `import Sharing` at the top. Add a shared key extension (in this file or a small `State` file — follow `pfw-sharing`):

```swift
extension SharedReaderKey where Self == AppStorageKey<Double>.Default {
  static var transcriptFontSize: Self {
    Self[.appStorage("transcriptFontSize"), default: 17]
  }
}
```

Add to `// MARK: - Properties`:

```swift
  @ObservationIgnored @Shared(.transcriptFontSize) var fontSize: Double
  let minFontSize = 11.0
  let maxFontSize = 36.0
  let fontStep = 2.0
```

Add to `// MARK: - View Helpers`:

```swift
  var canZoomIn: Bool { fontSize < maxFontSize }
  var canZoomOut: Bool { fontSize > minFontSize }
```

Add to `// MARK: - User Actions`:

```swift
  func zoomInTapped() { setFontSize(fontSize + fontStep) }
  func zoomOutTapped() { setFontSize(fontSize - fontStep) }
  func zoomResetTapped() { setFontSize(17) }
  func zoomChanged(_ size: Double) { setFontSize(size) }
```

Add to `// MARK: - Private Helpers`:

```swift
  private func setFontSize(_ size: Double) {
    $fontSize.withLock { $0 = min(max(size, minFontSize), maxFontSize) }
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd QuickInterviewEditor && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates`
Expected: PASS. If `.appStorage`/`SharedReaderKey` signatures differ from the above, follow the exact form `pfw-sharing` documents for the installed Sharing version — keep the behavior identical.

- [ ] **Step 5: Commit**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptPageModel.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/TranscriptZoomTests.swift
git commit -m "feat(transcript): persisted text zoom (11–36pt) via @Shared appStorage"
```

---

### Task 4: Auto-scroll follow-mode + playhead wiring

Model owns follow-mode and derives a scroll target word from the playhead; `EditorModel.observePlayback` pushes playhead samples into the transcript. User scroll pauses follow; playback (re)start resumes it.

**PFW skills first:** `pfw-observable-models`, `pfw-testing`, `pfw-custom-dump`, `pfw-case-paths` (for asserting the follow-mode enum).

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptPageModel.swift`
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift:260-271` (`observePlayback`)
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/TranscriptFollowTests.swift`

**Interfaces:**
- Consumes: `document.wordRanges` (to know word order), `plan.words` sample bounds.
- Produces on the model:
  - `enum TranscriptFollowMode: Equatable { case following, userPaused }`
  - `var followMode: TranscriptFollowMode` (default `.following`)
  - `var scrollTargetWordID: Word.ID?`
  - `func playheadChanged(sample: Int?, isPlaying: Bool)` — on the rising edge of `isPlaying` (false→true) sets `.following`; while `.following` and playing, sets `scrollTargetWordID` to the word whose sample range contains `sample`.
  - `func transcriptUserScrolled()` — sets `.userPaused`.

- [ ] **Step 1: Write the failing test** — `TranscriptFollowTests.swift`

```swift
import Testing
import CustomDump
@testable import QuickInterviewEditor

@MainActor
struct TranscriptFollowTests {
  private var plan: EditPlan {
    EditPlan(
      schemaVersion: 1,
      source: .init(path: "", sampleRate: 1000, channels: 1, durationSamples: 3000),
      words: [
        Word(id: 1, text: "one", start: 0, end: 1, startSample: 0, endSample: 1000),
        Word(id: 2, text: "two", start: 1, end: 2, startSample: 1000, endSample: 2000),
        Word(id: 3, text: "three", start: 2, end: 3, startSample: 2000, endSample: 3000),
      ], silences: [], segments: [])
  }

  @Test func playheadWhileFollowingUpdatesScrollTarget() {
    let model = TranscriptPageModel(editPlan: plan)
    model.playheadChanged(sample: 1500, isPlaying: true)
    expectNoDifference(model.scrollTargetWordID, 2)
  }

  @Test func userScrollPausesFollowSoPlayheadStopsMovingTarget() {
    let model = TranscriptPageModel(editPlan: plan)
    model.playheadChanged(sample: 1500, isPlaying: true)
    model.transcriptUserScrolled()
    expectNoDifference(model.followMode, .userPaused)
    model.playheadChanged(sample: 2500, isPlaying: true)
    expectNoDifference(model.scrollTargetWordID, 2)  // unchanged while paused
  }

  @Test func playbackRestartResumesFollowing() {
    let model = TranscriptPageModel(editPlan: plan)
    model.playheadChanged(sample: 1500, isPlaying: true)
    model.transcriptUserScrolled()
    model.playheadChanged(sample: 0, isPlaying: false)      // stop
    model.playheadChanged(sample: 200, isPlaying: true)     // rising edge → resume
    expectNoDifference(model.followMode, .following)
    expectNoDifference(model.scrollTargetWordID, 1)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd QuickInterviewEditor && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates`
Expected: FAIL — follow API missing.

- [ ] **Step 3: Implement follow-mode** — in `TranscriptPageModel.swift`

Add near the top (after imports) or in the file:

```swift
enum TranscriptFollowMode: Equatable {
  case following
  case userPaused
}
```

Add to `// MARK: - Properties`:

```swift
  var followMode: TranscriptFollowMode = .following
  var scrollTargetWordID: Word.ID?
  @ObservationIgnored private var wasPlaying = false
```

Add to `// MARK: - User Actions`:

```swift
  func playheadChanged(sample: Int?, isPlaying: Bool) {
    if isPlaying, !wasPlaying { followMode = .following }  // rising edge resumes follow
    wasPlaying = isPlaying
    guard isPlaying, followMode == .following, let sample, let plan = editPlan else { return }
    scrollTargetWordID = plan.words.first { word in
      guard let start = word.startSample, let end = word.endSample else { return false }
      return sample >= start && sample < end
    }?.id ?? scrollTargetWordID
  }

  func transcriptUserScrolled() { followMode = .userPaused }
```

- [ ] **Step 4: Wire `EditorModel.observePlayback`** — modify the loop at `EditorModel.swift:261-267`

Inside the `for await position in audioPlayer.positions()` loop, after the existing waveform playhead line, push the same position into the transcript so it can follow:

```swift
      waveform.playheadSample = position.isPlaying ? position.sample : nil
      transcript.playheadChanged(sample: position.sample, isPlaying: position.isPlaying && playingSliceID != nil)
```

Keep the early `continue` branch (when this editor doesn't own playback) as-is; also clear the transcript follow target there is unnecessary — the model ignores non-playing ticks.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd QuickInterviewEditor && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptPageModel.swift \
        QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/TranscriptFollowTests.swift
git commit -m "feat(transcript): auto-scroll follow-mode driven by playhead"
```

---

### Task 5: Sensitivity slider debounce + gap records

Split the sensitivity value into a live draft (label only) and a debounced effective value, and precompute per-adjacent-word gap records so a sensitivity change filters gaps instead of re-walking timestamps.

**PFW skills first:** `pfw-dependencies` (inject `\.continuousClock`), `pfw-observable-models`, `pfw-testing`, `pfw-custom-dump`.

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Models/RunTogether.swift` (add gap records)
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptPageModel.swift`
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/TranscriptSensitivityTests.swift`

**Interfaces:**
- Produces:
  - `struct WordGap: Equatable { let leftID: Word.ID; let rightID: Word.ID; let gapMs: Double }`
  - `func wordGaps(_ words: [Word]) -> [WordGap]`
  - `func runTogetherWordIDs(gaps: [WordGap], maxGapMs: Double) -> Set<Word.ID>`
  - On the model: `@ObservationIgnored @Dependency(\.continuousClock) var clock`, `var draftGapMs: Double` (label-only live value), `func sensitivityDragChanged(_ ms: Double)` (updates draft + schedules debounced commit), `var sensitivityValueLabel: String`.

- [ ] **Step 1: Write the failing test** — `TranscriptSensitivityTests.swift`

```swift
import Clocks
import Dependencies
import Testing
import CustomDump
@testable import QuickInterviewEditor

@MainActor
struct TranscriptSensitivityTests {
  private var plan: EditPlan {
    EditPlan(
      schemaVersion: 1,
      source: .init(path: "", sampleRate: 1000, channels: 1, durationSamples: 3000),
      words: [
        Word(id: 1, text: "one", start: 0.0, end: 0.10, startSample: 0, endSample: 100),
        Word(id: 2, text: "two", start: 0.12, end: 0.30, startSample: 120, endSample: 300),  // 20ms gap
        Word(id: 3, text: "three", start: 0.90, end: 1.0, startSample: 900, endSample: 1000), // 600ms gap
      ], silences: [], segments: [])
  }

  @Test func gapRecordsComputeAdjacentGapsInMs() {
    let gaps = wordGaps(plan.words)
    expectNoDifference(
      gaps,
      [
        WordGap(leftID: 1, rightID: 2, gapMs: 20),
        WordGap(leftID: 2, rightID: 3, gapMs: 600),
      ])
  }

  @Test func runTogetherFromGapsMatchesThreshold() {
    let gaps = wordGaps(plan.words)
    expectNoDifference(runTogetherWordIDs(gaps: gaps, maxGapMs: 30), [1, 2])
    expectNoDifference(runTogetherWordIDs(gaps: gaps, maxGapMs: 10), [])
  }

  @Test func draftUpdatesImmediatelyButCommitIsDebounced() async {
    let clock = TestClock()
    await withDependencies {
      $0.continuousClock = clock
    } operation: {
      let model = TranscriptPageModel(editPlan: plan)
      model.sensitivityDragChanged(80)
      expectNoDifference(model.draftGapMs, 80)                 // label follows instantly
      expectNoDifference(model.runTogetherMaxGapMs, 30)        // effective value not yet committed
      await clock.advance(by: .milliseconds(200))
      expectNoDifference(model.runTogetherMaxGapMs, 80)        // committed after debounce
    }
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd QuickInterviewEditor && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates`
Expected: FAIL — gap records / debounce missing.

- [ ] **Step 3: Add gap records** — in `RunTogether.swift`

```swift
struct WordGap: Equatable {
  let leftID: Word.ID
  let rightID: Word.ID
  let gapMs: Double
}

/// Adjacent-word gaps in milliseconds, computed once so sensitivity changes filter
/// records instead of re-walking every word's timestamps.
func wordGaps(_ words: [Word]) -> [WordGap] {
  var gaps: [WordGap] = []
  for index in 0..<max(0, words.count - 1) {
    let cur = words[index]
    let next = words[index + 1]
    let curEnd = cur.end ?? cur.start
    gaps.append(WordGap(leftID: cur.id, rightID: next.id, gapMs: (next.start - curEnd) * 1000))
  }
  return gaps
}

func runTogetherWordIDs(gaps: [WordGap], maxGapMs: Double) -> Set<Word.ID> {
  var ids: Set<Word.ID> = []
  for gap in gaps where gap.gapMs < maxGapMs {
    ids.insert(gap.leftID)
    ids.insert(gap.rightID)
  }
  return ids
}
```

- [ ] **Step 4: Add debounce + gap cache to the model** — in `TranscriptPageModel.swift`

Add to `// MARK: - Dependencies`:

```swift
  @ObservationIgnored @Dependency(\.continuousClock) var clock
```

Add to `// MARK: - Properties`:

```swift
  var draftGapMs: Double = 30
  @ObservationIgnored private var gaps: [WordGap] = []
  @ObservationIgnored private var sensitivityCommitTask: Task<Void, Never>?
```

Build the cache in `recomputeWords()` right after `document = TranscriptDocument(words: plan.words)`:

```swift
    if gaps.isEmpty { gaps = wordGaps(plan.words) }
```

Replace the body of `runTogetherWordIDs(plan.words, maxGapMs:)` usage in `recomputeWords()` with the gap-based overload:

```swift
    let red = runTogetherWordIDs(gaps: gaps, maxGapMs: runTogetherMaxGapMs)
```

Add to `// MARK: - View Helpers`:

```swift
  var sensitivityValueLabel: String { "\(Int(draftGapMs)) ms" }
```

Add to `// MARK: - User Actions`:

```swift
  /// Live slider drag: update the label immediately, debounce the expensive recompute.
  func sensitivityDragChanged(_ ms: Double) {
    draftGapMs = ms
    sensitivityCommitTask?.cancel()
    sensitivityCommitTask = Task { [weak self] in
      guard let self else { return }
      try? await self.clock.sleep(for: .milliseconds(150))
      guard !Task.isCancelled else { return }
      self.commitSensitivity(ms)
    }
  }

  private func commitSensitivity(_ ms: Double) {
    runTogetherMaxGapMs = ms
    recomputeWords()
  }
```

Keep the existing `sensitivityChanged(_:)` for any non-drag callers, or route it through `commitSensitivity`. The view (Task 7) calls `sensitivityDragChanged`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd QuickInterviewEditor && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Models/RunTogether.swift \
        QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptPageModel.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/TranscriptSensitivityTests.swift
git commit -m "feat(transcript): debounce sensitivity slider + precomputed gap records"
```

---

### Task 6: Expose run-together ranges + repoint EditorModel

Give the renderer the sets it needs and let `EditorModel.redRanges` read run-together ranges directly from the transcript model, breaking its dependency on the per-word `words` array (which Task 8 deletes). Still additive — `words` stays until Task 8.

**PFW skills first:** `pfw-observable-models`, `pfw-testing`, `pfw-custom-dump`, `pfw-identified-collections`.

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptPageModel.swift`
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift:155-162` (`redRanges`)
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/TranscriptRunTogetherRangesTests.swift`

**Interfaces:**
- Produces on the model:
  - `var runTogetherWordIDSet: Set<Word.ID>` (for the renderer's diff)
  - `var runTogetherSampleRanges: [Range<Int>]` (ordered; words missing sample bounds excluded)
  - `var runTogetherCount: Int` re-expressed off the set (replaces the `words.filter` version)
- `EditorModel.redRanges` becomes `transcript.runTogetherSampleRanges`.

- [ ] **Step 1: Write the failing test** — `TranscriptRunTogetherRangesTests.swift`

```swift
import Testing
import CustomDump
@testable import QuickInterviewEditor

@MainActor
struct TranscriptRunTogetherRangesTests {
  private var plan: EditPlan {
    EditPlan(
      schemaVersion: 1,
      source: .init(path: "", sampleRate: 1000, channels: 1, durationSamples: 3000),
      words: [
        Word(id: 1, text: "one", start: 0.0, end: 0.10, startSample: 0, endSample: 100),
        Word(id: 2, text: "two", start: 0.12, end: 0.30, startSample: 120, endSample: 300),  // 20ms gap
        Word(id: 3, text: "three", start: 0.90, end: 1.0, startSample: 900, endSample: 1000),
      ], silences: [], segments: [])
  }

  @Test func exposesRunTogetherSetAndRanges() {
    let model = TranscriptPageModel(editPlan: plan)  // default 30ms → words 1,2 run together
    expectNoDifference(model.runTogetherWordIDSet, [1, 2])
    expectNoDifference(model.runTogetherSampleRanges, [0..<100, 120..<300])
    expectNoDifference(model.runTogetherCount, 2)
  }

  @Test func editorRedRangesTrackTranscript() {
    let editor = EditorModel(
      sourceURL: URL(fileURLWithPath: "/tmp/x.wav"),
      canonicalAudioURL: URL(fileURLWithPath: "/tmp/x.aiff"),
      editPlan: plan)
    expectNoDifference(editor.redRanges, [0..<100, 120..<300])
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd QuickInterviewEditor && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates`
Expected: FAIL — `runTogetherWordIDSet` / `runTogetherSampleRanges` missing.

- [ ] **Step 3: Expose the sets/ranges** — in `TranscriptPageModel.swift`

Add to `// MARK: - Properties` a stored set updated in `recomputeWords()` (so the renderer reads a stable value), or compute on demand. Simplest: store alongside `red`:

```swift
  var runTogetherWordIDSet: Set<Word.ID> = []
```

In `recomputeWords()`, after computing `red`, assign `runTogetherWordIDSet = red`.

Add to `// MARK: - View Helpers`:

```swift
  var runTogetherSampleRanges: [Range<Int>] {
    guard let plan = editPlan else { return [] }
    return plan.words.compactMap { word in
      guard runTogetherWordIDSet.contains(word.id),
        let start = word.startSample, let end = word.endSample, start < end
      else { return nil }
      return start..<end
    }
  }
```

Replace the existing `runTogetherCount` (which used `words.filter`) with:

```swift
  var runTogetherCount: Int { runTogetherWordIDSet.count }
```

- [ ] **Step 4: Repoint `EditorModel.redRanges`** — in `EditorModel.swift`

Replace the `redRanges` computed property body (currently iterating `transcript.words`) with:

```swift
  var redRanges: [Range<Int>] { transcript.runTogetherSampleRanges }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd QuickInterviewEditor && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptPageModel.swift \
        QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/TranscriptRunTogetherRangesTests.swift
git commit -m "feat(transcript): expose run-together sets/ranges; repoint EditorModel.redRanges"
```

---

### Task 7: `TranscriptTextView` (TextKit 1) + rewritten `TranscriptPageView`

Build the dumb TextKit renderer and rewrite the page view to use it, with zoom controls, keyboard shortcuts, and native scrolling. This task is **build-and-manual-verified** (no unit test — it is view code with zero logic). All decisions already live in the model from Tasks 1–6.

**PFW skills first:** `pfw-modern-swiftui`, `pfw-observable-models` (to re-confirm the boundary).

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptTextView.swift`
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptPageView.swift`

**Interfaces:**
- Consumes: `model.plainTranscriptText`, `model.document.wordRanges`, `model.selectedWordIDSet`, `model.runTogetherWordIDSet`, `model.fontSize`, `model.scrollTargetWordID`, `model.transcriptClicked/DragBegan/Dragged/Ended(atUTF16Offset:)`, `model.transcriptUserScrolled()`, `model.zoom*`, `model.sensitivityDragChanged`.

- [ ] **Step 1: Implement `TranscriptTextView`** — `TranscriptTextView.swift`

```swift
import AppKit
import SwiftUI

/// Dumb TextKit-1 renderer. Owns the AppKit objects and converts points to UTF-16
/// offsets; every decision (which word, selection, follow) lives in the model.
struct TranscriptTextView: NSViewRepresentable {
  let model: TranscriptPageModel

  func makeCoordinator() -> Coordinator { Coordinator(model: model) }

  func makeNSView(context: Context) -> NSScrollView {
    let textView = HitTestingTextView()
    textView.coordinator = context.coordinator
    textView.isEditable = false
    textView.isSelectable = false          // slice-selection owns click/drag; OS copy deferred
    textView.drawsBackground = true
    textView.backgroundColor = .black
    textView.textContainerInset = NSSize(width: 4, height: 8)
    textView.autoresizingMask = [.width]

    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.documentView = textView
    context.coordinator.textView = textView
    context.coordinator.scrollView = scroll
    context.coordinator.observeScroll()
    context.coordinator.rebuildText()      // full attributed string once
    return scroll
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    context.coordinator.model = model
    context.coordinator.apply()            // incremental: font + selection/run-together diffs, scroll target
  }

  @MainActor
  final class Coordinator: NSObject {
    var model: TranscriptPageModel
    weak var textView: NSTextView?
    weak var scrollView: NSScrollView?
    private var lastSelected: Set<Word.ID> = []
    private var lastRunTogether: Set<Word.ID> = []
    private var lastFontSize: Double = 0
    private var lastScrollTarget: Word.ID?
    private var isProgrammaticScroll = false

    init(model: TranscriptPageModel) { self.model = model }

    private static let selectedBG = NSColor(calibratedRed: 0.80, green: 0.40, blue: 0.40, alpha: 0.30)
    private static let selectedFG = NSColor.white
    private static let runTogetherFG = NSColor(calibratedRed: 0.89, green: 0.58, blue: 0.58, alpha: 1)
    private static let normalFG = NSColor(calibratedWhite: 0.56, alpha: 1)

    func rebuildText() {
      guard let storage = textView?.textStorage else { return }
      let attr = NSMutableAttributedString(string: model.plainTranscriptText)
      let full = NSRange(location: 0, length: attr.length)
      attr.addAttribute(.font, value: NSFont.systemFont(ofSize: model.fontSize), range: full)
      attr.addAttribute(.foregroundColor, value: Self.normalFG, range: full)
      storage.setAttributedString(attr)
      lastSelected = []; lastRunTogether = []; lastFontSize = model.fontSize
      applyWordColors(added: model.runTogetherWordIDSet, role: .runTogether)
      applySelection(added: model.selectedWordIDSet, removed: [])
      lastRunTogether = model.runTogetherWordIDSet
      lastSelected = model.selectedWordIDSet
    }

    func apply() {
      guard let storage = textView?.textStorage, let textView else { return }
      // Text changed (new plan) → full rebuild.
      if storage.string != model.plainTranscriptText { rebuildText() }
      // Zoom → full font update.
      if model.fontSize != lastFontSize {
        storage.addAttribute(.font, value: NSFont.systemFont(ofSize: model.fontSize),
          range: NSRange(location: 0, length: storage.length))
        lastFontSize = model.fontSize
      }
      // Run-together diff.
      let rtAdded = model.runTogetherWordIDSet.subtracting(lastRunTogether)
      let rtRemoved = lastRunTogether.subtracting(model.runTogetherWordIDSet)
      applyWordColors(added: rtAdded, role: .runTogether)
      applyWordColors(added: rtRemoved.subtracting(model.selectedWordIDSet), role: .normal)
      lastRunTogether = model.runTogetherWordIDSet
      // Selection diff.
      let selAdded = model.selectedWordIDSet.subtracting(lastSelected)
      let selRemoved = lastSelected.subtracting(model.selectedWordIDSet)
      applySelection(added: selAdded, removed: selRemoved)
      lastSelected = model.selectedWordIDSet
      _ = textView
      // Scroll target.
      if let target = model.scrollTargetWordID, target != lastScrollTarget,
        model.followMode == .following, let range = range(for: target) {
        isProgrammaticScroll = true
        textView.scrollRangeToVisible(range)
        isProgrammaticScroll = false
        lastScrollTarget = target
      }
    }

    private enum Role { case selected, runTogether, normal }

    private func range(for id: Word.ID) -> NSRange? {
      model.document.wordRanges.first { $0.wordID == id }?.range
    }

    private func applyWordColors(added: Set<Word.ID>, role: Role) {
      guard let storage = textView?.textStorage else { return }
      let color = role == .runTogether ? Self.runTogetherFG : Self.normalFG
      for id in added where !model.selectedWordIDSet.contains(id) {
        if let r = range(for: id) { storage.addAttribute(.foregroundColor, value: color, range: r) }
      }
    }

    private func applySelection(added: Set<Word.ID>, removed: Set<Word.ID>) {
      guard let storage = textView?.textStorage else { return }
      for id in removed {
        guard let r = range(for: id) else { continue }
        storage.removeAttribute(.backgroundColor, range: r)
        let fg = model.runTogetherWordIDSet.contains(id) ? Self.runTogetherFG : Self.normalFG
        storage.addAttribute(.foregroundColor, value: fg, range: r)
      }
      for id in added {
        guard let r = range(for: id) else { continue }
        storage.addAttribute(.backgroundColor, value: Self.selectedBG, range: r)
        storage.addAttribute(.foregroundColor, value: Self.selectedFG, range: r)
      }
    }

    // MARK: Scroll observation
    func observeScroll() {
      guard let clip = scrollView?.contentView else { return }
      clip.postsBoundsChangedNotifications = true
      NotificationCenter.default.addObserver(
        self, selector: #selector(boundsChanged),
        name: NSView.boundsDidChangeNotification, object: clip)
    }

    @objc private func boundsChanged() {
      guard !isProgrammaticScroll else { return }
      model.transcriptUserScrolled()
    }

    // MARK: Hit testing (point → UTF-16 offset → model)
    func utf16Offset(at point: NSPoint) -> Int? {
      guard let textView, let lm = textView.layoutManager, let container = textView.textContainer
      else { return nil }
      let local = NSPoint(x: point.x - textView.textContainerInset.width,
                          y: point.y - textView.textContainerInset.height)
      let glyph = lm.glyphIndex(for: local, in: container)
      return lm.characterIndexForGlyph(at: glyph)
    }
  }
}

/// Forwards mouse events to the coordinator as UTF-16 offsets. No decisions here.
final class HitTestingTextView: NSTextView {
  weak var coordinator: TranscriptTextView.Coordinator?

  override func mouseDown(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    guard let offset = coordinator?.utf16Offset(at: p) else { return }
    if event.clickCount == 1 { coordinator?.model.transcriptClicked(atUTF16Offset: offset) }
    coordinator?.model.transcriptDragBegan(atUTF16Offset: offset)
  }

  override func mouseDragged(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    guard let offset = coordinator?.utf16Offset(at: p) else { return }
    coordinator?.model.transcriptDragged(toUTF16Offset: offset)
  }

  override func mouseUp(with event: NSEvent) {
    coordinator?.model.transcriptDragEnded()
  }
}
```

> Note on click vs drag: `mouseDown` records a drag anchor; a genuine single click (no `mouseDragged`) still toggles via `transcriptClicked`. If a click followed by tiny jitter double-applies, gate `transcriptDragBegan` behind the first `mouseDragged` instead — decide during manual QA. Keep all such gating in the view's event plumbing, never a model decision.

- [ ] **Step 2: Rewrite `TranscriptPageView`** — `TranscriptPageView.swift`

Replace `transcriptFlow` with the renderer, add zoom controls to the header and keyboard shortcuts, and route the slider through `sensitivityDragChanged`. Delete `FlowLayout` and `color(for:)` here (they move out with Task 8; if the build needs them gone now to compile, remove them in this step).

```swift
import SwiftUI

struct TranscriptPageView: View {
  @Bindable var model: TranscriptPageModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      TranscriptTextView(model: model)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      controls
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color.black)
    .background {
      // Hidden buttons carry the ⌘+/⌘-/⌘0 shortcuts without cluttering the UI.
      Group {
        Button("", action: model.zoomInTapped).keyboardShortcut("+", modifiers: .command)
        Button("", action: model.zoomOutTapped).keyboardShortcut("-", modifiers: .command)
        Button("", action: model.zoomResetTapped).keyboardShortcut("0", modifiers: .command)
      }
      .opacity(0).frame(width: 0, height: 0)
    }
    .task { await model.viewAppeared() }
  }

  private var header: some View {
    HStack {
      Text(model.transcriptCaption)
        .font(.system(size: 11, weight: .semibold)).tracking(1.5)
        .foregroundStyle(Color(white: 0.44))
      Spacer()
      zoomControls
      Text(model.runTogetherLegend)
        .font(.system(size: 11)).foregroundStyle(Color(white: 0.48))
    }
  }

  private var zoomControls: some View {
    HStack(spacing: 6) {
      Button { model.zoomOutTapped() } label: { Image(systemName: "textformat.size.smaller") }
        .disabled(!model.canZoomOut)
      Slider(
        value: Binding(get: { model.fontSize }, set: { model.zoomChanged($0) }),
        in: model.minFontSize...model.maxFontSize)
        .frame(width: 120)
      Button { model.zoomInTapped() } label: { Image(systemName: "textformat.size.larger") }
        .disabled(!model.canZoomIn)
    }
    .buttonStyle(.borderless)
  }

  private var controls: some View {
    HStack(spacing: 16) {
      Button(model.clearButtonLabel) { model.clearSelectionTapped() }
        .disabled(!model.hasSelection)
      Text(model.selectionSummary).foregroundStyle(Color(white: 0.6))
      Spacer()
      Text(model.runTogetherCountLabel).foregroundStyle(Color(white: 0.6))
      Text(model.sensitivityLabel).foregroundStyle(Color(white: 0.6))
      Slider(
        value: Binding(get: { model.draftGapMs }, set: { model.sensitivityDragChanged($0) }),
        in: model.sensitivityMinMs...model.sensitivityMaxMs
      ).frame(width: 180)
    }
    .font(.system(size: 12))
  }
}
```

- [ ] **Step 3: Build**

Run: `cd QuickInterviewEditor && xcodebuild build -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates`
Expected: BUILD SUCCEEDED. (If `FlowLayout`/`WordViewState`/`words` references still exist elsewhere, they're removed in Task 8 — but the app must still compile now; if the view file no longer references them, the build passes.)

- [ ] **Step 4: Manual QA (see memory: quick-interview-editor-macos-build for launching the real build dir)**

Verify: a large fixture scrolls; ⌘+/⌘−/⌘0 and the zoom slider resize text and persist across relaunch; single-click selects one word; drag paints a contiguous run; run-together words render red; playback auto-scrolls and manual scroll pauses follow.

- [ ] **Step 5: Commit**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptTextView.swift \
        QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptPageView.swift
git commit -m "feat(transcript): TextKit NSTextView renderer with zoom controls + scroll"
```

---

### Task 8: Remove the old per-word path + final verification

Delete the now-dead FlowLayout/`WordViewState`/`words`/`recomputeWords`-driven code and confirm the whole suite is green. Every consumer was repointed in Tasks 1–7.

**PFW skills first:** `pfw-observable-models`, `pfw-testing`.

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptPageModel.swift`
- Modify/Delete: `QuickInterviewEditor/QuickInterviewEditor/Models/RunTogether.swift` (remove unused `WordViewState`/`WordDisplayRole` and the old `runTogetherWordIDs(_:maxGapMs:)` if no longer referenced)
- Modify: any remaining references to `model.words` (grep first)

- [ ] **Step 1: Find remaining consumers**

Run:
```bash
cd QuickInterviewEditor && grep -rn "\.words\b\|WordViewState\|WordDisplayRole\|FlowLayout\|wordTapped\|recomputeWords\|func runTogetherWordIDs(_ words" QuickInterviewEditor --include="*.swift" | grep -v Tests
```
Expected after Tasks 1–7: only `TranscriptPageModel` internals and `RunTogether.swift`.

- [ ] **Step 2: Remove dead code**

In `TranscriptPageModel.swift`: delete `var words: IdentifiedArrayOf<WordViewState>`, the `wordTapped(_:)` method (view no longer calls it; keep `selectWord`/`clearSelectionTapped`), and simplify `recomputeWords()` to only rebuild `document`, `gaps`, `red`/`runTogetherWordIDSet` (drop the `WordViewState` mapping and the `words = …` assignment). Rename `recomputeWords()` → `recompute()` if desired, updating call sites.

In `RunTogether.swift`: delete `WordViewState`, `WordDisplayRole`, the `displayRole` extension, and the old `runTogetherWordIDs(_ words:maxGapMs:)` if grep shows no remaining callers (the gap-based overload replaced it).

- [ ] **Step 3: Run the full suite + build**

Run: `cd QuickInterviewEditor && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates`
Expected: `Test run with N tests … passed`, BUILD SUCCEEDED.

- [ ] **Step 4: Lint + format**

Run: `cd QuickInterviewEditor && make lint && make format-check`
Expected: no violations. Run `make format` if needed and re-check.

- [ ] **Step 5: Commit**

```bash
git add -A QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptPageModel.swift \
          QuickInterviewEditor/QuickInterviewEditor/Models/RunTogether.swift
git commit -m "refactor(transcript): remove dead FlowLayout/WordViewState/words path"
```

---

## Self-Review

**Spec coverage:**
- Sluggishness fix → Tasks 1, 7, 8 (single NSTextView, incremental attributes) + Task 5 (debounce). ✓
- Text zoom (buttons + slider + ⌘ shortcuts, persisted) → Task 3 (state) + Task 7 (controls/shortcuts). ✓
- Vertical scroll → Task 7 (`NSScrollView`). ✓
- Contiguous click/drag selection → Task 2. ✓
- Auto-scroll follow with manual override → Task 4. ✓
- Efficient incremental re-render → Task 7 coordinator diffing. ✓
- `EditorModel.redRanges` repoint → Task 6. ✓
- Slider throttle + gap records → Task 5. ✓
- Copy deferred (non-goal) → not built; range map enables later. ✓

**Placeholder scan:** No TBD/TODO; every code step has real code. The single judgment call (click-vs-drag event gating in Task 7) is flagged for manual QA with a concrete fallback, and it lives in view event-plumbing, not model logic.

**Type consistency:** `TranscriptDocument`, `TranscriptWordRange`, `WordGap`, `TranscriptFollowMode`, `selectedWordIDSet`, `runTogetherWordIDSet`, `runTogetherSampleRanges`, `fontSize`, `scrollTargetWordID`, `sensitivityDragChanged`, `transcriptClicked/DragBegan/Dragged/Ended` are named identically across producing and consuming tasks. `EditorModel.redRanges` → `transcript.runTogetherSampleRanges` matches Task 6's exposed name.

**Note for the implementer:** `@Shared(.appStorage)` and `TestClock`/`ImmediateClock` APIs must match the installed Point-Free versions — invoke `pfw-sharing`, `pfw-dependencies`, and `pfw-testing` and adjust the exact call syntax while preserving the asserted behavior. The `NSTextView`/TextKit-1 hit-testing calls (`glyphIndex(for:in:)`, `characterIndexForGlyph(at:)`, `scrollRangeToVisible`) are stable macOS APIs.
