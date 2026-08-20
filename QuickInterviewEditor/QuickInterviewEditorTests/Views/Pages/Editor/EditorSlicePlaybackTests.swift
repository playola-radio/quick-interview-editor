import CustomDump
import Dependencies
import Foundation
import Testing

@testable import QuickInterviewEditor

/// Slice playback must match slice EXPORT: a clip whose range crosses a removed span plays the
/// same slice-local render plan the exporter builds, never the raw source range that still
/// contains the removed audio. Plus the finish-cursor honesty rule for edited-timeline playback.
///
/// The fixture geometry every test below shares: one removal over SOURCE [40_000, 60_000) with a
/// 4_800-sample crossfade, and a slice over SOURCE [30_000, 80_000).
///
/// Slice-local axis (source 0 = 30_000): the removal rebases to [10_000, 30_000), leaving kept
/// runs [0, 10_000) at edited 0 and [30_000, 50_000) at edited 5_200 — an edited duration of
/// 25_200, with the crossfade occupying edited [5_200, 10_000).
@MainActor
struct EditorSlicePlaybackTests {
  private let removalID = Fixtures.uuid(1)

  private func editor(_ plan: EditPlan = Fixtures.editPlan()) -> EditorModel {
    EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: plan)
  }

  private func addRemoval(_ model: EditorModel, _ lower: Int, _ upper: Int, length: Int) {
    model.mutateDocument { doc in
      doc.timelineRemovals.append(
        TimelineRemoval(
          id: removalID, removedRange: lower..<upper,
          crossfade: Crossfade(lengthSamples: length, curve: .equalPower)))
    }
  }

  @discardableResult
  private func addSlice(_ model: EditorModel, _ start: Int, _ end: Int) -> Slice {
    let slice = Slice(
      id: UUID(), name: "S", startSample: start, endSample: end, wordIDs: [],
      snippet: "", warnings: [])
    model.mutateSlices { $0.append(slice) }
    return slice
  }

  private func settle(until condition: @autoclosure () -> Bool) async {
    for _ in 0..<1000 where !condition() { await Task.yield() }
  }

  /// Suspends a play call until the test releases it, so assertions can run mid-playback.
  private actor PlayGate {
    private var continuation: CheckedContinuation<PlaybackEnd, Never>?
    func play() async -> PlaybackEnd {
      await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ end: PlaybackEnd) {
      continuation?.resume(returning: end)
      continuation = nil
    }
  }

  // MARK: - Which path a slice takes

  @Test func sliceClearOfEveryRemovalStillPlaysTheRawSourceRange() async {
    let model = editor()
    addRemoval(model, 40_000, 60_000, length: 4_800)
    let slice = addSlice(model, 5_000, 20_000)
    let playedRange = LockIsolated<Range<Int>?>(nil)
    let playedEdited = LockIsolated(false)
    await withDependencies {
      $0.audioPlayer.play = { _, range, _, _, _ in
        playedRange.setValue(range)
        return .finished
      }
      $0.audioPlayer.playEdited = { _, _, _, _, _ in
        playedEdited.setValue(true)
        return EditedPlaybackEnd(end: .finished, finishedEditedSample: nil)
      }
    } operation: {
      await model.playSliceTapped(slice.id)
    }
    // No removal reaches this slice, so the tuned source-range path is untouched — the playlist
    // is never involved for audio that would be identical.
    expectNoDifference(playedRange.value, 5_000..<20_000)
    #expect(!playedEdited.value)
  }

  @Test func sliceCrossingARemovalPlaysTheSliceLocalRenderPlan() async {
    let model = editor()
    addRemoval(model, 40_000, 60_000, length: 4_800)
    let slice = addSlice(model, 30_000, 80_000)
    let recorded = LockIsolated<AudioEditRenderPlan?>(nil)
    let playedRaw = LockIsolated(false)
    await withDependencies {
      $0.audioPlayer.playEdited = { _, plan, _, _, _ in
        recorded.setValue(plan)
        return EditedPlaybackEnd(end: .finished, finishedEditedSample: nil)
      }
      $0.audioPlayer.play = { _, _, _, _, _ in
        playedRaw.setValue(true)
        return .finished
      }
    } operation: {
      await model.playSliceTapped(slice.id)
    }
    #expect(!playedRaw.value)
    // SOURCE ranges are ABSOLUTE (canonical-file coordinates) while the edited axis is
    // slice-local. Nothing between 40_000 and 60_000 is scheduled straight: the outgoing tail
    // stops at 40_000 and the incoming head resumes at 60_000, blended across the seam.
    expectNoDifference(
      recorded.value?.items,
      [
        .segment(source: 30_000..<35_200, editedStart: 0),
        .seam(
          id: removalID, leftTail: 35_200..<40_000, rightHead: 60_000..<64_800,
          length: 4_800, editedStart: 5_200, fadeOffset: 0),
        .segment(source: 64_800..<80_000, editedStart: 10_000),
      ])
  }

  @Test func sliceBuriedInsideARemovalPlaysNothing() async {
    let model = editor()
    addRemoval(model, 40_000, 60_000, length: 4_800)
    let slice = addSlice(model, 42_000, 58_000)
    let played = LockIsolated(false)
    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _, _ in
        played.setValue(true)
        return .finished
      }
      $0.audioPlayer.playEdited = { _, _, _, _, _ in
        played.setValue(true)
        return EditedPlaybackEnd(end: .finished, finishedEditedSample: nil)
      }
    } operation: {
      await model.playSliceTapped(slice.id)
    }
    // Its entire audio is removed — export calls it unexportable, and there is nothing to hear.
    // The transport must stay stopped rather than start a silent session.
    #expect(!played.value)
    expectNoDifference(model.transportPhase, .stopped)
    expectNoDifference(model.transportContext, .free)
  }

  // MARK: - Slice-local axis conversion

  @Test func slicePlaylistTickLandsCursorAtTheGlobalEditedPosition() async {
    let model = editor()
    addRemoval(model, 40_000, 60_000, length: 4_800)
    let slice = addSlice(model, 30_000, 80_000)
    let gate = PlayGate()
    let (stream, continuation) = AsyncStream.makeStream(of: PlaybackPosition.self)
    await withDependencies {
      $0.audioPlayer.playEdited = { _, _, _, _, _ in
        EditedPlaybackEnd(end: await gate.play(), finishedEditedSample: nil)
      }
      $0.audioPlayer.positions = { stream }
      $0.audioPlayer.stop = { _ in await gate.finish(.stopped) }
    } operation: {
      let observe = Task { await model.observePlayback() }
      let play = Task { await model.playSliceTapped(slice.id) }
      await settle(until: model.isTransportPlaying)
      let session = model.transportPhase.session!
      // Slice-local edited 12_000 is 6_800 into the post-cut run, i.e. slice-local source
      // 36_800 → absolute source 66_800.
      continuation.yield(
        PlaybackPosition(sessionID: session, sample: .edited(12_000), isPlaying: true))
      await settle(until: model.playheadSourceSample == 66_800)
      expectNoDifference(model.playheadSourceSample, 66_800)
      // …which is edited 42_000 on the GLOBAL axis the cursor lives on — NOT the raw 12_000 the
      // player reported, which would point at unrelated audio near the top of the recording.
      expectNoDifference(model.playheadEditedSample, 42_000)
      continuation.finish()
      await observe.value
      await model.transportStopTapped()
      await play.value
    }
  }

  @Test func slicePlaylistPauseFreezesCursorAtTheConvertedSourceSample() async {
    let model = editor()
    addRemoval(model, 40_000, 60_000, length: 4_800)
    let slice = addSlice(model, 30_000, 80_000)
    let gate = PlayGate()
    await withDependencies {
      $0.audioPlayer.playEdited = { _, _, _, _, _ in
        EditedPlaybackEnd(end: await gate.play(), finishedEditedSample: nil)
      }
      $0.audioPlayer.pause = { _ in .edited(12_000) }
      $0.audioPlayer.stop = { _ in await gate.finish(.stopped) }
    } operation: {
      let play = Task { await model.playSliceTapped(slice.id) }
      await settle(until: model.isTransportPlaying)
      let session = model.transportPhase.session!
      await model.transportPauseTapped()
      expectNoDifference(model.playheadSourceSample, 66_800)
      expectNoDifference(model.playheadEditedSample, 42_000)
      expectNoDifference(model.transportPhase, .paused(session))
      await model.transportStopTapped()
      await play.value
    }
  }

  @Test func slicePlaylistFinishRestsCursorAtTheSliceEnd() async {
    let model = editor()
    addRemoval(model, 40_000, 60_000, length: 4_800)
    let slice = addSlice(model, 30_000, 80_000)
    await withDependencies {
      $0.audioPlayer.playEdited = { _, _, _, _, _ in
        EditedPlaybackEnd(end: .finished, finishedEditedSample: nil)
      }
    } operation: {
      await model.playSliceTapped(slice.id)
    }
    // Unchanged from the source-range path: a slice rests at its own end on the SOURCE axis.
    // The player's finish sample is slice-local and deliberately ignored here.
    expectNoDifference(model.playheadSourceSample, 80_000)
    expectNoDifference(model.playheadEditedSample, 55_200)
    expectNoDifference(model.transportPhase, .stopped)
  }

  @Test func conversionIsDroppedWhenTheSlicePlaybackEnds() async {
    let model = editor()
    addRemoval(model, 40_000, 60_000, length: 4_800)
    let slice = addSlice(model, 30_000, 80_000)
    await withDependencies {
      $0.audioPlayer.playEdited = { _, _, _, _, _ in
        EditedPlaybackEnd(end: .finished, finishedEditedSample: nil)
      }
    } operation: {
      await model.playSliceTapped(slice.id)
    }
    // A later free-play session reports on the GLOBAL edited axis. If the finished slice's
    // conversion lingered, this tick would be mangled through the slice's local timeline.
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
    expectNoDifference(model.playheadEditedSample, 45_200)
  }

  // MARK: - A natural finish rests where the audio really ended

  @Test func finishRestsCursorAtTheSampleThePlaylistActuallyReached() async {
    let model = editor()
    model.playheadEditedSample = 1_000
    await withDependencies {
      // A stale/short canonical file clamps the schedule, so the audio stops well before the
      // plan's declared end. The player reports where it truly ended.
      $0.audioPlayer.playEdited = { _, _, _, _, _ in
        EditedPlaybackEnd(end: .finished, finishedEditedSample: 500_000)
      }
    } operation: {
      await model.transportPlayTapped()
    }
    expectNoDifference(model.playheadEditedSample, 500_000)
    #expect(model.playheadEditedSample != model.editPlan.source.durationSamples)
  }

  @Test func finishWithoutAReportedSampleFallsBackToThePlanEnd() async {
    let model = editor()
    model.playheadEditedSample = 1_000
    await withDependencies {
      $0.audioPlayer.playEdited = { _, _, _, _, _ in
        EditedPlaybackEnd(end: .finished, finishedEditedSample: nil)
      }
    } operation: {
      await model.transportPlayTapped()
    }
    expectNoDifference(
      model.playheadEditedSample, model.editedWaveform.timeline.editedDurationSamples)
  }

  @Test func supersededPlaylistIgnoresAnyReportedFinishSample() async {
    let model = editor()
    model.playheadEditedSample = 1_000
    await withDependencies {
      // Another tab took over the shared player. A non-`finished` end never moves the cursor,
      // whatever sample rides along with it.
      $0.audioPlayer.playEdited = { _, _, _, _, _ in
        EditedPlaybackEnd(end: .superseded, finishedEditedSample: 500_000)
      }
    } operation: {
      await model.transportPlayTapped()
    }
    expectNoDifference(model.playheadEditedSample, 1_000)
  }
}
