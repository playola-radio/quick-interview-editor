import Foundation

/// A two-stack undo/redo history over an `Equatable` value type.
///
/// The owner keeps the live value and hands snapshots in and out: `record` after a
/// mutation, `undo`/`redo` to move through history. Only the value is stored — never
/// selection, playback, or any other model state.
///
/// The undo stack is capped at `limit` (oldest evicted); the redo stack needs no
/// explicit cap because it only grows by undoing, so it can never exceed the undo depth.
struct UndoStack<State: Equatable> {
  private(set) var undo: [State] = []
  private(set) var redo: [State] = []
  /// Maximum entries kept on the undo stack; the oldest are evicted past this.
  var limit = 30

  var canUndo: Bool { !undo.isEmpty }
  var canRedo: Bool { !redo.isEmpty }

  /// Records a completed mutation. A no-op when nothing changed, so identical
  /// before/after snapshots never pollute the history. Any new record starts a fresh
  /// branch, so the redo stack is cleared.
  mutating func record(before old: State, after new: State) {
    guard old != new else { return }
    push(old, onto: &undo)
    redo.removeAll()
  }

  /// Steps back one entry, returning the state to restore (or `nil` at the bottom).
  /// The caller's `current` state is pushed onto the redo stack so the step is reversible.
  mutating func undo(current: State) -> State? {
    guard let previous = undo.popLast() else { return nil }
    redo.append(current)
    return previous
  }

  /// Steps forward one entry, returning the state to restore (or `nil` when there is no
  /// redo branch). The caller's `current` state is pushed back onto the undo stack.
  mutating func redo(current: State) -> State? {
    guard let next = redo.popLast() else { return nil }
    push(current, onto: &undo)
    return next
  }

  /// Appends to a stack, evicting the oldest entries once it exceeds `limit`.
  private func push(_ state: State, onto stack: inout [State]) {
    stack.append(state)
    if stack.count > limit {
      stack.removeFirst(stack.count - limit)
    }
  }
}
