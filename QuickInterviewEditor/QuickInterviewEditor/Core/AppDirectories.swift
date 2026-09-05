import Foundation

/// Single source of truth for the app's on-disk folder names in Application Support
/// and Caches, plus a one-time migration from the pre-rename folders to the unified
/// `Playola Interview Editor` name.
///
/// Before the Playola rename (PR 0) the app scattered its data under three
/// inconsistent names: `Application Support/QuickInterviewEditor` (TranscriptCache +
/// Projects), `Application Support/Quick Interview Editor` (Logs + cut-suggest
/// caches + scratch), and `Caches/Quick Interview Editor` (canonical audio). This
/// consolidates all of them under one name that matches the app's display name, and
/// migrates a returning user's existing data by moving it (atomic + instant on the
/// same volume, regardless of size) rather than copying.
enum AppDirectories {
  /// The unified on-disk folder name, matching the app's display name.
  static let folderName = "Playola Interview Editor"

  /// Pre-rename Application Support folder names a returning user may still have on
  /// disk. Ordered so the folder with the valuable data (`QuickInterviewEditor`:
  /// cache + irreplaceable Projects) migrates first via the fast atomic-rename path.
  static let legacyApplicationSupportNames = ["QuickInterviewEditor", "Quick Interview Editor"]

  /// Pre-rename Caches folder name.
  static let legacyCachesNames = ["Quick Interview Editor"]

  /// One-time move of any legacy folders to the unified name, in both Application
  /// Support and Caches. Idempotent and cheap to call at every launch: each move is
  /// a no-op once done. Must run before any store reads these folders.
  static func migrateLegacyFolders(fileManager fm: FileManager = .default) {
    if let appSupport = try? fm.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    {
      migrate(
        parent: appSupport, legacyNames: legacyApplicationSupportNames, newName: folderName,
        fileManager: fm)
    }
    if let caches = try? fm.url(
      for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    {
      migrate(parent: caches, legacyNames: legacyCachesNames, newName: folderName, fileManager: fm)
    }
  }

  /// Moves each existing legacy folder under `parent` into `parent/newName`. When the
  /// destination doesn't exist yet, the whole legacy folder is renamed in one atomic
  /// move; when it does (a second legacy root, or a partially-completed prior run),
  /// its contents are deep-merged in (see ``mergeContents(of:into:fileManager:)``).
  /// If the atomic rename fails (e.g. a concurrent launch created the destination
  /// first), it falls through to the same merge rather than stranding the legacy root.
  /// Exposed for testing against a temp `parent`.
  static func migrate(
    parent: URL,
    legacyNames: [String],
    newName: String,
    fileManager fm: FileManager = .default
  ) {
    let new = parent.appending(component: newName, directoryHint: .isDirectory)
    for legacy in legacyNames where legacy != newName {
      let old = parent.appending(component: legacy, directoryHint: .isDirectory)
      var isDir: ObjCBool = false
      guard fm.fileExists(atPath: old.path, isDirectory: &isDir), isDir.boolValue else { continue }

      if !fm.fileExists(atPath: new.path) {
        // Fast path: no destination yet — one atomic rename carries everything. On
        // failure, fall through to the per-child merge instead of stranding the root.
        if (try? fm.moveItem(at: old, to: new)) != nil { continue }
      }

      // Destination exists (or the atomic rename failed) — deep-merge the legacy
      // contents in, then drop the emptied legacy folder. Ensure the destination
      // exists first, so the rename-failed fallback doesn't move children into a
      // missing directory (createDirectory is a no-op when it already exists).
      try? fm.createDirectory(at: new, withIntermediateDirectories: true)
      mergeContents(of: old, into: new, fileManager: fm)
    }
  }

  /// Recursively moves every entry under `source` into `destination`. A destination
  /// entry that doesn't exist yet is moved in wholesale; when both sides hold a folder
  /// of the same name it recurses (so nested legacy data is never stranded behind a
  /// pre-existing destination subfolder — the shallow-merge data-loss trap); any leaf
  /// collision keeps the destination entry untouched (never clobbers newer data).
  /// Emptied source folders are removed bottom-up; a folder that still holds a colliding
  /// leaf is left in place.
  private static func mergeContents(
    of source: URL, into destination: URL, fileManager fm: FileManager
  ) {
    let children =
      (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? []
    for child in children {
      let dest = destination.appending(component: child.lastPathComponent)
      if !fm.fileExists(atPath: dest.path) {
        try? fm.moveItem(at: child, to: dest)
        continue
      }
      var childIsDir: ObjCBool = false
      var destIsDir: ObjCBool = false
      fm.fileExists(atPath: child.path, isDirectory: &childIsDir)
      fm.fileExists(atPath: dest.path, isDirectory: &destIsDir)
      if childIsDir.boolValue && destIsDir.boolValue {
        mergeContents(of: child, into: dest, fileManager: fm)
      }
      // Otherwise a leaf collision: keep the destination entry, leave the legacy copy.
    }
    if let remaining = try? fm.contentsOfDirectory(atPath: source.path), remaining.isEmpty {
      try? fm.removeItem(at: source)
    }
  }
}
