import CustomDump
import Dependencies
import Foundation
import Sharing
import Testing

@testable import PlayolaInterviewEditor

// swiftlint:disable large_tuple
// The (URL, Range<Int>, Int) recorded-call tuple mirrors `audioPlayer.play`'s three
// leading arguments, so it recurs across the gate helper and the tests that assert on a call.
// Free play (Play/Space from stopped) now goes through `audioPlayer.playEdited` instead, whose
// (URL, AudioEditRenderPlan, Int) tuple mirrors ITS three leading arguments the same way.

/// Suspends each `play` until released; reports starts. Holds an array of continuations so two
/// overlapping plays (a supersession) both suspend and resume together. Mirrors AuditionGate.
private final class TransportGate: @unchecked Sendable {
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

/// A minimal stand-in for the ONE shared player two editor tabs contend over. `play` supersedes any
/// in-flight play (resuming it `.superseded`) and suspends as the new current; the test finishes the
/// current play explicitly. Reproduces the cross-tab supersede the single-session gates can't: the
/// backgrounded tab's own `transportPhase` still holds its session because the foreground tab never
/// touches it, so only the `.superseded` return distinguishes it from a natural end.
private actor SharedFakePlayer {
  private var current: CheckedContinuation<PlaybackEnd, Never>?
  private let startedContinuation: AsyncStream<Void>.Continuation
  let started: AsyncStream<Void>
  init() {
    var continuation: AsyncStream<Void>.Continuation!
    started = AsyncStream { continuation = $0 }
    startedContinuation = continuation
  }
  func play() async -> PlaybackEnd {
    if let current {
      self.current = nil
      current.resume(returning: .superseded)
    }
    startedContinuation.yield(())
    return await withCheckedContinuation { self.current = $0 }
  }
  func finishCurrent() {
    guard let current else { return }
    self.current = nil
    current.resume(returning: .finished)
  }
  func awaitStarted() async {
    var it = started.makeAsyncIterator()
    _ = await it.next()
  }
}

@MainActor
struct EditorTransportTests {
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

  private func recordingPlay(
    _ recorded: LockIsolated<(URL, Range<Int>, Int)?>, _ gate: TransportGate
  ) -> @Sendable (URL, Range<Int>, Int, Double, PlaybackSessionID) async throws -> PlaybackEnd {
    { url, range, sampleRate, _, _ in
      recorded.setValue((url, range, sampleRate))
      return await gate.play()
    }
  }

  /// `playEdited` counterpart to `recordingPlay`, for free-play tests (the main Play/Space from
  /// stopped now builds an `AudioEditRenderPlan` instead of a source `Range<Int>`).
  private func recordingPlayEdited(
    _ recorded: LockIsolated<(URL, AudioEditRenderPlan, Int)?>, _ gate: TransportGate
  )
    -> @Sendable (URL, AudioEditRenderPlan, Int, Double, PlaybackSessionID) async throws ->
    EditedPlaybackEnd
  {
    { url, plan, sampleRate, _, _ in
      recorded.setValue((url, plan, sampleRate))
      return EditedPlaybackEnd(end: await gate.play(), finishedEditedSample: nil)
    }
  }

  // MARK: - Panel flags

  @Test func panelFlagsWhenStoppedWithPlayableCursor() {
    let model = editor()
    model.playheadEditedSample = 1000  // mid-file, no selection → a playable range exists
    #expect(model.canTransportPlay)
    #expect(!model.canTransportPause)
    #expect(!model.canTransportStop)
    #expect(!model.isTransportPlaying)
    #expect(!model.isTransportPaused)
  }

  @Test func playDisabledWhenCursorAtEndOfAudio() {
    let model = editor()
    model.playheadEditedSample = model.editPlan.source.durationSamples  // nothing left to play
    #expect(!model.canTransportPlay)
  }

