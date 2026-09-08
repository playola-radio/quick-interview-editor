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
      guard !cutSuggestions.candidateActionsDisabled else {
        clipEditorMessage = SuggestionReviewError.locked.localizedDescription
        return
      }
      guard let suggestion = documentCutSuggestions[id: id], suggestion.isPending else { return }
      do {
        let slice = try validatedSuggestion(suggestion).slice
        target = .suggestionDraft(suggestion)
        title = slice.name
        initialRange = slice.startSample..<slice.endSample
      } catch {
        clipEditorMessage = error.localizedDescription
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

  private func validatedSuggestion(_ suggestion: CutSuggestion) throws -> SuggestionAcceptance {
    try suggestionSliceForAcceptance(
      id: suggestion.id, state: documentState, plan: editPlan, sourceFingerprint: sourceFingerprint)
  }

  private func draftInvalidationReason(_ editing: EditSliceModel) -> String? {
    guard case .suggestionDraft(let snapshot) = editing.target else { return nil }
    guard let live = documentCutSuggestions[id: snapshot.id], live.isPending else {
      return "This suggestion is no longer pending. Cancel and choose another suggestion."
    }
    guard live.wordIDs == snapshot.wordIDs, live.provenance == snapshot.provenance else {
      return "This suggestion changed. Cancel and open the current suggestion again."
    }
    do {
      _ = try validatedSuggestion(live)
      return nil
    } catch {
      return error.localizedDescription
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
    if case .suggestionDraft = editing.target, cutSuggestions.candidateActionsDisabled {
      return .failed(SuggestionReviewError.locked.localizedDescription)
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
    let acceptance: SuggestionAcceptance?
    do {
      if case .suggestionDraft(let snapshot) = editing.target {
        acceptance = try validatedSuggestion(snapshot)
      } else {
        acceptance = nil
      }
    } catch {
      editing.invalidate(error.localizedDescription)
      return .failed(error.localizedDescription)
    }
    var slice = buildSlice(
      id: id, name: editing.title, range: range,
      wordIDs: wordIDs(anyOverlap: range, words: editPlan.words), plan: editPlan)
    if let acceptance {
      slice.name = acceptance.slice.name
      slice.suggestionNaming = acceptance.slice.suggestionNaming
      slice.suggestionTypeID = acceptance.slice.suggestionTypeID
    }
    let reservations = slice.suggestionNaming?.reservation.map { [$0] } ?? []
    committingDraftID = id
    defer { committingDraftID = nil }
    mutateDocument(
      selectionAfter: .object(.clip(id)), label: "Save Clip",
      recordingPermanentReservations: reservations
    ) {
      $0.slices.append(slice)
      if let acceptance {
        $0.cutSuggestions[id: acceptance.candidate.id] = acceptance.candidate
        $0.suggestionBatch = acceptance.batch
      }
    }
    if case .freeformDraft = editing.target { advanceSliceNumber() }
    selectTranscriptObject(.clip(id))
    return .committed
  }
}
