import CustomDump
import Dependencies
import Foundation
import IdentifiedCollections
import Testing

@testable import QuickInterviewEditor

private final class PlayerGate: @unchecked Sendable {
  private let lock = NSLock()
  private var releaseConts: [CheckedContinuation<Void, Never>] = []
  private var released = false
  private let startedContinuation: AsyncStream<Void>.Continuation
  let started: AsyncStream<Void>

  init() {
    var continuation: AsyncStream<Void>.Continuation!
    started = AsyncStream { continuation = $0 }
    startedContinuation = continuation
  }

  /// Stand-in for `audioPlayer.play`: signals "started", then suspends until `release()`.
  /// Queues its continuation rather than overwriting a prior one, so a test that starts a
  /// second (superseding) playback before releasing the first can still resolve both.
  func play() async {
    startedContinuation.yield(())
    await withCheckedContinuation { cont in
      lock.lock()
      if released {
        lock.unlock()
        cont.resume()
        return
      }
      releaseConts.append(cont)
      lock.unlock()
    }
  }

  /// Stand-in for `audioPlayer.stop` (and for natural completion in a test): resumes every
  /// in-flight `play()` call.
  func release() {
    lock.lock()
    let conts = releaseConts
    releaseConts = []
    released = true
    lock.unlock()
    for cont in conts { cont.resume() }
  }

  /// Resumes only the oldest suspended `play()`, leaving newer ones suspended — lets a test
  /// complete a stale (superseded) play in isolation before the newer play finishes.
  func releaseFirst() {
    lock.lock()
    let cont = releaseConts.isEmpty ? nil : releaseConts.removeFirst()
    lock.unlock()
    cont?.resume()
  }

  func awaitStarted() async {
    var iterator = started.makeAsyncIterator()
    _ = await iterator.next()
  }
}

