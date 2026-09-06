import SwiftUI

/// File-menu command to re-transcribe the focused project's source ignoring the cache. Reads
/// and acts through `TranscriptionCommandsModel`; no logic lives here.
struct TranscriptionCommands: Commands {
  @FocusedValue(\.projectModel) private var project

  var body: some Commands {
    let model = TranscriptionCommandsModel(project: project)
    CommandGroup(after: .newItem) {
      Button(model.reimportMenuLabel) { Task { await model.reimportTapped() } }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(!model.canReimport)
    }
  }
}

@MainActor
struct TranscriptionCommandsModel {
  let project: ProjectModel?

  var reimportMenuLabel: String { project?.reimportMenuLabel ?? "Re-import (Ignore Cache)" }
  var canReimport: Bool { project?.canReimport ?? false }

  func reimportTapped() async { await project?.reimportIgnoringCacheTapped() }
}
