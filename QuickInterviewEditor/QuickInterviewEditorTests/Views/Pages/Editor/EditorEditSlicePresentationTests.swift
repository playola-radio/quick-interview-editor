import CustomDump
import Dependencies
import Foundation
import Testing

@testable import QuickInterviewEditor

/// Suspends every `play` until released, so a test can hold a slice-edit playback "in flight"
/// (mirroring the transport's real suspended-`play` semantics) while it drives pause/resume.
private final class PlayGate: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [CheckedContinuation<PlaybackEnd, Never>] = []
  func play() async -> PlaybackEnd {
    await withCheckedContinuation { cont in
      lock.lock()
      continuations.append(cont)
      lock.unlock()
    }
  }
  func release(_ end: PlaybackEnd = .stopped) {
    lock.lock()
    let conts = continuations
    continuations = []
    lock.unlock()
    for cont in conts { cont.resume(returning: end) }
  }
}

@MainActor
struct EditorEditSlicePresentationTests {
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

  private func addSlice(_ model: EditorModel, _ first: Int, _ last: Int) {
    selectWords(model.transcript, first, last)
    model.addSliceTapped()
  }

  private func settle(until condition: () -> Bool) async {
    for _ in 0..<1000 where !condition() { await Task.yield() }
  }

  // MARK: - Presentation

  @Test func editSliceTappedPresentsModelForThatSlice() {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]

    model.editSliceTapped(slice.id)

