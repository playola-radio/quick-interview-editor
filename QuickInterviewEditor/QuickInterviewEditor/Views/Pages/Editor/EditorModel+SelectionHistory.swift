import Foundation

extension EditorModel {
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
    if documentChanged { await reconcilePlayback() }
  }

  /// History can outlive a background suggestion replacement. Never restore a
  /// missing identity or an out-of-source range as the active selection.
  func reconcileSelection() {
    switch selection {
    case .object:
      if selectedTranscriptObject == nil { clearSelection() }
    case .seam(let id):
      if timelineRemovals[id: id] == nil { clearSelection() }
    case .range(let range, let anchor):
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
    case .none: break
    }
  }
}
