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

  @Test(arguments: [false, true])
  func deleteObjectIsOneAtomicHistoryEntry(deletingSuggestion: Bool) async {
    let model = editor()
    let clip = Fixtures.slice(id: Fixtures.uuid(31), start: 70_648, end: 119_202)
    var suggestion = Fixtures.cutSuggestion(id: Fixtures.uuid(31))
    suggestion.status = deletingSuggestion ? .pending : .accepted
    suggestion.provenance.transcriptHash = model.editPlan.transcriptHash
    suggestion.provenance.sourceFingerprint = model.sourceFingerprint
    let removal = TimelineRemoval(
      id: Fixtures.uuid(33), removedRange: 300_000..<320_000,
      crossfade: Crossfade(lengthSamples: 96, curve: .equalPower))
    model.mutateDocument(recordUndo: false) {
      $0.slices.append(clip)
      $0.cutSuggestions.append(suggestion)
      $0.timelineRemovals.append(removal)
    }
    let selected = EditorSelection.object(
      deletingSuggestion ? .suggestion(suggestion.id) : .clip(clip.id))
    model.selection = selected
    let before = model.documentState
    var writes = 0
    model.onDocumentStateChanged = { _ in writes += 1 }
    await model.deleteSelectionTapped()
    expectNoDifference(model.selection, .none)
    expectNoDifference(model.timelineRemovals, before.timelineRemovals)
    expectNoDifference(model.slices[id: clip.id], deletingSuggestion ? clip : nil)
    expectNoDifference(
      model.documentCutSuggestions[id: suggestion.id], deletingSuggestion ? nil : suggestion)
    expectNoDifference(writes, 1)
    await model.undoTapped()
    expectNoDifference(model.selection, selected)
    expectNoDifference(model.documentState, before)
    #expect(!model.canUndo)
    await model.redoTapped()
    expectNoDifference(model.selection, .none)
    expectNoDifference(model.slices[id: clip.id], deletingSuggestion ? clip : nil)
    expectNoDifference(
      model.documentCutSuggestions[id: suggestion.id], deletingSuggestion ? nil : suggestion)
    #expect(!model.canRedo)
  }

  @Test func deleteRangeRemovesSelectedAudioWithCrossfadeAndIsUndoable() async {
    let model = editor()
    model.selectSourceRange(70_648..<119_202, snapPlayhead: false)
    let before = model.documentState
    var writes = 0
    model.onDocumentStateChanged = { _ in writes += 1 }
    await model.deleteSelectionTapped()
    expectNoDifference(model.selection, .none)
    expectNoDifference(model.timelineRemovals.map(\.removedRange), [70_648..<119_202])
    #expect(model.timelineRemovals.first?.crossfade.curve == .equalPower)
    #expect(model.removedWordIDs.isSuperset(of: [2, 3, 4]))
    expectNoDifference(writes, 1)
    await model.undoTapped()
    expectNoDifference(model.documentState, before)
    #expect(model.timelineRemovals.isEmpty)
    #expect(model.removedWordIDs.isEmpty)
    #expect(!model.canUndo)
    await model.redoTapped()
    expectNoDifference(model.timelineRemovals.map(\.removedRange), [70_648..<119_202])
    expectNoDifference(model.selection, .none)
  }

  @Test func deleteRangeBlockedWhileExporting() async {
    let model = editor()
    model.selectSourceRange(70_648..<119_202, snapPlayhead: false)
    model.exportPhase = .exporting(current: 1, total: 1)
    await model.deleteSelectionTapped()
    expectNoDifference(model.timelineRemovals, [])
  }

  @Test func deleteSeamRestoresAudioAndSelectionOnUndo() async {
    let model = editor()
    let removal = TimelineRemoval(
      id: Fixtures.uuid(33), removedRange: 300_000..<320_000,
      crossfade: Crossfade(lengthSamples: 96, curve: .equalPower))
    model.mutateDocument(recordUndo: false) { $0.timelineRemovals.append(removal) }
    model.selectSeam(removal.id)
    await model.deleteSelectionTapped()
    expectNoDifference(model.selection, .none)
    #expect(model.timelineRemovals.isEmpty)
    await model.undoTapped()
    expectNoDifference(model.selection, .seam(removal.id))
    expectNoDifference(model.timelineRemovals[id: removal.id], removal)
    #expect(!model.canUndo)
  }

  @Test func objectSelectionCannotBeNudgedResizedOrMarkedAgain() {
    let model = editor()
    let clip = Fixtures.slice(id: Fixtures.uuid(31), start: 70_648, end: 119_202)
    model.mutateDocument(recordUndo: false) { $0.slices.append(clip) }
    model.selectTranscriptObject(.clip(clip.id))
    let before = model.documentState
    let selected = model.selection
    #expect(!model.canAddSlice)
    #expect(!model.canRemoveSelectedSection)
    #expect(!model.canEditSelectionEdges)
    for key in [
      EditorKey.nudgeCutInEarlier, .nudgeCutInLater, .nudgeCutOutEarlier, .nudgeCutOutLater,
    ] {
      #expect(model.editorKeyDown(key))
      expectNoDifference(model.selection, selected)
    }
    model.selectionEdgeDragBegan(.start)
    model.selectionEdgeDraggedToSource(.start, 90_000)
    model.selectionNudged(.end, byMs: 10)
    model.addSliceTapped()
    expectNoDifference(model.selectionEditingEdge, nil)
    expectNoDifference(model.selection, selected)
    expectNoDifference(model.documentState, before)
  }

  @Test func escapeClearsObjectSelection() {
    let model = editor()
    let clip = Fixtures.slice(id: Fixtures.uuid(31), start: 70_648, end: 119_202)
    model.mutateDocument(recordUndo: false) { $0.slices.append(clip) }
    model.selectTranscriptObject(.clip(clip.id))
    #expect(model.editorKeyDown(.escape))
    expectNoDifference(model.selection, .none)
    #expect(!model.editorKeyDown(.escape))
  }

  @Test func escapePreservesUndoAndRedoHistory() async {
    let model = editor()
    let clip = Fixtures.slice(id: Fixtures.uuid(31), start: 70_648, end: 119_202)
    model.mutateDocument(recordUndo: false) { $0.slices.append(clip) }
    model.renameSlice(clip.id, to: "First name")
    model.renameSlice(clip.id, to: "Second name")
    await model.undoTapped()
    model.selectTranscriptObject(.clip(clip.id))
    let undoBefore = model.history.undo
    let redoBefore = model.history.redo

    #expect(model.editorKeyDown(.escape))

    expectNoDifference(model.selection, .none)
    expectNoDifference(model.history.undo, undoBefore)
    expectNoDifference(model.history.redo, redoBefore)
    await model.redoTapped()
    expectNoDifference(model.slices[id: clip.id]?.name, "Second name")
    await model.undoTapped()
    await model.undoTapped()
    expectNoDifference(model.slices[id: clip.id]?.name, clip.name)
    #expect(!model.canUndo)
  }

  @Test func deleteIsBlockedWhileExporting() async {
    let model = editor()
    let clip = Fixtures.slice(id: Fixtures.uuid(31), start: 70_648, end: 119_202)
    model.mutateDocument(recordUndo: false) { $0.slices.append(clip) }
    model.selectTranscriptObject(.clip(clip.id))
    let selected = model.selection
    let before = model.documentState
    model.exportPhase = .exporting(current: 0, total: 1)
    await model.deleteSelectionTapped()
    expectNoDifference(model.selection, selected)
    expectNoDifference(model.documentState, before)
    #expect(!model.canUndo)
  }

  @Test func deleteWithoutSelectionDoesNothing() async {
    let model = editor()
    let before = model.documentState
    await model.deleteSelectionTapped()
    expectNoDifference(model.selection, .none)
    expectNoDifference(model.documentState, before)
    #expect(!model.canUndo)
  }

  @Test func deletingClipDoesNotClearSelectionMadeDuringPlaybackReconciliation() async {
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
    let clip = Fixtures.slice(id: Fixtures.uuid(31), start: 70_648, end: 119_202)
    model.mutateDocument(recordUndo: false) { $0.slices.append(clip) }
    model.selectTranscriptObject(.clip(clip.id))
    model.transportContext = .slice(clip.id)
    model.transportPhase = .playing(PlaybackSessionID())
    let deletion = Task { await model.deleteSelectionTapped() }
    var starts = started.stream.makeAsyncIterator()
    _ = await starts.next()
    model.selectSourceRange(120_000..<150_000, snapPlayhead: false)
    let newerSelection = model.selection
    released.continuation.yield(())
    await deletion.value
    expectNoDifference(model.selection, newerSelection)
    expectNoDifference(model.slices[id: clip.id], nil)
    #expect(model.timelineRemovals.isEmpty)
    started.continuation.finish()
    released.continuation.finish()
  }
}