  @Test func panelFlagsWhilePlaying() {
    let model = editor()
    model.transportPhase = .playing(PlaybackSessionID())
    #expect(!model.canTransportPlay)
    #expect(model.canTransportPause)
    #expect(model.canTransportStop)
    #expect(model.isTransportPlaying)
  }

  @Test func panelFlagsWhilePaused() {
    let model = editor()
    model.transportPhase = .paused(PlaybackSessionID())
    #expect(model.canTransportPlay)  // resume
    #expect(!model.canTransportPause)
    #expect(model.canTransportStop)
    #expect(model.isTransportPaused)
  }

  // MARK: - Play

  @Test func playStartsFromCursorToEndOfAudioAndRecordsOrigin() async {
    let gate = TransportGate()
    let recorded = LockIsolated<(URL, AudioEditRenderPlan, Int)?>(nil)
    let model = editor()
    model.playheadEditedSample = 1000
    await withDependencies {
      $0.audioPlayer.playEdited = recordingPlayEdited(recorded, gate)
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      let task = Task { await model.transportPlayTapped() }
      await gate.awaitStarted()
      #expect(model.isTransportPlaying)
      expectNoDifference(model.transportOriginEditedSample, 1000)
      expectNoDifference(recorded.value?.0, model.canonicalAudioURL)
      expectNoDifference(recorded.value?.1.items.first?.editedSpan.lowerBound, 1000)
      expectNoDifference(
        recorded.value?.1.items.last?.editedSpan.upperBound,
        model.editPlan.source.durationSamples)
      expectNoDifference(recorded.value?.2, model.editPlan.source.sampleRate)
      await model.transportStopTapped()
      await task.value
    }
  }

  @Test func playRunsToFileEndIgnoringSelection() async {
    let gate = TransportGate()
    let recorded = LockIsolated<(URL, AudioEditRenderPlan, Int)?>(nil)
    let model = editor()
    selectWords(model.transcript, 1, 4)
    let selection = model.audioSelection!
    model.playheadEditedSample = selection.lowerBound
    await withDependencies {
      $0.audioPlayer.playEdited = recordingPlayEdited(recorded, gate)
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      let task = Task { await model.transportPlayTapped() }
      await gate.awaitStarted()
      // Plays from the cursor to the END OF THE FILE, not to the selection's end.
      expectNoDifference(recorded.value?.1.items.first?.editedSpan.lowerBound, selection.lowerBound)
      expectNoDifference(
        recorded.value?.1.items.last?.editedSpan.upperBound,
        model.editPlan.source.durationSamples)
      await model.transportStopTapped()
      await task.value
    }
  }

  @Test func playIsNoOpWhenCursorPastPlayableEnd() async {
    let played = LockIsolated(false)
    let model = editor()
    model.playheadEditedSample = model.editPlan.source.durationSamples
    await withDependencies {
      $0.audioPlayer.playEdited = { _, _, _, _, _ in
        played.setValue(true)
        return EditedPlaybackEnd(end: .finished, finishedEditedSample: nil)
      }
    } operation: {
      await model.transportPlayTapped()
    }
    #expect(!played.value)
    #expect(!model.isTransportPlaying)
    expectNoDifference(model.transportPhase, .stopped)
  }

  @Test func playFailureLeavesCursorPutAndResetsTransport() async {
    let model = editor()
    model.playheadEditedSample = 1000
    await withDependencies {
      $0.audioPlayer.playEdited = { _, _, _, _, _ in
        throw EngineClientError.engineFailed("boom")
      }
    } operation: {
      await withKnownIssue {
        await model.transportPlayTapped()
      }
    }
    // A failed play must not jump to the range end.
    expectNoDifference(model.playheadEditedSample, 1000)
    expectNoDifference(model.transportPhase, .stopped)
    #expect(model.transportPhase.session == nil)
  }

