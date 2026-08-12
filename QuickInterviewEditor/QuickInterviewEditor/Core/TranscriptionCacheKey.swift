import CryptoKit
import Foundation

/// Derives the transcript-cache key. Combines the source content fingerprint, the
/// engine fingerprint, and a schema version so any of the three changing yields a
/// different cache entry. Returns `nil` for non-`sha256:` fingerprints (unreadable
/// bytes) — a `path:` key could serve a stale transcript for a different file that
/// later occupies the same path, so those imports bypass the cache entirely.
enum TranscriptionCacheKey {
  // Cache-KEY schema; distinct from TranscriptCache.schemaVersion (on-disk manifest schema).
  static let schemaVersion = "1"

  static func make(sourceFingerprint: String, engineFingerprint: String) -> String? {
    guard sourceFingerprint.hasPrefix("sha256:") else { return nil }
    let material = sourceFingerprint + "\n" + engineFingerprint + "\n" + schemaVersion
    let digest = SHA256.hash(data: Data(material.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
