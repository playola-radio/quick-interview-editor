import SwiftUI

/// Replaces the Edit menu's Undo/Redo with the focused editor's chronological `EditorHistory`
/// (spec A7): ⌘Z / ⇧⌘Z route to `EditorModel.undoTapped()/redoTapped()`, never to the
/// document's `UndoManager` (which only carries dirtiness). All decisions live on the model.
struct EditUndoCommands: Commands {
  @FocusedValue(\.projectModel) private var project

  var body: some Commands {
    let model = EditUndoCommandsModel(project: project)
    CommandGroup(replacing: .undoRedo) {
      Button(model.undoLabel) { Task { await model.undoTapped() } }
        .keyboardShortcut("z", modifiers: .command)
        .disabled(!model.canUndo)
      Button(model.redoLabel) { Task { await model.redoTapped() } }
        .keyboardShortcut("z", modifiers: [.command, .shift])
        .disabled(!model.canRedo)
    }
  }
}

/// Undo/Redo menu state for whatever project is focused. With no focused project (or no
/// editor yet) the items keep their default labels and are disabled.
@MainActor
struct EditUndoCommandsModel {
  let project: ProjectModel?

  private var editor: EditorModel? { project?.editor }
  private var textEditor: NSTextView? {
    guard let responder = NSApp?.keyWindow?.firstResponder as? NSTextView, responder.isEditable
    else { return nil }
    return responder
  }

  var undoLabel: String {
    textEditor?.undoManager?.undoMenuItemTitle ?? editor?.undoLabel ?? "Undo"
  }
  var redoLabel: String {
    textEditor?.undoManager?.redoMenuItemTitle ?? editor?.redoLabel ?? "Redo"
  }
  var canUndo: Bool {
    textEditor.map { $0.undoManager?.canUndo ?? false } ?? editor?.canUndo ?? false
  }
  var canRedo: Bool {
    textEditor.map { $0.undoManager?.canRedo ?? false } ?? editor?.canRedo ?? false
  }

  func undoTapped() async {
    if let textEditor {
      textEditor.undoManager?.undo()
      return
    }
    await editor?.undoTapped()
  }
  func redoTapped() async {
    if let textEditor {
      textEditor.undoManager?.redo()
      return
    }
    await editor?.redoTapped()
  }
}
