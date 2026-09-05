import CustomDump
import Dependencies
import Foundation
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct EditorRulerTests {
  private func editor(_ plan: EditPlan = Fixtures.editPlan()) -> EditorModel {
    EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: plan)
  }

  /// Installs explicit waveform geometry (no audio decode) so `xToSample` is meaningful:
  /// `xToSample(x) == start + floor(x * samplesPerPixel)`.
  private func geometry(
    _ model: EditorModel, samplesPerPixel: Double = 100, start: Int = 0,
    viewportWidth: CGFloat = 1000
  ) {
    let duration = model.editPlan.source.durationSamples
    model.waveform.totalSamples = duration
    // The editor now hit-tests on the EDITED adapter, whose `hasUsableGeometry` requires a loaded
    // source waveform — install a trivial pyramid so ruler moves aren't gated off.
    model.waveform.waveform = Waveform.pyramid(
      baseMins: [0], baseMaxs: [0], sampleRate: model.editPlan.source.sampleRate,
      totalSamples: duration, baseBucketSize: 4)
    model.waveform.viewportWidth = viewportWidth
    model.waveform.samplesPerPixel = samplesPerPixel
    model.waveform.visibleStartSample = start
    model.editedWaveform.viewportWidth = viewportWidth
    model.editedWaveform.samplesPerPixel = samplesPerPixel
    model.editedWaveform.visibleStartSample = start
  }

  private func settle(until condition: () -> Bool) async {
    for _ in 0..<1000 where !condition() { await Task.yield() }
  }

  private func selectWords(_ transcript: TranscriptPageModel, _ first: Int, _ last: Int) {
    transcript.transcriptDragBegan(
      atUTF16Offset: transcript.document.wordRanges[first].range.location)
    transcript.transcriptDragged(
      toUTF16Offset: transcript.document.wordRanges[last].range.location)
  }

  private func gatedPlay(_ gate: RulerPlayGate)
    -> @Sendable (URL, Range<Int>, Int, Double, PlaybackSessionID) async throws -> PlaybackEnd
  {
    { _, _, _, _, _ in await gate.play() }
  }

  /// `playEdited` counterpart to `gatedPlay`: the ruler's playback-interaction tests all drive
  /// free play (`transportPlayTapped` from stopped), which now goes through `playEdited`.
  private func gatedPlayEdited(_ gate: RulerPlayGate)
    -> @Sendable (URL, AudioEditRenderPlan, Int, Double, PlaybackSessionID) async throws ->
    EditedPlaybackEnd
  {
    { _, _, _, _, _ in EditedPlaybackEnd(end: await gate.play(), finishedEditedSample: nil) }
  }

  // MARK: - Mapping + clamping

  @Test func rulerClickMapsViewXToPlanSample() {
    let model = editor()
    geometry(model, samplesPerPixel: 100, start: 0)
    model.rulerMovedPlayhead(toX: 5)  // 0 + floor(5 * 100) = 500
    expectNoDifference(model.playheadEditedSample, 500)
  }

  @Test func rulerClickHonorsScrolledStartAndZoom() {
    let model = editor()
    geometry(model, samplesPerPixel: 50, start: 2000)
    model.rulerMovedPlayhead(toX: 10)  // 2000 + floor(10 * 50) = 2500
    expectNoDifference(model.playheadEditedSample, 2500)
  }

  @Test func rulerClickClampsNegativeXToZero() {
    let model = editor()
    geometry(model, samplesPerPixel: 100, start: 0)
    model.playheadEditedSample = 4321
    model.rulerMovedPlayhead(toX: -25)  // would map below 0
    expectNoDifference(model.playheadEditedSample, 0)
  }

  @Test func rulerClickClampsPastEndToDurationSamples() {
    let model = editor()
    let duration = model.editPlan.source.durationSamples
    geometry(model, samplesPerPixel: 100, start: 0)
    model.rulerMovedPlayhead(toX: 100_000)  // 10,000,000 samples, well past EOF
    expectNoDifference(model.playheadEditedSample, duration)  // EOF is a valid resting cursor
  }

  @Test func rulerMoveIsNoOpWithoutWaveformGeometry() {
    let model = editor()
    model.playheadEditedSample = 777  // no geometry loaded → totalSamples == 0
    model.rulerMovedPlayhead(toX: 40)
    // Unchanged: the mapping would be meaningless.
    expectNoDifference(model.playheadEditedSample, 777)
  }

  @Test func rulerMoveIsNoOpWhenViewportNotYetMeasured() {
    let model = editor()
    model.waveform.totalSamples = model.editPlan.source.durationSamples  // file length known...
    model.waveform.viewportWidth = 0  // ...but layout hasn't measured the viewport yet
    model.playheadEditedSample = 555
    model.rulerMovedPlayhead(toX: 40)  // spp is still the default 1; the mapping would be garbage
    // Guarded on usable geometry, not just totalSamples.
    expectNoDifference(model.playheadEditedSample, 555)
  }

  @Test func rulerMoveIsNoOpWhileWaveformLoading() {
    let model = editor()
    model.waveform.totalSamples = model.editPlan.source.durationSamples  // length set early in load
    model.waveform.viewportWidth = 1000
    model.waveform.samplesPerPixel = 1  // still the default; the real fit isn't set until load ends
    model.waveform.isLoading = true  // mid-decode
    model.playheadEditedSample = 555
    model.rulerMovedPlayhead(toX: 40)
    // Guarded on !isLoading: mapping with the default spp during the decode window is garbage.
    expectNoDifference(model.playheadEditedSample, 555)
  }

  // MARK: - Interaction with the transport

  @Test func rulerMoveWhileStoppedJustMovesTheCursor() {
    let model = editor()
    geometry(model, samplesPerPixel: 100, start: 0)
    model.rulerMovedPlayhead(toX: 3)
    expectNoDifference(model.playheadEditedSample, 300)
    expectNoDifference(model.transportPhase, .stopped)
  }

  @Test func rulerMoveDuringPlaybackStopsThenMovesToClick() async {
    let gate = RulerPlayGate()
    let stoppedSession = LockIsolated<PlaybackSessionID?>(nil)
    let model = editor()
    geometry(model, samplesPerPixel: 100, start: 0)
    model.playheadEditedSample = 1000
    await withDependencies {
      $0.audioPlayer.playEdited = gatedPlayEdited(gate)
      $0.audioPlayer.stop = { session in
        stoppedSession.setValue(session)
        gate.release()
      }
    } operation: {
      let task = Task { await model.transportPlayTapped() }
      await gate.awaitStarted()
      #expect(model.isTransportPlaying)
      let session = model.transportPhase.session
      model.playheadEditedSample = 8000  // audio "advanced" the cursor during playback

      model.rulerMovedPlayhead(toX: 6)  // stops the transport, then snaps to floor(6*100)=600
      expectNoDifference(model.transportPhase, .stopped)  // reset synchronously
      // Where the user clicked, not the range end.
      expectNoDifference(model.playheadEditedSample, 600)

      await settle { stoppedSession.value != nil }
      expectNoDifference(stoppedSession.value, session)  // stopped OUR session, not stop(nil)
      await task.value
      expectNoDifference(model.playheadEditedSample, 600)  // the superseded play never moved it
    }
  }

  @Test func rulerMoveWhilePausedStopsAndMoves() async {
    let gate = RulerPlayGate()
    let stopped = LockIsolated(false)
    let model = editor()
    geometry(model, samplesPerPixel: 100, start: 0)
    model.playheadEditedSample = 1000
    await withDependencies {
      $0.audioPlayer.playEdited = gatedPlayEdited(gate)
      $0.audioPlayer.pause = { _ in .edited(4321) }
      $0.audioPlayer.stop = { _ in
        stopped.setValue(true)
        gate.release()
      }
    } operation: {
      let task = Task { await model.transportPlayTapped() }
      await gate.awaitStarted()
      await model.transportPauseTapped()
      #expect(model.isTransportPaused)  // paused session still owns scheduled audio

      model.rulerMovedPlayhead(toX: 2)  // must tear down the paused session, then move
      expectNoDifference(model.transportPhase, .stopped)
      expectNoDifference(model.playheadEditedSample, 200)

      await settle { stopped.value }
      #expect(stopped.value)
      await task.value
    }
  }

  @Test func fastRulerDragLandsOnTheLastEventSample() {
    let model = editor()
    geometry(model, samplesPerPixel: 100, start: 0)
    // A drag delivers ordered synchronous move events; the cursor tracks the latest one.
    model.rulerMovedPlayhead(toX: 1)
    model.rulerMovedPlayhead(toX: 4)
    model.rulerMovedPlayhead(toX: 9)
    expectNoDifference(model.playheadEditedSample, 900)
  }

  @Test func rulerMoveDoesNotClearTheSelection() {
    let model = editor()
    geometry(model, samplesPerPixel: 100, start: 0)
    selectWords(model.transcript, 1, 4)
    let selection = model.audioSelection
    #expect(selection != nil)

    model.rulerMovedPlayhead(toX: 3)
    expectNoDifference(model.playheadEditedSample, 300)
    // Ruling D: a ruler move never clears the selection.
    expectNoDifference(model.audioSelection, selection)
  }

  /// A ruler click landing while `transportSelectionChanged` is suspended awaiting its stop must
  /// win: that snap changes neither the selection nor the session, so only the cursor-move epoch
  /// tells it a ruler placement happened and it must bail instead of clobbering the ruler position.
  @Test func rulerMoveDuringSuspendedSelectionSnapIsNotClobbered() async {
    let stopGate = RulerPlayGate()
    let model = editor()
    geometry(model, samplesPerPixel: 100, start: 0)
    selectWords(model.transcript, 1, 3)  // selection A
    let rangeA = model.audioSelection!
    model.transportPhase = .playing(PlaybackSessionID())  // A's snap must stop this first
    await withDependencies {
      $0.audioPlayer.stop = { _ in _ = await stopGate.play() }  // suspend inside A's stop
    } operation: {
      let token = model.cursorMoveToken  // captured synchronously, as the view's onChange does
      let snap = Task { await model.transportSelectionChanged(rangeA, cursorToken: token) }
      await stopGate.awaitStarted()  // the snap is suspended awaiting the stop
      model.rulerMovedPlayhead(toX: 7)  // ruler click lands during the suspension → 700
      expectNoDifference(model.playheadEditedSample, 700)
      stopGate.release()  // the snap resumes and must NOT clobber the ruler position
      await snap.value
      // Still where the ruler put it, not snapped to rangeA's start.
      expectNoDifference(model.playheadEditedSample, 700)
    }
  }

  /// The no-playback version: a deferred selection snap (token captured at selection-change time)
  /// must yield to a ruler click that lands before the snap task runs, even with nothing playing.
  @Test func rulerMoveBeatsADeferredSelectionSnapWhenStopped() async {
    let model = editor()
    geometry(model, samplesPerPixel: 100, start: 0)
    selectWords(model.transcript, 1, 3)  // selection A registered; onChange captures the token now
    let rangeA = model.audioSelection!
    let token = model.cursorMoveToken
    model.rulerMovedPlayhead(toX: 7)  // ruler click lands before the deferred snap runs → 700
    // The deferred snap runs late; the ruler is the later action and wins.
    await model.transportSelectionChanged(rangeA, cursorToken: token)
    expectNoDifference(model.playheadEditedSample, 700)
  }

  /// A deferred selection snap must not stop a transport the user started AFTER changing the
  /// selection: the Play takes cursor authority (bumping the generation), so the stale snap bails
  /// before touching playback instead of stopping it and snapping the cursor back.
  @Test func deferredSelectionSnapDoesNotStopALaterPlay() async {
    let gate = RulerPlayGate()
    let stopped = LockIsolated(false)
    let model = editor()
    geometry(model, samplesPerPixel: 100, start: 0)
    selectWords(model.transcript, 1, 3)  // selection A; the view would capture the token here
    let rangeA = model.audioSelection!
    let token = model.cursorMoveToken
    model.playheadEditedSample = rangeA.lowerBound  // a valid play start within the selection
    await withDependencies {
      $0.audioPlayer.playEdited = gatedPlayEdited(gate)
      $0.audioPlayer.stop = { _ in
        stopped.setValue(true)
        gate.release()
      }
    } operation: {
      // Play starts after the selection change.
      let play = Task { await model.transportPlayTapped() }
      await gate.awaitStarted()
      #expect(model.isTransportPlaying)
      // The deferred snap runs late; it must bail, not stop the Play the user just started.
      await model.transportSelectionChanged(rangeA, cursorToken: token)
      #expect(model.isTransportPlaying)
      #expect(!stopped.value)
      await model.transportStopTapped()
      await play.value
    }
  }
}

/// Suspends each `play` until released so a ruler interaction can act against a genuinely in-flight
/// transport. Mirrors `EditorTransportTests`'s gate (file-private there); kept local to this suite.
private final class RulerPlayGate: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [CheckedContinuation<Void, Never>] = []
  private let startedContinuation: AsyncStream<Void>.Continuation
  let started: AsyncStream<Void>
  init() {
    var continuation: AsyncStream<Void>.Continuation!
    started = AsyncStream { continuation = $0 }
    startedContinuation = continuation
  }
  func play() async -> PlaybackEnd {
    startedContinuation.yield(())
    await withCheckedContinuation { cont in
      lock.lock()
      continuations.append(cont)
      lock.unlock()
    }
    return .finished
  }
  func release() {
    lock.lock()
    let conts = continuations
    continuations = []
    lock.unlock()
    for cont in conts { cont.resume() }
  }
  func awaitStarted() async {
    var it = started.makeAsyncIterator()
    _ = await it.next()
  }
}
