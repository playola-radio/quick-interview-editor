import CustomDump
import Testing

@testable import PlayolaInterviewEditor

struct EditorHistoryTests {
  @Test func selectionOnlyClearInterleavesWithDocumentHistory() throws {
    var history = EditorHistory<Int, EditorSelection>()
    let selection = EditorSelection.range(100..<300, anchor: 300)
    history.record(
      .init(
        document: .init(before: 1, after: 2), selection: nil, label: "Rename"))
    history.record(
      .init(
        document: nil, selection: .init(before: selection, after: .none),
        label: "Clear Selection"))
    history.rebase { $0 += 10 }
    let clearEntry = history.undoEntry()
    let clear = try #require(clearEntry)
    expectNoDifference(clear.document, nil)
    expectNoDifference(clear.selection?.before, selection)
    let editEntry = history.undoEntry()
    let edit = try #require(editEntry)
    expectNoDifference(edit.document, .init(before: 11, after: 12))
    expectNoDifference(history.redoEntry(), edit)
    expectNoDifference(history.redoEntry(), clear)
  }

  @Test func backgroundChangesRebaseBothBranchesWithoutTouchingSelection() throws {
    var history = EditorHistory<Int, Int>()
    let selection = HistoryChange(before: 8, after: 0)
    history.record(
      .init(
        document: .init(before: 1, after: 2), selection: selection, label: "Delete"))
    _ = history.undoEntry()
    history.rebase { $0 += 10 }
    let redoEntry = history.redoEntry()
    let entry = try #require(redoEntry)
    expectNoDifference(entry.document, .init(before: 11, after: 12))
    expectNoDifference(entry.selection, selection)
  }

  @Test func noOpPreservesRedoAndNewActionInvalidatesIt() {
    var history = EditorHistory<Int, Int>()
    history.record(
      .init(
        document: .init(before: 1, after: 2), selection: nil, label: "Edit"))
    _ = history.undoEntry()
    history.record(
      .init(
        document: .init(before: 1, after: 1), selection: .init(before: 0, after: 0),
        label: "No-op"))
    #expect(history.canRedo)
    #expect(!history.canUndo)
    history.record(
      .init(
        document: nil, selection: .init(before: 0, after: 8), label: "Clear"))
    #expect(!history.canRedo)
    #expect(history.canUndo)
  }

  @Test func historyEvictsOldestEntriesAtLimit() {
    var history = EditorHistory<Int, Int>(limit: 2)
    for value in 1...3 {
      history.record(
        .init(
          document: .init(before: value - 1, after: value), selection: nil, label: "Edit"))
    }
    expectNoDifference(history.undo.count, 2)
    expectNoDifference(history.undoEntry()?.document?.before, 2)
    expectNoDifference(history.undoEntry()?.document?.before, 1)
    expectNoDifference(history.undoEntry(), nil)
    _ = history.redoEntry()
    _ = history.redoEntry()
    expectNoDifference(history.undo.count, 2)
  }

  @Test func zeroLimitNeverRetainsHistory() {
    var history = EditorHistory<Int, Int>(limit: 0)
    history.record(
      .init(
        document: .init(before: 1, after: 2), selection: nil, label: "Edit"))
    #expect(!history.canUndo)
    #expect(!history.canRedo)
  }
}
