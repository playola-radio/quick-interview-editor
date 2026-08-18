import CustomDump
import Dependencies
import Foundation
import Testing

@testable import QuickInterviewEditor

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
