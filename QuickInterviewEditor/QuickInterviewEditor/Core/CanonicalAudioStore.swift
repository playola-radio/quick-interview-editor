import Foundation

/// App-owned cache of canonical PCM AIFFs — one per transcription job.
///
/// The engine's `plan` step writes a canonical `<stem>.plan.aiff` into its scratch
/// dir (which is deleted right after). Before that deletion we copy it here so a
/// single file can back the waveform, playback, and render for the whole editing
/// session. This data is **derived, large, and rebuildable**, so it lives under
/// `Caches` (not Application Support): `Caches/Playola Interview Editor/Canonical/
/// <jobID>/canonical.aiff`.
///
/// Lifecycle: created during transcription (``store(planAIFF:in:)``), owned by the
/// editor and removed on tab close (``remove(_:in:)``), and any dirs left by a
/// crashed or force-quit run are reaped once they age out (``reapStale(olderThan:in:now:)``).
///
/// Reaping is age-based, NOT a blanket wipe, because a launch can overlap a still-running
/// instance — the auto-update relaunch, the relocation's deliberate second instance
/// (`InstallLocation`, `createsNewApplicationInstance = true`), or a manual double-launch.
/// A blanket prune at launch would delete the canonical audio the *other* instance is
/// actively editing, stranding its next export. A just-imported dir is far younger than the
/// cutoff, so in practice a launch never reaps another instance's working audio.
///
/// The known gap: a job dir's mtime reflects when it was written, not when it was last used,
/// so a session left open PAST the cutoff (days) could still be reaped by another instance's
/// launch. We accept that over a lock/heartbeat ownership scheme: the window is days, not the
/// seconds-long relaunch overlap that caused the original bug, and export re-checks the file
/// before rendering. Revisit with per-process ownership if long-lived sessions prove common.
enum CanonicalAudioStore {

  /// The fixed file name inside each per-job dir.
  static let fileName = "canonical.aiff"

  /// `Caches/Playola Interview Editor/Canonical`. Created on demand.
  static func baseDirectory() throws -> URL {
    try FileManager.default.url(
      for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    )
    .appendingPathComponent("\(AppDirectories.folderName)/Canonical")
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

  /// Default reap cutoff: a week. A live editor's canonical dir is minted fresh at import,
  /// so a dir untouched for a week belongs only to a session that is long gone.
  static let staleAfter: TimeInterval = 7 * 24 * 60 * 60

  /// Reaps per-job dirs untouched for at least `maxAge` — leftovers from a crashed or
  /// force-quit run whose editor never got to call ``remove(_:in:)``. Safe to call at
  /// launch even while another instance is running: that instance's canonical audio was
  /// minted moments ago, so it is far younger than `maxAge` and is left alone. A dir whose
  /// age can't be read is kept, so a transient stat error never deletes live work.
  static func reapStale(
    olderThan maxAge: TimeInterval = staleAfter, in base: URL? = nil, now: Date = Date()
  ) {
    guard let base = try? (base ?? baseDirectory()) else { return }
    let fm = FileManager.default
    guard
      let dirs = try? fm.contentsOfDirectory(
        at: base, includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles])
    else { return }
    for dir in dirs {
      guard
        let modified = try? dir.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate
      else { continue }
      if now.timeIntervalSince(modified) > maxAge {
        try? fm.removeItem(at: dir)
      }
    }
  }
}
