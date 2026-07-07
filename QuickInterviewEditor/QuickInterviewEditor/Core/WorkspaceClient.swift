import AppKit
import Dependencies
import Foundation
import IssueReporting

/// Wraps the user-facing filesystem side effects (choose an export folder, reveal
/// files in Finder) so the export flow is testable with no real panels or Finder.
struct WorkspaceClient: Sendable {
  /// Prompt for a destination directory. Returns nil if the user cancels.
  var chooseDirectory: @Sendable () async -> URL?
  /// Reveal (select) the given files in Finder.
  var reveal: @Sendable ([URL]) -> Void
}

extension WorkspaceClient: DependencyKey {
  static let liveValue = WorkspaceClient(
    chooseDirectory: {
      await MainActor.run {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for the exported AIFFs"
        return panel.runModal() == .OK ? panel.url : nil
      }
    },
    reveal: { urls in
      guard !urls.isEmpty else { return }
      NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
  )
}

extension WorkspaceClient: TestDependencyKey {
  static let testValue = WorkspaceClient(
    chooseDirectory: {
      reportIssue("WorkspaceClient.chooseDirectory called without a test override")
      return nil
    },
    reveal: { _ in
      reportIssue("WorkspaceClient.reveal called without a test override")
    }
  )

  static let previewValue = WorkspaceClient(
    chooseDirectory: { nil },
    reveal: { _ in }
  )
}

extension DependencyValues {
  var workspace: WorkspaceClient {
    get { self[WorkspaceClient.self] }
    set { self[WorkspaceClient.self] = newValue }
  }
}
