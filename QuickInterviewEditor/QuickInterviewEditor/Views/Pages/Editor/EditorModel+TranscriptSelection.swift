import Foundation

extension EditorModel {
  func wireTranscriptInteractions() {
    transcript.overlap.sampleRate = editPlan.source.sampleRate
    transcript.overlap.onChoose = { [weak self] id in self?.selectTranscriptObject(id) }
    cutSuggestions.onBandsVisibilityChanged = { [weak self] in self?.reconcileTranscriptOverlap() }
    cutSuggestions.onOpenSuggestion = { [weak self] suggestion in
      self?.cutSuggestionSelected(suggestion)
      self?.openSelectionTapped()
    }
    transcript.onGroupClick = { [weak self] click in self?.transcriptClicked(click) }
  }

  func cutSuggestionSelected(_ suggestion: CutSuggestion) {
    if suggestion.isPending {
      selectTranscriptObject(.suggestion(suggestion.id), fromSidebar: true)
    } else if suggestion.isAccepted, slices[id: suggestion.id] != nil {
      selectTranscriptObject(.clip(suggestion.id), fromSidebar: true)
    } else {
      revealWords(suggestion.wordIDs)
    }
  }

  func sliceRevealTapped(_ id: Slice.ID) {
    selectTranscriptObject(.clip(id), fromSidebar: true)
  }

  var transcriptObjects: [TranscriptObject] {
    // Read the document even on a cache hit so Observation tracks live replacements.
    _ = slices
    _ = documentCutSuggestions
    if let transcriptObjectCache { return transcriptObjectCache }
    let objects = buildTranscriptObjects()
    transcriptObjectCache = objects
    return objects
  }

  private func buildTranscriptObjects() -> [TranscriptObject] {
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
    return transcriptObjects.first { $0.id == id }
  }

  func selectTranscriptObject(_ id: TranscriptObjectID, fromSidebar: Bool = false) {
    guard let object = transcriptObjects.first(where: { $0.id == id }) else { return }
    if selection != .object(id) {
      selectSourceRange(object.range, snapPlayhead: true)
      selection = .object(id)
    }
    selectionEditingEdge = nil
    transcript.invalidateSelectionAnchor()
    revealSelectedSidebarObject(id)
    if fromSidebar {
      revealSourceRange(object.range, zoomWaveform: true)
    } else {
      panWaveformToObject(object.range)
    }
  }

  func revealSelectedSidebarObject(_ id: TranscriptObjectID) {
    sidebarReveal = SidebarReveal(objectID: id, token: (sidebarReveal?.token ?? 0) &+ 1)
    switch id {
    case .clip(let clipID):
      if rightPanelTab != .both { rightPanelTab = .slices }
      if !visibleSliceRows.contains(where: { $0.id == clipID }) { sliceFilter = .all }
      sliceScrollTarget = clipID
    case .suggestion:
      cutSuggestions.showsSuggestionBands = true
      if rightPanelTab != .both { rightPanelTab = .suggestions }
    }
    cutSuggestions.sidebarReveal = sidebarReveal
    reconcileTranscriptOverlap()
  }

  private func panWaveformToObject(_ range: Range<Int>) {
    guard editedWaveform.viewportWidth > 0,
      let start = editedTimeline.sourceToEdited(range.lowerBound, bias: .rightEdge),
      let end = editedTimeline.sourceToEdited(range.upperBound, bias: .leftEdge)
    else { return }
    let visibleStart = editedWaveform.visibleStartSample
    let count = editedWaveform.visibleSampleCount
    if start < visibleStart || start >= visibleStart + count {
      editedWaveform.scrolled(toStartEditedSample: start)
    } else if end > visibleStart + count, end - start <= count {
      editedWaveform.scrolled(toStartEditedSample: end - count)
    }
  }