  @Test func naturalCompletionLeavesCursorAtRangeEnd() async {
    let gate = TransportGate()
    let model = editor()
    model.playheadEditedSample = 1000
    let end = model.editPlan.source.durationSamples
    await withDependencies {
      $0.audioPlayer.playEdited = { _, _, _, _, _ in
        EditedPlaybackEnd(end: await gate.play(), finishedEditedSample: nil)
      }
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      let task = Task { await model.transportPlayTapped() }
      await gate.awaitStarted()
      gate.release()  // natural completion (no Stop)
      await task.value
      expectNoDifference(model.transportPhase, .stopped)
      expectNoDifference(model.playheadEditedSample, end)  // left where the audio ended
      #expect(model.transportPhase.session == nil)
    }
  }

  // MARK: - Pause / resume

  @Test func pauseFreezesCursorAtReportedSampleAndHoldsPlay() async {
    let gate = TransportGate()
    let model = editor()
    model.playheadEditedSample = 1000
    await withDependencies {
      $0.audioPlayer.playEdited = { _, _, _, _, _ in
        EditedPlaybackEnd(end: await gate.play(), finishedEditedSample: nil)
      }
      $0.audioPlayer.pause = { _ in .edited(4321) }
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      let task = Task { await model.transportPlayTapped() }
      await gate.awaitStarted()
      let session = model.transportPhase.session
      await model.transportPauseTapped()
      expectNoDifference(model.playheadEditedSample, 4321)  // frozen at the exact reported sample
      #expect(model.isTransportPaused)
      expectNoDifference(model.transportPhase, .paused(session!))
      #expect(!task.isCancelled)  // the play call is still in flight
      await model.transportStopTapped()
      await task.value
    }
  }

  @Test func pausedCursorIgnoresBufferedTick() async {
    let model = editor()
    let session = PlaybackSessionID()
    model.transportPhase = .paused(session)  // the session is carried by the phase now
    model.playheadEditedSample = 4321  // the exact sample `pause` froze the cursor at
    let (stream, continuation) = AsyncStream.makeStream(of: PlaybackPosition.self)
    await withDependencies {
      $0.audioPlayer.positions = { stream }
    } operation: {
      let task = Task { await model.observePlayback() }
      // A buffered straggler tick for the paused session must NOT thaw the frozen cursor.
      continuation.yield(
        PlaybackPosition(sessionID: session, sample: .source(9000), isPlaying: true))
      await settle { false }  // let the tick be processed
      expectNoDifference(model.playheadEditedSample, 4321)
      continuation.finish()
      await task.value
    }
  }

  @Test func resumeContinuesTheSameSession() async {
    let gate = TransportGate()
    let resumed = LockIsolated(false)
    let model = editor()
    model.playheadEditedSample = 1000
    await withDependencies {
      $0.audioPlayer.playEdited = { _, _, _, _, _ in
        EditedPlaybackEnd(end: await gate.play(), finishedEditedSample: nil)
      }
      $0.audioPlayer.pause = { _ in .edited(4321) }
      $0.audioPlayer.resume = { _ in
        resumed.setValue(true)
        return true
      }
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      let task = Task { await model.transportPlayTapped() }
      await gate.awaitStarted()
      let session = model.transportPhase.session
      await model.transportPauseTapped()
      await model.transportPlayTapped()  // resume
      #expect(resumed.value)
      #expect(model.isTransportPlaying)
      expectNoDifference(model.transportPhase, .playing(session!))
      await model.transportStopTapped()
      await task.value
    }
  }

  @Test func resumeFailureLeavesTransportPaused() async {
    let gate = TransportGate()
    let model = editor()
    model.playheadEditedSample = 1000
    await withDependencies {
      $0.audioPlayer.playEdited = { _, _, _, _, _ in
        EditedPlaybackEnd(end: await gate.play(), finishedEditedSample: nil)
      }
      $0.audioPlayer.pause = { _ in .edited(4321) }
      $0.audioPlayer.resume = { _ in false }  // engine restart failed
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      let task = Task { await model.transportPlayTapped() }
      await gate.awaitStarted()
      let session = model.transportPhase.session
      await model.transportPauseTapped()
      await model.transportPlayTapped()  // resume attempt fails
      #expect(model.isTransportPaused)  // stays paused — the panel doesn't claim to be playing
      expectNoDifference(model.transportPhase, .paused(session!))
      await model.transportStopTapped()
      await task.value
    }
  }

