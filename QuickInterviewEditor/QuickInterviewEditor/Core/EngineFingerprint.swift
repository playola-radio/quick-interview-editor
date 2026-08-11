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
  static func compute(
    launch: EngineLaunch,
    pythonFiles: (URL) -> [URL],
    contentHash: (URL) -> String?
  ) -> String {
    if launch.isBundled {
      return "engine:bin:\(contentHash(launch.executable) ?? "missing")"
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
