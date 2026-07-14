import Foundation

/// App-owned cache of canonical PCM AIFFs — one per transcription job.
///
/// The engine's `plan` step writes a canonical `<stem>.plan.aiff` into its scratch
/// dir (which is deleted right after). Before that deletion we copy it here so a
/// single file can back the waveform, playback, and render for the whole editing
/// session. This data is **derived, large, and rebuildable**, so it lives under
/// `Caches` (not Application Support): `Caches/Quick Interview Editor/Canonical/
/// <jobID>/canonical.aiff`.
///
/// Lifecycle: created during transcription (``store(planAIFF:in:)``), owned by the
/// editor and removed on tab close (``remove(_:in:)``), and any dirs left by a prior
/// run are pruned at launch (``pruneAll(in:)``) — at launch no editor references any
/// of them, so all are stale.
enum CanonicalAudioStore {

  /// The fixed file name inside each per-job dir.
  static let fileName = "canonical.aiff"

  /// `Caches/Quick Interview Editor/Canonical`. Created on demand.
  static func baseDirectory() throws -> URL {
    try FileManager.default.url(
      for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    )
    .appendingPathComponent("Quick Interview Editor/Canonical")
  }

  /// Copies `planAIFF` into a fresh per-job dir and returns the cached AIFF's URL.
  /// Must be called while the engine's scratch dir still exists (before it's deleted).
  static func store(planAIFF: URL, in base: URL? = nil) throws -> URL {
    let base = try base ?? baseDirectory()
    let dir = base.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let dest = dir.appendingPathComponent(fileName)
    try? FileManager.default.removeItem(at: dest)
    try FileManager.default.copyItem(at: planAIFF, to: dest)
    return dest
  }

  /// Removes one job's canonical dir (the parent of `canonicalAudioURL`). Guarded to
  /// only ever delete inside our own cache, so a URL that somehow points elsewhere
  /// (e.g. a raw source file) can never take its folder with it.
  static func remove(_ canonicalAudioURL: URL, in base: URL? = nil) {
    guard let base = try? (base ?? baseDirectory()) else { return }
    let dir = canonicalAudioURL.deletingLastPathComponent()
    guard
      dir.deletingLastPathComponent().standardizedFileURL == base.standardizedFileURL
    else { return }
    try? FileManager.default.removeItem(at: dir)
  }

  /// Removes every cached canonical dir. Called at launch, when nothing references
  /// any prior-run dir.
  static func pruneAll(in base: URL? = nil) {
    guard let base = try? (base ?? baseDirectory()) else { return }
    try? FileManager.default.removeItem(at: base)
  }
}
