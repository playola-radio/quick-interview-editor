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
