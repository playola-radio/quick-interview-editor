import CustomDump
import Dependencies
import Foundation
import Sharing
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct DraftEditingTests {
  private func draft() -> EditSliceModel {
    EditSliceModel(
      target: .freeformDraft(UUID(0)), title: "Draft", range: 55_000..<90_000,
      editPlan: Fixtures.editPlan())
  }

  @Test func unchangedDraftCommitsOnce() {
    let model = draft()
    var commits: [Range<Int>] = []
    var dismissals = 0
    model.onCommit = {
      commits.append($0)
      return .committed
    }
    model.onDismiss = { dismissals += 1 }
    #expect(model.canSave)
    model.saveTapped()
    model.saveTapped()
    expectNoDifference(commits, [55_000..<90_000])
    expectNoDifference(dismissals, 1)
  }

  @Test func failedCommitRetainsDraftAndHistory() {
    let model = draft()
    var dismissals = 0
    model.onDismiss = { dismissals += 1 }
    model.onCommit = { _ in .failed("Unavailable") }
    model.cutInNudgedForward()
    let range = model.fineTune.draftRange
    model.saveTapped()
    expectNoDifference(model.commitError, "Unavailable")
    expectNoDifference(model.fineTune.draftRange, range)
    expectNoDifference(dismissals, 0)
    #expect(model.canUndoDraft)
  }

  @Test func dragAndNudgesHaveLocalHistoryWithFixedAnchors() async {
    let model = draft()
    let anchor = model.fineTune.committedRange
    let window = model.fineTune.cutInWindow
    model.boundaryGestureBegan()
    model.cutInDragged(toInsetX: 130)
    model.cutInDragged(toInsetX: 135)
    model.boundaryGestureEnded()
    let dragged = model.fineTune.draftRange
    model.cutOutNudgedBack()
    model.cutOutNudgedBack()
    await model.undoTapped()
    await model.undoTapped()
    expectNoDifference(model.fineTune.draftRange, dragged)
    await model.undoTapped()
    expectNoDifference(model.fineTune.draftRange, anchor)
    await model.redoTapped()
    expectNoDifference(model.fineTune.draftRange, dragged)
    expectNoDifference(model.fineTune.committedRange, anchor)
    expectNoDifference(model.fineTune.cutInWindow, window)
  }

  @Test func cancelledDragRecordsNothingAndDraftUndoNeverFallsThrough() async {
    let model = draft()
    var documentUndos = 0
    model.onUndo = { documentUndos += 1 }
    model.boundaryGestureBegan()
    model.cutInDragged(toInsetX: 140)
    model.boundaryGestureCancelled()
    model.boundaryGestureEnded()
    await model.undoTapped()
    expectNoDifference(model.fineTune.draftRange, model.fineTune.committedRange)
    expectNoDifference(documentUndos, 0)
    #expect(!model.canUndoDraft)
  }

  @Test func draftDocumentActionsAreUnavailableAndGuarded() async {
    let model = draft()
    var mutations = 0
    model.onSetEditingComplete = { _ in mutations += 1 }
    model.onRestore = { _ in mutations += 1 }
    model.selectedSeamID = UUID(1)
    model.editingCompleteToggled()
    await model.removeSectionKeyPressed()
    expectNoDifference(mutations, 0)
    #expect(!model.canMutateDocument)
    #expect(!model.canRemoveSelection)
    expectNoDifference(model.waveformContextMenuItems(atX: 0).count, 0)
  }
  private func editor() -> EditorModel {
    EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: Fixtures.editPlan(),
      sourceFingerprint: "draft-source")
  }

  private func suggestion(_ model: EditorModel) -> CutSuggestion {
    var candidate = Fixtures.cutSuggestion(id: UUID(7), wordIDs: [1, 2, 3])
    candidate.provenance.sourceFingerprint = model.sourceFingerprint
    candidate.provenance.transcriptHash = model.editPlan.transcriptHash
    return candidate
  }

  @Test func openingCancellingAndEmptyParentUndoNeverWriteDocument() async throws {
    let model = withDependencies {
      $0.uuid = .incrementing
    } operation: {
      editor()
    }
    model.mutateDocument { $0.speakerCountOverride = 2 }
    let before = model.documentState
    let history = model.history.undo.count
    var writes = 0
    model.onDocumentStateChanged = { _ in writes += 1 }
    model.selection = .range(55_000..<90_000, anchor: 55_000)
    model.openSelectionTapped()
    let child = try #require(model.editSlice)
    await model.undoTapped()
    await model.redoTapped()
    await model.reconcilePlayback()
    #expect(model.editSlice === child)
    child.cancelTapped()
    expectNoDifference(model.documentState, before)
    expectNoDifference(model.history.undo.count, history)
    expectNoDifference(writes, 0)
  }

  @Test func freeformSaveAppliesOffsetsOnceAndUsesOneStableID() async throws {
    try await withDependencies {
      $0.uuid = .incrementing
      $0.defaultAppStorage = UserDefaults(suiteName: "draft-offset-\(UUID())")!
    } operation: {
      @Shared(.clipStartOffsetMs) var startOffset = -20.0
      @Shared(.clipEndOffsetMs) var endOffset = 15.0
      let model = editor()
      model.selection = .range(55_000..<90_000, anchor: 55_000)
      model.openSelectionTapped()
      let child = try #require(model.editSlice)
      let range = try #require(child.fineTune.draftRange)
      expectNoDifference(range, 54_118..<90_662)
      let id = child.target.resultingClipID
      expectNoDifference(id, UUID(0))
      var played: [Range<Int>] = []
      child.onPlay = { played.append($0) }
      await child.playPauseTapped()
      child.saveTapped()
      child.saveTapped()
      expectNoDifference(model.slices.count, 1)
      let slice = try #require(model.slices[id: id])
      expectNoDifference(slice.startSample..<slice.endSample, range)
      expectNoDifference(played, [range])
      expectNoDifference(model.selection, .object(.clip(id)))
      await model.undoTapped()
      #expect(model.slices.isEmpty)
      await model.redoTapped()
      expectNoDifference(model.slices[id: id], slice)
    }
  }

  @Test func suggestionSaveAllowsEditedMembershipAndAcceptsAtomically() async throws {
    let model = editor()
    let candidate = suggestion(model)
    model.cutSuggestions.onSuggestionsProduced?([candidate])
    model.selection = .object(.suggestion(candidate.id))
    model.openSelectionTapped()
    let child = try #require(model.editSlice)
    #expect(model.slices.isEmpty)
    expectNoDifference(model.documentCutSuggestions[id: candidate.id]?.status, .pending)
    child.fineTune.restoreDraftRange(70_648..<98_916)
    var writes: [EditorDocumentState] = []
    model.onDocumentStateChanged = { writes.append($0) }
    child.saveTapped()
    expectNoDifference(writes.count, 1)
    expectNoDifference(model.slices[id: candidate.id]?.wordIDs, [2, 3])
    expectNoDifference(model.documentCutSuggestions[id: candidate.id]?.status, .accepted)
    #expect(child.invalidationReason == nil)
    await model.undoTapped()
    #expect(model.slices.isEmpty)
    expectNoDifference(model.documentCutSuggestions[id: candidate.id]?.status, .pending)
    await model.redoTapped()
    expectNoDifference(model.slices[id: candidate.id]?.wordIDs, [2, 3])
    expectNoDifference(model.documentCutSuggestions[id: candidate.id]?.status, .accepted)
  }

  @Test(arguments: ["missing", "rejected", "replaced", "source", "transcript"])
  func suggestionInvalidationRetainsDraftAndRefusesSave(reason: String) throws {
    let model = editor()
    let candidate = suggestion(model)
    model.cutSuggestions.onSuggestionsProduced?([candidate])
    model.selection = .object(.suggestion(candidate.id))
    model.openSelectionTapped()
    let child = try #require(model.editSlice)
    child.cutInNudgedForward()
    let range = child.fineTune.draftRange
    model.mutateDocument {
      switch reason {
      case "missing": $0.cutSuggestions.remove(id: candidate.id)
      case "rejected": $0.cutSuggestions[id: candidate.id]?.reject()
      case "replaced": $0.cutSuggestions[id: candidate.id]?.wordIDs = [2, 3]
      case "source": $0.cutSuggestions[id: candidate.id]?.provenance.sourceFingerprint = "changed"
      default: $0.cutSuggestions[id: candidate.id]?.provenance.transcriptHash = "changed"
      }
    }
    let before = model.documentState
    child.saveTapped()
    #expect(model.editSlice === child)
    #expect(!child.canSave)
    #expect(child.commitError != nil)
    #expect(child.canUndoDraft)
    expectNoDifference(child.fineTune.draftRange, range)
    expectNoDifference(model.documentState, before)
  }

  @Test func missingSavedClipCommitFailureRetainsSheet() throws {
    let model = editor()
    let slice = Fixtures.slice(start: 55_000, end: 90_000)
    model.mutateSlices { $0.append(slice) }
    model.editSliceTapped(slice.id)
    let child = try #require(model.editSlice)
    child.cutInNudgedForward()
    model.mutateSlices { $0.remove(id: slice.id) }
    child.saveTapped()
    #expect(model.editSlice === child)
    expectNoDifference(child.commitError, "This clip no longer exists.")
  }

  @Test func disposablePendingFineTuneDoesNotBlockOpening() throws {
    let model = withDependencies {
      $0.uuid = .incrementing
    } operation: {
      editor()
    }
    model.selection = .range(55_000..<90_000, anchor: 55_000)
    model.fineTune.begin(target: .pendingSelection, range: 55_000..<90_000)
    model.fineTune.nudgeCutIn(byMs: 10)
    model.openSelectionTapped()
    #expect(model.editSlice != nil)
  }

  @Test func unwiredSaveShowsFailureAndRetainsDraft() {
    let model = draft()
    var dismissals = 0
    model.onDismiss = { dismissals += 1 }
    model.saveTapped()
    #expect(model.commitError != nil)
    expectNoDifference(dismissals, 0)
  }

  @Test func invalidRangesCannotSave() {
    let model = draft()
    for range in [-1..<90_000, 55_000..<55_001, 0..<10_000, 55_000..<Int.max] {
      model.fineTune.draftRange = range
      #expect(!model.canSave)
    }
  }

  @Test func savedEditorWithDirtyBoundariesCannotBeReplaced() throws {
    let model = editor()
    let slice = Fixtures.slice(start: 55_000, end: 90_000)
    model.mutateSlices { $0.append(slice) }
    model.editSliceTapped(slice.id)
    let editing = try #require(model.editSlice)
    editing.cutInNudgedForward()
    model.selection = .range(55_000..<90_000, anchor: 55_000)
    model.openSelectionTapped()
    #expect(model.editSlice === editing)
    expectNoDifference(
      model.clipEditorMessage, "Save or cancel the current edit before opening another clip.")
  }

  @Test func savedEditorNeverAppliesCreationOffsets() throws {
    try withDependencies {
      $0.defaultAppStorage = UserDefaults(suiteName: "saved-draft-offset-\(UUID())")!
    } operation: {
      @Shared(.clipStartOffsetMs) var offset = 50.0
      let model = editor()
      let slice = Fixtures.slice(start: 55_000, end: 90_000)
      model.mutateSlices { $0.append(slice) }
      model.selection = .object(.clip(slice.id))
      model.openSelectionTapped()
      let editing = try #require(model.editSlice)
      expectNoDifference(editing.fineTune.draftRange, 55_000..<90_000)
      expectNoDifference(editing.transcript.document.wordRanges.map(\.wordID), slice.wordIDs)
    }
  }

  @Test func draftCallbackMutationPathsRemainReadOnly() async throws {
    let model = withDependencies {
      $0.uuid = .incrementing
    } operation: {
      editor()
    }
    let removal = Fixtures.timelineRemoval(range: 70_000..<75_000)
    model.mutateDocument { $0.timelineRemovals.append(removal) }
    model.selection = .range(55_000..<90_000, anchor: 55_000)
    model.openSelectionTapped()
    let editing = try #require(model.editSlice)
    let before = model.documentState
    await editing.onRemoveSection(55_000..<60_000)
    editing.onRestore(removal.id)
    editing.onStretchCrossfade(removal.id, 100)
    editing.onMoveCutPoint(removal.id, 70_000..<76_000)
    editing.onSetEditingComplete(true)
    expectNoDifference(model.documentState, before)
    #expect(!editing.canEditCrossfade())
  }

  @Test func localUndoInvalidatesPreviewSynchronouslyAndKeepsNewPlayback() async {
    let model = draft()
    var invalidations = 0
    var played: [Range<Int>] = []
    model.onInvalidatePreview = { invalidations += 1 }
    model.onPlay = { played.append($0) }
    model.cutInNudgedForward()
    await model.playPauseTapped()
    #expect(model.isPlaying)
    await model.undoTapped()
    expectNoDifference(invalidations, 1)
    #expect(!model.isPlaying)
    await model.playPauseTapped()
    #expect(model.isPlaying)
    expectNoDifference(played, [55_441..<90_000, 55_000..<90_000])
  }

  @Test func clampedNudgeAndUnchangedDragRecordNoHistory() async {
    let model = EditSliceModel(
      target: .freeformDraft(UUID(1)), title: "Draft", range: 0..<90_000,
      editPlan: Fixtures.editPlan())
    model.cutInNudgedBack()
    model.boundaryGestureBegan()
    model.boundaryGestureEnded()
    #expect(!model.canUndoDraft)
    await model.undoTapped()
    expectNoDifference(model.fineTune.draftRange, 0..<90_000)
  }

  @Test func explicitSessionInvalidationSurvivesReconciliation() throws {
    let model = withDependencies {
      $0.uuid = .incrementing
    } operation: {
      editor()
    }
    model.selection = .range(55_000..<90_000, anchor: 55_000)
    model.openSelectionTapped()
    let editing = try #require(model.editSlice)
    editing.invalidate("The source changed.")
    model.mutateDocument { $0.speakerCountOverride = 3 }
    expectNoDifference(editing.invalidationReason, "The source changed.")
    #expect(!editing.canSave)
  }

  @Test func undoDuringPhysicalDragIgnoresRemainingPointerEvents() async {
    let model = draft()
    model.cutOutNudgedBack()
    model.boundaryGestureBegan()
    model.cutInDragged(toInsetX: 140)
    await model.undoTapped()
    model.boundaryGestureBegan()
    model.cutInDragged(toInsetX: 150)
    model.cutInDragged(toInsetX: 160)
    model.boundaryGestureEnded()
    expectNoDifference(model.fineTune.draftRange, 55_000..<90_000)
    #expect(!model.canUndoDraft)
    model.boundaryGestureBegan()
    model.cutInDragged(toInsetX: 140)
    model.boundaryGestureEnded()
    #expect(model.canUndoDraft)
  }

  @Test func undersizedInitialDraftRoundTripsThroughHistory() async {
    let model = EditSliceModel(
      target: .freeformDraft(UUID(2)), title: "Short draft", range: 55_000..<55_100,
      editPlan: Fixtures.editPlan())
    #expect(!model.canSave)
    model.cutOutNudgedForward()
    #expect(model.canSave)
    let grown = model.fineTune.draftRange
    await model.undoTapped()
    expectNoDifference(model.fineTune.draftRange, 55_000..<55_100)
    #expect(!model.canSave)
    await model.redoTapped()
    expectNoDifference(model.fineTune.draftRange, grown)
    #expect(model.canSave)
  }

}