    expectNoDifference(model.editSlice?.sliceID, slice.id)
    expectNoDifference(
      model.editSlice?.fineTune.committedRange, slice.startSample..<slice.endSample)
  }

  @Test func editSliceTappedIsANoOpWhenTheFineTunePaneHasAnUnsavedEdit() {
    let model = editor()
    addSlice(model, 0, 3)
    addSlice(model, 4, 5)
    let first = model.slices[0]
    let second = model.slices[1]
    model.sliceSelected(first.id)
    model.cutOutNudged(byMs: 10)  // dirty fine-tune pane edit
    #expect(model.fineTune.hasUnsavedChange)

    model.editSliceTapped(second.id)

    #expect(model.editSlice == nil)
  }

  @Test func editSliceTappedIsANoOpForAMissingSlice() {
    let model = editor()
    addSlice(model, 0, 3)

    model.editSliceTapped(UUID())

    #expect(model.editSlice == nil)
  }

  // MARK: - Save / cancel round-trip

  @Test func modalSaveCommitsThroughEditorAndDismisses() {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    model.editSliceTapped(slice.id)
    let child = model.editSlice!
    let depthBefore = model.sliceUndo.undo.count

    child.fineTune.nudgeCutIn(byMs: 30)
    let draft = child.fineTune.draftRange!
    child.saveTapped()

    expectNoDifference(model.slices[id: slice.id]?.startSample, draft.lowerBound)
    #expect(model.editSlice == nil)
    // Global invariant: commit → exactly one undo entry, even through the modal's save path.
    expectNoDifference(model.sliceUndo.undo.count, depthBefore + 1)
  }

  @Test func modalCancelDismissesWithoutCommitting() {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    let before = model.slices
    model.editSliceTapped(slice.id)
    let child = model.editSlice!

    child.fineTune.nudgeCutIn(byMs: 30)
    child.cancelTapped()

    expectNoDifference(model.slices, before)
    #expect(model.editSlice == nil)
  }

  // MARK: - Seek (R4: seek moves the persistent cursor, it does not re-anchor playback)

  @Test func seekMovesThePersistentCursorAndReflectsInTheModal() async {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    model.editSliceTapped(slice.id)
    let child = model.editSlice!
    let target = slice.startSample + 500

    await child.seekTapped(toSample: target)

    expectNoDifference(model.playheadSample, target)
    expectNoDifference(model.editSlice?.playheadSample, target)
    expectNoDifference(model.transportPhase, .stopped)
  }

  // MARK: - Playhead push during `.sliceEdit` playback

  @Test func observePlaybackPushesPlayingPositionIntoTheModalDuringSliceEdit() async {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    model.editSliceTapped(slice.id)
    let session = PlaybackSessionID()
    model.transportContext = .sliceEdit
    model.transportPhase = .playing(session)
    let (stream, continuation) = AsyncStream.makeStream(of: PlaybackPosition.self)

    await withDependencies {
      $0.audioPlayer.positions = { stream }
    } operation: {
      let task = Task { await model.observePlayback() }
      continuation.yield(
        PlaybackPosition(sessionID: session, sample: slice.startSample + 200, isPlaying: true))
      await settle { model.editSlice?.playheadSample == slice.startSample + 200 }

      expectNoDifference(model.playheadSample, slice.startSample + 200)
      expectNoDifference(model.editSlice?.playheadSample, slice.startSample + 200)
      #expect(model.editSlice?.isPlaying == true)

      continuation.finish()
      await task.value
    }
  }

  // MARK: - Modal transport: resume, range-drift, natural finish, open-supersede

  /// FIX 1 (P1): Pause then Play must RESUME the paused `.sliceEdit` session, not start a fresh
  /// play from the draft start. Verifies `resume` is called exactly once and `play` is NOT
  /// re-invoked.
  @Test func modalPlayAfterPauseResumesRatherThanRestarting() async {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    model.editSliceTapped(slice.id)
    let child = model.editSlice!
    let gate = PlayGate()
    let plays = LockIsolated(0)
    let resumes = LockIsolated(0)

    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _, _ in
        plays.withValue { $0 += 1 }
        return await gate.play()
      }
      $0.audioPlayer.pause = { _ in 500 }
      $0.audioPlayer.resume = { _ in
        resumes.withValue { $0 += 1 }
        return true
      }
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      let play = Task { await child.playPauseTapped() }  // begins the .sliceEdit play (suspends)
      await settle { plays.value == 1 && child.isPlaying }

      await child.playPauseTapped()  // pause
      #expect(model.isTransportPaused)
      #expect(child.isPlaying == false)

      await child.playPauseTapped()  // play again → resume, not restart

      expectNoDifference(resumes.value, 1)
      expectNoDifference(plays.value, 1)  // no fresh play scheduled
      #expect(model.isTransportPlaying)

      gate.release()  // let the original suspended play unwind
      await play.value
    }
  }

  /// FIX 1: if the draft boundaries change while paused, Play must start a FRESH play at the new
  /// range rather than resume the stale scheduled range.
  @Test func modalPlayAfterPauseWithADriftedDraftRestarts() async {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    model.editSliceTapped(slice.id)
    let child = model.editSlice!
    let gate = PlayGate()
    let plays = LockIsolated(0)
    let resumes = LockIsolated(0)

    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _, _ in
        plays.withValue { $0 += 1 }
        return await gate.play()
      }
      $0.audioPlayer.pause = { _ in 500 }
      $0.audioPlayer.resume = { _ in
        resumes.withValue { $0 += 1 }
        return true
      }
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      let play1 = Task { await child.playPauseTapped() }
      await settle { plays.value == 1 && child.isPlaying }

      await child.playPauseTapped()  // pause
      child.fineTune.nudgeCutIn(byMs: 20)  // the draft range drifts

      let play2 = Task { await child.playPauseTapped() }  // must restart, not resume
      await settle { plays.value == 2 }

      expectNoDifference(plays.value, 2)
      expectNoDifference(resumes.value, 0)

      gate.release()
      await play1.value
      await play2.value
    }
  }

  /// FIX 4: a natural finish returns from the suspended `play` await; the parent must publish the
  /// stopped state back to the modal so its Play/Pause button doesn't stay stuck on "Pause".
  @Test func naturalFinishPublishesStoppedBackToTheModal() async {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    model.editSliceTapped(slice.id)
    let child = model.editSlice!

    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _, _ in .finished }  // completes immediately
    } operation: {
      await child.playPauseTapped()  // starts the play, which finishes right away

      #expect(child.isPlaying == false)
      expectNoDifference(model.transportPhase, .stopped)
    }
  }

  /// FIX 1 (resume failure): if `resume` fails (engine restart), the transport stays paused, so
  /// the modal's optimistic `isPlaying` must be corrected back to false — its button can't lie.
  @Test func modalPlayAfterPauseWhereResumeFailsClearsIsPlaying() async {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    model.editSliceTapped(slice.id)
    let child = model.editSlice!
    let gate = PlayGate()

    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _, _ in await gate.play() }
      $0.audioPlayer.pause = { _ in 500 }
      $0.audioPlayer.resume = { _ in false }  // engine restart failed
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      let play = Task { await child.playPauseTapped() }
      await settle { child.isPlaying }

      await child.playPauseTapped()  // pause
      #expect(model.isTransportPaused)

      await child.playPauseTapped()  // play → resume fails, stays paused

      #expect(model.isTransportPaused)
      #expect(child.isPlaying == false)  // button reflects the still-paused truth

      gate.release()
      await play.value
    }
  }

  /// FIX 1 (dismiss→reopen race): a stale sheet `onDismiss` callback that fires after a new modal
  /// has taken over must NOT tear down the new modal's transport.
  @Test func sheetDismissCallbackSkipsWhenANewModalIsAlreadyPresent() async {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    let newSession = PlaybackSessionID()
    model.editSliceTapped(slice.id)  // "new" modal already present
    model.transportContext = .sliceEdit
    model.transportPhase = .playing(newSession)
    let stopped = LockIsolated<PlaybackSessionID?>(nil)

    await withDependencies {
      $0.audioPlayer.stop = { stopped.setValue($0) }
    } operation: {
      model.sliceEditSheetDismissed()  // stale callback for the PREVIOUS modal

      expectNoDifference(model.transportPhase, .playing(newSession))  // untouched
      for _ in 0..<5 { await Task.yield() }  // give any errant stop task a chance to run
      #expect(stopped.value == nil)
    }
  }

  /// FIX 2/3: opening the modal must stop a PAUSED main transport (not just a playing one), and
  /// must stop only the captured session so a late stop can't kill a newer `.sliceEdit` session.
  @Test func openingModalStopsAPausedMainTransport() async {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    let mainSession = PlaybackSessionID()
    model.transportContext = .free
    model.transportPhase = .paused(mainSession)
    model.transportOriginSample = 100
    let stopped = LockIsolated<PlaybackSessionID?>(nil)

    await withDependencies {
      $0.audioPlayer.stop = { stopped.setValue($0) }
    } operation: {
      model.editSliceTapped(slice.id)

      expectNoDifference(model.transportPhase, .stopped)  // reset synchronously on open
      #expect(model.editSlice != nil)
      await settle { stopped.value != nil }
      expectNoDifference(stopped.value, mainSession)  // only the captured session stopped
    }
  }

  @Test func observePlaybackPushesTheStoppedTickIntoTheModalDuringSliceEdit() async {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    model.editSliceTapped(slice.id)
    let session = PlaybackSessionID()
    model.transportContext = .sliceEdit
    model.transportPhase = .playing(session)
    let (stream, continuation) = AsyncStream.makeStream(of: PlaybackPosition.self)

    await withDependencies {
      $0.audioPlayer.positions = { stream }
    } operation: {
      let task = Task { await model.observePlayback() }
      continuation.yield(
        PlaybackPosition(sessionID: session, sample: slice.startSample + 200, isPlaying: true))
      await settle { model.editSlice?.playheadSample == slice.startSample + 200 }

      continuation.yield(
        PlaybackPosition(sessionID: session, sample: slice.startSample + 200, isPlaying: false))
      await settle { model.editSlice?.isPlaying == false }

      #expect(model.editSlice?.isPlaying == false)
      expectNoDifference(model.editSlice?.playheadSample, model.playheadSample)

      continuation.finish()
      await task.value
    }
  }
}
