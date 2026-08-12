import SwiftUI

/// File-menu commands for the transcription cache. Reads/acts through `RootModel`;
/// no logic lives here beyond binding the menu item to the model.
struct TranscriptionCommands: Commands {
  let root: RootModel

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button(root.reimportMenuLabel) { root.reimportSelectedTabIgnoringCache() }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(!root.canReimportSelectedTab)
    }
  }
}
