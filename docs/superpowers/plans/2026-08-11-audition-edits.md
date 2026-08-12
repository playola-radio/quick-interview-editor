# Audition Edits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a pro editor hear whether a cut lands cleanly — audition the out-point (2s pre-roll, stop dead on the cut) and the in-point (start on the cut, play forward) on whatever region is drawn on the waveform — via `[` / `]` / Space and on-waveform buttons.

**Architecture:** All behavior lives on `EditorModel`. A third playback owner (`audition`) joins the existing `playingSliceID` and `isPreviewingDraft`, all funneled through one `beginExclusivePlayback()` helper + a generation token so mashing keys never leaves stale UI. Keys are captured by a scoped `NSEvent` monitor (a dumb `NSViewRepresentable`) that stands down while a text field is focused. On-waveform edge buttons and a status line make the shortcuts always visible. Playback reuses the existing `AudioPlayerClient.play(url, Range<Int>, sampleRate)` primitive.

**Tech Stack:** Swift, SwiftUI, `@Observable`, swift-dependencies, swift-sharing, Swift Testing, swift-custom-dump, AppKit (`NSEvent`, `NSViewRepresentable`).

## Global Constraints

- **Skills (mandatory before writing code):** `pfw-observable-models` (model), `pfw-testing` + `pfw-custom-dump` (tests), `pfw-modern-swiftui` (views). Each subagent invokes the relevant `pfw-*` skills first and lists them in its checklist.
- **MV architecture:** zero logic in views. Every string, label, and *decision of what to show* is a model property. Views only position/style and call model actions.
- **Coordinates are plan samples** of `canonicalAudioURL`; sample rate is `editPlan.source.sampleRate`.
- **Value comparisons** use `expectNoDifference` / `expectDifference`, never raw `#expect(a == b)`.
- **Never use `Task.sleep` in tests.** Use the `PlayerGate` continuation pattern + the `settle(until:)` yield-loop already used in `EditorTests.swift`.
- **Model actions are named for the user action** (`auditionOutTapped`, not `playOutRange`).
- **Commands run from the `QuickInterviewEditor/` directory** (the one containing `Makefile` and `project.yml`):
  - Tests: `make test`
  - Lint: `make lint` — Format: `make format`
  - After adding any **new** source file: `make generate` (XcodeGen picks up files by folder), then `make test`.
- **Pre-roll:** 2.0 seconds. **Keys:** `[` = in-cut (keyCode 33), `]` = out-cut (keyCode 30), Space = stop/replay (keyCode 49).

---

## File map

- `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift` — **modify.** Audition state, actions, `beginExclusivePlayback`, `startAudition`, `stopAllPlayback`, extended `observePlayback`, refactor of `playSliceTapped`/`previewEditTapped`, display props, `AuditionMode`/`AuditionKey` enums.
- `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorAuditionTests.swift` — **create.** All model-level audition tests.
- `QuickInterviewEditor/QuickInterviewEditor/Views/Reusable Components/AuditionKeyMonitor.swift` — **create.** Dumb `NSViewRepresentable` key monitor.
- `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/WaveformView.swift` — **modify.** Edge buttons over the highlight span + status line binding.
- `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorView.swift` — **modify.** Mount the key monitor.

---

## Task 1: Unify playback ownership behind one helper

Introduce `beginExclusivePlayback()` and route the two existing playback starts through it, with no behavior change. This de-risks the audition owner added in Task 2 by first proving the refactor keeps all existing playback tests green.

**Files:**
- Modify: `Views/Pages/Editor/EditorModel.swift` (`playSliceTapped` ~415, `previewEditTapped` ~594; add helper near `observePlayback` ~276)
- Test: `QuickInterviewEditorTests/Views/Pages/Editor/EditorTests.swift` (add one coordination test)

**Interfaces:**
- Produces: `private func beginExclusivePlayback()` — resets **all** playback owners (`playingSliceID = nil`, `endTranscriptFollow()`, bumps `previewGeneration`, `isPreviewingDraft = false`) and, once Task 2 lands, the audition owner too. Callers set their own owner *after* calling it.

- [ ] **Step 1: Write the failing test** — starting a preview cancels a playing slice's ownership.

Add to `EditorTests.swift` (it already declares `PlayerGate`, `editor()`, `selectWords`, `addSlices`, `settle`):

