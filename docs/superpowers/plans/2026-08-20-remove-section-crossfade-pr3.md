# Remove Section + Crossfade — PR 3 Implementation Plan (Live edited transport — "hear the edit")

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Also invoke the relevant `pfw-*` skills before writing Swift (this repo mandates them): `pfw-observable-models`, `pfw-dependencies`, `pfw-testing`, `pfw-custom-dump`, `pfw-sharing`, `pfw-identified-collections`. List them in your checklist.
>
> **Model tiering (binding for this PR):** the coordinate migration (Tasks 1–3's design-bearing edits in `EditorModel`/`AudioPlayerClient`) stays in the coordinating agent's own loop — it is exactly the stale-anchor-prone shape this repo was burned by in PR #54. Delegate to Sonnet subagents only: mechanical test renames/updates once specified, `removalPlaybackNote` removal, and build/test/lint runs.

**Goal:** The main transport plays the edited timeline — removals collapsed, seams blended by the equal-power crossfade — with every position consumer converted to EDITED coordinates first, so the cursor, ruler, transcript highlight, and pause/resume/seek stay truthful at any rate.

**Architecture:** Three moves, strictly ordered. (1) The transport cursor becomes `playheadEditedSample` — always the edited axis, identity when there are no removals, never a runtime branch on removals existing — and every consumer (current-word sync, waveform/ruler playhead, selection snaps, pause freeze, slice-edit modal boundary) converts through `EditedTimeline` at its boundary. (2) The player contract makes the coordinate space unambiguous in types: `PlaybackPosition`/`pause` carry an axis-tagged `PlaybackSample` (`.source` for `play(url:range:)` sessions, `.edited` for playlist sessions). (3) `playEdited` is exposed on `AudioPlayerClient` and the main Play path builds an `AudioEditRenderPlan` from the cursor (seek = stop + rebuild plan from the new edited sample; a seek into a seam gets a partial-seam plan so the fade continues). Slice/preview/audition/slice-edit-modal playback stays on the source-range path (their ranges ARE source data); the modal stays source-coordinate internally.

**Tech Stack:** Swift 6, SwiftUI + AppKit (macOS), `@Observable` MV models, swift-dependencies, Swift Testing, swift-custom-dump, AVFoundation (`AVAudioPlayerNode` playlist scheduling already spiked in PR 2).

**Spec:** `docs/superpowers/specs/2026-08-18-remove-section-crossfade-design.md` (§6 superseded) + `docs/superpowers/plans/2026-08-20-remove-section-crossfade-completion.md` (locked decisions 2 & 3 + the PR 3 section INCLUDING its Codex challenge contract note). Read both before starting.

## Global Constraints

- **The contract note is binding:** every position consumer converts to edited coordinates BEFORE `playEdited` is wired to the transport (Tasks 1–2 before Task 3). Never a bare `sample` that could mean either axis in new/renamed code.
- **Coordinates are SAMPLES.** New names must carry the axis: `playheadEditedSample`, `sourceSample`, `editedSample`, `PlaybackSample.source/.edited`.
- **Slice-edit modal stays SOURCE-coordinate internally** and keeps the `play(url:range:)` path; convert at its boundary only.
- **Export stays hard-blocked** while removals exist (`canExportAll`/`canExportSlice` unchanged — that's PR 6). `removalPlaybackNote` is removed (Task 3).
- **Zero removals ⇒ identical behavior to main**; the full suite must stay green after each task.
- **Zero logic in views.** Views bind to model properties and call model methods only.
- **Tests:** Swift Testing; `expectNoDifference`/`expectDifference` for value comparisons; **no `Task.sleep`**; audio via test doubles/fixture plans, never real playback.
- Iterate with `make test-fast` in `QuickInterviewEditor/` (`ONLY=...` to focus); `make generate` only after adding files; before pushing: `make test`, `make format-check`, `make lint`.
- Conventional commits (`feat:`, `refactor:`, `test:`); **NO `Co-Authored-By` or any co-sign trailer**.
- Bounded lookahead scheduling is **not** implemented unless seam-buffer memory profiling warrants it; keep the PR 2 full-plan scheduling and say so in the PR description (one short PCM buffer per removal is the only retained audio).
- Architecture is LOCKED (Codex consult; session id in `.context/codex-session-id`). Do NOT re-open design. DO run gstack `codex` review then challenge on the final diff before opening the PR.

---

## File Structure

**Modify:**
- `QuickInterviewEditor/QuickInterviewEditor/Core/AudioPlayerClient.swift` — `PlaybackSample` axis enum; `PlaybackPosition.sample` retyped; `pause` returns `PlaybackSample?`; new `playEdited` closure + testValue/previewValue/live wiring; `LivePlayerBox.positionSample` returns the tagged axis.
- `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift` — `playheadEditedSample` (renamed + converted consumers), `transportOriginEditedSample`, `editedCursor(forSource:)`, `playheadSourceSample`, edited-axis ruler/snaps, `TransportPlayback` funnel, free play via `playEdited`, `removalPlaybackNote` removed.
- `QuickInterviewEditor/QuickInterviewEditor/Models/EditedWaveformAdapter.swift` — `playheadX(forEdited:)`; lane conformance cursor axis = edited.
- `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/WaveformLaneView.swift` — protocol `lanePlayheadX(forSource:)` → `lanePlayheadX(forCursor:)` (cursor = the driver's presentation axis).
- `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/WaveformModel.swift` — lane conformance rename (cursor = plan/source axis, unchanged behavior).
- `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/WaveformView.swift` — playhead closure binds `playheadEditedSample`; `removalPlaybackNote` display removed.
- Tests: `EditorTransportTests`, `EditorRulerTests`, `EditorCurrentWordTests`, `EditorTests`, `EditorAuditionTests`, `EditorAreaSelectTests`, `EditorEditSlicePresentationTests`, `EditorRemovalTests`, `EditorFineTuneTests`, `EditSliceTests` (mechanical updates) — plus new `EditorEditedCursorTests.swift`.

**Create:**
- `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorEditedCursorTests.swift` — the new conversion-behavior tests (Task 1) and edited-playback transport tests (Task 3 adds to it).

---

## Task 1: Transport cursor → `playheadEditedSample` (every consumer converts; ticks still source Ints)

The stale-anchor-prone core. The cursor becomes EDITED-axis; every reader/writer converts through `EditedTimeline` at its boundary. The player still reports source Ints in this task (`PlaybackSample` lands in Task 2), so `observePlayback`/`pause` convert source→edited on arrival. With zero removals every conversion is identity — the existing suite (after mechanical rename) must pass unchanged.

**Files:**
- Modify: `EditorModel.swift`, `EditedWaveformAdapter.swift`, `WaveformLaneView.swift`, `WaveformModel.swift`, `WaveformView.swift`
- Create test: `QuickInterviewEditorTests/Views/Pages/Editor/EditorEditedCursorTests.swift`
- Modify tests (mechanical rename `playheadSample` → `playheadEditedSample` on **EditorModel** only — `EditSliceModel.playheadSample` stays source and keeps its name): `EditorTransportTests`, `EditorRulerTests`, `EditorCurrentWordTests`, `EditorTests`, `EditorAuditionTests`, `EditorAreaSelectTests`, `EditorEditSlicePresentationTests`, `EditorRemovalTests`, `EditorFineTuneTests`, `EditSliceTests`.

**Interfaces:**
- Produces on `EditorModel`:
  - `var playheadEditedSample: Int` (renamed from `playheadSample`; didSet still syncs current word, now via source conversion)
  - `var transportOriginEditedSample: Int?` (renamed from `transportOriginSample`)
  - `func editedCursor(forSource sourceSample: Int) -> Int` — total; `.rightEdge` bias (a source sample inside a removal resolves to the seam's crossfade start, where the post-cut audio first becomes audible)
  - `var playheadSourceSample: Int` — `editedToSource(playheadEditedSample)`; the boundary value for word lookup / transcript follow / modal publish
- Produces on `EditedWaveformAdapter`: `func playheadX(forEdited editedSample: Int) -> CGFloat?`
- Produces on `WaveformLaneDriving`: `func lanePlayheadX(forCursor cursorSample: Int) -> CGFloat?` — cursor is the DRIVER's presentation axis (edited for `EditedWaveformAdapter`, plan/source for `WaveformModel`)
- Consumes: `EditedTimeline.sourceToEdited(_:bias:)`, `.editedToSource(_:)`, `.editedDurationSamples`; `EditedWaveformAdapter.timeline` (the synced instance — hot paths must NOT read the computed `editedTimeline`, which rebuilds per read).

- [x] **Step 0: Invoke `pfw-observable-models`, `pfw-testing`, `pfw-custom-dump`** (list them in the task checklist).

- [x] **Step 1: Write the failing conversion tests** in the new `EditorEditedCursorTests.swift`. One removal `[40_000, 60_000)` with crossfade `4_800` on the standard fixture; hand-compute the edited values (fixture `editPlan.source.durationSamples` and sample rate — read `Fixtures.editPlan()` first and adjust the constants so the removal + fade sit inside the file with ≥ crossfade-length handles on both sides).

```swift
import CustomDump
import Dependencies
import Foundation
import Testing

@testable import QuickInterviewEditor

@MainActor
struct EditorEditedCursorTests {
  private func editor(_ plan: EditPlan = Fixtures.editPlan()) -> EditorModel {
    EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: plan)
  }

  /// One removal [a, b) with crossfade L, well inside the fixture file.
  private func addRemoval(
    _ model: EditorModel, _ lower: Int, _ upper: Int, length: Int
  ) {
    model.mutateDocument { doc in
      doc.timelineRemovals.append(
        TimelineRemoval(
          id: UUID(), removedRange: lower..<upper,
          crossfade: Crossfade(lengthSamples: length, curve: .equalPower)))
    }
  }

  @Test func editedCursorIsIdentityWithoutRemovals() {
    let model = editor()
    expectNoDifference(model.editedCursor(forSource: 12_345), 12_345)
    expectNoDifference(model.playheadSourceSample, model.playheadEditedSample)
  }

  @Test func editedCursorInsideRemovalResolvesToCrossfadeStart() {
    let model = editor()
    addRemoval(model, 40_000, 60_000, length: 4_800)
    // Kept K0=[0,40_000) K1=[60_000,dur). Overlap starts at edited 40_000 - 4_800 = 35_200.
    expectNoDifference(model.editedCursor(forSource: 50_000), 35_200)
    // After the removal: source 70_000 → edited 70_000 - 20_000 - 4_800 + ... = 45_200
    // (10_000 into K1, whose editedStart is 35_200).
    expectNoDifference(model.editedCursor(forSource: 70_000), 45_200)
  }

  @Test func selectionSnapAfterRemovalPlacesCursorOnEditedAxis() {
    let model = editor()
    addRemoval(model, 40_000, 60_000, length: 4_800)
    model.selectSourceRange(70_000..<80_000, snapPlayhead: true)
    expectNoDifference(model.playheadEditedSample, 45_200)
  }

  @Test func sourcePositionTickAfterRemovalMovesCursorOnEditedAxis() async {
    let model = editor()
    addRemoval(model, 40_000, 60_000, length: 4_800)
    let session = PlaybackSessionID()
    model.transportPhase = .playing(session)
    let (stream, continuation) = AsyncStream.makeStream(of: PlaybackPosition.self)
    await withDependencies {
      $0.audioPlayer.positions = { stream }
    } operation: {
      let observe = Task { await model.observePlayback() }
      continuation.yield(PlaybackPosition(sessionID: session, sample: 70_000, isPlaying: true))
      continuation.finish()
      await observe.value
    }
    expectNoDifference(model.playheadEditedSample, 45_200)
    // The transcript/word boundary keeps reading SOURCE samples.
    expectNoDifference(model.playheadSourceSample, 70_000)
  }

  @Test func pauseSampleAfterRemovalFreezesCursorOnEditedAxis() async {
    let model = editor()
    addRemoval(model, 40_000, 60_000, length: 4_800)
    let session = PlaybackSessionID()
    model.transportPhase = .playing(session)
    await withDependencies {
      $0.audioPlayer.pause = { _ in 70_000 }
    } operation: {
      await model.transportPauseTapped()
    }
    expectNoDifference(model.playheadEditedSample, 45_200)
  }

  @Test func rulerMapsThroughEditedAxis() {
    let model = editor()
    addRemoval(model, 40_000, 60_000, length: 4_800)
    // Give the adapter usable geometry: 100 px viewport, 1_000 edited samples per pixel.
    model.editedWaveform.viewportResized(width: 100)
    model.editedWaveform.samplesPerPixel = 1_000
    model.editedWaveform.visibleStartSample = 40_000  // EDITED samples
    // x=10 → edited 50_000 (post-seam); the cursor stores the EDITED sample as-is.
    model.rulerMovedPlayhead(toX: 10)
    expectNoDifference(model.playheadEditedSample, 50_000)
  }

  @Test func rulerClampsToEditedDuration() {
    let model = editor(Fixtures.editPlan())
    addRemoval(model, 40_000, 60_000, length: 4_800)
    let editedDuration = model.editedWaveform.timeline.editedDurationSamples
    model.editedWaveform.viewportResized(width: 100)
    model.editedWaveform.samplesPerPixel = 1_000
    model.editedWaveform.visibleStartSample = max(0, editedDuration - 1_000)
    model.rulerMovedPlayhead(toX: 5_000)  // way past the end
    expectNoDifference(model.playheadEditedSample, editedDuration)
  }

  @Test func currentWordSyncInCrossfadeOverlapUsesPostCutWord() {
    // Words at the fixture's real boundaries: place the cursor in the overlap zone and expect
    // the highlight to resolve to the word containing the RIGHT-side (post-cut) source sample,
    // because editedToSource resolves overlap to the incoming segment.
    let model = editor()
    addRemoval(model, 40_000, 60_000, length: 4_800)
    model.playheadEditedSample = 35_300  // 100 into the overlap → source 60_100
    expectNoDifference(model.playheadSourceSample, 60_100)
  }
}
```

**Adjust the sample constants to the fixture:** before finalizing the test, print/inspect `Fixtures.editPlan().source.durationSamples`. If it is smaller than 80_000, scale all constants down (e.g. divide by 10) keeping the shape: removal `[a,b)` with `L` ≤ min(a, dur−b), a tick/selection source sample `s > b`, expected edited `s − (b−a) − L`.

- [x] **Step 2: Run to verify failure** — `cd QuickInterviewEditor && make generate && make test-fast ONLY=QuickInterviewEditorTests/EditorEditedCursorTests`. Expected: compile FAIL (`editedCursor`, `playheadEditedSample` undefined).

- [x] **Step 3: Implement the migration in `EditorModel` + adapter + lane.** All in one pass — this is the consumer sweep; the checklist below is exhaustive (grep `playheadSample`, `transportOriginSample` to confirm nothing is missed):

  In `EditorModel.swift`:
  ```swift
  /// THE persistent, always-visible playhead cursor, in EDITED-timeline samples — the collapsed
  /// axis the main lane renders. Always edited: with zero removals the timeline is the identity
  /// map, so the value equals the plan/source sample; consumers that need source data convert
  /// via `playheadSourceSample`. Kept a SEPARATE observed property (not folded into a transport
  /// struct) so its ~30 Hz updates don't invalidate views that read `transportPhase`/
  /// `transportContext`.
  var playheadEditedSample = 0 {
    didSet { syncCurrentWordToCursor() }
  }

  /// The SOURCE sample under the cursor — the boundary value for anything that reasons about
  /// the original recording (word lookup, transcript follow, the slice-edit modal). In a seam's
  /// overlap zone this resolves to the incoming (post-cut) side, matching what is audible.
  var playheadSourceSample: Int { editedWaveform.timeline.editedToSource(playheadEditedSample) }

  /// The edited-axis cursor position for a SOURCE sample. Total: outside removals it is the
  /// exact mapped position; inside a removed span the `.rightEdge` bias resolves to the seam's
  /// crossfade start — the edited moment the audio after the cut first becomes audible. The
  /// fallback only fires for a defensively out-of-range input.
  func editedCursor(forSource sourceSample: Int) -> Int {
    let timeline = editedWaveform.timeline
    return timeline.sourceToEdited(sourceSample, bias: .rightEdge)
      ?? min(max(0, sourceSample), timeline.editedDurationSamples)
  }

  private func syncCurrentWordToCursor() {
    guard let word = wordID(atSample: playheadSourceSample), word != transcript.currentWordID
    else { return }
    transcript.currentWordID = word
  }
  ```
  - `transportOriginSample` → `transportOriginEditedSample` (declaration + every use; doc: "in EDITED samples").
  - `playheadX`: `editedWaveform.playheadX(forEdited: playheadEditedSample)`.
  - `observePlayback` (ticks still `Int` source samples this task):
    ```swift
    if position.isPlaying {
      playheadEditedSample = editedCursor(forSource: position.sample)
      if case .sliceEdit = transportContext {
        editSlice?.updatePlayback(sample: position.sample, isPlaying: true)
      }
      transcript.playheadChanged(
        sample: position.sample, isPlaying: transportContext.followsTranscript)
    } else { /* unchanged, but the sliceEdit publish uses playheadSourceSample */ }
    ```
  - `transportPauseTapped`: `if let sample { playheadEditedSample = editedCursor(forSource: sample) }`.
  - `beginTransportPlayback`: `transportOriginEditedSample = editedCursor(forSource: range.lowerBound)`; `playheadEditedSample = editedCursor(forSource: range.lowerBound)`; on `.finished` → `playheadEditedSample = editedCursor(forSource: range.upperBound)`.
  - `transportPlayableRange` (still the source-range free play this task): start from the source sample under the cursor:
    ```swift
    private var transportPlayableRange: Range<Int>? {
      let end = editPlan.source.durationSamples
      let start = playheadSourceSample
      guard start >= 0, start < end, playheadEditedSample < editedWaveform.timeline.editedDurationSamples
      else { return nil }
      return start..<end
    }
    ```
  - `selectSourceRange` snap branch: `playheadEditedSample = editedCursor(forSource: lower)`.
  - `transportSelectionChanged`: `playheadEditedSample = editedCursor(forSource: newRange.lowerBound)`.
  - Ruler: 
    ```swift
    func rulerMovedPlayhead(toX positionX: CGFloat) {
      guard editedWaveform.hasUsableGeometry else { return }
      stopTransportForRuler()
      playheadEditedSample = clampedRulerEditedSample(positionX)
      cursorMoveGeneration &+= 1
    }
    /// The ruler's view-x mapped to an EDITED sample, clamped to a valid cursor position.
    /// `editedDurationSamples` (end-of-timeline) is inclusive: a legal resting cursor where
    /// Play is a correct no-op.
    private func clampedRulerEditedSample(_ positionX: CGFloat) -> Int {
      min(
        max(0, editedWaveform.xToEditedSample(positionX)),
        editedWaveform.timeline.editedDurationSamples)
    }
    ```
  - Slice-edit modal boundary (source-coordinate internally): `child.onSeek = { … playheadEditedSample = editedCursor(forSource: sample); editSlice?.updatePlayback(sample: sample, …) }`; `onPause`/`onStop` closures publish `editSlice?.updatePlayback(sample: playheadSourceSample, …)`.

  In `WaveformLaneView.swift` — rename the protocol requirement and update the doc comment:
  ```swift
  /// View-x of the persistent cursor. `cursorSample` is in the DRIVER's presentation axis —
  /// EDITED samples for ``EditedWaveformAdapter`` (the main editor), plan/source samples for
  /// ``WaveformModel`` (the slice-edit sheet, where source IS the presented axis).
  func lanePlayheadX(forCursor cursorSample: Int) -> CGFloat?
  ```
  Update `WaveformPlayhead`/`RulerPlayhead` call sites (`lanePlayheadX(forCursor: sample)`).

  In `EditedWaveformAdapter.swift`:
  ```swift
  /// View-x of the persistent playhead cursor for an EDITED sample, or nil when it falls
  /// outside the viewport.
  func playheadX(forEdited editedSample: Int) -> CGFloat? {
    guard viewportWidth > 0 else { return nil }
    let posX = editedSampleToX(editedSample)
    guard posX >= 0, posX <= viewportWidth else { return nil }
    return posX
  }
  ```
  Lane conformance: `func lanePlayheadX(forCursor cursorSample: Int) -> CGFloat? { playheadX(forEdited: cursorSample) }`. Keep `playheadX(forSource:)` only if other callers remain (grep; `EditorModel.playheadX` switches to `forEdited`) — delete it if unused.

  In `WaveformModel.swift`: rename the conformance method only (`lanePlayheadX(forCursor:)` forwarding to `playheadX(for:)`).

  In `WaveformView.swift`: `playhead: { model.playheadEditedSample }`.

- [x] **Step 4: Mechanical test rename (Sonnet subagent OK):** in the 10 test files listed above, rename `model.playheadSample` / `.transportOriginSample` → `model.playheadEditedSample` / `.transportOriginEditedSample` **only on `EditorModel` instances** (the `EditSliceModel.playheadSample` property keeps its name — it is the modal's own SOURCE cursor). Instruct the subagent to invoke `pfw-testing`/`pfw-custom-dump` and to change nothing else.

- [x] **Step 5: Run the full suite** — `cd QuickInterviewEditor && make test-fast`. Expected: PASS (zero-removal identity keeps every existing assertion; new conversion tests pass).

- [x] **Step 6: Format, lint, commit**

```bash
cd QuickInterviewEditor && make format && make lint
git add -A
git commit -m "refactor: transport cursor is playheadEditedSample — every consumer converts at its boundary"
```

---

## Task 2: Axis-tagged `PlaybackSample` in the player contract

Make the coordinate space unambiguous in the type/API, not a comment: positions and pause results carry which axis they are in. `play(url:range:)` sessions report `.source`; `playEdited` playlist sessions report `.edited` (from `PlaylistFrameTimeline`).

**Files:**
- Modify: `Core/AudioPlayerClient.swift`, `EditorModel.swift`
- Modify tests: every construction of `PlaybackPosition` and every `pause` stub (`EditorTransportTests`, `EditorCurrentWordTests`, `EditorEditSlicePresentationTests`, `EditorAuditionTests`, `EditorEditedCursorTests`, any other match of `PlaybackPosition(` / `audioPlayer.pause`).

**Interfaces:**
- Produces in `AudioPlayerClient.swift`:
  ```swift
  /// A playback position's sample tagged with its coordinate axis, so a consumer can never
  /// mistake one axis for the other. `.source` = plan samples of the canonical file — every
  /// `play(url:range:)` session (slice, preview, audition, slice-edit modal). `.edited` =
  /// edited-timeline samples — every `playEdited` playlist session.
  enum PlaybackSample: Sendable, Equatable {
    case source(Int)
    case edited(Int)
  }
  ```
  - `PlaybackPosition.sample: PlaybackSample`
  - `pause: @Sendable (PlaybackSessionID) async -> PlaybackSample?`
- Consumes: `PlaylistFrameTimeline.editedSample(forFramesPlayed:)` (already returns edited samples when a playlist runs).

- [x] **Step 0: Invoke `pfw-dependencies`, `pfw-testing`, `pfw-custom-dump`.**

- [x] **Step 1: Write the failing tests** (append to `EditorEditedCursorTests.swift`):

```swift
@Test func editedAxisTickMovesCursorDirectly() async {
  let model = editor()
  addRemoval(model, 40_000, 60_000, length: 4_800)
  let session = PlaybackSessionID()
  model.transportPhase = .playing(session)
  let (stream, continuation) = AsyncStream.makeStream(of: PlaybackPosition.self)
  await withDependencies {
    $0.audioPlayer.positions = { stream }
  } operation: {
    let observe = Task { await model.observePlayback() }
    continuation.yield(
      PlaybackPosition(sessionID: session, sample: .edited(45_200), isPlaying: true))
    continuation.finish()
    await observe.value
  }
  // An edited tick is already on the cursor's axis — stored as-is, no conversion.
  expectNoDifference(model.playheadEditedSample, 45_200)
}

@Test func editedAxisPauseFreezesCursorDirectly() async {
  let model = editor()
  addRemoval(model, 40_000, 60_000, length: 4_800)
  let session = PlaybackSessionID()
  model.transportPhase = .playing(session)
  await withDependencies {
    $0.audioPlayer.pause = { _ in .edited(45_200) }
  } operation: {
    await model.transportPauseTapped()
  }
  expectNoDifference(model.playheadEditedSample, 45_200)
  expectNoDifference(model.transportPhase, .paused(session))
}
```

Also update Task 1's two source-axis tests to the new shape: `sample: .source(70_000)` and `pause = { _ in .source(70_000) }`.

- [x] **Step 2: Run to verify failure** — `make test-fast ONLY=QuickInterviewEditorTests/EditorEditedCursorTests`. Expected: compile FAIL (`.edited` not defined).

- [x] **Step 3: Implement.**
  - `AudioPlayerClient.swift`: add `PlaybackSample`; retype `PlaybackPosition.sample`; retype `pause`; update its doc comment ("returns the exact resting sample, tagged with its axis").
  - `LivePlayerBox`:
    ```swift
    private func positionSample(forFramesPlayed framesPlayed: Int) -> PlaybackSample {
      if let editedFrameTimeline {
        return .edited(editedFrameTimeline.editedSample(forFramesPlayed: framesPlayed))
      }
      return .source(startPlanSample + Int(Double(framesPlayed) / max(playRatio, .ulpOfOne)))
    }
    ```
    (`pause`, `stopTicking`, `emitPosition` compile through unchanged — they pass the result along.) This completes the edited-playback pause contract: pause during a playlist freezes the node (`node.pause()`, schedule intact) and the frozen cursor comes from `PlaylistFrameTimeline` as an EDITED sample; `resume()` is `node.play()` with no reschedule (both already generic).
  - `EditorModel.observePlayback`:
    ```swift
    if position.isPlaying {
      let sourceSample: Int
      switch position.sample {
      case .edited(let editedSample):
        playheadEditedSample = editedSample
        sourceSample = playheadSourceSample
      case .source(let source):
        playheadEditedSample = editedCursor(forSource: source)
        sourceSample = source
      }
      if case .sliceEdit = transportContext {
        editSlice?.updatePlayback(sample: sourceSample, isPlaying: true)
      }
      transcript.playheadChanged(
        sample: sourceSample, isPlaying: transportContext.followsTranscript)
    } else { /* unchanged */ }
    ```
  - `EditorModel.transportPauseTapped`:
    ```swift
    if let sample {
      switch sample {
      case .edited(let editedSample): playheadEditedSample = editedSample
      case .source(let source): playheadEditedSample = editedCursor(forSource: source)
      }
    }
    ```

- [x] **Step 4: Mechanical test updates (Sonnet subagent OK):** wrap every `PlaybackPosition(sessionID:sample:isPlaying:)` integer with `.source(...)` and every `pause` stub return with `.source(...)` across the test tree (grep `PlaybackPosition(` and `audioPlayer.pause`). No behavioral edits.

- [x] **Step 5: Run the full suite** — `make test-fast`. Expected: PASS.

- [x] **Step 6: Format, lint, commit**

```bash
cd QuickInterviewEditor && make format && make lint
git add -A
git commit -m "feat: axis-tagged PlaybackSample makes the position coordinate space explicit"
```

---

## Task 3: Expose `playEdited`; main Play drives the edited playlist; remove `removalPlaybackNote`

The transport's free play (`Play` button / Space from stopped) builds an `AudioEditRenderPlan` from the cursor's edited sample and plays it through the newly exposed `playEdited`. Seek semantics per locked decision 3: a ruler move stops the transport (existing behavior) and the next Play rebuilds the plan from the new edited cursor — a seek into a seam gets the partial-seam plan (`fadeOffset`), so the fade continues rather than restarts. Slice/preview/audition/modal playback stays on `.sourceRange` (their ranges are source data). Full-plan scheduling is kept (PR 2 deviation note; state it in the PR description).

**Files:**
- Modify: `Core/AudioPlayerClient.swift`, `EditorModel.swift`, `WaveformView.swift`
- Modify tests: `EditorEditedCursorTests.swift` (new transport tests), `EditorTransportTests.swift` + `EditorRulerTests.swift` + `EditorCurrentWordTests.swift` + `EditorAreaSelectTests.swift` (free-play stubs move `play` → `playEdited`), `EditorRemovalTests.swift` (delete `removalPlaybackNote` tests).

**Interfaces:**
- Produces on `AudioPlayerClient`:
  ```swift
  /// Plays an edited-timeline render plan as ONE gapless stream — kept-segment interiors
  /// scheduled from `url`, seam crossfades pre-rendered and blended — at `rate`
  /// (pitch-preserving), reporting positions/pause samples on the EDITED axis
  /// (`PlaybackSample.edited`). Mirrors `play`'s session/rate contract.
  var playEdited:
    @Sendable (URL, AudioEditRenderPlan, Int, Double, PlaybackSessionID) async throws
      -> PlaybackEnd
  ```
  with `testValue` `reportIssue` stub (matching `play`'s style), `previewValue` `{ _, _, _, _, _ in .finished }`, and `live()` wiring to the existing `box.playEdited`.
- Produces on `EditorModel`:
  - `private enum TransportPlayback { case sourceRange(Range<Int>); case editedTimeline(fromEdited: Int) }`
  - `private func beginTransportPlayback(_ playback: TransportPlayback, context: TransportContext) async` (replaces the range-only funnel)
- Removes: `EditorModel.removalPlaybackNote`, its `WaveformView` display, `transportPlayableRange` (folded into the funnel/`canTransportPlay`).

- [x] **Step 0: Invoke `pfw-observable-models`, `pfw-dependencies`, `pfw-testing`, `pfw-custom-dump`.**

- [x] **Step 1: Write the failing tests** (append to `EditorEditedCursorTests.swift`):

```swift
@Test func freePlayBuildsEditedPlanFromCursor() async {
  let model = editor()
  addRemoval(model, 40_000, 60_000, length: 4_800)
  model.playheadEditedSample = 10_000
  let recorded = LockIsolated<(URL, AudioEditRenderPlan, Int)?>(nil)
  await withDependencies {
    $0.audioPlayer.playEdited = { url, plan, sampleRate, _, _ in
      recorded.setValue((url, plan, sampleRate))
      return .finished
    }
  } operation: {
    await model.transportPlayTapped()
  }
  let (url, plan, sampleRate) = recorded.value!
  expectNoDifference(url, Fixtures.canonicalAudioURL)
  expectNoDifference(sampleRate, model.editPlan.source.sampleRate)
  // The plan starts exactly at the cursor's edited sample …
  expectNoDifference(plan.items.first?.editedSpan.lowerBound, 10_000)
  // … and covers the timeline to its edited end.
  expectNoDifference(
    plan.items.last?.editedSpan.upperBound,
    model.editedWaveform.timeline.editedDurationSamples)
}

@Test func freePlayWithoutRemovalsIsIdentityPlan() async {
  let model = editor()
  let recorded = LockIsolated<AudioEditRenderPlan?>(nil)
  await withDependencies {
    $0.audioPlayer.playEdited = { _, plan, _, _, _ in
      recorded.setValue(plan)
      return .finished
    }
  } operation: {
    await model.transportPlayTapped()
  }
  // Zero removals → the identity playlist: one segment, the whole file.
  expectNoDifference(
    recorded.value?.items,
    [.segment(source: 0..<model.editPlan.source.durationSamples, editedStart: 0)])
}

@Test func freePlayFinishRestsCursorAtEditedEnd() async {
  let model = editor()
  addRemoval(model, 40_000, 60_000, length: 4_800)
  model.playheadEditedSample = 10_000
  await withDependencies {
    $0.audioPlayer.playEdited = { _, _, _, _, _ in .finished }
  } operation: {
    await model.transportPlayTapped()
  }
  expectNoDifference(
    model.playheadEditedSample, model.editedWaveform.timeline.editedDurationSamples)
}

@Test func playDisabledAtEditedEndOfTimeline() {
  let model = editor()
  addRemoval(model, 40_000, 60_000, length: 4_800)
  model.playheadEditedSample = model.editedWaveform.timeline.editedDurationSamples
  #expect(!model.canTransportPlay)
}

@Test func seekIntoSeamPlaysPartialFade() async {
  let model = editor()
  addRemoval(model, 40_000, 60_000, length: 4_800)
  // Crossfade occupies edited [35_200, 40_000). Seek 1_000 samples into it.
  model.playheadEditedSample = 36_200
  let recorded = LockIsolated<AudioEditRenderPlan?>(nil)
  await withDependencies {
    $0.audioPlayer.playEdited = { _, plan, _, _, _ in
      recorded.setValue(plan)
      return .finished
    }
  } operation: {
    await model.transportPlayTapped()
  }
  guard case .seam(_, _, _, let length, let editedStart, let fadeOffset) =
    recorded.value?.items.first
  else {
    Issue.record("expected a partial seam first")
    return
  }
  // The fade CONTINUES from the seek point: 1_000 consumed, 3_800 remaining.
  expectNoDifference(fadeOffset, 1_000)
  expectNoDifference(length, 3_800)
  expectNoDifference(editedStart, 36_200)
}

@Test func sliceShortcutStillPlaysSourceRange() async {
  let model = editor()
  addRemoval(model, 40_000, 60_000, length: 4_800)
  let slice = Slice(
    id: UUID(), name: "S", startSample: 5_000, endSample: 20_000, wordIDs: [],
    snippet: "", warnings: [])
  model.mutateSlices { $0.append(slice) }
  let recorded = LockIsolated<Range<Int>?>(nil)
  await withDependencies {
    $0.audioPlayer.play = { _, range, _, _, _ in
      recorded.setValue(range)
      return .finished
    }
  } operation: {
    await model.playSliceTapped(slice.id)
  }
  // The slice path keeps SOURCE-range playback (its range IS source data).
  expectNoDifference(recorded.value, 5_000..<20_000)
}
```

- [x] **Step 2: Run to verify failure** — `make test-fast ONLY=QuickInterviewEditorTests/EditorEditedCursorTests`. Expected: compile FAIL (`playEdited` not on the client).

- [x] **Step 3: Implement.**
  - `AudioPlayerClient.swift`: add the `playEdited` closure per the interface block; testValue:
    ```swift
    playEdited: { _, _, _, _, _ -> PlaybackEnd in
      reportIssue("AudioPlayerClient.playEdited called without a test override")
      throw EngineClientError.unimplemented("AudioPlayerClient.playEdited")
    },
    ```
    previewValue `{ _, _, _, _, _ in .finished }`; `live()`:
    ```swift
    playEdited: { url, plan, sampleRate, rate, session in
      try await box.playEdited(
        url: url, plan: plan, planSampleRate: sampleRate, rate: rate, session: session)
    },
    ```
    Update `LivePlayerBox.playEdited`'s doc comment: no longer a spike — it is the transport's edited-playback engine (drop the "SPIKE (PR2)" framing; keep the scheduling description; note full-plan scheduling retained per the PR 2 deviation note).
  - `EditorModel.swift` — replace the funnel:
    ```swift
    /// What the transport should play. `.sourceRange` = a range of the ORIGINAL audio (slice,
    /// preview, audition, slice-edit modal — paths whose ranges are source data). `.editedTimeline`
    /// = the collapsed timeline from an EDITED sample (the main Play — removals collapsed, seams
    /// blended). With zero removals the edited plan is the identity playlist, so the two produce
    /// the same audio.
    private enum TransportPlayback {
      case sourceRange(Range<Int>)
      case editedTimeline(fromEdited: Int)
    }

    private func beginTransportPlayback(
      _ playback: TransportPlayback, context: TransportContext
    ) async {
      let timeline = editedWaveform.timeline
      let startEditedSample: Int
      let finishEditedSample: Int
      let sourceRange: Range<Int>?
      switch playback {
      case .sourceRange(let explicitRange):
        let upper = min(explicitRange.upperBound, editPlan.source.durationSamples)
        let lower = max(0, min(explicitRange.lowerBound, upper))
        guard lower < upper else { return }
        sourceRange = lower..<upper
        startEditedSample = editedCursor(forSource: lower)
        finishEditedSample = editedCursor(forSource: upper)
      case .editedTimeline(let fromEdited):
        let editedDuration = timeline.editedDurationSamples
        let start = max(0, min(fromEdited, editedDuration))
        guard start < editedDuration else { return }
        sourceRange = nil
        startEditedSample = start
        finishEditedSample = editedDuration
      }
      beginExclusivePlayback()
      let session = PlaybackSessionID()
      transportContext = context
      transportOriginEditedSample = startEditedSample
      playheadEditedSample = startEditedSample
      cursorMoveGeneration &+= 1
      transportPhase = .playing(session)
      let outcome: PlaybackEnd
      do {
        if let sourceRange {
          outcome = try await audioPlayer.play(
            canonicalAudioURL, sourceRange, editPlan.source.sampleRate,
            transcript.playbackRate, session)
        } else {
          outcome = try await audioPlayer.playEdited(
            canonicalAudioURL,
            AudioEditRenderPlan(timeline: timeline, startEditedSample: startEditedSample),
            editPlan.source.sampleRate, transcript.playbackRate, session)
        }
      } catch {
        reportIssue(error)
        outcome = .stopped
      }
      guard transportPhase.session == session else { return }
      if outcome == .finished { playheadEditedSample = finishEditedSample }
      // … existing owningSliceEdit capture + resetTransportState() + endTranscriptFollow()
      //   + owningSliceEdit publish, verbatim from the current implementation …
    }
    ```
    Keep the existing doc comment's guarantees (explicit range, cursor authority, suspended across pause/resume) and extend it with the two playback kinds. Update the five existing callers: `playSliceTapped` / `previewEditTapped` / `auditionInTapped` / `auditionOutTapped` / the modal's `onPlay` → `.sourceRange(…)`; `transportPlayTapped`'s stopped branch →
    ```swift
    await beginTransportPlayback(
      .editedTimeline(fromEdited: playheadEditedSample), context: .free)
    ```
  - Replace `transportPlayableRange` with the edited-axis predicate `canTransportPlay` reads:
    ```swift
    /// Whether a Play-from-stopped has anywhere to go: the cursor sits before the edited end of
    /// the timeline. (Play is a straight listen-through of the EDITED timeline to its end; a
    /// selection marks a clip, it never scopes playback.)
    private var canStartTimelinePlayback: Bool {
      playheadEditedSample >= 0
        && playheadEditedSample < editedWaveform.timeline.editedDurationSamples
    }
    var canTransportPlay: Bool {
      if isTransportPlaying { return false }
      return isTransportPaused || canStartTimelinePlayback
    }
    ```
    (`transportPlayTapped` drops its `transportPlayableRange` guard — the funnel's `.editedTimeline` validation covers it.)
  - Delete `removalPlaybackNote` (model) and its `WaveformView` display block.
- [x] **Step 4: Migrate the free-play test stubs (Sonnet subagent OK, with this exact spec):** any test that drives `transportPlayTapped` / `transportPlayStopTapped` / Space (contexts `.free`) and stubs `$0.audioPlayer.play` must stub `$0.audioPlayer.playEdited` instead (signature `(URL, AudioEditRenderPlan, Int, Double, PlaybackSessionID)`); range assertions become plan assertions (`plan.items.first?.editedSpan.lowerBound` for the start; with zero removals the expected plan is `[.segment(source: start..<duration, editedStart: start)]`). Slice/preview/audition/modal tests keep `play`. `TransportGate`-style helpers gain a `playEdited` variant where needed. Delete `removalPlaybackNote` assertions (`EditorRemovalTests`). Subagent must invoke `pfw-testing` + `pfw-custom-dump` and run `make test-fast` to green.
- [x] **Step 5: Run the full suite** — `make test-fast`. Expected: PASS.
- [x] **Step 6: Format, lint, commit**

```bash
cd QuickInterviewEditor && make format && make lint
git add -A
git commit -m "feat: main transport plays the edited timeline through playEdited"
```

---

## Task 4: CI-parity green, manual verification, Codex review, PR

- [ ] **Step 1: Full pre-push checks** — `cd QuickInterviewEditor && make test && make format-check && make lint`. Expected: all green (fastlane suite included).
- [ ] **Step 2: Update docs status** — in `docs/superpowers/plans/2026-08-20-remove-section-crossfade-completion.md`, mark PR 3 shipped-pending-review if the doc carries status; note "bounded lookahead not needed — full-plan scheduling retained (one short PCM buffer per removal)".
- [ ] **Step 3: MANUAL VERIFICATION (do not skip — this PR is about what you hear).** Run the app (`open QuickInterviewEditor/QuickInterviewEditor.xcodeproj`, run the scheme), import a clip, make a removal. Confirm:
  - playback is continuous and blended across the seam (no gap, no removed audio, no click) at 1x, 0.5x, and 2x;
  - pause and resume mid-crossfade;
  - seek into a seam via the ruler then Play (fade continues, doesn't restart);
  - playhead, ruler, and transcript highlight agree with what you hear;
  - multiple removals in one file;
  - zero-removal file behaves exactly as before (cursor, slice playback, listen/mark flow, cross-tab cursor with two tabs open).
- [ ] **Step 4: Codex adversarial pass** — gstack `codex` skill: **review** mode on the final diff, then **challenge** mode. Fix findings; re-run if fixes were non-trivial. (Architecture stays locked — do not re-consult.)
- [ ] **Step 5: Open the PR** — `gh pr create --base main` with a body that: summarizes the completion sequence and this PR's slice ("hear the edit"), states the coordinate-migration-first contract and that slice/preview/audition/modal keep source-range playback by design, states full-plan scheduling retained (bounded lookahead deferred per the PR 2 deviation note — seam buffers are the only retained PCM), notes export stays blocked (PR 6), links the spec + completion plan. Then run `/fix-review` (repo runs Greptile + CodeRabbit; no re-review if confidence ≥ 4/5).

---

## Self-Review (completed by plan author)

**Scope coverage (prompt requirement → task):** Transport migration first, every consumer (cursor, current-word highlight/follow, waveform playhead, ruler, cross-tab session gating, pause/resume freezes, slice-edit boundary) → Task 1. Explicit coordinate space in the type/API (`PlaybackSample`), edited pause contract from `PlaylistFrameTimeline` → Task 2. `playEdited` exposed with testValue stub; main transport plays the edited plan; seek-into-seam continues the fade; `removalPlaybackNote` removed; export gating untouched → Task 3. Bounded lookahead: deliberately not implemented; PR description states it → Tasks 3/4. Manual verification + Codex review/challenge + `/fix-review` → Task 4.

**Deliberate decisions the executor must not "fix":**
- Slice/preview/audition/slice-row playback keeps `play(url:range:)` (source ranges are source data; the completion plan's decision 2 lists slice ranges among the source boundaries). Their ticks convert at the boundary via `PlaybackSample.source`. A slice straddling a removal therefore still plays its full source audio in this PR — consistent with exports (blocked) and revisited with PR 6.
- The ruler stopping the transport before placing the cursor (no live scrub) is existing v1 behavior; "seek" = ruler place + Play rebuilding the plan, which satisfies the locked seek contract (stop, invalidate generation, rebuild from the edited sample).
- Hot paths read `editedWaveform.timeline` (synced instance), never the computed `editedTimeline` (which rebuilds per read).

**Placeholder scan:** none — every step carries real code or names the exact existing code to keep verbatim.

**Type consistency:** `playheadEditedSample`, `transportOriginEditedSample`, `editedCursor(forSource:)`, `playheadSourceSample`, `PlaybackSample.source/.edited`, `playEdited(URL, AudioEditRenderPlan, Int, Double, PlaybackSessionID)`, `TransportPlayback.sourceRange/.editedTimeline(fromEdited:)`, `lanePlayheadX(forCursor:)`, `playheadX(forEdited:)` used consistently across tasks.

**Known test-constant caveat:** the sample constants (40_000/60_000/4_800) assume the fixture file is comfortably longer than 80_000 samples; Task 1 Step 1 instructs verifying against `Fixtures.editPlan()` and scaling if needed.
