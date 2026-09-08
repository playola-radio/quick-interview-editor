import Foundation

extension EditorModel {
  var openSelectionLabel: String { "Open / Edit" }
  var canOpenSelection: Bool { audioSelection != nil }
  var canOpenClipEditor: Bool {
    let savedSheetDirty =
      editSlice.map { !$0.target.isDraft && $0.fineTune.hasUnsavedChange } ?? false
    let savedPaneDirty = fineTune.isEditingExistingSlice && fineTune.hasUnsavedChange
    guard !savedSheetDirty, !savedPaneDirty else {
      clipEditorMessage = "Save or cancel the current edit before opening another clip."
      return false
    }
    clipEditorMessage = nil
    return true
  }

  func openSelectionTapped() {
    guard canOpenClipEditor else { return }
    let target: ClipEditTarget
    let title: String
    let initialRange: Range<Int>
    switch selection {
    case .object(.clip(let id)):
      editSliceTapped(id)
      return
    case .object(.suggestion(let id)):
      guard let suggestion = documentCutSuggestions[id: id], suggestion.isPending else { return }
      switch validatedSuggestion(suggestion) {
      case .accepted(let slice, _):
        target = .suggestionDraft(suggestion)
        title = slice.name
        initialRange = slice.startSample..<slice.endSample
      case .stale(let reason):
        clipEditorMessage = cutSuggestionStaleMessage(reason)
        return
      case .invalid(let reason):
        clipEditorMessage = cutSuggestionInvalidMessage(reason)
        return
      }
    case .range(let range, _):
      target = .freeformDraft(draftUUID())
      title = "Slice \(nextSliceNumber)"
      initialRange = range
    default:
      return
    }
    let range = offsetClipRange(
      initialRange, startOffsetMs: clipStartOffsetMs, endOffsetMs: clipEndOffsetMs,
      sampleRate: editPlan.source.sampleRate, totalSamples: editPlan.source.durationSamples)
    presentClipEditor(
      EditSliceModel(target: target, title: title, range: range, editPlan: editPlan))
  }

  func validClipEditRange(_ range: Range<Int>) -> Bool {
    range.lowerBound >= 0 && range.upperBound <= editPlan.source.durationSamples
      && range.count >= max(1, Int((0.05 * Double(editPlan.source.sampleRate)).rounded()))
      && !wordIDs(anyOverlap: range, words: editPlan.words).isEmpty
  }

  private func validatedSuggestion(_ suggestion: CutSuggestion) -> AcceptResult {
    PlayolaInterviewEditor.acceptCutSuggestion(
      suggestion.id, in: ProjectState(cutSuggestions: documentCutSuggestions), plan: editPlan,
      sourceFingerprint: sourceFingerprint, transcriptHash: editPlan.transcriptHash)
  }

  private func draftInvalidationReason(_ editing: EditSliceModel) -> String? {
    guard case .suggestionDraft(let snapshot) = editing.target else { return nil }
    guard let live = documentCutSuggestions[id: snapshot.id], live.isPending else {
      return "This suggestion is no longer pending. Cancel and choose another suggestion."
    }
    guard live.wordIDs == snapshot.wordIDs, live.provenance == snapshot.provenance else {
      return "This suggestion changed. Cancel and open the current suggestion again."
    }
    switch validatedSuggestion(snapshot) {
    case .accepted: return nil
    case .stale(let reason): return cutSuggestionStaleMessage(reason)
    case .invalid(let reason): return cutSuggestionInvalidMessage(reason)
    }
  }

  func reconcileDraftEditing() {
    guard committingDraftID == nil, let editing = editSlice, editing.target.isDraft,
      let reason = draftInvalidationReason(editing)
    else { return }
    editing.invalidate(reason)
  }

  func commitDraftEdit(_ editing: EditSliceModel, range: Range<Int>) -> ClipEditCommitResult {
    guard editSlice === editing, editing.target.isDraft else {
      return .failed("This draft is no longer available.")
    }
    if let reason = editing.invalidationReason ?? draftInvalidationReason(editing) {
      editing.invalidate(reason)
      return .failed(reason)
    }
    guard validClipEditRange(range) else {
      return .failed("Choose a valid range containing words.")
    }
    let id = editing.target.resultingClipID
    guard slices[id: id] == nil else { return .failed("This clip has already been saved.") }
    let slice = buildSlice(
      id: id, name: editing.title, range: range,
      wordIDs: wordIDs(anyOverlap: range, words: editPlan.words), plan: editPlan)
    committingDraftID = id
    defer { committingDraftID = nil }
    mutateDocument(selectionAfter: .object(.clip(id)), label: "Save Clip") {
      $0.slices.append(slice)
      if case .suggestionDraft(let snapshot) = editing.target {
        $0.cutSuggestions[id: snapshot.id]?.accept()
      }
    }
    if case .freeformDraft = editing.target { advanceSliceNumber() }
    selectTranscriptObject(.clip(id))
    return .committed
  }
}
