import CustomDump
import Testing

@testable import QuickInterviewEditor

struct UndoStackTests {

  @Test func recordUndoRedoRoundTrips() {
    var stack = UndoStack<Int>()
    stack.record(before: 0, after: 1)
    stack.record(before: 1, after: 2)
    expectNoDifference(stack.canUndo, true)
    expectNoDifference(stack.canRedo, false)

    expectNoDifference(stack.undo(current: 2), 1)
    expectNoDifference(stack.undo(current: 1), 0)
    expectNoDifference(stack.canUndo, false)

    expectNoDifference(stack.redo(current: 0), 1)
    expectNoDifference(stack.redo(current: 1), 2)
    expectNoDifference(stack.canRedo, false)
  }

  @Test func undoAtBottomReturnsNil() {
    var stack = UndoStack<Int>()
    expectNoDifference(stack.undo(current: 0), nil)
  }

  @Test func redoAtTopReturnsNil() {
    var stack = UndoStack<Int>()
    stack.record(before: 0, after: 1)
    expectNoDifference(stack.redo(current: 1), nil)
  }

  @Test func recordIsNoOpWhenUnchanged() {
    var stack = UndoStack<Int>()
    stack.record(before: 5, after: 5)
    expectNoDifference(stack.canUndo, false)
    expectNoDifference(stack.undo(current: 5), nil)
  }

  @Test func newRecordClearsRedo() {
    var stack = UndoStack<Int>()
    stack.record(before: 0, after: 1)
    _ = stack.undo(current: 1)
    expectNoDifference(stack.canRedo, true)

    stack.record(before: 0, after: 9)
    expectNoDifference(stack.canRedo, false)
    expectNoDifference(stack.redo(current: 9), nil)
  }

  @Test func editAfterUndoTruncatesRedoBranch() {
    var stack = UndoStack<Int>()
    stack.record(before: 0, after: 1)
    stack.record(before: 1, after: 2)
    _ = stack.undo(current: 2)  // back to 1, redo has [2]
    _ = stack.undo(current: 1)  // back to 0, redo has [2, 1]

    stack.record(before: 0, after: 42)  // new branch
    expectNoDifference(stack.canRedo, false)
    // The undo history now walks the new branch, not the abandoned one.
    expectNoDifference(stack.undo(current: 42), 0)
  }

  @Test func limitEvictsOldestUndoEntries() {
    var stack = UndoStack<Int>()
    stack.limit = 2
    stack.record(before: 0, after: 1)
    stack.record(before: 1, after: 2)
    stack.record(before: 2, after: 3)  // evicts the oldest (before: 0)

    expectNoDifference(stack.undo, [1, 2])
    expectNoDifference(stack.undo(current: 3), 2)
    expectNoDifference(stack.undo(current: 2), 1)
    expectNoDifference(stack.undo(current: 1), nil)  // can only step back `limit` times
  }
}