```swift
@Test func startingPreviewSupersedesPlayingSlice() async {
  let gate = PlayerGate()
  let model = editor()
  addSlices(model, [(0, 2)])
  let slice = model.slices[0]
  await withDependencies {
    $0.audioPlayer.play = { _, _, _ in await gate.play() }
    $0.audioPlayer.stop = { gate.release() }
  } operation: {
    let slicePlay = Task { await model.playSliceTapped(slice.id) }
    await gate.awaitStarted()
    expectNoDifference(model.playingSliceID, slice.id)
    // Open a fine-tune session on the slice, then preview its draft.
    model.sliceSelected(slice.id)
    let preview = Task { await model.previewEditTapped() }
    await gate.awaitStarted()
    // The slice is no longer the owner; the preview took over.
    expectNoDifference(model.playingSliceID, nil)
    #expect(model.isPreviewingDraft)
    gate.release()
    await slicePlay.value
    await preview.value
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: FAIL — today `previewEditTapped` sets `playingSliceID = nil` itself, so this may already pass. If it PASSES, keep it (it becomes a regression guard) and proceed; the refactor must keep it green.

- [ ] **Step 3: Add the helper and route both starts through it**

Add near `observePlayback` (after line ~289):

```swift
/// Takes exclusive ownership of the single global player for a new playback: clears every
/// other owner's flag and bumps their generation tokens so a stale completing task can't
/// clear the new owner's state. The caller sets its own owner *after* calling this. The
/// audition owner is added in the audition section.
private func beginExclusivePlayback() {
  playingSliceID = nil
  endTranscriptFollow()
  previewGeneration &+= 1
  isPreviewingDraft = false
}
```

In `playSliceTapped(_:)`, replace the ownership prologue:

```swift
func playSliceTapped(_ id: Slice.ID) async {
  guard let slice = slices[id: id] else { return }
  beginExclusivePlayback()
  playingSliceID = id
  do {
    try await audioPlayer.play(
      canonicalAudioURL, slice.startSample..<slice.endSample, editPlan.source.sampleRate)
  } catch {
    reportIssue(error)
  }
  if playingSliceID == id {
    playingSliceID = nil
    endTranscriptFollow()
  }
}
```

(The old `if let playing = playingSliceID, playing != id { endTranscriptFollow() }` line is now covered by `beginExclusivePlayback` calling `endTranscriptFollow` unconditionally.)

In `previewEditTapped()`, replace the prologue:

```swift
func previewEditTapped() async {
  guard let range = fineTune.draftRange ?? fineTune.committedRange else { return }
  beginExclusivePlayback()
  previewGeneration &+= 1
  let generation = previewGeneration
  isPreviewingDraft = true
  do {
    try await audioPlayer.play(canonicalAudioURL, range, editPlan.source.sampleRate)
  } catch {
    reportIssue(error)
  }
  if previewGeneration == generation { isPreviewingDraft = false }
}
```

Note the double `previewGeneration &+= 1` (helper + local) is intentional and harmless — the local bump establishes this call's token after the helper's cancel-bump.

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: PASS — the new test plus all existing playback/preview tests in `EditorTests.swift` and `EditorFineTuneTests.swift` (nothing regressed by the unconditional `endTranscriptFollow`).

- [ ] **Step 5: Lint + commit**

```bash
make format && make lint
git add QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorTests.swift
git commit -m "refactor: funnel playback ownership through beginExclusivePlayback"
```

---

## Task 2: Audition state, in/out actions, and playhead during audition

Add the third owner and the two boundary auditions.

**Files:**
- Modify: `Views/Pages/Editor/EditorModel.swift` (properties ~64-86; helper from Task 1; `observePlayback` ~276; new audition section)
- Create: `QuickInterviewEditorTests/Views/Pages/Editor/EditorAuditionTests.swift`

**Interfaces:**
- Consumes: `beginExclusivePlayback()` (Task 1), `activeEditingRange: Range<Int>?` (`EditorModel.swift:117`), `editPlan.source.sampleRate`, `editPlan.source.durationSamples`, `audioPlayer.play`.
- Produces:
  - `enum AuditionMode: Equatable { case cutIn, cutOut }`
  - `enum AuditionKey: Equatable { case cutIn, cutOut, space }`
  - `var audition: AuditionMode?`
  - `func auditionInTapped() async`, `func auditionOutTapped() async`
  - `var canAudition: Bool`, `let auditionInButtonLabel/auditionOutButtonLabel: String`, `var isAuditioningIn/isAuditioningOut: Bool`, `var auditionStatusText: String?`

- [ ] **Step 1: Write the failing tests**

Create `QuickInterviewEditorTests/Views/Pages/Editor/EditorAuditionTests.swift`. It declares its own private gate + helpers, mirroring `EditorFineTuneTests.swift`:

```swift
import CustomDump
import Dependencies
import Foundation
import Testing

@testable import QuickInterviewEditor

