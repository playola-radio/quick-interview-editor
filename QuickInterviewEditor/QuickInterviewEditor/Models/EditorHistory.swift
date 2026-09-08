/// An explicit change lets selection-only history omit the document entirely.
struct HistoryChange<Value: Equatable>: Equatable {
  var before: Value
  var after: Value
}

/// Chronological history of document edits and transient selection actions.
/// Ordinary document edits omit selection so Undo does not rewind navigation.
struct EditorHistory<Document: Equatable, Selection: Equatable> {
  struct Entry: Equatable {
    var document: HistoryChange<Document>?
    var selection: HistoryChange<Selection>?
    var label: String
  }

  private(set) var undo: [Entry] = []
  private(set) var redo: [Entry] = []
  let limit: Int

  init(limit: Int = 30) {
    precondition(limit >= 0, "EditorHistory limit must be non-negative")
    self.limit = limit
  }

  var canUndo: Bool { !undo.isEmpty }
  var canRedo: Bool { !redo.isEmpty }

  mutating func record(_ entry: Entry) {
    let documentChanged = entry.document.map { $0.before != $0.after } ?? false
    let selectionChanged = entry.selection.map { $0.before != $0.after } ?? false
    guard documentChanged || selectionChanged else { return }
    undo.append(entry)
    trimUndo()
    redo.removeAll()
  }

  mutating func undoEntry() -> Entry? {
    guard let entry = undo.popLast() else { return nil }
    redo.append(entry)
    return entry
  }

  mutating func redoEntry() -> Entry? {
    guard let entry = redo.popLast() else { return nil }
    undo.append(entry)
    trimUndo()
    return entry
  }

  /// Background document updates survive navigation through both history branches.
  mutating func rebase(_ transform: (inout Document) -> Void) {
    for index in undo.indices {
      guard var change = undo[index].document else { continue }
      transform(&change.before)
      transform(&change.after)
      undo[index].document = change
    }
    for index in redo.indices {
      guard var change = redo[index].document else { continue }
      transform(&change.before)
      transform(&change.after)
      redo[index].document = change
    }
  }

  private mutating func trimUndo() {
    if undo.count > limit { undo.removeFirst(undo.count - limit) }
  }
}
