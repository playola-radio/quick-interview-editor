import Dependencies
import Foundation
import Observation

/// Drives first-launch model setup: checks whether the speech models are already
/// installed, and if not downloads them (resumable + checksummed) with progress.
///
/// All display text and derived state live here; the view only renders — see
/// CLAUDE.md's "no logic in views" rule.
@MainActor
@Observable
final class ModelSetupModel: ViewModel {

  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.modelDownloader) var modelDownloader

  // MARK: - Manifest
  let manifest: ModelManifest

  // MARK: - Phase
  enum Phase: Equatable {
    case checking
    case downloading(ModelDownloadProgress)
    case ready(ModelInstallation)
    case failed(String)
  }

  // MARK: - Properties
  var phase: Phase = .checking
  @ObservationIgnored private var task: Task<Void, Never>?
  /// Fired once models are installed, so the app can move on to import.
  @ObservationIgnored var onReady: ((ModelInstallation) -> Void)?

  // MARK: - Initialization
  init(manifest: ModelManifest = .current) {
    self.manifest = manifest
    super.init()
  }

  // MARK: - Display Text
  let title = "Setting up transcription"
  let subtitle =
    "A one-time download of the on-device speech models used to transcribe your interviews. "
    + "They're stored on your Mac; nothing is uploaded."
  let checkingMessage = "Checking for installed models…"
  let readyMessage = "Models ready."
  let retryButtonLabel = "Try Again"
  let cancelButtonLabel = "Cancel"

  // MARK: - View Helpers
  var isChecking: Bool { phase == .checking }
  var isDownloading: Bool {
    if case .downloading = phase { return true }
    return false
  }
  var isReady: Bool {
    if case .ready = phase { return true }
    return false
  }
  var showsProgressBar: Bool { isDownloading }
  var showsCancel: Bool { isDownloading }
  var showsRetry: Bool { errorMessage != nil }

  /// 0…1 for a determinate progress bar.
  var progressFraction: Double {
    if case .downloading(let progress) = phase { return progress.fractionCompleted }
    return 0
  }

  /// The line under the title: what's happening right now.
  var statusMessage: String {
    switch phase {
    case .checking: return checkingMessage
    case .downloading(let progress):
      let percent = Int((progress.fractionCompleted * 100).rounded())
      let done = Self.byteFormatter.string(fromByteCount: progress.completedBytes)
      let total = Self.byteFormatter.string(fromByteCount: progress.totalBytes)
      let file = progress.currentFileName.isEmpty ? "" : " · \(progress.currentFileName)"
      return "Downloading \(done) of \(total) (\(percent)%)\(file)"
    case .ready: return readyMessage
    case .failed(let message): return message
    }
  }

  var errorMessage: String? {
    if case .failed(let message) = phase { return message }
    return nil
  }

  /// Whether the status line should read as an error (drives its color).
  var statusIsError: Bool { errorMessage != nil }

  // MARK: - User Actions
  func viewAppeared() async {
    // Already installed (verified) — skip straight through.
    if let installed = modelDownloader.installedLocation(manifest) {
      phase = .ready(installed)
      onReady?(installed)
      return
    }
    await runDownload()
  }

  func retryTapped() async {
    await runDownload()
  }

  func cancelTapped() {
    task?.cancel()
    phase = .failed("Download cancelled. \(retryButtonLabel) to resume.")
  }

  // MARK: - Private Helpers
  private func runDownload() async {
    task?.cancel()
    phase = .downloading(
      ModelDownloadProgress(
        completedBytes: 0, totalBytes: manifest.totalByteCount, currentFileName: ""))
    do {
      for try await event in modelDownloader.download(manifest) {
        switch event {
        case .progress(let progress):
          phase = .downloading(progress)
        case .completed(let installation):
          phase = .ready(installation)
          onReady?(installation)
        }
      }
    } catch is CancellationError {
      // cancelTapped() already set the phase; nothing to do.
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  private static let byteFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useGB, .useMB]
    return formatter
  }()
}
