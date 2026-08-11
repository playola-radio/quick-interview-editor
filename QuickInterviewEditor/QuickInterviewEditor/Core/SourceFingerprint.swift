import CryptoKit
import Foundation

/// A stable identity for a source audio file, used to key the per-file project sidecar
/// (`@Shared(.projectState(fingerprint:))`). Content-derived — the SHA256 of the file
/// bytes — so it survives engine re-runs (which rewrite `edit-plan.json` but not the
/// source) and, unlike a path, does not mis-attach a user's saved suggestions when a
/// different file later sits at the same location. Falls back to the standardized path
/// when the bytes can't be read.
enum SourceFingerprint {
  /// Computes the fingerprint off the main actor (hashing can touch a large file).
  static func make(for url: URL) async -> String {
    await Task.detached(priority: .utility) { compute(for: url) }.value
  }

  /// Synchronous fingerprint: `sha256:<hex>` of the file, or `path:<standardized path>`
  /// when unreadable. Memory-maps the file so a large interview isn't loaded whole.
  static func compute(for url: URL) -> String {
    if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
      let digest = SHA256.hash(data: data)
      return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }
    return "path:" + url.standardizedFileURL.path
  }
}
