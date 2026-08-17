import SwiftUI

/// "Check for Updates…" under the app menu. All behavior lives on the model; the
/// view only binds the label, action, and enabled state.
struct UpdaterCommands: Commands {
  @State private var model = UpdaterCommandsModel()

  var body: some Commands {
    CommandGroup(after: .appInfo) {
      Button(model.checkForUpdatesLabel) { model.checkForUpdatesTapped() }
        .disabled(!model.canCheckForUpdates)
    }
  }
}