  // MARK: - Stop

  @Test func stopReturnsCursorToOrigin() async {
    let gate = TransportGate()
    let stoppedSession = LockIsolated<PlaybackSessionID?>(nil)
    let model = editor()
    model.playheadEditedSample = 1000
    await withDependencies {
      $0.audioPlayer.playEdited = { _, _, _, _, _ in
        EditedPlaybackEnd(end: await gate.play(), finishedEditedSample: nil)
      }
      $0.audioPlayer.stop = { session in
        stoppedSession.setValue(session)
        gate.release()
      }
    } operation: {
      let task = Task { await model.transportPlayTapped() }
      await gate.awaitStarted()
      let session = model.transportPhase.session
      model.playheadEditedSample = 8000  // simulate the cursor having advanced during playback
      await model.transportStopTapped()
      await task.value
      expectNoDifference(model.playheadEditedSample, 1000)  // back to the origin
      expectNoDifference(model.transportPhase, .stopped)
      #expect(model.transportPhase.session == nil)
      expectNoDifference(stoppedSession.value, session)  // stopped OUR session, not stop(nil)
    }
  }

  // MARK: - Coexistence with the convenience shortcuts

  @Test func startingASliceSupersedesTheTransport() async {
    let gate = TransportGate()
    let model = editor()
    model.playheadEditedSample = 1000
    selectWords(model.transcript, 0, 2)
    model.addSliceTapped()
    let slice = model.slices[0]
    await withDependencies {
      // Both paths are exercised: the transport (free play) starts via `playEdited`, then the
      // slice shortcut (`play`) takes it over.
      $0.audioPlayer.playEdited = { _, _, _, _, _ in
        EditedPlaybackEnd(end: await gate.play(), finishedEditedSample: nil)
      }
      $0.audioPlayer.play = { _, _, _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      let transport = Task { await model.transportPlayTapped() }
      await gate.awaitStarted()
      #expect(model.isTransportPlaying)
      let slicePlay = Task { await model.playSliceTapped(slice.id) }
      await gate.awaitStarted()
      // The slice IS the transport now — it took over the context and keeps playing.
      expectNoDifference(model.transportContext.sliceID, slice.id)
      #expect(model.isTransportPlaying)
      gate.release()
      await transport.value
      await slicePlay.value
    }
  }

  @Test func sliceShortcutSetsContextCursorAndRangeThenPlays() async {
    let gate = TransportGate()
    let recorded = LockIsolated<(URL, Range<Int>, Int)?>(nil)
    let model = editor()
    model.playheadEditedSample = 7777
    selectWords(model.transcript, 0, 2)
    model.addSliceTapped()
    let slice = model.slices[0]
    await withDependencies {
      $0.audioPlayer.play = recordingPlay(recorded, gate)
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      let task = Task { await model.playSliceTapped(slice.id) }
      await gate.awaitStarted()
      // The shortcut selects the clip (context), positions the cursor + origin at its start, and
      // plays its range through the one transport.
      expectNoDifference(model.transportContext, .slice(slice.id))
      expectNoDifference(model.playheadEditedSample, slice.startSample)
      expectNoDifference(model.transportOriginEditedSample, slice.startSample)
      expectNoDifference(recorded.value?.1, slice.startSample..<slice.endSample)
      #expect(model.isTransportPlaying)
      await model.transportStopTapped()
      await task.value
      // Stop → origin (slice start)
      expectNoDifference(model.playheadEditedSample, slice.startSample)
    }
  }

  // MARK: - Space (Play/Stop)

  @Test func spaceStartsTransportWhenIdle() async {
    let gate = TransportGate()
    let model = editor()
    model.playheadEditedSample = 1000
    await withDependencies {
      $0.audioPlayer.playEdited = { _, _, _, _, _ in
        EditedPlaybackEnd(end: await gate.play(), finishedEditedSample: nil)
      }
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      let task = Task { await model.transportPlayStopTapped() }
      await gate.awaitStarted()
      #expect(model.isTransportPlaying)
      await model.transportStopTapped()
      await task.value
    }
  }

  @Test func spaceStopsTransportWhenPlaying() async {
    let gate = TransportGate()
    let model = editor()
    model.playheadEditedSample = 1000
    await withDependencies {
      $0.audioPlayer.playEdited = { _, _, _, _, _ in
        EditedPlaybackEnd(end: await gate.play(), finishedEditedSample: nil)
      }
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      let task = Task { await model.transportPlayTapped() }
      await gate.awaitStarted()
      model.playheadEditedSample = 8000
      await model.transportPlayStopTapped()  // playing → stop to origin
      await task.value
      expectNoDifference(model.transportPhase, .stopped)
      expectNoDifference(model.playheadEditedSample, 1000)
    }
  }

  @Test func spaceStopsAPlayingSlice() async {
    let gate = TransportGate()
    let stopped = LockIsolated(false)
    let model = editor()
    selectWords(model.transcript, 0, 2)
    model.addSliceTapped()
    let slice = model.slices[0]
    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { _ in
        stopped.setValue(true)
        gate.release()
      }
    } operation: {
      let task = Task { await model.playSliceTapped(slice.id) }
      await gate.awaitStarted()
      await model.transportPlayStopTapped()  // a slice IS the transport now — Space stops it
      await task.value
      expectNoDifference(model.transportContext.sliceID, nil)
      expectNoDifference(model.transportContext, .free)
      #expect(stopped.value)
    }
  }

