import CustomDump
import Dependencies
import Foundation
import Testing

@testable import QuickInterviewEditor

// swiftlint:disable large_tuple
// The (URL, Range<Int>, Int) recorded-call tuple mirrors `audioPlayer.play`'s three
// leading arguments, so it recurs across the gate helper and the tests that assert on a call.

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
  func play() async {
    startedContinuation.yield(())
    await withCheckedContinuation { cont in
      lock.lock()
      continuations.append(cont)
      lock.unlock()
    }
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
  ) -> @Sendable (URL, Range<Int>, Int, PlaybackSessionID) async throws -> Void {
    { url, range, rate, _ in
      recorded.setValue((url, range, rate))
      await gate.play()
    }
  }

  // MARK: - Panel flags

  @Test func panelFlagsWhenStoppedWithPlayableCursor() {
    let model = editor()
    model.playheadSample = 1000  // mid-file, no selection → a playable range exists
    #expect(model.canTransportPlay)
    #expect(!model.canTransportPause)
    #expect(!model.canTransportStop)
    #expect(!model.isTransportPlaying)
    #expect(!model.isTransportPaused)
  }

  @Test func playDisabledWhenCursorAtEndOfAudio() {
    let model = editor()
    model.playheadSample = model.editPlan.source.durationSamples  // nothing left to play
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
    let recorded = LockIsolated<(URL, Range<Int>, Int)?>(nil)
    let model = editor()
    model.playheadSample = 1000
    await withDependencies {
      $0.audioPlayer.play = recordingPlay(recorded, gate)
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      let task = Task { await model.transportPlayTapped() }
      await gate.awaitStarted()
      #expect(model.isTransportPlaying)
      expectNoDifference(model.transportOriginSample, 1000)
      expectNoDifference(recorded.value?.0, model.canonicalAudioURL)
      expectNoDifference(recorded.value?.1, 1000..<model.editPlan.source.durationSamples)
      expectNoDifference(recorded.value?.2, model.editPlan.source.sampleRate)
      await model.transportStopTapped()
      await task.value
    }
  }

  @Test func playEndsAtSelectionEndWhenSelectionActive() async {
    let gate = TransportGate()
    let recorded = LockIsolated<(URL, Range<Int>, Int)?>(nil)
    let model = editor()
    selectWords(model.transcript, 1, 4)
    let selection = model.transcript.selectedSampleRange!
    model.playheadSample = selection.lowerBound
    await withDependencies {
      $0.audioPlayer.play = recordingPlay(recorded, gate)
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      let task = Task { await model.transportPlayTapped() }
      await gate.awaitStarted()
      expectNoDifference(recorded.value?.1, selection.lowerBound..<selection.upperBound)
      await model.transportStopTapped()
      await task.value
    }
  }

  @Test func playIsNoOpWhenCursorPastPlayableEnd() async {
    let played = LockIsolated(false)
    let model = editor()
    model.playheadSample = model.editPlan.source.durationSamples
    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _ in played.setValue(true) }
    } operation: {
      await model.transportPlayTapped()
    }
    #expect(!played.value)
    #expect(!model.isTransportPlaying)
    expectNoDifference(model.transportPhase, .stopped)
  }

  @Test func playFailureLeavesCursorPutAndResetsTransport() async {
    let model = editor()
    model.playheadSample = 1000
    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _ in throw EngineClientError.engineFailed("boom") }
    } operation: {
      await withKnownIssue {
        await model.transportPlayTapped()
      }
    }
    expectNoDifference(model.playheadSample, 1000)  // a failed play must not jump to the range end
    expectNoDifference(model.transportPhase, .stopped)
    #expect(model.currentPlaybackSession == nil)
  }

  @Test func naturalCompletionLeavesCursorAtRangeEnd() async {
    let gate = TransportGate()
    let model = editor()
    model.playheadSample = 1000
    let end = model.editPlan.source.durationSamples
    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      let task = Task { await model.transportPlayTapped() }
      await gate.awaitStarted()
      gate.release()  // natural completion (no Stop)
      await task.value
      expectNoDifference(model.transportPhase, .stopped)
      expectNoDifference(model.playheadSample, end)  // left where the audio ended
      #expect(model.currentPlaybackSession == nil)
    }
  }

  // MARK: - Pause / resume

  @Test func pauseFreezesCursorAtReportedSampleAndHoldsPlay() async {
    let gate = TransportGate()
    let model = editor()
    model.playheadSample = 1000
    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _ in await gate.play() }
      $0.audioPlayer.pause = { _ in 4321 }
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      let task = Task { await model.transportPlayTapped() }
      await gate.awaitStarted()
      let session = model.currentPlaybackSession
      await model.transportPauseTapped()
      expectNoDifference(model.playheadSample, 4321)  // frozen at the exact reported sample
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
    model.transportPhase = .paused(session)
    model.currentPlaybackSession = session
    model.playheadSample = 4321  // the exact sample `pause` froze the cursor at
    let (stream, continuation) = AsyncStream.makeStream(of: PlaybackPosition.self)
    await withDependencies {
      $0.audioPlayer.positions = { stream }
    } operation: {
      let task = Task { await model.observePlayback() }
      // A buffered straggler tick for the paused session must NOT thaw the frozen cursor.
      continuation.yield(PlaybackPosition(sessionID: session, sample: 9000, isPlaying: true))
      await settle { false }  // let the tick be processed
      expectNoDifference(model.playheadSample, 4321)
      continuation.finish()
      await task.value
    }
  }

  @Test func resumeContinuesTheSameSession() async {
    let gate = TransportGate()
    let resumed = LockIsolated(false)
    let model = editor()
    model.playheadSample = 1000
    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _ in await gate.play() }
      $0.audioPlayer.pause = { _ in 4321 }
      $0.audioPlayer.resume = { _ in
        resumed.setValue(true)
        return true
      }
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      let task = Task { await model.transportPlayTapped() }
      await gate.awaitStarted()
      let session = model.currentPlaybackSession
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
    model.playheadSample = 1000
    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _ in await gate.play() }
      $0.audioPlayer.pause = { _ in 4321 }
      $0.audioPlayer.resume = { _ in false }  // engine restart failed
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      let task = Task { await model.transportPlayTapped() }
      await gate.awaitStarted()
      let session = model.currentPlaybackSession
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
    model.playheadSample = 1000
    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { session in
        stoppedSession.setValue(session)
        gate.release()
      }
    } operation: {
      let task = Task { await model.transportPlayTapped() }
      await gate.awaitStarted()
      let session = model.currentPlaybackSession
      model.playheadSample = 8000  // simulate the cursor having advanced during playback
      await model.transportStopTapped()
      await task.value
      expectNoDifference(model.playheadSample, 1000)  // back to the origin
      expectNoDifference(model.transportPhase, .stopped)
      #expect(model.currentPlaybackSession == nil)
      expectNoDifference(stoppedSession.value, session)  // stopped OUR session, not stop(nil)
    }
  }

  // MARK: - Coexistence with legacy owners

  @Test func startingASliceSupersedesTheTransport() async {
    let gate = TransportGate()
    let model = editor()
    model.playheadSample = 1000
    selectWords(model.transcript, 0, 2)
    model.addSliceTapped()
    let slice = model.slices[0]
    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      let transport = Task { await model.transportPlayTapped() }
      await gate.awaitStarted()
      #expect(model.isTransportPlaying)
      let slicePlay = Task { await model.playSliceTapped(slice.id) }
      await gate.awaitStarted()
      expectNoDifference(model.transportPhase, .stopped)  // the slice took over
      expectNoDifference(model.playingSliceID, slice.id)
      gate.release()
      await transport.value
      await slicePlay.value
    }
  }

  @Test func beginningPlaybackNeverResetsTheCursor() async {
    let gate = TransportGate()
    let model = editor()
    model.playheadSample = 7777
    selectWords(model.transcript, 0, 2)
    model.addSliceTapped()
    let slice = model.slices[0]
    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      let task = Task { await model.playSliceTapped(slice.id) }
      await gate.awaitStarted()
      expectNoDifference(model.playheadSample, 7777)  // supersession preserved the cursor
      await model.stopPlaybackTapped()
      await task.value
    }
  }

  // MARK: - Space (Play/Stop)

  @Test func spaceStartsTransportWhenIdle() async {
    let gate = TransportGate()
    let model = editor()
    model.playheadSample = 1000
    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _ in await gate.play() }
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
    model.playheadSample = 1000
    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      let task = Task { await model.transportPlayTapped() }
      await gate.awaitStarted()
      model.playheadSample = 8000
      await model.transportPlayStopTapped()  // playing → stop to origin
      await task.value
      expectNoDifference(model.transportPhase, .stopped)
      expectNoDifference(model.playheadSample, 1000)
    }
  }

  @Test func spaceStopsALegacySliceOwner() async {
    let gate = TransportGate()
    let stopped = LockIsolated(false)
    let model = editor()
    selectWords(model.transcript, 0, 2)
    model.addSliceTapped()
    let slice = model.slices[0]
    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { _ in
        stopped.setValue(true)
        gate.release()
      }
    } operation: {
      let task = Task { await model.playSliceTapped(slice.id) }
      await gate.awaitStarted()
      await model.transportPlayStopTapped()  // stops the slice owner
      await task.value
      expectNoDifference(model.playingSliceID, nil)
      #expect(stopped.value)
    }
  }

  // MARK: - Selection snap

  @Test func selectionSnapsCursorToSelectionStart() async {
    let model = editor()
    model.playheadSample = 9999
    selectWords(model.transcript, 2, 4)
    let selection = model.transcript.selectedSampleRange!
    await model.transportSelectionChanged(selection)
    expectNoDifference(model.playheadSample, selection.lowerBound)
  }

  @Test func clearingSelectionLeavesCursorPut() async {
    let model = editor()
    model.playheadSample = 5000
    await model.transportSelectionChanged(nil)
    expectNoDifference(model.playheadSample, 5000)  // clearing the selection never moves the cursor
  }

  @Test func staleSelectionTaskDoesNotOverwriteNewerCursor() async {
    let stopGate = TransportGate()
    let model = editor()
    selectWords(model.transcript, 1, 3)  // selection A
    let rangeA = model.transcript.selectedSampleRange!
    let session = PlaybackSessionID()
    model.transportPhase = .playing(session)  // A's reconciliation must stop this first
    model.currentPlaybackSession = session
    await withDependencies {
      $0.audioPlayer.stop = { _ in await stopGate.play() }  // suspend inside A's stopAllPlayback
    } operation: {
      let taskA = Task { await model.transportSelectionChanged(rangeA) }
      await stopGate.awaitStarted()  // A is now suspended awaiting the stop
      selectWords(model.transcript, 5, 7)  // selection B arrives
      let rangeB = model.transcript.selectedSampleRange!
      await model.transportSelectionChanged(rangeB)  // B snaps immediately (no owner left)
      expectNoDifference(model.playheadSample, rangeB.lowerBound)
      stopGate.release()  // A resumes and must bail on the stale selection
      await taskA.value
      expectNoDifference(model.playheadSample, rangeB.lowerBound)  // A did NOT clobber B
    }
  }

  @Test func selectionChangeStopsActivePlaybackThenSnaps() async {
    let gate = TransportGate()
    let stopped = LockIsolated(false)
    let model = editor()
    model.playheadSample = 1000
    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { _ in
        stopped.setValue(true)
        gate.release()
      }
    } operation: {
      let task = Task { await model.transportPlayTapped() }
      await gate.awaitStarted()
      #expect(model.isTransportPlaying)
      selectWords(model.transcript, 3, 5)
      let selection = model.transcript.selectedSampleRange!
      await model.transportSelectionChanged(selection)  // stop first, then snap
      await task.value
      #expect(stopped.value)
      expectNoDifference(model.transportPhase, .stopped)
      expectNoDifference(model.playheadSample, selection.lowerBound)
    }
  }
}

// swiftlint:enable large_tuple
