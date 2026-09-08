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

  var undoLabel: String { editor?.undoLabel ?? "Undo" }
  var redoLabel: String { editor?.redoLabel ?? "Redo" }
  var canUndo: Bool { editor?.canUndo ?? false }
  var canRedo: Bool { editor?.canRedo ?? false }

  func undoTapped() async { await editor?.undoTapped() }
  func redoTapped() async { await editor?.redoTapped() }
}