  // MARK: - Selection snap

  @Test func selectionSnapsCursorToSelectionStart() async {
    let model = editor()
    model.playheadEditedSample = 9999
    selectWords(model.transcript, 2, 4)
    let selection = model.audioSelection!
    await model.transportSelectionChanged(selection, cursorToken: model.cursorMoveToken)
    expectNoDifference(model.playheadEditedSample, selection.lowerBound)
  }

  @Test func clearingSelectionLeavesCursorPut() async {
    let model = editor()
    model.playheadEditedSample = 5000
    await model.transportSelectionChanged(nil, cursorToken: model.cursorMoveToken)
    // Clearing the selection never moves the cursor.
    expectNoDifference(model.playheadEditedSample, 5000)
  }

  @Test func staleSelectionTaskDoesNotOverwriteNewerCursor() async {
    let stopGate = TransportGate()
    let model = editor()
    selectWords(model.transcript, 1, 3)  // selection A
    let rangeA = model.audioSelection!
    let session = PlaybackSessionID()
    model.transportPhase = .playing(session)  // A's reconciliation must stop this first
    await withDependencies {
      $0.audioPlayer.stop = { _ in _ = await stopGate.play() }  // suspend inside A's stop
    } operation: {
      let tokenA = model.cursorMoveToken
      let taskA = Task { await model.transportSelectionChanged(rangeA, cursorToken: tokenA) }
      await stopGate.awaitStarted()  // A is now suspended awaiting the stop
      selectWords(model.transcript, 5, 7)  // selection B arrives
      let rangeB = model.audioSelection!
      // B snaps immediately (no owner left)
      await model.transportSelectionChanged(rangeB, cursorToken: model.cursorMoveToken)
      expectNoDifference(model.playheadEditedSample, rangeB.lowerBound)
      stopGate.release()  // A resumes and must bail on the stale selection
      await taskA.value
      expectNoDifference(model.playheadEditedSample, rangeB.lowerBound)  // A did NOT clobber B
    }
  }

