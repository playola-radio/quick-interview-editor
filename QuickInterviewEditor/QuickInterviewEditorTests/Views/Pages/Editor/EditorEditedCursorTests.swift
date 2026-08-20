import ConcurrencyExtras
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
    // After the removal: source 70_000 is 10_000 into K1, whose editedStart is 35_200 → 45_200.
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
      continuation.yield(
        PlaybackPosition(sessionID: session, sample: .source(70_000), isPlaying: true))
      continuation.finish()
      await observe.value
    }
    expectNoDifference(model.playheadEditedSample, 45_200)
    // The transcript/word boundary keeps reading SOURCE samples.
    expectNoDifference(model.playheadSourceSample, 70_000)
  }

  @Test func sourceTickInCrossfadeTailKeepsPreCutWord() async {
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
        PlaybackPosition(sessionID: session, sample: .source(38_000), isPlaying: true))
      continuation.finish()
      await observe.value
    }
    // Source 38_000 sits in the crossfade's outgoing tail: its edited position lies in the
    // overlap zone, whose edited→source round trip resolves to the post-cut side (62_800 —
    // the fixture's word 1). The highlight must track the EXACT source sample still playing:
    // no word covers 38_000 in the fixture, so the current word stays unset.
    expectNoDifference(model.transcript.currentWordID, nil)
  }

  @Test func pauseSampleAfterRemovalFreezesCursorOnEditedAxis() async {
    let model = editor()
    addRemoval(model, 40_000, 60_000, length: 4_800)
    let session = PlaybackSessionID()
    model.transportPhase = .playing(session)
    await withDependencies {
      $0.audioPlayer.pause = { _ in .source(70_000) }
    } operation: {
      await model.transportPauseTapped()
    }
    expectNoDifference(model.playheadEditedSample, 45_200)
  }

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

  private actor EditedPlayGate {
    private var continuation: CheckedContinuation<PlaybackEnd, Never>?
    func play() async -> PlaybackEnd {
      await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ end: PlaybackEnd) {
      continuation?.resume(returning: end)
      continuation = nil
    }
  }

  private struct RecordedPlayEdited: Equatable {
    var url: URL
    var plan: AudioEditRenderPlan
    var sampleRate: Int
  }

  @Test func freePlayBuildsEditedPlanFromCursor() async {
    let model = editor()
    addRemoval(model, 40_000, 60_000, length: 4_800)
    model.playheadEditedSample = 10_000
    let recorded = LockIsolated<RecordedPlayEdited?>(nil)
    await withDependencies {
      $0.audioPlayer.playEdited = { url, plan, sampleRate, _, _ in
        recorded.setValue(RecordedPlayEdited(url: url, plan: plan, sampleRate: sampleRate))
        return .finished
      }
    } operation: {
      await model.transportPlayTapped()
    }
    let played = recorded.value!
    expectNoDifference(played.url, Fixtures.canonicalAudioURL)
    expectNoDifference(played.sampleRate, model.editPlan.source.sampleRate)
    // The plan starts exactly at the cursor's edited sample …
    expectNoDifference(played.plan.items.first?.editedSpan.lowerBound, 10_000)
    // … and covers the timeline to its edited end.
    expectNoDifference(
      played.plan.items.last?.editedSpan.upperBound,
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
    guard
      case .seam(_, _, _, let length, let editedStart, let fadeOffset) = recorded.value?.items
        .first
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

  /// Installs explicit waveform geometry (no audio decode) so the edited adapter's
  /// `hasUsableGeometry` holds and x↔sample mapping is meaningful.
  private func geometry(
    _ model: EditorModel, samplesPerPixel: Double, visibleStartSample: Int,
    viewportWidth: CGFloat = 100
  ) {
    let duration = model.editPlan.source.durationSamples
    model.waveform.totalSamples = duration
    model.waveform.waveform = Waveform.pyramid(
      baseMins: [0], baseMaxs: [0], sampleRate: model.editPlan.source.sampleRate,
      totalSamples: duration, baseBucketSize: 4)
    model.editedWaveform.viewportWidth = viewportWidth
    model.editedWaveform.samplesPerPixel = samplesPerPixel
    model.editedWaveform.visibleStartSample = visibleStartSample
  }

  @Test func pauseInCrossfadeTailKeepsExactSourceSample() async {
    let model = editor()
    addRemoval(model, 40_000, 60_000, length: 4_800)
    let session = PlaybackSessionID()
    model.transportPhase = .playing(session)
    await withDependencies {
      $0.audioPlayer.pause = { _ in .source(38_000) }
    } operation: {
      await model.transportPauseTapped()
    }
    // The cursor renders inside the seam's overlap zone (edited 38_000), but the SOURCE
    // boundary value keeps the EXACT paused sample — the modal's "play from the playhead"
    // must resume at 38_000, not the post-cut side (62_800) the round trip resolves to.
    expectNoDifference(model.playheadEditedSample, 38_000)
    expectNoDifference(model.playheadSourceSample, 38_000)
  }

  @Test func addingRemovalStopsFreeEditedPlayback() async {
    let model = editor()
    let gate = EditedPlayGate()
    let stopped = LockIsolated(false)
    await withDependencies {
      $0.audioPlayer.playEdited = { _, _, _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { _ in stopped.setValue(true) }
    } operation: {
      let play = Task { await model.transportPlayTapped() }
      await settle(until: model.isTransportPlaying)
      // The running playlist was built from the identity timeline; a removal rebuilds the
      // edited axis, so the stale session must stop rather than let audio and cursor diverge.
      addRemoval(model, 40_000, 60_000, length: 4_800)
      #expect(!model.isTransportPlaying)
      await gate.finish(.superseded)
      await play.value
      await settle(until: stopped.value)
    }
    #expect(stopped.value)
  }

  private func settle(until condition: @autoclosure () -> Bool) async {
    for _ in 0..<1000 where !condition() { await Task.yield() }
  }

  @Test func stopReturnsSourceRangeOriginWithExactSourceSample() async {
    let model = editor()
    addRemoval(model, 40_000, 60_000, length: 4_800)
    let slice = Slice(
      id: UUID(), name: "S", startSample: 38_000, endSample: 70_000, wordIDs: [],
      snippet: "", warnings: [])
    model.mutateSlices { $0.append(slice) }
    let gate = EditedPlayGate()
    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { _ in await gate.finish(.stopped) }
    } operation: {
      let play = Task { await model.playSliceTapped(slice.id) }
      await settle(until: model.isTransportPlaying)
      await model.transportStopTapped()
      await play.value
    }
    // The origin (source 38_000) sits in the crossfade's outgoing tail; Stop must restore it
    // exactly, not clear the anchor and round-trip edited 38_000 to the post-cut 62_800.
    expectNoDifference(model.playheadEditedSample, 38_000)
    expectNoDifference(model.playheadSourceSample, 38_000)
  }

  @Test func timelineChangePreservesSourceRangeOriginExactly() async {
    let model = editor()
    addRemoval(model, 40_000, 60_000, length: 4_800)
    let slice = Slice(
      id: UUID(), name: "S", startSample: 38_000, endSample: 70_000, wordIDs: [],
      snippet: "", warnings: [])
    model.mutateSlices { $0.append(slice) }
    let gate = EditedPlayGate()
    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { _ in await gate.finish(.stopped) }
    } operation: {
      let play = Task { await model.playSliceTapped(slice.id) }
      await settle(until: model.isTransportPlaying)
      // A second, non-overlapping removal rebuilds the timeline mid-playback. The source-range
      // session keeps playing (original audio is unaffected), and the origin's remap must carry
      // its EXACT source sample rather than round-tripping through the old edited axis.
      addRemoval(model, 100_000, 120_000, length: 4_800)
      #expect(model.isTransportPlaying)
      await model.transportStopTapped()
      await play.value
    }
    expectNoDifference(model.playheadSourceSample, 38_000)
  }

  @Test func rulerMapsThroughEditedAxis() {
    let model = editor()
    addRemoval(model, 40_000, 60_000, length: 4_800)
    geometry(model, samplesPerPixel: 1_000, visibleStartSample: 40_000)  // EDITED samples
    // x=10 → edited 50_000 (post-seam); the cursor stores the EDITED sample as-is.
    model.rulerMovedPlayhead(toX: 10)
    expectNoDifference(model.playheadEditedSample, 50_000)
  }

  @Test func rulerClampsToEditedDuration() {
    let model = editor(Fixtures.editPlan())
    addRemoval(model, 40_000, 60_000, length: 4_800)
    let editedDuration = model.editedWaveform.timeline.editedDurationSamples
    geometry(model, samplesPerPixel: 1_000, visibleStartSample: max(0, editedDuration - 1_000))
    model.rulerMovedPlayhead(toX: 5_000)  // way past the end
    expectNoDifference(model.playheadEditedSample, editedDuration)
  }

  @Test func addingRemovalRemapsCursorToSameSourceMoment() {
    // The cursor is STORED in edited samples, so a timeline change must remap it: a cursor
    // sitting past a new removal keeps pointing at the same instant of the recording.
    let model = editor()
    model.playheadEditedSample = 70_000
    addRemoval(model, 40_000, 60_000, length: 4_800)
    expectNoDifference(model.playheadEditedSample, 45_200)
    expectNoDifference(model.playheadSourceSample, 70_000)
  }

  @Test func currentWordSyncInCrossfadeOverlapUsesPostCutWord() {
    // Place the cursor in the seam's overlap zone: `editedToSource` resolves overlap to the
    // incoming (post-cut) segment, so the source boundary value — and thus the word highlight —
    // tracks the audio that is actually becoming audible.
    let model = editor()
    addRemoval(model, 40_000, 60_000, length: 4_800)
    model.playheadEditedSample = 35_300  // 100 into the overlap → source 60_100
    expectNoDifference(model.playheadSourceSample, 60_100)
  }
}