@MainActor
struct EditorTests {
  private func editor(_ plan: EditPlan = Fixtures.editPlan()) -> EditorModel {
    EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: plan)
  }

  @Test func addSliceFromSelectionCreatesSlice() {
    let model = editor()
    selectWords(model.transcript, 0, 3)
    let selectedWordIDs = model.transcript.orderedSelectedWordIDs
    model.addSliceTapped()
    expectNoDifference(model.slices.count, 1)
    let slice = model.slices[0]
    expectNoDifference(slice.name, "Slice 1")
    expectNoDifference(slice.wordIDs, selectedWordIDs)
    #expect(slice.startSample < slice.endSample)
    #expect(!slice.snippet.isEmpty)
  }

  // MARK: - Snippet middle-truncation

  @Test func shortSnippetPassesThroughUnchanged() {
    expectNoDifference(
      middleTruncatedSnippet("So a young Hayes Carl", maxLength: 68),
      "So a young Hayes Carl")
  }

  @Test func longSnippetKeepsFirstAndLastWordsWithMiddleEllipsis() {
    let text = "So a young Hayes Carl goes to a Ray Wiley Hubbard concert and it was great"
    let out = middleTruncatedSnippet(text, maxLength: 40)
    #expect(out.hasPrefix("So "))
    #expect(out.hasSuffix(" great"))
    #expect(out.contains("…"))
    #expect(out.count <= 40)
  }

  @Test func fewerThanThreeWordsPassThrough() {
    let longTwoWords = String(repeating: "a", count: 40) + " " + String(repeating: "b", count: 40)
    expectNoDifference(middleTruncatedSnippet(longTwoWords, maxLength: 20), longTwoWords)
  }

  @Test func oversizedFirstOrLastWordStillRespectsMaxLength() {
    // A single run-on word (or long URL) as the first/last word must not let the
    // result exceed maxLength — the minimal first…last window itself overflows.
    let text = String(repeating: "x", count: 80) + " b " + String(repeating: "y", count: 80)
    let out = middleTruncatedSnippet(text, maxLength: 20)
    #expect(out.count <= 20)
    #expect(out.hasSuffix("…"))
  }

  @Test func sliceSnippetShowsFirstAndLastWordsOfSelection() {
    let model = editor()
    let lastIndex = model.transcript.document.wordRanges.count - 1
    selectWords(model.transcript, 0, lastIndex)  // "So" … "Carl"
    model.addSliceTapped()
    let snippet = model.slices[0].snippet
    #expect(snippet.hasPrefix("“So"))
    #expect(snippet.hasSuffix("Carl”"))
    #expect(snippet.contains("…"))
  }

  @Test func addSliceRejectedWithoutSelection() {
    let model = editor()
    #expect(!model.canAddSlice)
    model.addSliceTapped()
    expectNoDifference(model.slices.count, 0)
  }

  @Test func addSliceNamesSequentially() {
    let model = editor()
    selectWords(model.transcript, 0, 1)
    model.addSliceTapped()
    selectWords(model.transcript, 2, 3)
    model.addSliceTapped()
    expectNoDifference(model.slices.map(\.name), ["Slice 1", "Slice 2"])
  }

  @Test func renameReorderDeleteMutateSlices() async {
    let model = editor()
    for pair in [(0, 1), (2, 3), (4, 5)] {
      selectWords(model.transcript, pair.0, pair.1)
      model.addSliceTapped()
    }
    let firstID = model.slices[0].id
    model.renameSlice(firstID, to: "Intro")
    expectNoDifference(model.slices[id: firstID]?.name, "Intro")
    model.moveSlices(fromOffsets: IndexSet(integer: 0), toOffset: 3)
    expectNoDifference(model.slices.last?.id, firstID)
    await model.deleteSlice(firstID)
    #expect(model.slices[id: firstID] == nil)
    expectNoDifference(model.slices.count, 2)
  }

  // MARK: - Undo / Redo

  @Test func addThenUndoRemovesSliceAndRedoRestores() async {
    let model = editor()
    #expect(!model.canUndo)
    addSlices(model, [(0, 1)])
    let slice = model.slices[0]
    expectNoDifference(model.slices.count, 1)
    #expect(model.canUndo)

    await model.undoTapped()
    expectNoDifference(model.slices, [])
    #expect(!model.canUndo)
    #expect(model.canRedo)

    await model.redoTapped()
    expectNoDifference(model.slices, [slice])
    #expect(!model.canRedo)
  }

  @Test func deleteThenUndoRestoresSlice() async {
    let model = editor()
    addSlices(model, [(0, 1)])
    let slice = model.slices[0]
    await model.deleteSlice(slice.id)
    expectNoDifference(model.slices, [])

    await model.undoTapped()
    expectNoDifference(model.slices, [slice])
  }

  @Test func renameThenUndoRestoresPreviousName() async {
    let model = editor()
    addSlices(model, [(0, 1)])
    let id = model.slices[0].id
    model.renameSlice(id, to: "Intro")
    expectNoDifference(model.slices[id: id]?.name, "Intro")

    await model.undoTapped()
    expectNoDifference(model.slices[id: id]?.name, "Slice 1")
  }

  @Test func reorderThenUndoRestoresOrder() async {
    let model = editor()
    addSlices(model, [(0, 1), (2, 3), (4, 5)])
    let originalOrder = model.slices.map(\.id)
    model.moveSlices(fromOffsets: IndexSet(integer: 0), toOffset: 3)
    #expect(model.slices.map(\.id) != originalOrder)

    await model.undoTapped()
    expectNoDifference(model.slices.map(\.id), originalOrder)
  }

  @Test func editAfterUndoTruncatesRedoBranch() async {
    let model = editor()
    addSlices(model, [(0, 1)])  // Slice 1
    addSlices(model, [(2, 3)])  // Slice 2
    await model.undoTapped()  // removes Slice 2
    #expect(model.canRedo)

    addSlices(model, [(4, 5)])  // Slice 3 — new branch, redo gone
    #expect(!model.canRedo)
    expectNoDifference(model.slices.map(\.name), ["Slice 1", "Slice 3"])
  }

  @Test func undoRemovingPlayingSliceReconcilesPlayback() async {
    let gate = PlayerGate()
    let stopped = LockIsolated(false)
    let model = editor()
    addSlices(model, [(0, 1)])  // one undo entry: the add
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
      expectNoDifference(model.playingSliceID, slice.id)
      // Undoing the add removes the currently-playing slice; reconcile must stop playback.
      await model.undoTapped()
      await task.value
      expectNoDifference(model.slices, [])
      expectNoDifference(model.playingSliceID, nil)
      #expect(stopped.value)
    }
  }

  @Test func undoLeavesUnrelatedPlaybackRunning() async {
    let gate = PlayerGate()
    let stopped = LockIsolated(false)
    let model = editor()
    addSlices(model, [(0, 1)])  // Slice 1 — the slice we'll keep playing
    addSlices(model, [(2, 3)])  // Slice 2 — the mutation we'll undo
    let playing = model.slices[0]
    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { _ in
        stopped.setValue(true)
        gate.release()
      }
    } operation: {
      let task = Task { await model.playSliceTapped(playing.id) }
      await gate.awaitStarted()
      // Undoing the Slice 2 add leaves the playing Slice 1 intact — playback continues.
      await model.undoTapped()
      expectNoDifference(model.playingSliceID, playing.id)
      #expect(!stopped.value)
      gate.release()  // finish the test cleanly
      await task.value
    }
  }

  @Test func multiRowDeleteIsOneUndoEntry() async {
    let model = editor()
    addSlices(model, [(0, 1), (2, 3), (4, 5)])
    let all = model.slices
    let toDelete = [model.slices[0].id, model.slices[2].id]

    await model.deleteSlices(toDelete)
    expectNoDifference(model.slices.map(\.id), [all[1].id])

    // A single Delete of multiple rows undoes in one step: one undo restores BOTH removed
    // slices (two entries would restore only one), proving the batch recorded once.
    await model.undoTapped()
    expectNoDifference(model.slices, all)
  }

  @Test func sliceRowsFormatDurationAndRange() {
    let model = editor()
    selectWords(model.transcript, 0, 2)
    model.addSliceTapped()
    let row = model.sliceRows[0]
    #expect(row.durationLabel.hasSuffix("s"))
    #expect(row.rangeLabel.contains("–"))
    expectNoDifference(row.isPlaying, false)
  }

  @Test func sliceCountLabelPluralises() {
    let model = editor()
    expectNoDifference(model.sliceCountLabel, "0 clips")
    selectWords(model.transcript, 0, 1)
    model.addSliceTapped()
    expectNoDifference(model.sliceCountLabel, "1 clip")
  }

  @Test func playSetsPlayingDuringPlaybackAndRecordsSourceRange() async {
    let gate = PlayerGate()
    // swiftlint:disable:next large_tuple
    let recorded = LockIsolated<(URL, Range<Int>, Int)?>(nil)
    let model = editor()
    selectWords(model.transcript, 0, 2)
    model.addSliceTapped()
    let slice = model.slices[0]
    await withDependencies {
      $0.audioPlayer.play = { url, range, rate, _ in
        recorded.setValue((url, range, rate))
        await gate.play()
      }
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      let task = Task { await model.playSliceTapped(slice.id) }
      await gate.awaitStarted()
      expectNoDifference(model.playingSliceID, slice.id)
      // Playback reads the canonical AIFF, not the original source.
      expectNoDifference(recorded.value?.0, model.canonicalAudioURL)
      expectNoDifference(recorded.value?.1, slice.startSample..<slice.endSample)
      expectNoDifference(recorded.value?.2, model.editPlan.source.sampleRate)
      gate.release()  // natural completion
      await task.value
      expectNoDifference(model.playingSliceID, nil)
    }
  }

  @Test func startingPreviewSupersedesPlayingSlice() async {
    let gate = PlayerGate()
    let model = editor()
    addSlices(model, [(0, 2)])
    let slice = model.slices[0]
    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { _ in gate.release() }
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

  @Test func stopPlaybackClearsPlayingSlice() async {
    let gate = PlayerGate()
    let model = editor()
    selectWords(model.transcript, 0, 1)
    model.addSliceTapped()
    let slice = model.slices[0]
    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      let task = Task { await model.playSliceTapped(slice.id) }
      await gate.awaitStarted()
      await model.stopPlaybackTapped()
      await task.value
      expectNoDifference(model.playingSliceID, nil)
    }
  }

  @Test func playStopTappedTogglesPlayback() async {
    let gate = PlayerGate()
    let model = editor()
    selectWords(model.transcript, 0, 1)
    model.addSliceTapped()
    let slice = model.slices[0]
    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      let task = Task { await model.playStopTapped(slice.id) }
      await gate.awaitStarted()
      expectNoDifference(model.playingSliceID, slice.id)
      await model.playStopTapped(slice.id)  // second tap stops
      await task.value
      expectNoDifference(model.playingSliceID, nil)
    }
  }

  @Test func playSliceRollsBackPlayingIDOnError() async {
    let model = editor()
    selectWords(model.transcript, 0, 1)
    model.addSliceTapped()
    let slice = model.slices[0]
    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _ in throw EngineClientError.engineFailed("boom") }
    } operation: {
      await withKnownIssue {
        await model.playSliceTapped(slice.id)
      }
    }
    expectNoDifference(model.playingSliceID, nil)
  }

  @Test func sliceRowPlayButtonLabelReflectsPlayingState() async {
    let gate = PlayerGate()
    let model = editor()
    for pair in [(0, 1), (2, 3)] {
      selectWords(model.transcript, pair.0, pair.1)
      model.addSliceTapped()
    }
    let first = model.slices[0]
    let second = model.slices[1]
    expectNoDifference(model.sliceRows[id: first.id]?.playButtonLabel, model.playLabel)
    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      let task = Task { await model.playStopTapped(first.id) }
      await gate.awaitStarted()
      expectNoDifference(model.sliceRows[id: first.id]?.playButtonLabel, model.stopLabel)
      expectNoDifference(model.sliceRows[id: second.id]?.playButtonLabel, model.playLabel)
      gate.release()
      await task.value
    }
  }

  @Test func deletingPlayingSliceStopsPlayback() async {
    let gate = PlayerGate()
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
      await model.deleteSlice(slice.id)
      await task.value
      expectNoDifference(model.playingSliceID, nil)
      #expect(stopped.value)
      #expect(model.slices[id: slice.id] == nil)
    }
  }

  @Test func renameSlicePreservesInternalSpaces() {
    let model = editor()
    selectWords(model.transcript, 0, 1)
    model.addSliceTapped()
    let slice = model.slices[0]
    model.renameSlice(slice.id, to: "My Clip")
    expectNoDifference(model.slices[id: slice.id]?.name, "My Clip")
    model.renameSlice(slice.id, to: "   ")
    expectNoDifference(model.slices[id: slice.id]?.name, "   ")
  }

  @Test func addSliceDoesNotReuseNumberAfterDeletion() async {
    let model = editor()
    for pair in [(0, 1), (2, 3), (4, 5)] {
      selectWords(model.transcript, pair.0, pair.1)
      model.addSliceTapped()
    }
    expectNoDifference(model.slices.map(\.name), ["Slice 1", "Slice 2", "Slice 3"])
    let middleID = model.slices[1].id
    await model.deleteSlice(middleID)
    selectWords(model.transcript, 6, 7)
    model.addSliceTapped()
    expectNoDifference(model.slices.map(\.name), ["Slice 1", "Slice 3", "Slice 4"])
  }

  @Test func multiRowDeleteRemovesExactlyTheSelectedRows() async {
    let model = editor()
    for pair in [(0, 1), (2, 3), (4, 5)] {
      selectWords(model.transcript, pair.0, pair.1)
      model.addSliceTapped()
    }
    let middleID = model.slices[1].id
    let ids = [model.slices[0].id, model.slices[2].id]
    for id in ids { await model.deleteSlice(id) }
    expectNoDifference(model.slices.map(\.id), [middleID])
  }

  // MARK: - Playhead (playback position)

  @Test func observePlaybackMovesCursorAndKeepsItOnExit() async {
    let model = editor()
    let session = PlaybackSessionID()
    model.playingSliceID = UUID()  // this editor owns playback
    model.currentPlaybackSession = session
    let (stream, continuation) = AsyncStream.makeStream(of: PlaybackPosition.self)
    await withDependencies {
      $0.audioPlayer.positions = { stream }
    } operation: {
      let task = Task { await model.observePlayback() }
      continuation.yield(
        PlaybackPosition(sessionID: session, sample: 1000, isPlaying: true))
      await settle { model.playheadSample == 1000 }
      #expect(model.playheadSample == 1000)  // maps the live position
      continuation.finish()  // stands in for the task being cancelled / stream ending
      await task.value
      #expect(model.playheadSample == 1000)  // persists after exit — the cursor is never cleared
    }
  }

  @Test func observePlaybackIgnoresTicksWhenThisEditorIsNotPlaying() async {
    let model = editor()  // owns no playback — another tab owns it; cursor rests at 0
    let (stream, continuation) = AsyncStream.makeStream(of: PlaybackPosition.self)
    await withDependencies {
      $0.audioPlayer.positions = { stream }
    } operation: {
      let task = Task { await model.observePlayback() }
      continuation.yield(
        PlaybackPosition(sessionID: PlaybackSessionID(), sample: 5000, isPlaying: true))
      await settle { false }  // let the tick be processed
      #expect(model.playheadSample == 0)  // never adopts another tab's position
      continuation.finish()
      await task.value
    }
  }

  @Test func observePlaybackKeepsCursorOnStopTick() async {
    let model = editor()
    let session = PlaybackSessionID()
    model.playingSliceID = UUID()  // this editor owns playback
    model.currentPlaybackSession = session
    let (stream, continuation) = AsyncStream.makeStream(of: PlaybackPosition.self)
    await withDependencies {
      $0.audioPlayer.positions = { stream }
    } operation: {
      let task = Task { await model.observePlayback() }
      continuation.yield(
        PlaybackPosition(sessionID: session, sample: 1000, isPlaying: true))
      await settle { model.playheadSample == 1000 }
      // A false/final tick ends transcript follow but must NOT move the persistent cursor.
      continuation.yield(
        PlaybackPosition(sessionID: session, sample: 1200, isPlaying: false))
      await settle { false }  // let the false tick be processed
      #expect(model.playheadSample == 1000)  // cursor stays where the audio last played
      continuation.finish()
      await task.value
    }
  }

  @Test func observePlaybackIgnoresTicksFromASupersededSession() async {
    let model = editor()
    let session = PlaybackSessionID()
    model.playingSliceID = UUID()  // this editor owns playback
    model.currentPlaybackSession = session
    let (stream, continuation) = AsyncStream.makeStream(of: PlaybackPosition.self)
    await withDependencies {
      $0.audioPlayer.positions = { stream }
    } operation: {
      let task = Task { await model.observePlayback() }
      continuation.yield(
        PlaybackPosition(sessionID: session, sample: 1000, isPlaying: true))
      await settle { model.playheadSample == 1000 }
      // A straggler tick from a superseded/foreign session must NOT move the cursor.
      continuation.yield(
        PlaybackPosition(sessionID: PlaybackSessionID(), sample: 9999, isPlaying: true))
      await settle { false }  // let the foreign tick be processed
      #expect(model.playheadSample == 1000)  // unchanged — foreign tick ignored
      continuation.finish()
      await task.value
    }
  }

  @Test func stopPlaybackUsesTheCurrentSessionNotNil() async {
    let gate = PlayerGate()
    let stoppedSession = LockIsolated<PlaybackSessionID?>(nil)
    let model = editor()
    addSlices(model, [(0, 1)])
    let slice = model.slices[0]
    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { session in stoppedSession.setValue(session) }
    } operation: {
      let task = Task { await model.playSliceTapped(slice.id) }
      await gate.awaitStarted()
      let session = model.currentPlaybackSession
      #expect(session != nil)
      await model.stopPlaybackTapped()
      gate.release()
      await task.value
      // Stopped OUR session, not stop(nil) — so a delayed cleanup can't kill newer/global playback.
      expectNoDifference(stoppedSession.value, session)
    }
  }

  @Test func stopWhenIdleDoesNotStealAnotherTabsPlayback() async {
    let stopCalled = LockIsolated(false)
    let model = editor()  // owns no playback: currentPlaybackSession == nil
    await withDependencies {
      $0.audioPlayer.stop = { _ in stopCalled.setValue(true) }
    } operation: {
      await model.stopPlaybackTapped()  // e.g. close-tab / reimport cleanup on an idle editor
    }
    #expect(!stopCalled.value)  // nothing owned → no stop(nil) → can't steal another tab
  }

  @Test func stalePlayCompletionDoesNotClearANewerSameSliceSession() async {
    let gate = PlayerGate()
    let model = editor()
    addSlices(model, [(0, 1)])
    let slice = model.slices[0]
    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { _ in }
    } operation: {
      let first = Task { await model.playSliceTapped(slice.id) }
      await gate.awaitStarted()
      let s1 = model.currentPlaybackSession
      // Restart the SAME slice: supersedes S1 with a new session S2 while S1 is still in flight.
      let second = Task { await model.playSliceTapped(slice.id) }
      await gate.awaitStarted()
      let s2 = model.currentPlaybackSession
      #expect(s1 != s2)
      // Complete ONLY the stale S1 play; its completion must NOT clear the newer S2 owner.
      gate.releaseFirst()
      await first.value
      #expect(model.playingSliceID == slice.id)  // still owned by S2's playback
      expectNoDifference(model.currentPlaybackSession, s2)
      gate.release()  // let S2 finish
      await second.value
    }
  }

  @Test func playingADegenerateSliceIsANoOp() async {
    let played = LockIsolated(false)
    let model = editor()
    addSlices(model, [(0, 1)])
    // Collapse the slice to a zero-length range; playing it must not disturb playback state.
    let id = model.slices[0].id
    model.slices[0].endSample = model.slices[0].startSample
    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _ in played.setValue(true) }
    } operation: {
      await model.playSliceTapped(id)
    }
    #expect(!played.value)  // empty range refused before touching the player
    #expect(model.playingSliceID == nil)
    #expect(model.currentPlaybackSession == nil)
  }

  @Test func playingASlicePastEndOfAudioIsANoOp() async {
    let played = LockIsolated(false)
    let model = editor()
    addSlices(model, [(0, 1)])
    // Non-empty in plan samples but entirely past the audio's end: it clamps to empty in the
    // player, which would no-op WITHOUT superseding and orphan current playback.
    let dur = model.editPlan.source.durationSamples
    model.slices[0].startSample = dur
    model.slices[0].endSample = dur + 1000
    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _ in played.setValue(true) }
    } operation: {
      await model.playSliceTapped(model.slices[0].id)
    }
    #expect(!played.value)  // past-EOF range refused before touching the player
    #expect(model.playingSliceID == nil)
    #expect(model.currentPlaybackSession == nil)
  }

  @Test func stoppingPlaybackResetsTranscriptFollowForNextSlice() async {
    let model = editor()
    let word = model.editPlan.words.first { $0.startSample != nil && $0.endSample != nil }!
    // A slice is playing and the transcript is following it, then the user scrolls away.
    model.transcript.playheadChanged(sample: word.startSample!, isPlaying: true)
    model.transcript.transcriptUserScrolled()
    expectNoDifference(model.transcript.followMode, .userPaused)
    model.playingSliceID = UUID()

    await withDependencies {
      $0.audioPlayer.stop = { _ in }
    } operation: {
      await model.stopPlaybackTapped()
    }

    // Stopping reset the transcript's playing flag, so the next slice's first tick is a
    // clean rising edge (false→true) and follow resumes instead of staying paused.
    model.transcript.playheadChanged(sample: word.startSample!, isPlaying: true)
    expectNoDifference(model.transcript.followMode, .following)
  }

  // MARK: - Waveform sync

  /// Sets identity geometry (1 sample per pixel, no scroll) so xToSample(x) == x.
  private func identityGeometry(_ model: EditorModel, viewportWidth: CGFloat = 1_000_000) {
    model.waveform.viewportWidth = viewportWidth
    model.waveform.samplesPerPixel = 1
    model.waveform.visibleStartSample = 0
  }

  @Test func waveformTapSelectsContainingWord() {
    let model = editor()
    identityGeometry(model)
    let word = model.editPlan.words.first { $0.startSample != nil && $0.endSample != nil }!
    model.waveformClicked(atX: CGFloat(word.startSample! + 1), extending: false)
    expectNoDifference(model.transcript.orderedSelectedWordIDs, [word.id])
  }

  @Test func waveformTapAtWordStartIsInclusiveAtEndIsExclusive() {
    let model = editor()
    identityGeometry(model)
    // choose a non-final word with sample bounds
    let words = model.editPlan.words
    let index = words.firstIndex {
      $0.startSample != nil && $0.endSample != nil && $0.id != words.last?.id
    }!
    let word = words[index]
    model.waveformClicked(atX: CGFloat(word.startSample!), extending: false)  // start is inclusive
    expectNoDifference(model.transcript.orderedSelectedWordIDs, [word.id])
    // Clear first: a tap at the exclusive end lands in the next word or a gap, never
    // back on this word — so the selection must not be this word afterward.
    model.transcript.clearSelectionTapped()
    model.waveformClicked(atX: CGFloat(word.endSample!), extending: false)  // end is exclusive
    #expect(model.transcript.orderedSelectedWordIDs != [word.id])
  }

  @Test func waveformTapInEmptyAreaLeavesSelectionUntouched() {
    let model = editor()
    identityGeometry(model)
    selectWords(model.transcript, 0, 0)
    let before = model.transcript.orderedSelectedWordIDs
    // a sample far beyond the audio belongs to no word
    model.waveformClicked(
      atX: CGFloat(model.editPlan.source.durationSamples + 10_000), extending: false)
    expectNoDifference(model.transcript.orderedSelectedWordIDs, before)
  }

  @Test func highlightedSampleRangeMirrorsTranscriptSelection() {
    let model = editor()
    #expect(model.highlightedSampleRange == nil)
    selectWords(model.transcript, 0, 2)
    expectNoDifference(model.highlightedSampleRange, model.transcript.selectedSampleRange)
    #expect(model.highlightedSampleRange != nil)
  }

  @Test func waveformHighlightSpanCombinesSelectionWithGeometry() {
    let model = editor()
    identityGeometry(model)
    model.transcript.selectWord(model.editPlan.words[0].id)
    let range = model.highlightedSampleRange!
    expectNoDifference(model.waveformHighlightSpan, model.waveform.span(for: range))
    #expect(model.waveformHighlightSpan != nil)
  }

  @Test func redRangesTrackRunTogetherWordsAndSensitivity() {
    let model = editor()
    model.transcript.sensitivityChanged(10)
    let tight = model.redRanges.count
    model.transcript.sensitivityChanged(80)
    let loose = model.redRanges.count
    #expect(tight < loose)
    for range in model.redRanges { #expect(range.lowerBound < range.upperBound) }
  }

  @Test func loadWaveformPopulatesChildViaClientFromCanonicalURL() async {
    let plan = Fixtures.editPlan()
    let fixture = Waveform.pyramid(
      baseMins: [0], baseMaxs: [0.5], sampleRate: plan.source.sampleRate,
      totalSamples: plan.source.durationSamples)
    let canonical = URL(fileURLWithPath: "/tmp/qie-canonical-load.aiff")
    let loadedURL = LockIsolated<URL?>(nil)
    let model = withDependencies {
      $0.waveform = WaveformClient(loadWaveform: { url, _, _ in
        loadedURL.setValue(url)
        return fixture
      })
    } operation: {
      EditorModel(
        sourceURL: URL(fileURLWithPath: "/clip.m4a"),
        canonicalAudioURL: canonical, editPlan: plan)
    }
    await model.loadWaveform()
    expectNoDifference(model.waveform.waveform, fixture)
    #expect(model.waveform.totalSamples == plan.source.durationSamples)
    // The waveform is built from the canonical AIFF, not the original source.
    expectNoDifference(loadedURL.value, canonical)
  }

  // MARK: - Export

  private func selectWords(_ transcript: TranscriptPageModel, _ first: Int, _ last: Int) {
    transcript.transcriptDragBegan(
      atUTF16Offset: transcript.document.wordRanges[first].range.location)
    transcript.transcriptDragged(
      toUTF16Offset: transcript.document.wordRanges[last].range.location)
  }

  private func addSlices(_ model: EditorModel, _ pairs: [(Int, Int)]) {
    for pair in pairs {
      selectWords(model.transcript, pair.0, pair.1)
      model.addSliceTapped()
    }
  }

  /// Yields cooperatively until `condition` holds (or a generous bound), so a
  /// worker task on the shared main actor can advance without `Task.sleep`.
  private func settle(until condition: () -> Bool) async {
    for _ in 0..<1000 where !condition() { await Task.yield() }
  }

  private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("qie-export-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func writeTempAIFF(in dir: URL, named name: String) throws -> URL {
    let url = dir.appendingPathComponent(name)
    try Data("aiff".utf8).write(to: url)
    return url
  }

  /// A stream that reports rendering `ids` and completes with a temp AIFF per id.
  private func renderedSlices(
    for ids: [Slice.ID], workDir: URL
  ) throws -> [RenderedSlice] {
    try ids.map { id in
      RenderedSlice(id: id, url: try writeTempAIFF(in: workDir, named: "\(id.uuidString).aiff"))
    }
  }

  @Test func exportAllCopiesRevealsAndRemembersDestination() async throws {
    let model = editor()
    addSlices(model, [(0, 1), (2, 3)])
    let ids = model.slices.map(\.id)
    let workDir = try makeTempDir()
    let destination = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: destination) }
    let rendered = try renderedSlices(for: ids, workDir: workDir)
    let revealed = LockIsolated<[URL]>([])
    let capturedRequest = LockIsolated<RenderRequest?>(nil)

    await withDependencies {
      $0.engine.renderSlices = { request in
        capturedRequest.setValue(request)
        return AsyncThrowingStream { continuation in
          continuation.yield(.progress(RenderProgress(message: "", index: 1, total: ids.count)))
          continuation.yield(.completed(RenderResult(slices: rendered, workDir: workDir)))
          continuation.finish()
        }
      }
      $0.workspace.reveal = { revealed.setValue($0) }
    } operation: {
      model.destinationURL = destination
      model.exportAllTapped()
      await model.exportTask?.value
    }

    expectNoDifference(model.exportPhase, .done(count: 2))
    expectNoDifference(Set(capturedRequest.value?.slices.map(\.id) ?? []), Set(ids))
    // Render is driven from the canonical AIFF, not the original source file, and
    // carries the plan's duration so the engine can verify the exact file.
    expectNoDifference(capturedRequest.value?.audioURL, model.canonicalAudioURL)
    expectNoDifference(
      capturedRequest.value?.durationSamples, model.editPlan.source.durationSamples)
    let contents = try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted()
    expectNoDifference(contents.count, 2)
    expectNoDifference(revealed.value.count, 2)
    expectNoDifference(
      Set(revealed.value.map { $0.deletingLastPathComponent().path }), [destination.path])
    // The engine work-dir is removed after the copy.
    #expect(!FileManager.default.fileExists(atPath: workDir.path))
  }

  @Test func exportAllMapsResultsByIdNotOrder() async throws {
    let model = editor()
    addSlices(model, [(0, 1), (2, 3)])
    let ids = model.slices.map(\.id)
    let stem = model.sourceURL.deletingPathExtension().lastPathComponent
    let workDir = try makeTempDir()
    let destination = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: destination) }
    // Render results returned in REVERSE order; copy must still match slice → name by id.
    let rendered = try renderedSlices(for: ids, workDir: workDir).reversed()

    await withDependencies {
      $0.engine.renderSlices = { _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.completed(RenderResult(slices: Array(rendered), workDir: workDir)))
          continuation.finish()
        }
      }
      $0.workspace.reveal = { _ in }
    } operation: {
      model.destinationURL = destination
      model.exportAllTapped()
      await model.exportTask?.value
    }

    let contents = Set(try FileManager.default.contentsOfDirectory(atPath: destination.path))
    expectNoDifference(contents, ["\(stem) - Slice 1.aiff", "\(stem) - Slice 2.aiff"])
  }

  @Test func missingDestinationPromptsChooseDirectory() async throws {
    let model = editor()
    addSlices(model, [(0, 1)])
    let ids = model.slices.map(\.id)
    let workDir = try makeTempDir()
    let destination = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: destination) }
    let rendered = try renderedSlices(for: ids, workDir: workDir)
    let promptCount = LockIsolated(0)

    await withDependencies {
      $0.workspace.chooseDirectory = {
        promptCount.withValue { $0 += 1 }
        return destination
      }
      $0.workspace.reveal = { _ in }
      $0.engine.renderSlices = { _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.completed(RenderResult(slices: rendered, workDir: workDir)))
          continuation.finish()
        }
      }
    } operation: {
      model.exportAllTapped()
      await model.exportTask?.value
    }

    expectNoDifference(promptCount.value, 1)
    expectNoDifference(model.destinationURL, destination)
    expectNoDifference(model.exportPhase, .done(count: 1))
  }

  @Test func cancellingDestinationPromptLeavesIdle() async {
    let model = editor()
    addSlices(model, [(0, 1)])
    let revealed = LockIsolated(false)

    await withDependencies {
      $0.workspace.chooseDirectory = { nil }  // user cancelled the panel
      $0.workspace.reveal = { _ in revealed.setValue(true) }
    } operation: {
      model.exportAllTapped()
      await model.exportTask?.value
    }

    expectNoDifference(model.exportPhase, .idle)
    #expect(!revealed.value)
    #expect(model.destinationURL == nil)
  }

  @Test func throwingRenderStreamSetsFailed() async throws {
    let model = editor()
    addSlices(model, [(0, 1)])
    let destination = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: destination) }

    await withDependencies {
      $0.engine.renderSlices = { _ in
        AsyncThrowingStream { continuation in
          continuation.finish(throwing: EngineClientError.renderFailed("boom"))
        }
      }
    } operation: {
      model.destinationURL = destination
      model.exportAllTapped()
      await model.exportTask?.value
    }

    guard case .failed(let message) = model.exportPhase else {
      Issue.record("expected .failed, got \(model.exportPhase)")
      return
    }
    #expect(message.contains("boom"))
  }

  @Test func partialRenderResultIsReportedAsFailureNotSuccess() async throws {
    let model = editor()
    addSlices(model, [(0, 1), (2, 3)])
    let ids = model.slices.map(\.id)
    let workDir = try makeTempDir()
    let destination = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: destination) }
    // Engine returns only the FIRST of two requested slices.
    let rendered = Array(try renderedSlices(for: ids, workDir: workDir).prefix(1))
    let revealed = LockIsolated(false)

    await withDependencies {
      $0.engine.renderSlices = { _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.completed(RenderResult(slices: rendered, workDir: workDir)))
          continuation.finish()
        }
      }
      $0.workspace.reveal = { _ in revealed.setValue(true) }
    } operation: {
      model.destinationURL = destination
      model.exportAllTapped()
      await model.exportTask?.value
    }

    guard case .failed(let message) = model.exportPhase else {
      Issue.record("expected .failed, got \(model.exportPhase)")
      return
    }
    #expect(message.contains("1 of 2"))
    #expect(!revealed.value)  // no partial reveal
    #expect(!FileManager.default.fileExists(atPath: workDir.path))  // still cleaned up
  }

  @Test func progressEventsWalkExportingThenDone() async throws {
    let model = editor()
    addSlices(model, [(0, 1), (2, 3)])
    let ids = model.slices.map(\.id)
    let workDir = try makeTempDir()
    let destination = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: destination) }
    let rendered = try renderedSlices(for: ids, workDir: workDir)
    let (stream, continuation) = AsyncThrowingStream<RenderEvent, Error>.makeStream()

    await withDependencies {
      $0.engine.renderSlices = { _ in stream }
      $0.workspace.reveal = { _ in }
    } operation: {
      model.destinationURL = destination
      model.exportAllTapped()

      continuation.yield(.progress(RenderProgress(message: "", index: 1, total: 2)))
      await settle { model.exportPhase == .exporting(current: 1, total: 2) }
      expectNoDifference(model.exportPhase, .exporting(current: 1, total: 2))

      continuation.yield(.progress(RenderProgress(message: "", index: 2, total: 2)))
      await settle { model.exportPhase == .exporting(current: 2, total: 2) }
      expectNoDifference(model.exportPhase, .exporting(current: 2, total: 2))

      continuation.yield(.completed(RenderResult(slices: rendered, workDir: workDir)))
      continuation.finish()
      await model.exportTask?.value
      expectNoDifference(model.exportPhase, .done(count: 2))
    }
  }

  @Test func cancelExportReportsPartialAndCleansTemp() async throws {
    let model = editor()
    addSlices(model, [(0, 1), (2, 3)])
    let destination = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: destination) }
    let (stream, continuation) = AsyncThrowingStream<RenderEvent, Error>.makeStream()
    let terminated = LockIsolated(false)
    continuation.onTermination = { _ in terminated.setValue(true) }

    await withDependencies {
      $0.engine.renderSlices = { _ in stream }
      $0.workspace.reveal = { _ in }
    } operation: {
      model.destinationURL = destination
      model.exportAllTapped()  // sync fire; stores the cancellable task
      continuation.yield(.progress(RenderProgress(message: "", index: 1, total: 2)))
      await Task.yield()
      #expect(model.isExporting)
      model.cancelExportTapped()
      await model.exportTask?.value
    }

    #expect(terminated.value)
    guard case .failed(let message) = model.exportPhase else {
      Issue.record("expected .failed, got \(model.exportPhase)")
      return
    }
    #expect(message.contains("cancelled"))
    // Nothing was copied to the destination.
    let contents = try FileManager.default.contentsOfDirectory(atPath: destination.path)
    expectNoDifference(contents, [])
  }

  @Test func tightJoinWarningCarriedIntoSummary() async throws {
    let model = editor()
    let tight = Slice(
      id: UUID(), name: "Intro", startSample: 10, endSample: 200,
      wordIDs: [], snippet: "x", warnings: [.tightStart])
    model.slices.append(tight)
    let workDir = try makeTempDir()
    let destination = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: destination) }
    let rendered = try renderedSlices(for: [tight.id], workDir: workDir)

    await withDependencies {
      $0.engine.renderSlices = { _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.completed(RenderResult(slices: rendered, workDir: workDir)))
          continuation.finish()
        }
      }
      $0.workspace.reveal = { _ in }
    } operation: {
      model.destinationURL = destination
      model.exportAllTapped()
      await model.exportTask?.value
    }

    #expect(model.exportTightWarning.contains("Intro"))
    #expect(model.exportTightWarning.contains("tight"))
  }

  @Test func renderRequestNudgesCollidingMarkerPositions() async {
    let plan = EditPlan(
      schemaVersion: 1,
      source: .init(path: "/clip.m4a", sampleRate: 44100, channels: 1, durationSamples: 100_000),
      words: [
        .init(id: 1, text: "a", start: 0.1, end: 0.2, startSample: 4410, endSample: 8820),
        .init(id: 2, text: "b", start: 0.1, end: 0.2, startSample: 4410, endSample: 8820),
      ],
      silences: [], segments: [])
    let model = editor(plan)
    model.slices.append(
      Slice(
        id: UUID(), name: "A", startSample: 0, endSample: 8820, wordIDs: [1, 2], snippet: "x",
        warnings: []))
    let captured = LockIsolated<RenderRequest?>(nil)

    await withDependencies {
      $0.engine.renderSlices = { request in
        captured.setValue(request)
        return AsyncThrowingStream { $0.finish() }
      }
    } operation: {
      model.destinationURL = URL(fileURLWithPath: NSTemporaryDirectory())
      model.exportAllTapped()
      await model.exportTask?.value
    }

    // Colliding start samples become strictly increasing marker positions.
    expectNoDifference(captured.value?.markers.map(\.position), [4410, 4411])
  }

  @Test func exportControlsGatedByStateAndExporting() async {
    let model = editor()
    expectNoDifference(model.canExportAll, false)  // no slices yet
    addSlices(model, [(0, 1)])
    expectNoDifference(model.canExportAll, true)
    model.exportPhase = .exporting(current: 0, total: 1)
    expectNoDifference(model.canExportAll, false)
    expectNoDifference(model.canExportSlice, false)
    expectNoDifference(model.showsCancelExport, true)
  }

  // MARK: - Waveform scroll / click / key routing

  /// The waveform's geometry (`totalSamples`) is only populated by the async audio load,
  /// which tests never run — so set it explicitly, exactly like `WaveformTests` does, or the
  /// `totalSamples > 0` guards make every zoom/pan a silent no-op.
  private func geometryReadyEditor() -> EditorModel {
    let model = editor()
    model.waveform.totalSamples = 100_000_000
    model.waveform.viewportWidth = 1000
    model.waveform.samplesPerPixel = 100
    model.waveform.visibleStartSample = 400_000
    return model
  }

  @Test func optionCommandScrollZoomsWaveform() {
    let model = geometryReadyEditor()
    let before = model.waveform.samplesPerPixel
    model.waveformScrolled(
      deltaX: 0, deltaY: 30, hasPreciseDeltas: true,
      optionDown: true, commandDown: true, atX: 500)
    #expect(model.waveform.samplesPerPixel != before)  // zoom changed
  }

  @Test func plainScrollPansWaveformNotZoom() {
    let model = geometryReadyEditor()
    let sppBefore = model.waveform.samplesPerPixel
    model.waveformScrolled(
      deltaX: 0, deltaY: 20, hasPreciseDeltas: true,
      optionDown: false, commandDown: false, atX: 500)
    expectNoDifference(model.waveform.samplesPerPixel, sppBefore)  // zoom untouched
    #expect(model.waveform.visibleStartSample != 400_000)  // panned
  }

  @Test func commandScrollZoomsWaveform() {
    let model = geometryReadyEditor()
    let before = model.waveform.samplesPerPixel
    model.waveformScrolled(
      deltaX: 0, deltaY: 30, hasPreciseDeltas: true,
      optionDown: false, commandDown: true, atX: 500)
    #expect(model.waveform.samplesPerPixel != before)  // ⌘+scroll zooms
  }

  @Test func lineBasedScrollNormalizesToFortyPixelsPerLine() {
    // Pan: 1 line == 40 precise px.
    let lineModel = geometryReadyEditor()
    lineModel.waveformScrolled(
      deltaX: 0, deltaY: 1, hasPreciseDeltas: false,
      optionDown: false, commandDown: false, atX: 500)

    let preciseModel = geometryReadyEditor()
    preciseModel.waveformScrolled(
      deltaX: 0, deltaY: 40, hasPreciseDeltas: true,
      optionDown: false, commandDown: false, atX: 500)

    expectNoDifference(
      lineModel.waveform.visibleStartSample, preciseModel.waveform.visibleStartSample)

    // Zoom: 1 line == 40 precise px under ⌥⌘.
    let lineZoom = geometryReadyEditor()
    lineZoom.waveform.visibleStartSample = 0
    lineZoom.waveformScrolled(
      deltaX: 0, deltaY: 1, hasPreciseDeltas: false,
      optionDown: true, commandDown: true, atX: 500)

    let preciseZoom = geometryReadyEditor()
    preciseZoom.waveform.visibleStartSample = 0
    preciseZoom.waveformScrolled(
      deltaX: 0, deltaY: 40, hasPreciseDeltas: true,
      optionDown: true, commandDown: true, atX: 500)

    expectNoDifference(lineZoom.waveform.samplesPerPixel, preciseZoom.waveform.samplesPerPixel)
  }

  @Test func waveformClickExtendingExtendsSelection() {
    let model = editor()  // default plan = Fixtures.editPlan()
    model.waveform.totalSamples = 100_000_000
    model.waveform.viewportWidth = 1000
    model.waveform.samplesPerPixel = 1
    model.waveform.visibleStartSample = 0
    // With spp 1 / start 0, view-x == plan sample, so x = startSample+1 lands inside a word.
    let words = Fixtures.editPlan().words
    let first = words[0]
    let later = words[4]
    model.waveformClicked(atX: CGFloat(first.startSample! + 1), extending: false)
    model.waveformClicked(atX: CGFloat(later.startSample! + 1), extending: true)
    #expect(model.transcript.selectedWordIDSet.count >= 2)  // extended across the run
  }

  @Test func editorKeyDownZoomFitTogglesUsingSelection() {
    let model = editor()
    model.waveform.totalSamples = 100_000_000
    model.waveform.viewportWidth = 1000
    model.waveform.samplesPerPixel = 50
    model.waveform.visibleStartSample = 0
    selectWords(model.transcript, 0, 1)  // a real, resolvable selection
    let consumed = model.editorKeyDown(.zoomFit)  // fit selection (stores 50/0)
    expectNoDifference(consumed, true)
    #expect(model.waveform.samplesPerPixel != 50)  // it fit to something
    _ = model.editorKeyDown(.zoomFit)  // restore
    expectNoDifference(model.waveform.samplesPerPixel, 50)
    expectNoDifference(model.waveform.visibleStartSample, 0)
  }

  @Test func editorKeyDownZoomInOut() {
    let model = editor()
    model.waveform.totalSamples = 100_000_000  // fit spp = 100_000; 100 is well inside range
    model.waveform.viewportWidth = 1000
    model.waveform.samplesPerPixel = 100
    model.waveform.visibleStartSample = 0
    _ = model.editorKeyDown(.zoomIn)
    #expect(model.waveform.samplesPerPixel < 100)
    let zoomedIn = model.waveform.samplesPerPixel
    _ = model.editorKeyDown(.zoomOut)
    #expect(model.waveform.samplesPerPixel > zoomedIn)
  }
}
