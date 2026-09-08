import Foundation

extension EditorModel {
  var transcriptObjects: [TranscriptObject] {
    var objects = slices.enumerated().compactMap { index, slice in
      transcriptObject(for: slice, colorIndex: index)
    }
    let transcriptHash = editPlan.transcriptHash
    for (index, suggestion) in documentCutSuggestions.pending.enumerated() {
      if let object = transcriptObject(
        for: suggestion, colorIndex: slices.count + index, transcriptHash: transcriptHash)
      {
        objects.append(object)
      }
    }
    return objects
  }

  var selectedTranscriptObject: TranscriptObject? {
    guard let id = selection.objectID else { return nil }
    return transcriptObject(id)
  }

  func selectTranscriptObject(_ id: TranscriptObjectID) {
    guard transcriptObject(id) != nil else { return }
    selection = .object(id)
    selectionEditingEdge = nil
    transcript.invalidateSelectionAnchor()
    sidebarReveal = SidebarReveal(objectID: id, token: (sidebarReveal?.token ?? 0) &+ 1)
    switch id {
    case .clip(let clipID):
      if rightPanelTab != .both { rightPanelTab = .slices }
      sliceScrollTarget = clipID
    case .suggestion:
      if rightPanelTab != .both { rightPanelTab = .suggestions }
    }
  }

  private func transcriptObject(_ id: TranscriptObjectID) -> TranscriptObject? {
    switch id {
    case .clip(let id):
      guard let index = slices.index(id: id) else { return nil }
      return transcriptObject(for: slices[index], colorIndex: index)
    case .suggestion(let id):
      let suggestions = documentCutSuggestions.pending
      guard let index = suggestions.firstIndex(where: { $0.id == id }) else { return nil }
      return transcriptObject(
        for: suggestions[index], colorIndex: slices.count + index,
        transcriptHash: editPlan.transcriptHash)
    }
  }

  private func transcriptObject(for slice: Slice, colorIndex: Int) -> TranscriptObject? {
    guard slice.startSample >= 0, slice.startSample < slice.endSample,
      slice.endSample <= editPlan.source.durationSamples
    else { return nil }
    let range = slice.startSample..<slice.endSample
    return TranscriptObject(
      id: .clip(slice.id), name: slice.name, range: range,
      wordIDs: Set(wordIDs(anyOverlap: range, words: editPlan.words)), colorIndex: colorIndex)
  }

  private func transcriptObject(
    for suggestion: CutSuggestion, colorIndex: Int, transcriptHash: String
  ) -> TranscriptObject? {
    guard
      case .accepted(let resolved, _) = PlayolaInterviewEditor.acceptCutSuggestion(
        suggestion.id, in: ProjectState(cutSuggestions: [suggestion]), plan: editPlan,
        sourceFingerprint: sourceFingerprint, transcriptHash: transcriptHash)
    else { return nil }
    let range = resolved.startSample..<resolved.endSample
    return TranscriptObject(
      id: .suggestion(suggestion.id), name: resolved.name, range: range,
      wordIDs: Set(wordIDs(anyOverlap: range, words: editPlan.words)), colorIndex: colorIndex)
  }
}
