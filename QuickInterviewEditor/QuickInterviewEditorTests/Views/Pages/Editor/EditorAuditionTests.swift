import CustomDump
import Dependencies
import Foundation
import Testing

@testable import QuickInterviewEditor

// swiftlint:disable large_tuple
// The (URL, Range<Int>, Int) recorded-call tuple mirrors `audioPlayer.play`'s three
// arguments, so it recurs by design across the gate helper and every test that asserts
// on a recorded call.

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
    var continuation: AsyncStream<Void>.Continuation!
    started = AsyncStream { continuation = $0 }
    startedContinuation = continuation
  }
  /// Signals "started", then suspends until `release()`.
  func play() async {
    startedContinuation.yield(())
    await withCheckedContinuation { cont in
      lock.lock()
      continuations.append(cont)
      lock.unlock()
    }
  }
  /// Resumes every currently-suspended `play()` (natural completion, or a `stop`).
  func release() {
    lock.lock()
    let conts = continuations
    continuations = []
    lock.unlock()
    for cont in conts { cont.resume() }
  }
  /// Resumes only the oldest currently-suspended `play()`, leaving the rest suspended —
  /// lets a test complete a stale (superseded) play in isolation, deterministically, before
  /// the newer play is allowed to finish.
  func releaseFirst() {
    lock.lock()
    let cont = continuations.isEmpty ? nil : continuations.removeFirst()
    lock.unlock()
    cont?.resume()
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

  private func recordingPlay(
    _ recorded: LockIsolated<(URL, Range<Int>, Int)?>, _ gate: AuditionGate
  ) -> @Sendable (URL, Range<Int>, Int, PlaybackSessionID) async throws -> Void {
    { url, range, rate, _ in
      recorded.setValue((url, range, rate))
      await gate.play()
    }
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
      $0.audioPlayer.stop = { _ in gate.release() }
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
      $0.audioPlayer.stop = { _ in gate.release() }
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
      $0.audioPlayer.stop = { _ in gate.release() }
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
      $0.audioPlayer.play = { _, _, _, _ in played.setValue(true) }
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
      $0.audioPlayer.play = { _, _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      let slicePlay = Task { await model.playSliceTapped(slice.id) }
      await gate.awaitStarted()
      expectNoDifference(model.playingSliceID, slice.id)
      selectWords(model.transcript, 3, 5)  // a region to audition
      let audition = Task { await model.auditionInTapped() }
      await gate.awaitStarted()
      expectNoDifference(model.playingSliceID, nil)  // slice ownership released
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
      $0.audioPlayer.play = { _, _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      selectWords(model.transcript, 3, 5)
      let audition = Task { await model.auditionOutTapped() }
      await gate.awaitStarted()
      expectNoDifference(model.audition, .cutOut)
      let slicePlay = Task { await model.playSliceTapped(slice.id) }
      await gate.awaitStarted()
      expectNoDifference(model.audition, nil)  // audition ownership released
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
      $0.audioPlayer.play = { _, _, _, _ in
        starts.withValue { $0 += 1 }
        await gate.play()
      }
      $0.audioPlayer.stop = { _ in gate.release() }
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
      $0.audioPlayer.play = { _, _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      // stale owner .cutOut (older generation)
      let first = Task { await model.auditionOutTapped() }
      await gate.awaitStarted()
      let second = Task { await model.auditionInTapped() }  // newer owner .cutIn
      await gate.awaitStarted()
      expectNoDifference(model.audition, .cutIn)
      // Complete ONLY the stale .cutOut play; the newer .cutIn play stays suspended.
      gate.releaseFirst()
      await first.value
      // The stale completion's generation guard must have left the newer owner intact.
      expectNoDifference(model.audition, .cutIn)
      // Now finish the newer one; it clears itself.
      gate.release()
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
      continuation.yield(
        PlaybackPosition(sessionID: PlaybackSessionID(), sample: 2000, isPlaying: true))
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

  @Test func spaceStopsAnActiveAudition() async {
    let gate = AuditionGate()
    let stopped = LockIsolated(false)
    let model = editor()
    selectWords(model.transcript, 3, 5)
    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { _ in
        stopped.setValue(true)
        gate.release()
      }
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
      $0.audioPlayer.play = { _, _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { _ in
        stopped.setValue(true)
        gate.release()
      }
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
      $0.audioPlayer.stop = { _ in gate.release() }
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
      $0.audioPlayer.play = { _, _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { _ in gate.release() }
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
      $0.audioPlayer.stop = { _ in gate.release() }
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

  @Test func deletingAuditionedActiveSliceStopsAudition() async {
    let gate = AuditionGate()
    let stopped = LockIsolated(false)
    let model = editor()
    selectWords(model.transcript, 0, 2)
    model.addSliceTapped()
    let slice = model.slices[0]
    model.sliceSelected(slice.id)  // active slice drives activeEditingRange == its range
    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { _ in
        stopped.setValue(true)
        gate.release()
      }
    } operation: {
      let task = Task { await model.auditionInTapped() }
      await gate.awaitStarted()
      expectNoDifference(model.audition, .cutIn)
      await model.deleteSlice(slice.id)  // removes the active slice mid-audition
      await task.value
      expectNoDifference(model.audition, nil)
      #expect(stopped.value)
      #expect(model.slices[id: slice.id] == nil)
    }
  }

  @Test func retargetingEditSessionStopsAudition() async {
    let gate = AuditionGate()
    let stopped = LockIsolated(false)
    let model = editor()
    selectWords(model.transcript, 0, 2)
    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { _ in
        stopped.setValue(true)
        gate.release()
      }
    } operation: {
      let task = Task { await model.auditionInTapped() }
      await gate.awaitStarted()
      expectNoDifference(model.audition, .cutIn)
      // Selecting different words retargets the fine-tune session, which must stop the stale audition.
      selectWords(model.transcript, 4, 6)
      model.syncEditSession()
      await task.value  // completes only when the guarded stop task releases the gate
      expectNoDifference(model.audition, nil)
      #expect(stopped.value)
    }
  }

  @Test func auditionOutClampsRangeToEndOfFile() async {
    let gate = AuditionGate()
    let recorded = LockIsolated<(URL, Range<Int>, Int)?>(nil)
    let model = editor()
    let dur = model.editPlan.source.durationSamples
    // A slice whose out-point runs past EOF (corrupt/rounded data): audition must clamp to duration.
    let overrun = Slice(
      id: UUID(), name: "S", startSample: dur - 500, endSample: dur + 5000, wordIDs: [],
      snippet: "x",
      warnings: [])
    model.slices.append(overrun)
    model.activeSliceID = overrun.id
    await withDependencies {
      $0.audioPlayer.play = recordingPlay(recorded, gate)
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      let task = Task { await model.auditionOutTapped() }
      await gate.awaitStarted()
      expectNoDifference(recorded.value?.1.upperBound, dur)  // clamped from dur+5000 to EOF
      gate.release()
      await task.value
    }
  }

  @Test func committingPendingSelectionStopsAudition() async {
    let gate = AuditionGate()
    let stopped = LockIsolated(false)
    let model = editor()
    selectWords(model.transcript, 0, 2)
    model.syncEditSession()
    model.cutOutNudged(byMs: -10)  // a tuned draft so canCommitEdit is true
    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { _ in
        stopped.setValue(true)
        gate.release()
      }
    } operation: {
      let task = Task { await model.auditionInTapped() }
      await gate.awaitStarted()
      expectNoDifference(model.audition, .cutIn)
      // Committing the pending selection closes the pane and clears the region — the audition of
      // the now-saved draft must stop instead of playing on with nothing shown.
      model.commitEditTapped()
      await task.value  // completes only when the guarded stop task releases the gate
      expectNoDifference(model.audition, nil)
      #expect(stopped.value)
    }
  }

  @Test func cancellingEditStopsAudition() async {
    let gate = AuditionGate()
    let stopped = LockIsolated(false)
    let model = editor()
    selectWords(model.transcript, 0, 2)
    model.syncEditSession()
    model.cutOutNudged(byMs: -10)  // a tuned draft to cancel back to the committed range
    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { _ in
        stopped.setValue(true)
        gate.release()
      }
    } operation: {
      let task = Task { await model.auditionInTapped() }
      await gate.awaitStarted()
      expectNoDifference(model.audition, .cutIn)
      // Cancelling reverts the draft to the committed range — the audition of the discarded draft
      // must stop rather than keep playing a range the waveform no longer shows.
      model.cancelEditTapped()
      await task.value
      expectNoDifference(model.audition, nil)
      #expect(stopped.value)
    }
  }
}
// swiftlint:enable large_tuple