/// Suspends each `play` until released; reports starts. Holds an ARRAY of continuations so
/// two overlapping plays (a supersession) can both be suspended and then resumed together —
/// a single-continuation gate would deadlock the first play. Mirrors EditorFineTuneTests's
/// PreviewPlayGate. `release()` has no sticky flag, so a play starting after a release still
/// suspends until the next release (needed by the Space-replay test).
private final class AuditionGate: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [CheckedContinuation<Void, Never>] = []
  private let startedContinuation: AsyncStream<Void>.Continuation
  let started: AsyncStream<Void>
  init() {
    var c: AsyncStream<Void>.Continuation!
    started = AsyncStream { c = $0 }
    startedContinuation = c
  }
  /// Signals "started", then suspends until `release()`.
  func play() async {
    startedContinuation.yield(())
    await withCheckedContinuation { cont in
      lock.lock(); continuations.append(cont); lock.unlock()
    }
  }
  /// Resumes every currently-suspended `play()` (natural completion, or a `stop`).
  func release() {
    lock.lock(); let conts = continuations; continuations = []; lock.unlock()
    for cont in conts { cont.resume() }
  }
  func awaitStarted() async {
    var it = started.makeAsyncIterator()
    _ = await it.next()
  }
}

@MainActor
struct EditorAuditionTests {
  private func editor(_ plan: EditPlan = Fixtures.editPlan()) -> EditorModel {
    EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: plan)
  }
  private func selectWords(_ transcript: TranscriptPageModel, _ first: Int, _ last: Int) {
    transcript.transcriptDragBegan(
      atUTF16Offset: transcript.document.wordRanges[first].range.location)
    transcript.transcriptDragged(
      toUTF16Offset: transcript.document.wordRanges[last].range.location)
  }
  private func settle(until condition: () -> Bool) async {
    for _ in 0..<1000 where !condition() { await Task.yield() }
  }

  // swiftlint:disable:next large_tuple
  private func recordingPlay(
    _ recorded: LockIsolated<(URL, Range<Int>, Int)?>, _ gate: AuditionGate
  ) -> @Sendable (URL, Range<Int>, Int) async throws -> Void {
    { url, range, rate in recorded.setValue((url, range, rate)); await gate.play() }
  }

  @Test func auditionOutPlaysPreRollEndingAtOutPoint() async {
    let gate = AuditionGate()
    let recorded = LockIsolated<(URL, Range<Int>, Int)?>(nil)
    let model = editor()
    selectWords(model.transcript, 3, 6)  // a mid-transcript region, so end - preRoll > 0
    let region = model.activeEditingRange!
    let preRoll = Int(model.auditionPreRollSeconds * Double(model.editPlan.source.sampleRate))
    await withDependencies {
      $0.audioPlayer.play = recordingPlay(recorded, gate)
      $0.audioPlayer.stop = { gate.release() }
    } operation: {
      let task = Task { await model.auditionOutTapped() }
      await gate.awaitStarted()
      expectNoDifference(model.audition, .cutOut)
      expectNoDifference(recorded.value?.0, model.canonicalAudioURL)
      expectNoDifference(
        recorded.value?.1, max(0, region.upperBound - preRoll)..<region.upperBound)
      expectNoDifference(recorded.value?.2, model.editPlan.source.sampleRate)
      gate.release()
      await task.value
      expectNoDifference(model.audition, nil)
    }
  }

  @Test func auditionOutClampsPreRollAtZero() async {
    let gate = AuditionGate()
    let recorded = LockIsolated<(URL, Range<Int>, Int)?>(nil)
    let model = editor()
    // Drive the region from an active slice with a deterministic, tiny out-point (< pre-roll),
    // so the clamp is exercised regardless of the fixture's word timings. `activeSliceRange`
    // needs only `activeSliceID` + the slice present.
    let shortSlice = Slice(
      id: UUID(), name: "S", startSample: 0, endSample: 1000, wordIDs: [], snippet: "x",
      warnings: [])
    model.slices.append(shortSlice)
    model.activeSliceID = shortSlice.id
    expectNoDifference(model.activeEditingRange, 0..<1000)
    let preRoll = Int(model.auditionPreRollSeconds * Double(model.editPlan.source.sampleRate))
    #expect(1000 < preRoll)  // 2s @ any sane rate ≫ 1000 samples, so end - preRoll < 0
    await withDependencies {
      $0.audioPlayer.play = recordingPlay(recorded, gate)
      $0.audioPlayer.stop = { gate.release() }
    } operation: {
      let task = Task { await model.auditionOutTapped() }
      await gate.awaitStarted()
      expectNoDifference(recorded.value?.1, 0..<1000)  // clamped at 0, still ends on the cut
      gate.release()
      await task.value
    }
  }

  @Test func auditionInPlaysFromInPointToEndOfFile() async {
    let gate = AuditionGate()
    let recorded = LockIsolated<(URL, Range<Int>, Int)?>(nil)
    let model = editor()
    selectWords(model.transcript, 2, 4)
    let region = model.activeEditingRange!
    await withDependencies {
      $0.audioPlayer.play = recordingPlay(recorded, gate)
      $0.audioPlayer.stop = { gate.release() }
    } operation: {
      let task = Task { await model.auditionInTapped() }
      await gate.awaitStarted()
      expectNoDifference(model.audition, .cutIn)
      expectNoDifference(
        recorded.value?.1, region.lowerBound..<model.editPlan.source.durationSamples)
      gate.release()
      await task.value
    }
  }

  @Test func auditionNoOpsWithoutARegion() async {
    let played = LockIsolated(false)
    let model = editor()  // no selection, no active slice → activeEditingRange == nil
    #expect(model.activeEditingRange == nil)
    #expect(!model.canAudition)
    await withDependencies {
      $0.audioPlayer.play = { _, _, _ in played.setValue(true) }
    } operation: {
      await model.auditionInTapped()
      await model.auditionOutTapped()
    }
    #expect(!played.value)
    expectNoDifference(model.audition, nil)
  }

  @Test func startingAuditionSupersedesSlicePlayback() async {
    let gate = AuditionGate()
    let model = editor()
    selectWords(model.transcript, 0, 2)
    model.addSliceTapped()
    let slice = model.slices[0]
    await withDependencies {
      $0.audioPlayer.play = { _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { gate.release() }
    } operation: {
      let slicePlay = Task { await model.playSliceTapped(slice.id) }
      await gate.awaitStarted()
      expectNoDifference(model.playingSliceID, slice.id)
      selectWords(model.transcript, 3, 5)  // a region to audition
      let audition = Task { await model.auditionInTapped() }
      await gate.awaitStarted()
      expectNoDifference(model.playingSliceID, nil)   // slice ownership released
      expectNoDifference(model.audition, .cutIn)
      gate.release()
      await slicePlay.value
      await audition.value
    }
  }

  @Test func startingSlicePlaybackSupersedesAudition() async {
    let gate = AuditionGate()
    let model = editor()
    selectWords(model.transcript, 0, 2)
    model.addSliceTapped()
    let slice = model.slices[0]
    await withDependencies {
      $0.audioPlayer.play = { _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { gate.release() }
    } operation: {
      selectWords(model.transcript, 3, 5)
      let audition = Task { await model.auditionOutTapped() }
      await gate.awaitStarted()
      expectNoDifference(model.audition, .cutOut)
      let slicePlay = Task { await model.playSliceTapped(slice.id) }
      await gate.awaitStarted()
      expectNoDifference(model.audition, nil)          // audition ownership released
      expectNoDifference(model.playingSliceID, slice.id)
      gate.release()
      await audition.value
      await slicePlay.value
    }
  }

  @Test func rePressingRestartsSameAudition() async {
    let gate = AuditionGate()
    let starts = LockIsolated(0)
    let model = editor()
    selectWords(model.transcript, 3, 5)
    await withDependencies {
      $0.audioPlayer.play = { _, _, _ in starts.withValue { $0 += 1 }; await gate.play() }
      $0.audioPlayer.stop = { gate.release() }
    } operation: {
      let first = Task { await model.auditionOutTapped() }
      await gate.awaitStarted()
      let second = Task { await model.auditionOutTapped() }  // re-press supersedes
      await gate.awaitStarted()
      expectNoDifference(model.audition, .cutOut)
      #expect(starts.value == 2)
      gate.release()
      await first.value
      await second.value
    }
  }

  @Test func staleAuditionCompletionDoesNotClearNewerOwner() async {
    let gate = AuditionGate()
    let model = editor()
    selectWords(model.transcript, 3, 5)
    await withDependencies {
      $0.audioPlayer.play = { _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { gate.release() }
    } operation: {
      let first = Task { await model.auditionOutTapped() }
      await gate.awaitStarted()
      let second = Task { await model.auditionInTapped() }  // supersedes; newer owner is .cutIn
      await gate.awaitStarted()
      expectNoDifference(model.audition, .cutIn)
      gate.release()               // completes BOTH suspended plays (older then newer)
      await first.value
      await settle { model.audition == nil }
      // The stale .cutOut completion must not have cleared, then the newer .cutIn clears itself.
      await second.value
      expectNoDifference(model.audition, nil)
    }
  }

  @Test func observePlaybackMovesPlayheadWhileAuditioning() async {
    let model = editor()
    model.audition = .cutIn  // this editor owns audition playback
    let (stream, continuation) = AsyncStream.makeStream(of: PlaybackPosition.self)
    await withDependencies {
      $0.audioPlayer.positions = { stream }
    } operation: {
      let task = Task { await model.observePlayback() }
      continuation.yield(PlaybackPosition(sample: 2000, isPlaying: true))
      await settle { model.waveform.playheadSample == 2000 }
      #expect(model.waveform.playheadSample == 2000)
      continuation.finish()
      await task.value
      #expect(model.waveform.playheadSample == nil)
    }
  }

  @Test func displayPropsReflectAuditionState() {
    let model = editor()
    expectNoDifference(model.canAudition, false)
    #expect(model.auditionStatusText == nil)
    selectWords(model.transcript, 1, 3)
    expectNoDifference(model.canAudition, true)
    model.audition = .cutOut
    #expect(model.isAuditioningOut)
    #expect(!model.isAuditioningIn)
    expectNoDifference(model.auditionStatusText, "Auditioning out-cut — Space to stop")
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make generate && make test`
Expected: FAIL to compile — `audition`, `auditionInTapped`, `auditionOutTapped`, `canAudition`, `auditionPreRollSeconds`, `auditionStatusText`, `isAuditioningIn/Out` don't exist yet.

- [ ] **Step 3: Add audition state + actions to `EditorModel`**

In the Properties section (after `previewGeneration`, ~line 78) add:

```swift
/// Which boundary audition is currently playing, or nil. The third playback owner
/// alongside `playingSliceID` and `isPreviewingDraft`.
var audition: AuditionMode?
/// The last audition the user triggered this session — replayed by Space when idle.
@ObservationIgnored private var lastAudition: AuditionMode?
/// Bumped each time an audition starts or is superseded, so a stale completing audition
/// task can't clear a newer owner's state (mirrors `previewGeneration`).
@ObservationIgnored private var auditionGeneration = 0
```

Add the enums near the top-level types (e.g. below `ExportPhase`, ~line 62):

```swift
enum AuditionMode: Equatable { case cutIn, cutOut }
enum AuditionKey: Equatable { case cutIn, cutOut, space }
```

Extend `beginExclusivePlayback()` (from Task 1) to also clear the audition owner:

```swift
private func beginExclusivePlayback() {
  playingSliceID = nil
  endTranscriptFollow()
  previewGeneration &+= 1
  isPreviewingDraft = false
  auditionGeneration &+= 1
  audition = nil
}
```

Extend the `observePlayback()` guard (line ~278) to include auditions:

```swift
guard playingSliceID != nil || isPreviewingDraft || audition != nil else {
  if waveform.playheadSample != nil { waveform.playheadSample = nil }
  continue
}
```

(Leave the transcript-follow line unchanged — `isPlaying: position.isPlaying && playingSliceID != nil` — so auditions move the waveform playhead but don't drive transcript scroll.)

Add a new `// MARK: - Audition` section (place it after the preview actions, ~line 612):

```swift
// MARK: - Audition
let auditionPreRollSeconds = 2.0
let auditionInButtonLabel = "▶ In  ["
let auditionOutButtonLabel = "]  Out ▶"

/// Samples of pre-roll for the out-cut audition, from the plan sample rate.
private var auditionPreRollSamples: Int {
  Int(auditionPreRollSeconds * Double(editPlan.source.sampleRate))
}
/// The region drawn on the waveform, if it's a non-empty range worth auditioning.
private var auditionRegion: Range<Int>? {
  guard let region = activeEditingRange, !region.isEmpty else { return nil }
  return region
}
var canAudition: Bool { auditionRegion != nil }
var isAuditioningIn: Bool { audition == .cutIn }
var isAuditioningOut: Bool { audition == .cutOut }
var auditionStatusText: String? {
  switch audition {
  case .cutIn: return "Auditioning in-cut — Space to stop"
  case .cutOut: return "Auditioning out-cut — Space to stop"
  case .none: return nil
  }
}

/// In-cut: drop in at the region's start and play forward to end-of-file.
func auditionInTapped() async {
  guard let region = auditionRegion else { return }
  let end = editPlan.source.durationSamples
  guard region.lowerBound < end else { return }
  await startAudition(.cutIn, range: region.lowerBound..<end)
}

/// Out-cut: play a pre-roll ending exactly at the region's out-point, stopping on the cut.
/// The pre-roll may begin before the region's own start (clamped at 0).
func auditionOutTapped() async {
  guard let region = auditionRegion else { return }
  let end = region.upperBound
  let start = max(0, end - auditionPreRollSamples)
  await startAudition(.cutOut, range: start..<end)
}

/// Shared audition start. `beginExclusivePlayback`'s generation bump is this call's token —
/// only the latest audition clears `audition` on completion, so mashing keys can't leave
/// stale UI (mirrors `playSliceTapped`'s id check and `previewEditTapped`'s generation check).
private func startAudition(_ mode: AuditionMode, range: Range<Int>) async {
  guard !range.isEmpty else { return }
  beginExclusivePlayback()
  let generation = auditionGeneration
  audition = mode
  lastAudition = mode
  do {
    try await audioPlayer.play(canonicalAudioURL, range, editPlan.source.sampleRate)
  } catch {
    reportIssue(error)
  }
  if auditionGeneration == generation { audition = nil }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: PASS — all of `EditorAuditionTests` plus the existing suites.

- [ ] **Step 5: Lint + commit**

```bash
make format && make lint
git add QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorAuditionTests.swift
git commit -m "feat: audition in/out cut boundaries with pre-roll and playhead"
```

---

## Task 3: Space to stop / replay, and key routing

**Files:**
- Modify: `Views/Pages/Editor/EditorModel.swift` (audition section)
- Test: `QuickInterviewEditorTests/Views/Pages/Editor/EditorAuditionTests.swift`

**Interfaces:**
- Consumes: `beginExclusivePlayback()`, `auditionInTapped`, `auditionOutTapped`, `audition`, `playingSliceID`, `isPreviewingDraft`.
- Produces: `func auditionSpaceTapped() async`, `func auditionKeyPressed(_ key: AuditionKey) async`, `private func stopAllPlayback() async`.

- [ ] **Step 1: Write the failing tests**

Append to `EditorAuditionTests`:

```swift
@Test func spaceStopsAnActiveAudition() async {
  let gate = AuditionGate()
  let stopped = LockIsolated(false)
  let model = editor()
  selectWords(model.transcript, 3, 5)
  await withDependencies {
    $0.audioPlayer.play = { _, _, _ in await gate.play() }
    $0.audioPlayer.stop = { stopped.setValue(true); gate.release() }
  } operation: {
    let task = Task { await model.auditionInTapped() }
    await gate.awaitStarted()
    await model.auditionSpaceTapped()  // playing → stop
    await task.value
    expectNoDifference(model.audition, nil)
    #expect(stopped.value)
  }
}

@Test func spaceStopsSlicePlayback() async {
  let gate = AuditionGate()
  let stopped = LockIsolated(false)
  let model = editor()
  selectWords(model.transcript, 0, 2)
  model.addSliceTapped()
  let slice = model.slices[0]
  await withDependencies {
    $0.audioPlayer.play = { _, _, _ in await gate.play() }
    $0.audioPlayer.stop = { stopped.setValue(true); gate.release() }
  } operation: {
    let task = Task { await model.playSliceTapped(slice.id) }
    await gate.awaitStarted()
    await model.auditionSpaceTapped()  // stops whatever the editor owns
    await task.value
    expectNoDifference(model.playingSliceID, nil)
    #expect(stopped.value)
  }
}

@Test func spaceWhenIdleReplaysLastAudition() async {
  let gate = AuditionGate()
  let recorded = LockIsolated<(URL, Range<Int>, Int)?>(nil)
  let model = editor()
  selectWords(model.transcript, 3, 6)
  let region = model.activeEditingRange!
  let preRoll = Int(model.auditionPreRollSeconds * Double(model.editPlan.source.sampleRate))
  await withDependencies {
    $0.audioPlayer.play = recordingPlay(recorded, gate)
    $0.audioPlayer.stop = { gate.release() }
  } operation: {
    let out = Task { await model.auditionOutTapped() }  // last audition = .cutOut
    await gate.awaitStarted()
    gate.release()
    await out.value
    expectNoDifference(model.audition, nil)
    // Idle now: Space replays the out-cut, not the in-cut.
    let replay = Task { await model.auditionSpaceTapped() }
    await gate.awaitStarted()
    expectNoDifference(model.audition, .cutOut)
    expectNoDifference(recorded.value?.1, max(0, region.upperBound - preRoll)..<region.upperBound)
    gate.release()
    await replay.value
  }
}

@Test func spaceWhenIdleWithNoHistoryPlaysInCut() async {
  let gate = AuditionGate()
  let model = editor()
  selectWords(model.transcript, 2, 4)
  await withDependencies {
    $0.audioPlayer.play = { _, _, _ in await gate.play() }
    $0.audioPlayer.stop = { gate.release() }
  } operation: {
    let task = Task { await model.auditionSpaceTapped() }
    await gate.awaitStarted()
    expectNoDifference(model.audition, .cutIn)
    gate.release()
    await task.value
  }
}

@Test func auditionKeyPressedRoutesToActions() async {
  let gate = AuditionGate()
  let recorded = LockIsolated<(URL, Range<Int>, Int)?>(nil)
  let model = editor()
  selectWords(model.transcript, 2, 4)
  let region = model.activeEditingRange!
  await withDependencies {
    $0.audioPlayer.play = recordingPlay(recorded, gate)
    $0.audioPlayer.stop = { gate.release() }
  } operation: {
    let task = Task { await model.auditionKeyPressed(.cutIn) }
    await gate.awaitStarted()
    expectNoDifference(model.audition, .cutIn)
    expectNoDifference(
      recorded.value?.1, region.lowerBound..<model.editPlan.source.durationSamples)
    gate.release()
    await task.value
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test`
Expected: FAIL to compile — `auditionSpaceTapped`, `auditionKeyPressed` don't exist.

- [ ] **Step 3: Implement Space + routing**

Add to the audition section:

```swift
/// Space: stop whatever the editor is playing; if idle, replay the last audition, else in-cut.
func auditionSpaceTapped() async {
  if playingSliceID != nil || isPreviewingDraft || audition != nil {
    await stopAllPlayback()
    return
  }
  switch lastAudition ?? .cutIn {
  case .cutIn: await auditionInTapped()
  case .cutOut: await auditionOutTapped()
  }
}

/// Routes a captured key to its action so the key-monitor view stays logic-free.
func auditionKeyPressed(_ key: AuditionKey) async {
  switch key {
  case .cutIn: await auditionInTapped()
  case .cutOut: await auditionOutTapped()
  case .space: await auditionSpaceTapped()
  }
}

/// Stops any editor-owned playback (slice, preview, or audition) and clears all owners.
private func stopAllPlayback() async {
  beginExclusivePlayback()
  await audioPlayer.stop()
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Lint + commit**

```bash
make format && make lint
git add QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorAuditionTests.swift
git commit -m "feat: Space stops or replays the last audition; key routing"
```

---

## Task 4: Scoped keyboard monitor

A dumb `NSViewRepresentable` installing an `NSEvent` local key-down monitor that stands down while a text field is being edited. No unit test (a logic-free AppKit bridge, like the live audio engine path); verified by build + manual check.

**Files:**
- Create: `Views/Reusable Components/AuditionKeyMonitor.swift`
- Modify: `Views/Pages/Editor/EditorView.swift`

**Interfaces:**
- Consumes: `AuditionKey` (Task 2), `EditorModel.auditionKeyPressed(_:)` (Task 3).
- Produces: `struct AuditionKeyMonitor: NSViewRepresentable` taking `onKey: (AuditionKey) -> Void`.

- [ ] **Step 1: Create the monitor**

```swift
import AppKit
import SwiftUI

/// A logic-free bridge: installs an app-local key-down monitor while it's mounted and forwards
/// the audition keys ( [ ] space ) to the model. It stands down while a text field is being
/// edited (the field editor is first responder), so slice renaming and any future text input
/// keep the keys. The transcript is a non-editable NSTextView, so it never blocks auditions.
struct AuditionKeyMonitor: NSViewRepresentable {
  let onKey: (AuditionKey) -> Void

  func makeNSView(context: Context) -> TrackingView {
    let view = TrackingView()
    context.coordinator.onKey = onKey
    context.coordinator.install(host: view)
    return view
  }

  func updateNSView(_ nsView: TrackingView, context: Context) {
    context.coordinator.onKey = onKey
  }

  static func dismantleNSView(_ nsView: TrackingView, coordinator: Coordinator) {
    coordinator.remove()
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  /// A zero-size marker view; its only job is to give the coordinator a handle on the window.
  final class TrackingView: NSView {}

  final class Coordinator {
    var onKey: ((AuditionKey) -> Void)?
    private weak var host: NSView?
    private var monitor: Any?

    func install(host: NSView) {
      self.host = host
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        self?.handle(event) ?? event
      }
    }

    func remove() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
      // Only act for the window this view lives in, and only when it's key.
      guard let window = host?.window, window.isKeyWindow, event.window === window else {
        return event
      }
      // Stand down while a text field is being edited.
      if let responder = window.firstResponder as? NSText, responder.isEditable {
        return event
      }
      let key: AuditionKey?
      switch event.keyCode {
      case 33: key = .cutIn   // [
      case 30: key = .cutOut  // ]
      case 49: key = .space   // space
      default: key = nil
      }
      guard let key else { return event }
      onKey?(key)
      return nil  // consume so the key doesn't also scroll / beep
    }
  }
}
```

- [ ] **Step 2: Mount it in `EditorView`**

In `EditorView.swift`, add a background to the root `HStack` (after `.background(Color.black)`):

```swift
.background(
  AuditionKeyMonitor { key in
    Task { await model.auditionKeyPressed(key) }
  }
)
```

- [ ] **Step 3: Generate + build + manual verify**

Run: `make generate && make test`
Expected: builds and the full suite passes (no new tests here).

Manual check (run the app): with a slice selected, `[` starts the in-cut, `]` plays the 2s out-cut and stops on the cut, Space stops/replays. Click into a slice-rename field and confirm `[` `]` Space type normally and do **not** trigger auditions.

- [ ] **Step 4: Lint + commit**

```bash
make format && make lint
git add QuickInterviewEditor/QuickInterviewEditor/Views/Reusable\ Components/AuditionKeyMonitor.swift \
        QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorView.swift \
        QuickInterviewEditor/QuickInterviewEditor.xcodeproj/project.pbxproj
git commit -m "feat: scoped NSEvent key monitor for audition shortcuts"
```

---

## Task 5: On-waveform buttons + status line

Make the shortcuts always visible: two edge buttons over the highlight span (labels carry the keys), and a status line while auditioning. View-only; all content/decisions come from model props added in Task 2.

**Files:**
- Modify: `Views/Pages/Editor/WaveformView.swift`

**Interfaces:**
- Consumes: `model.canAudition`, `model.waveformHighlightSpan` (`WaveformSpan {positionX, width}`), `model.auditionInButtonLabel/auditionOutButtonLabel`, `model.isAuditioningIn/isAuditioningOut`, `model.auditionStatusText`, `model.auditionInTapped()/auditionOutTapped()`.

- [ ] **Step 1: Add the edge buttons overlay**

In `WaveformView.body`, add an overlay to the band `ZStack` (the one framed to `bandHeight`), after `.gesture(panGesture)`:

```swift
.overlay(alignment: .topLeading) {
  if model.canAudition, let span = model.waveformHighlightSpan {
    AuditionEdgeButtons(model: model, span: span)
  }
}
```

Add the subview at the bottom of the file (alongside `WaveformCanvas`):

```swift
/// Two buttons pinned to the highlighted region's edges. Labels (and their keys) come from the
/// model; this view only positions them and clamps so they don't overlap on a narrow span.
private struct AuditionEdgeButtons: View {
  let model: EditorModel
  let span: WaveformSpan

  private let buttonWidth: CGFloat = 74
  private let gap: CGFloat = 4

  var body: some View {
    // Left edge for In, right edge for Out; clamp both into a side-by-side pair when the span
    // is too narrow to separate them.
    let leftIdeal = span.positionX
    let rightIdeal = span.positionX + span.width - buttonWidth
    let clampedRight = max(rightIdeal, leftIdeal + buttonWidth + gap)
    ZStack(alignment: .topLeading) {
      button(model.auditionInButtonLabel, active: model.isAuditioningIn) {
        Task { await model.auditionInTapped() }
      }
      .offset(x: leftIdeal, y: 8)
      button(model.auditionOutButtonLabel, active: model.isAuditioningOut) {
        Task { await model.auditionOutTapped() }
      }
      .offset(x: clampedRight, y: 8)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .allowsHitTesting(true)
  }

  private func button(_ label: String, active: Bool, _ run: @escaping () -> Void)
    -> some View
  {
    Button(action: run) {
      Text(label)
        .font(.system(size: 11, weight: .semibold))
        .frame(width: buttonWidth)
        .padding(.vertical, 3)
    }
    .buttonStyle(.borderless)
    .background(
      RoundedRectangle(cornerRadius: 4)
        .fill(active ? Color(red: 0.96, green: 0.86, blue: 0.4).opacity(0.28)
                     : Color.white.opacity(0.12)))
    .foregroundStyle(active ? Color(red: 0.96, green: 0.86, blue: 0.4) : Color(white: 0.85))
  }
}
```

- [ ] **Step 2: Add the status line to the header**

In `WaveformView.header`, put the status between the caption and the `Spacer`:

```swift
private var header: some View {
  HStack(spacing: 12) {
    Text(model.waveform.caption)
      .font(.system(size: 11, weight: .semibold)).tracking(1.5)
      .foregroundStyle(Color(white: 0.44))
    if let status = model.auditionStatusText {
      Text(status)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Color(red: 0.96, green: 0.86, blue: 0.4))
    }
    Spacer()
    // …existing zoom buttons unchanged…
```

- [ ] **Step 3: Build + manual verify**

Run: `make test`
Expected: builds, full suite passes.

Manual check: selecting words shows `▶ In  [` at the region's left edge and `]  Out ▶` at the right; on a very narrow selection the two sit side-by-side without overlapping. Clicking each does the same as its key. While an audition plays, the active button highlights and the header shows "Auditioning …-cut — Space to stop".

- [ ] **Step 4: Lint + commit**

```bash
make format && make lint
git add QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/WaveformView.swift
git commit -m "feat: on-waveform audition buttons and status line"
```

---

## Self-review notes (coverage of the spec)

- Source of truth `activeEditingRange` (not `highlightedSampleRange`): Task 2 `auditionRegion`. ✅
- Out-cut `[max(0, end - preRoll), end)` + clamp: Task 2 tests `auditionOutPlaysPreRollEndingAtOutPoint`, `auditionOutClampsPreRollAtZero`. ✅
- In-cut `[start, durationSamples)`: Task 2 `auditionInPlaysFromInPointToEndOfFile`. ✅
- Space stop/replay/in: Task 3. ✅
- Re-press restarts; `[`/`]` never toggle-stop: Task 2 `rePressingRestartsSameAudition`. ✅
- One ownership path + generation guard + supersession both ways: Tasks 1-2. ✅
- `observePlayback` gate includes auditions: Task 2. ✅
- Keys via scoped `NSEvent`, stands down in text fields: Task 4. ✅
- Discoverability (edge buttons w/ keys, status, narrow-span clamp, disabled when no region): Task 5 + `canAudition`. ✅
- Deferred (not in plan, per spec): transcript-follow during audition, silence-zone warnings, unified-enum rewrite. ✅

**Known limitation to flag at review:** the `NSEvent` monitor is scoped to its key window; if the app ever renders two `EditorView`s concurrently in the *same* window, both monitors would fire. The app shows one editor at a time, so this is acceptable for v1 — revisit if concurrent same-window editors land.
