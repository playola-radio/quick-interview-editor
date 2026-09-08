import Foundation

extension EditorModel {
  func playSelectedClipTapped() async {
    guard case .object(.clip(let id)) = selection else { return }
    await playSliceTapped(id)
  }

  func acceptSelectedSuggestionTapped() {
    guard !isExporting, case .object(.suggestion(let id)) = selection else { return }
    cutSuggestions.acceptTapped(id)
  }

  func rejectSelectedSuggestionTapped() {
    guard !isExporting, case .object(.suggestion(let id)) = selection else { return }
    cutSuggestions.rejectTapped(id)
  }

  func deleteSelectionTapped() async {
    guard !isExporting else { return }
    switch selection {
    case .object(.clip(let id)):
      mutateDocument(selectionAfter: EditorSelection.none, label: "Delete Clip") {
        $0.slices[id: id] = nil
      }
      await reconcilePlayback()
    case .object(.suggestion(let id)):
      mutateDocument(selectionAfter: EditorSelection.none, label: "Delete Suggestion") {
        $0.cutSuggestions[id: id] = nil
      }
      await reconcilePlayback()
    case .range:
      clearSelectionTapped()
    case .seam(let id):
      mutateDocument(selectionAfter: EditorSelection.none, label: "Restore Removed Audio") {
        $0.timelineRemovals[id: id] = nil
      }
      await reconcilePlayback()
    case .none:
      break
    }
  }

  /// Explicit Clear is undoable; ordinary navigation uses the non-recording clear.
  func clearSelectionTapped() {
    finishCutSuggestionTitleEdit()
    let before = selection
    clearSelection()
    selectionPreservesTransport = true
    history.record(
      .init(
        document: nil, selection: .init(before: before, after: selection),
        label: "Clear Selection"))
  }

  func applyHistory(
    _ entry: EditorHistory<EditorDocumentState, EditorSelection>.Entry, undoing: Bool
  ) async {
    var documentChanged = false
    if let change = entry.document {
      let restored = undoing ? change.before : change.after
      if restored != documentState {
        restore(restored)
        documentChanged = true
      }
    }
    if let change = entry.selection {
      selection = undoing ? change.before : change.after
      selectionEditingEdge = nil
      transcript.invalidateSelectionAnchor()
    }
    reconcileSelection()
    selectionPreservesTransport = true
    if let id = selection.objectID { revealSelectedSidebarObject(id) }
    if documentChanged { await reconcilePlayback() }
  }

  /// History can outlive a background suggestion replacement. Never restore a
  /// missing identity or an out-of-source range as the active selection.
  func reconcileSelection() {
    transcript.clickCapture = nil
    defer { reconcileTranscriptOverlap() }
    switch selection {
    case .object(.suggestion(let id)):
      if documentCutSuggestions[id: id]?.isAccepted == true, slices[id: id] != nil {
        selection = .object(.clip(id))
      } else if selectedTranscriptObject == nil {
        clearSelection()
      }
    case .object(.clip):
      if selectedTranscriptObject == nil { clearSelection() }
    case .seam(let id):
      if timelineRemovals[id: id] == nil { clearSelection() }
    case .range(let range, let anchor):
      reconcileFreeformRange(range, anchor: anchor)
    case .none: break
    }
  }
  private func reconcileFreeformRange(_ range: Range<Int>, anchor: Int) {
    let lower = max(0, range.lowerBound)
    let upper = min(editPlan.source.durationSamples, range.upperBound)
    guard lower < upper else {
      clearSelection()
      return
    }
    let clampedAnchor: Int
    if anchor <= lower {
      clampedAnchor = lower
    } else if anchor >= upper {
      clampedAnchor = upper
    } else {
      clampedAnchor = anchor - lower <= upper - anchor ? lower : upper
    }
    selection = .range(lower..<upper, anchor: clampedAnchor)
  }

}