  func reconcileTranscriptOverlap() {
    let click = transcript.overlapClick
    let candidates: [TranscriptObject]
    if let click, let id = click.wordID {
      candidates = visibleTranscriptObjects.filter {
        $0.wordIDs.contains(id) && transcriptHit(click, belongsTo: $0.wordIDs)
      }
    } else {
      candidates = []
    }
    transcript.overlap.update(candidates, anchor: click?.wordID, selected: selection.objectID)
    cutSuggestions.selectedObjectID = selection.objectID
  }

  var visibleTranscriptObjects: [TranscriptObject] {
    let visibleSuggestionIDs = Set(cutSuggestions.pendingSuggestions.map(\.id))
    return foregroundObjects(
      transcriptObjects.filter { object in
        if case .suggestion(let id) = object.id {
          return cutSuggestions.showsSuggestionBands && visibleSuggestionIDs.contains(id)
        }
        return true
      }, selected: selection.objectID)
  }

  var clipBands: [TranscriptClipBand] {
    visibleTranscriptObjects.map { object in
      let id: UUID
      let kind: TranscriptClipKind
      switch object.id {
      case .clip(let value):
        id = value
        kind = .approved
      case .suggestion(let value):
        id = value
        kind = .suggested
      }
      let draft = transcriptResizeDraft
      let isResizing: Bool
      switch (draft?.identity, object.id) {
      case (.clip(let resizingID), .clip(let objectID)),
        (.suggestion(let resizingID), .suggestion(let objectID)):
        isResizing = resizingID == objectID
      default: isResizing = false
      }
      let words = isResizing ? draft!.draftedWordIDs : object.wordIDs.sorted()
      return TranscriptClipBand(
        id: id, wordIDs: words, kind: kind,
        colorIndex: object.colorIndex, isActive: object.id == selection.objectID,
        isPreviewed: object.id == transcript.overlap.previewID,
        isSubdued: selection.objectID != nil && object.id != selection.objectID)
    }
  }

  func transcriptClicked(_ click: TranscriptClick) {
    if click.count == 2 {
      openCapturedTranscriptClick(click)
      return
    }
    guard click.count == 1 else { return }
    transcript.clickCapture = nil
    transcript.overlapClick = click.extending ? nil : click
    defer { reconcileTranscriptOverlap() }
    guard let wordID = click.wordID else {
      clearSelection()
      return
    }
    if click.extending {
      selectWord(wordID, extending: true)
      return
    }
    let candidates = objectsCovering(
      wordID, objects: visibleTranscriptObjects,
      selected: selection.objectID
    ).filter { transcriptHit(click, belongsTo: $0.wordIDs) }
    if selection.freeformRange != nil, transcriptHit(click, belongsTo: selectedWordIDs) {
      // The live freeform highlight is the top click target throughout its extent.
    } else if let object = candidates.first {
      selectTranscriptObject(object.id)
    } else if click.utf16Offset.map({ transcript.document.containsWord(atUTF16Offset: $0) }) ?? true
    {
      selectWord(wordID, extending: false)
    } else {
      clearSelection()
    }
    guard let range = audioSelection else { return }
    transcript.clickCapture = TranscriptClickCapture(
      selection: selection, range: range, timestamp: click.timestamp)
  }

  private func openCapturedTranscriptClick(_ click: TranscriptClick) {
    defer { transcript.clickCapture = nil }
    guard !click.extending, let captured = transcript.clickCapture,
      captured.selection == selection, captured.range == audioSelection,
      click.timestamp >= captured.timestamp,
      click.timestamp - captured.timestamp <= click.doubleClickInterval,
      transcriptHit(
        click, belongsTo: Set(wordIDs(anyOverlap: captured.range, words: editPlan.words)))
    else { return }
    openSelectionTapped()
  }

  private func transcriptHit(_ click: TranscriptClick, belongsTo wordIDs: Set<Word.ID>) -> Bool {
    guard let id = click.wordID, wordIDs.contains(id) else { return false }
    guard let offset = click.utf16Offset else { return true }
    return transcript.document.groupContains(atUTF16Offset: offset, wordIDs: wordIDs)
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
