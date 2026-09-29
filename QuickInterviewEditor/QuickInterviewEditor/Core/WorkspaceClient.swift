import AppKit
import Dependencies
import Foundation
import IssueReporting

/// Wraps the user-facing filesystem side effects (choose an export folder, reveal
/// files in Finder) so the export flow is testable with no real panels or Finder.
struct WorkspaceClient: Sendable {
  /// Prompt for a destination directory. Returns nil if the user cancels.
  var chooseDirectory: @Sendable () async -> URL?
  var chooseDirectoryNear: @Sendable (URL?, String, String) async -> URL?
  var createDirectory: @Sendable (URL) throws -> Void
  var open: @Sendable (URL) -> Void
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
    chooseDirectoryNear: { suggested, prompt, message in
      await MainActor.run {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        panel.message = message
        if var directory = suggested {
          var isDirectory: ObjCBool = false
          while !FileManager.default.fileExists(
            atPath: directory.path, isDirectory: &isDirectory) || !isDirectory.boolValue
          {
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
          }
          panel.directoryURL = directory
        }
        return panel.runModal() == .OK ? panel.url : nil
      }
    },
    createDirectory: { url in
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    },
    open: { _ = NSWorkspace.shared.open($0) },
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
    chooseDirectoryNear: { _, _, _ in
      reportIssue("WorkspaceClient.chooseDirectoryNear called without a test override")
      return nil
    },
    createDirectory: { _ in
      reportIssue("WorkspaceClient.createDirectory called without a test override")
    },
    open: { _ in reportIssue("WorkspaceClient.open called without a test override") },
    reveal: { _ in
      reportIssue("WorkspaceClient.reveal called without a test override")
    }
  )

  static let previewValue = WorkspaceClient(
    chooseDirectory: { nil },
    chooseDirectoryNear: { _, _, _ in nil },
    createDirectory: { _ in },
    open: { _ in },
    reveal: { _ in }
  )
}

extension DependencyValues {
  var workspace: WorkspaceClient {
    get { self[WorkspaceClient.self] }
    set { self[WorkspaceClient.self] = newValue }
  }
}
