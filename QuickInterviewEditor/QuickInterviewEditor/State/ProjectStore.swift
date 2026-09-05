import CryptoKit
import Foundation
import Sharing

/// Persistence for the per-file project sidecar. The store is a `@Shared`
/// file-storage value keyed by source fingerprint, so it survives engine re-runs
/// (which rewrite `edit-plan.json`) and never bleeds between source files.
///
/// Usage from a model:
/// ```swift
/// @ObservationIgnored
/// @Shared(.projectState(fingerprint: fingerprint)) var projectState
/// ```
/// In tests the `.fileStorage` strategy is backed by an in-memory file system by
/// default, so no real files are written.
extension SharedKey where Self == FileStorageKey<ProjectState>.Default {
  static func projectState(fingerprint: String) -> Self {
    Self[.fileStorage(ProjectState.sidecarURL(fingerprint: fingerprint)), default: ProjectState()]
  }
}

extension ProjectState {
  /// The on-disk sidecar location for a given source fingerprint:
  /// `…/Application Support/Playola Interview Editor/Projects/<sha256>.json`.
  ///
  /// The fingerprint is hashed into a fixed 64-char lowercase-hex filename rather than
  /// used verbatim. That makes the name filename-safe (no path separators can escape
  /// the Projects directory), fixed-length (no OS filename-limit failures), and
  /// case-stable (distinct fingerprints can't alias on case-insensitive APFS).
  static func sidecarURL(fingerprint: String) -> URL {
    let digest = SHA256.hash(data: Data(fingerprint.utf8))
    let name = digest.map { String(format: "%02x", $0) }.joined()
    return
      URL.applicationSupportDirectory
      .appending(component: AppDirectories.folderName, directoryHint: .isDirectory)
      .appending(component: "Projects", directoryHint: .isDirectory)
      .appending(component: "\(name).json", directoryHint: .notDirectory)
  }
}