  @Test func selectionChangeStopsActivePlaybackThenSnaps() async {
    let gate = TransportGate()
    let stopped = LockIsolated(false)
    let model = editor()
    model.playheadEditedSample = 1000
    await withDependencies {
      $0.audioPlayer.playEdited = { _, _, _, _, _ in
        EditedPlaybackEnd(end: await gate.play(), finishedEditedSample: nil)
      }
      $0.audioPlayer.stop = { _ in
        stopped.setValue(true)
        gate.release()
      }
    } operation: {
      let task = Task { await model.transportPlayTapped() }
      await gate.awaitStarted()
      #expect(model.isTransportPlaying)
      selectWords(model.transcript, 3, 5)
      let selection = model.audioSelection!
      // Stop first, then snap.
      await model.transportSelectionChanged(selection, cursorToken: model.cursorMoveToken)
      await task.value
      #expect(stopped.value)
      expectNoDifference(model.transportPhase, .stopped)
      expectNoDifference(model.playheadEditedSample, selection.lowerBound)
    }
  }

  @Test func staleSelectionTaskDoesNotYankCursorIntoNewPlayback() async {
    let playGate = TransportGate()
    let stopGate = TransportGate()
    let model = editor()
    selectWords(model.transcript, 0, 2)
    model.addSliceTapped()  // clears the selection
    let slice = model.slices[0]
    selectWords(model.transcript, 6, 8)  // selection A, distinct from the slice's words
    let rangeA = model.audioSelection!
    model.transportPhase = .playing(PlaybackSessionID())  // the transport owns playback
    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _, _ in await playGate.play() }
      $0.audioPlayer.stop = { _ in _ = await stopGate.play() }
    } operation: {
      let tokenA = model.cursorMoveToken
      let taskA = Task { await model.transportSelectionChanged(rangeA, cursorToken: tokenA) }
      await stopGate.awaitStarted()  // A is suspended inside its stop
      // A slice shortcut B starts while A is stopping — it doesn't touch the selection.
      let taskB = Task { await model.playSliceTapped(slice.id) }
      await playGate.awaitStarted()
      expectNoDifference(model.transportContext.sliceID, slice.id)
      let cursorUnderB = model.playheadEditedSample  // B positioned the cursor at its start
      #expect(cursorUnderB != rangeA.lowerBound)
      stopGate.release()  // A resumes and must bail — B is playing now
      await taskA.value
      // NOT yanked to selection A's start
      expectNoDifference(model.playheadEditedSample, cursorUnderB)
      playGate.release()
      await taskB.value
    }
  }

  // MARK: - Multi-tab supersede vs natural end

  @Test func supersededPlayLeavesCursorPutNotAtRangeEnd() async {
    let gate = TransportGate()
    let model = editor()
    model.playheadEditedSample = 1000
    await withDependencies {
      // Another tab took over the shared player: `playEdited` returns `.superseded` while our own
      // session is still set (the other tab can't touch it). The transport must reset without
      // jumping the cursor to the range end.
      $0.audioPlayer.playEdited = { _, _, _, _, _ in
        _ = await gate.play()
        return EditedPlaybackEnd(end: .superseded, finishedEditedSample: nil)
      }
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      let task = Task { await model.transportPlayTapped() }
      await gate.awaitStarted()
      #expect(model.isTransportPlaying)
      gate.release()  // resolves play() → .superseded
      await task.value
      expectNoDifference(model.playheadEditedSample, 1000)  // NOT durationSamples
      expectNoDifference(model.transportPhase, .stopped)
      #expect(model.transportPhase.session == nil)
    }
  }

  @Test func backgroundTabSupersededByAnotherTabKeepsItsCursor() async {
    let shared = SharedFakePlayer()
    let client = AudioPlayerClient(
      play: { _, _, _, _, _ in await shared.play() },
      playEdited: { _, _, _, _, _ in
        EditedPlaybackEnd(end: await shared.play(), finishedEditedSample: nil)
      },
      pause: { _ in nil }, resume: { _ in true },
      stop: { _ in }, setRate: { _ in }, positions: { AsyncStream { $0.finish() } })
    let tabA = editor()
    let tabB = editor()
    tabA.playheadEditedSample = 1000
    tabB.playheadEditedSample = 5000
    let durationB = tabB.editPlan.source.durationSamples
    await withDependencies {
      $0.audioPlayer = client
    } operation: {
      let playA = Task { await tabA.transportPlayTapped() }
      await shared.awaitStarted()
      #expect(tabA.isTransportPlaying)
      let playB = Task { await tabB.transportPlayTapped() }
      await shared.awaitStarted()  // B supersedes A on the shared player
      await playA.value
      // Background tab A: superseded, not completed — cursor stays put, transport resets.
      expectNoDifference(tabA.playheadEditedSample, 1000)
      expectNoDifference(tabA.transportPhase, .stopped)
      #expect(tabA.transportPhase.session == nil)
      #expect(tabB.isTransportPlaying)
      await shared.finishCurrent()  // B finishes naturally
      await playB.value
      // The foreground tab lands at the range end.
      expectNoDifference(tabB.playheadEditedSample, durationB)
    }
  }

  // MARK: - Playback speed

  @Test func applyPlaybackRateForwardsTheCurrentSpeedToThePlayer() async {
    let recorded = LockIsolated<Double?>(nil)
    await withDependencies {
      $0.defaultAppStorage = UserDefaults(suiteName: "editor-speed-apply-\(UUID())")!
      $0.audioPlayer.setRate = { recorded.setValue($0) }
    } operation: {
      let model = editor()
      model.transcript.speedSelected(2.0)  // commit the speed; applyPlaybackRate reads the latest
      await model.applyPlaybackRate()
      expectNoDifference(recorded.value, 2.0)
    }
  }

  @Test func playStartsAtTheCurrentSpeed() async {
    let gate = TransportGate()
    let playedRate = LockIsolated<Double?>(nil)
    await withDependencies {
      $0.defaultAppStorage = UserDefaults(suiteName: "editor-speed-play-\(UUID())")!
      $0.audioPlayer.playEdited = { _, _, _, rate, _ in
        playedRate.setValue(rate)
        return EditedPlaybackEnd(end: await gate.play(), finishedEditedSample: nil)
      }
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      @Shared(.playbackRate) var playbackRate
      $playbackRate.withLock { $0 = 2.0 }  // the persisted speed the model should start at
      let model = editor()
      model.playheadEditedSample = 1000
      let task = Task { await model.transportPlayTapped() }
      await gate.awaitStarted()
      expectNoDifference(playedRate.value, 2.0)  // the rate rides along with the play call
      await model.transportStopTapped()
      await task.value
    }
  }

  @Test func changingSpeedWhilePlayingAppliesLive() async {
    let gate = TransportGate()
    let rates = LockIsolated<[Double]>([])
    await withDependencies {
      $0.defaultAppStorage = UserDefaults(suiteName: "editor-speed-live-\(UUID())")!
      $0.audioPlayer.playEdited = { _, _, _, _, _ in
        EditedPlaybackEnd(end: await gate.play(), finishedEditedSample: nil)
      }
      $0.audioPlayer.setRate = { rate in rates.withValue { $0.append(rate) } }
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      let model = editor()
      model.playheadEditedSample = 1000
      let task = Task { await model.transportPlayTapped() }
      await gate.awaitStarted()
      model.transcript.speedSelected(1.5)  // routed through the transcript → EditorModel callback
      await settle { !rates.value.isEmpty }
      expectNoDifference(rates.value, [1.5])  // applied live via setRate (play carries the initial)
      await model.transportStopTapped()
      await task.value
    }
  }
}

// swiftlint:enable large_tuple
