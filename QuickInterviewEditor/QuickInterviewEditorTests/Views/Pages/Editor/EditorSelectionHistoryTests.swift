import CustomDump
import Dependencies
import Foundation
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct EditorSelectionHistoryTests {
  private func editor() -> EditorModel {
    EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: Fixtures.editPlan())
  }

  @Test func explicitClearRestoresReversedAnchorWithoutDocumentWrites() async {
    let model = editor()
    model.selectSourceRange(70_648..<119_202, snapPlayhead: false)
    model.selectionAnchorSample = 119_202
    let selected = model.selection
    let before = model.documentState
    var writes = 0
    model.onDocumentStateChanged = { _ in writes += 1 }
    model.clearSelectionTapped()
    expectNoDifference(model.selection, .none)
    #expect(model.canUndo)
    await model.undoTapped()
    expectNoDifference(model.selection, selected)
    expectNoDifference(model.documentState, before)
    expectNoDifference(writes, 0)
    await model.redoTapped()
    expectNoDifference(model.selection, .none)
    expectNoDifference(writes, 0)
  }

  @Test func clearInterleavesWithRenameInChronologicalOrder() async {
    let model = editor()
    let clip = Fixtures.slice(id: Fixtures.uuid(1))
    model.mutateDocument(recordUndo: false) { $0.slices.append(clip) }
    model.mutateDocument { $0.slices[id: clip.id]?.name = "Renamed" }
    model.selectSourceRange(70_648..<119_202, snapPlayhead: false)
    let selected = model.selection
    model.clearSelectionTapped()
    await model.undoTapped()
    expectNoDifference(model.selection, selected)
    expectNoDifference(model.slices[id: clip.id]?.name, "Renamed")
    await model.undoTapped()
    expectNoDifference(model.slices[id: clip.id]?.name, clip.name)
    expectNoDifference(model.selection, selected)
    await model.redoTapped()
    expectNoDifference(model.slices[id: clip.id]?.name, "Renamed")
    await model.redoTapped()
    expectNoDifference(model.selection, .none)
  }

  @Test func undoClearDuringPlaybackDoesNotStopOrSeek() async {
    let stops = LockIsolated(0)
    let model = withDependencies {
      $0.audioPlayer.stop = { _ in stops.withValue { $0 += 1 } }
    } operation: {
      editor()
    }
    model.selectSourceRange(70_648..<119_202, snapPlayhead: false)
    model.clearSelectionTapped()
    let session = PlaybackSessionID()
    model.transportPhase = .playing(session)
    model.playheadEditedSample = 150_000
    await model.undoTapped()
    expectNoDifference(model.audioSelection, 70_648..<119_202)
    // Exercise the same deferred reconciliation used by the view observer.
    await model.transportSelectionChanged(model.audioSelection, cursorToken: model.cursorMoveToken)
    expectNoDifference(model.transportPhase, .playing(session))
    expectNoDifference(model.playheadEditedSample, 150_000)
    expectNoDifference(stops.value, 0)
  }

  @Test func delayedHistoryObserverCannotStopPlaybackAfterAnotherSelection() async {
    let stops = LockIsolated(0)
    let model = withDependencies {
      $0.audioPlayer.stop = { _ in stops.withValue { $0 += 1 } }
    } operation: {
      editor()
    }
    model.selectSourceRange(70_648..<119_202, snapPlayhead: false)
    model.clearSelectionTapped()
    await model.undoTapped()
    let restoredRange = model.audioSelection
    let capturedToken = model.cursorMoveToken
    model.selectSourceRange(120_000..<150_000, snapPlayhead: false)
    let session = PlaybackSessionID()
    model.transportPhase = .playing(session)
    await model.transportSelectionChanged(restoredRange, cursorToken: capturedToken)
    expectNoDifference(model.transportPhase, .playing(session))
    expectNoDifference(stops.value, 0)
  }

  @Test func historyRestoreDuringSuspendedStopDoesNotSeekWhenStopCompletes() async {
    let started = AsyncStream<Void>.makeStream()
    let released = AsyncStream<Void>.makeStream()
    let model = withDependencies {
      $0.audioPlayer.stop = { _ in
        started.continuation.yield(())
        for await _ in released.stream { break }
      }
    } operation: {
      editor()
    }
    model.selectSourceRange(70_648..<119_202, snapPlayhead: false)
    model.playheadEditedSample = 150_000
    model.transportPhase = .playing(PlaybackSessionID())
    let range = model.audioSelection
    let token = model.cursorMoveToken
    let observer = Task { await model.transportSelectionChanged(range, cursorToken: token) }
    var starts = started.stream.makeAsyncIterator()
    _ = await starts.next()
    model.clearSelectionTapped()
    await model.undoTapped()
    released.continuation.yield(())
    await observer.value
    expectNoDifference(model.audioSelection, range)
    expectNoDifference(model.playheadEditedSample, 150_000)
    started.continuation.finish()
    released.continuation.finish()
  }

  @Test(arguments: [TransportContext.audition(.cutIn), .draftPreview, .sliceEdit])
  func historySyncDoesNotCancelScopedPlayback(context: TransportContext) async {
    let stops = LockIsolated(0)
    let model = withDependencies {
      $0.audioPlayer.stop = { _ in stops.withValue { $0 += 1 } }
    } operation: {
      editor()
    }
    model.selectSourceRange(70_648..<119_202, snapPlayhead: false)
    model.syncEditSession()
    let session = PlaybackSessionID()
    model.transportPhase = .playing(session)
    model.transportContext = context
    model.clearSelectionTapped()
    model.syncEditSession()
    expectNoDifference(model.transportPhase, .playing(session))
    await model.undoTapped()
    model.syncEditSession()
    expectNoDifference(model.transportPhase, .playing(session))
    expectNoDifference(model.transportContext, context)
    expectNoDifference(model.fineTune.draftRange, 70_648..<119_202)
    await model.redoTapped()
    model.syncEditSession()
    expectNoDifference(model.transportPhase, .playing(session))
    expectNoDifference(stops.value, 0)
  }

  @Test(arguments: [Int.min, Int.max])
  func restoredRangeClampsBoundsAndExtremeAnchors(anchor: Int) async {
    let model = editor()
    let end = model.editPlan.source.durationSamples
    let restored = EditorSelection.range(-100..<(end + 100), anchor: anchor)
    await model.applyHistory(
      .init(
        document: nil, selection: .init(before: restored, after: .none), label: "Clear"),
      undoing: true)
    expectNoDifference(model.selection, .range(0..<end, anchor: anchor < 0 ? 0 : end))
  }

  @Test(arguments: [EditorSelection.object(.clip(Fixtures.uuid(80))), .seam(Fixtures.uuid(80))])
  func missingRestoredIdentityDoesNotReappear(selection: EditorSelection) async {
    let model = editor()
    var writes = 0
    model.onDocumentStateChanged = { _ in writes += 1 }
    await model.applyHistory(
      .init(
        document: nil, selection: .init(before: selection, after: .none), label: "Clear"),
      undoing: true)
    expectNoDifference(model.selection, .none)
    expectNoDifference(writes, 0)
  }

  @Test func ordinaryClearDoesNotRecordNavigation() {
    let model = editor()
    model.selectSourceRange(70_648..<119_202, snapPlayhead: false)
    model.clearSelection()
    #expect(!model.canUndo)
  }
}
