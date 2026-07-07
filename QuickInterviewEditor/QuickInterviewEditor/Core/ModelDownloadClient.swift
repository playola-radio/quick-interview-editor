import Dependencies
import Foundation
import IssueReporting

// MARK: - Events

/// Progress across the whole manifest (all files summed), plus the file in flight.
struct ModelDownloadProgress: Equatable, Sendable {
  var completedBytes: Int64
  var totalBytes: Int64
  var currentFileName: String

  var fractionCompleted: Double {
    totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0
  }
}

enum ModelDownloadEvent: Equatable, Sendable {
  case progress(ModelDownloadProgress)
  case completed(ModelInstallation)
}

// MARK: - ModelDownloadClient

/// Side-effecting boundary for first-launch model download. Injecting it keeps
/// ``ModelSetupModel`` fully testable with no network and no filesystem.
struct ModelDownloadClient: Sendable {
  /// The installed models iff **every** manifest file is present and its SHA-256
  /// matches; `nil` otherwise (never downloaded, or a partial/corrupt install).
  var installedLocation: @Sendable (ModelManifest) -> ModelInstallation?

  /// Downloads every missing/mismatched file — resumable (HTTP Range) and
  /// SHA-256 verified — streaming aggregate progress, then the installation.
  var download: @Sendable (ModelManifest) -> AsyncThrowingStream<ModelDownloadEvent, Error>
}

extension ModelDownloadClient: DependencyKey {
  static let liveValue = ModelDownloadClient(
    installedLocation: { manifest in LiveModelDownloader.installedLocation(manifest) },
    download: { manifest in LiveModelDownloader.download(manifest) }
  )
}

extension ModelDownloadClient: TestDependencyKey {
  static let testValue = ModelDownloadClient(
    installedLocation: { _ in
      reportIssue("ModelDownloadClient.installedLocation called without a test override")
      return nil
    },
    download: { _ in
      AsyncThrowingStream { continuation in
        reportIssue("ModelDownloadClient.download called without a test override")
        continuation.finish(throwing: ModelDownloadError.unimplemented)
      }
    }
  )
}

extension DependencyValues {
  var modelDownloader: ModelDownloadClient {
    get { self[ModelDownloadClient.self] }
    set { self[ModelDownloadClient.self] = newValue }
  }
}

// MARK: - Errors

enum ModelDownloadError: Error, Equatable, LocalizedError {
  case unimplemented
  case checksumMismatch(file: String, expected: String, actual: String)
  case httpError(file: String, status: Int)
  case incompleteDownload(file: String, expected: Int64, actual: Int64)

  // Surfaced to the user via `error.localizedDescription` (e.g. ModelSetupModel's
  // failed phase), so give an actionable message instead of the enum's default.
  var errorDescription: String? {
    switch self {
    case .unimplemented:
      return "The model downloader was used without a live implementation."
    case .checksumMismatch(let file, _, _):
      return "\(file) failed its checksum after downloading. It may be corrupted; try again."
    case .httpError(let file, let status):
      return "Downloading \(file) failed (HTTP \(status)). Check your connection and try again."
    case .incompleteDownload(let file, let expected, let actual):
      return "\(file) downloaded incompletely (\(actual) of \(expected) bytes). Try again."
    }
  }
}
