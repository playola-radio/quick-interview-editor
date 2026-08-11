import CryptoKit
import Dependencies
import Foundation
import Synchronization

/// A per-process content hash of the transcription engine, folded into the
/// transcription cache key so any engine change auto-invalidates cached results.
///
/// Dev (runs `python -m logic_markers.cli` from the repo root) is defined by the
/// `logic_markers` package plus the dependency pins. Packaged (frozen helper) is
/// defined by the binary's contents. `size+mtime` is deliberately NOT used — it
/// false-hits on a rebuild that changes behavior without changing size/mtime.
enum EngineFingerprint {

  /// The dependency-pin files (relative to the dev repo root) folded in alongside
  /// the Python sources, so a WhisperX/dep bump also invalidates.
  static let pinFiles = ["requirements.txt", "pyproject.toml"]

  private static let cached = Mutex<String?>(nil)

  /// Memoized once per app launch (hashing the packaged binary can take ~1s).
  static func current(launch: EngineLaunch = LiveEngine.resolvedLaunch()) -> String {
    cached.withLock { stored in
      if let stored { return stored }
      let value = compute(
        launch: launch,
        pythonFiles: { pythonFiles(under: $0) },
        contentHash: { sha256OfFile($0) })
      stored = value
      return value
    }
  }

  /// Pure core with filesystem access injected, so it unit-tests without disk.
  ///
  /// Packaged (`launch.isBundled`): PyInstaller ONE-FOLDER ships the launcher
  /// executable beside `_internal/`, which holds the actual Python code, native
  /// libs, and package data. A rebuild can change `_internal/` without changing
  /// the launcher, so hashing only the launcher under-invalidates (a stale cache
  /// hit on a real engine change). This folds in: the launcher's content hash,
  /// a stat-only (relativePath, size) digest of every file under the engine dir
  /// (content hashing would mean reading a multi-gigabyte tree on every launch),
  /// the app version, and the pinned model identity. Over-invalidation (an extra
  /// re-transcribe) is safe; under-invalidation (a stale hit) is the hazard this
  /// guards against — a real engine or model change cannot collapse to the same
  /// fingerprint in practice.
  static func compute(
    launch: EngineLaunch,
    pythonFiles: (URL) -> [URL],
    contentHash: (URL) -> String?,
    engineTree: (URL) -> [(relativePath: String, size: Int64)] = { engineTreeSizes(under: $0) },
    modelIdentity: String = ModelManifest.current.fingerprintIdentity,
    appVersion: String = bundleVersionIdentity()
  ) -> String {
    if launch.isBundled {
      let engineDir = launch.executable.deletingLastPathComponent()
      var entries: [String] = ["exe:\(contentHash(launch.executable) ?? "missing")"]
      for entry in engineTree(engineDir).sorted(by: { $0.relativePath < $1.relativePath }) {
        entries.append("\(entry.relativePath):\(entry.size)")
      }
      entries.append("app:\(appVersion)")
      entries.append("models:\(modelIdentity)")
      let digest = SHA256.hash(data: Data(entries.joined(separator: "\n").utf8))
      return "engine:bin:" + digest.map { String(format: "%02x", $0) }.joined()
    }
    let root = launch.workingDirectory
    let pkg = root.appendingPathComponent("logic_markers")
    var entries: [String] = []
    for file in pythonFiles(pkg).sorted(by: { $0.path < $1.path }) {
      let rel = String(file.path.dropFirst(root.path.count + 1))
      entries.append("\(rel):\(contentHash(file) ?? "missing")")
    }
    for pin in pinFiles {
      let url = root.appendingPathComponent(pin)
      entries.append("\(pin):\(contentHash(url) ?? "missing")")
    }
    let digest = SHA256.hash(data: Data(entries.joined(separator: "\n").utf8))
    return "engine:src:" + digest.map { String(format: "%02x", $0) }.joined()
  }

  // MARK: - Filesystem

  private static func pythonFiles(under dir: URL) -> [URL] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else { return [] }
    return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "py" }
  }

  private static func sha256OfFile(_ url: URL) -> String? {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// Stat-only (never content-reading) enumeration of every file under the
  /// packaged engine directory, relative to `dir`. The `_internal/` tree can be
  /// gigabytes, so this uses `.fileSizeKey` rather than hashing bytes.
  static func engineTreeSizes(under dir: URL) -> [(relativePath: String, size: Int64)] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
    else { return [] }
    var results: [(relativePath: String, size: Int64)] = []
    for case let url as URL in enumerator {
      guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
      else { continue }
      let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
      let relativePath =
        url.path.hasPrefix(dir.path)
        ? String(url.path.dropFirst(dir.path.count + 1))
        : url.path
      results.append((relativePath: relativePath, size: size))
    }
    return results
  }
}

/// `"<CFBundleShortVersionString>-<CFBundleVersion>"` from the app's own Info
/// dictionary, folded into the packaged fingerprint so an app rebuild that
/// bumps the shipped engine also invalidates cached transcripts.
func bundleVersionIdentity() -> String {
  let info = Bundle.main.infoDictionary
  let shortVersion = info?["CFBundleShortVersionString"] as? String ?? "?"
  let buildVersion = info?["CFBundleVersion"] as? String ?? "?"
  return "\(shortVersion)-\(buildVersion)"
}

// MARK: - EngineFingerprintClient

struct EngineFingerprintClient: Sendable {
  var current: @Sendable () -> String
}

extension EngineFingerprintClient: DependencyKey {
  static let liveValue = EngineFingerprintClient(current: { EngineFingerprint.current() })
}

extension EngineFingerprintClient: TestDependencyKey {
  static let testValue = EngineFingerprintClient(current: { "engine:test" })
}

extension DependencyValues {
  var engineFingerprint: EngineFingerprintClient {
    get { self[EngineFingerprintClient.self] }
    set { self[EngineFingerprintClient.self] = newValue }
  }
}
