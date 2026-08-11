import Dependencies
import Foundation

/// A finished transcription pulled from (or written to) the on-disk cache: the
/// decoded plan plus a **cache-owned** canonical AIFF URL.
struct CachedTranscription: Sendable, Equatable {
  var editPlan: EditPlan
  var canonicalAudioURL: URL
}

/// Persistent, fingerprint-keyed cache of transcription results so a re-import of a
/// byte-identical file is instant. Lives under Application Support (durable) — NOT
/// `Caches` (where `CanonicalAudioStore` keeps its session-scoped, pruned copies).
///
/// Layout: `TranscriptCache/<key>/{plan.json, canonical.aiff, manifest.json}`.
/// The cache owns its own AIFF copy; `CanonicalAudioStore.remove` is guarded to its
/// own base, so tab-close cleanup never deletes a cache-owned file.
enum TranscriptCache {
  static let schemaVersion = 1
  static let planName = "plan.json"
  static let audioName = "canonical.aiff"
  static let manifestName = "manifest.json"

  struct Manifest: Codable, Equatable {
    var schemaVersion: Int
    var key: String
  }

  static func baseDirectory() throws -> URL {
    URL.applicationSupportDirectory
      .appending(component: "QuickInterviewEditor", directoryHint: .isDirectory)
      .appending(component: "TranscriptCache", directoryHint: .isDirectory)
  }

  static func lookup(key: String, base: URL) -> CachedTranscription? {
    let dir = base.appendingPathComponent(key)
    let manifestURL = dir.appendingPathComponent(manifestName)
    let planURL = dir.appendingPathComponent(planName)
    let audioURL = dir.appendingPathComponent(audioName)
    let fm = FileManager.default
    guard
      fm.fileExists(atPath: manifestURL.path),
      fm.fileExists(atPath: planURL.path),
      fm.fileExists(atPath: audioURL.path),
      let manifestData = try? Data(contentsOf: manifestURL),
      let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData),
      manifest.schemaVersion == schemaVersion,
      let plan = try? EditPlan.decoded(from: planURL)
    else { return nil }
    return CachedTranscription(editPlan: plan, canonicalAudioURL: audioURL)
  }

  static func store(key: String, plan: EditPlan, canonicalAudioURL: URL, base: URL) throws
    -> CachedTranscription
  {
    let fm = FileManager.default
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let tmp = base.appendingPathComponent("\(key).tmp.\(UUID().uuidString)")
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }  // no-op once renamed away

    try JSONEncoder().encode(plan).write(to: tmp.appendingPathComponent(planName))
    try fm.copyItem(at: canonicalAudioURL, to: tmp.appendingPathComponent(audioName))
    // Manifest written LAST — its presence is the commit marker a lookup checks.
    let manifest = Manifest(schemaVersion: schemaVersion, key: key)
    try JSONEncoder().encode(manifest).write(to: tmp.appendingPathComponent(manifestName))

    let dest = base.appendingPathComponent(key)
    try? fm.removeItem(at: dest)  // replace any prior entry (force-refresh)
    try fm.moveItem(at: tmp, to: dest)
    return CachedTranscription(
      editPlan: plan, canonicalAudioURL: dest.appendingPathComponent(audioName))
  }

  static func clear(base: URL) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: base.path) { try fm.removeItem(at: base) }
  }

  static func totalSize(base: URL) -> Int64 {
    guard
      let enumerator = FileManager.default.enumerator(
        at: base, includingPropertiesForKeys: [.fileSizeKey], options: [])
    else { return 0 }
    var total: Int64 = 0
    for case let url as URL in enumerator {
      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      total += Int64(size)
    }
    return total
  }
}

struct TranscriptCacheClient: Sendable {
  var lookup: @Sendable (_ key: String) -> CachedTranscription?
  var store:
    @Sendable (_ key: String, _ plan: EditPlan, _ canonicalAudioURL: URL) throws ->
      CachedTranscription
  var clear: @Sendable () throws -> Void
  var totalSize: @Sendable () -> Int64

  /// Wires the client to a concrete base dir. `liveValue` uses the real Application
  /// Support base; tests pass a temp dir.
  static func onDisk(base: URL) -> TranscriptCacheClient {
    TranscriptCacheClient(
      lookup: { TranscriptCache.lookup(key: $0, base: base) },
      store: { try TranscriptCache.store(key: $0, plan: $1, canonicalAudioURL: $2, base: base) },
      clear: { try TranscriptCache.clear(base: base) },
      totalSize: { TranscriptCache.totalSize(base: base) })
  }
}

extension TranscriptCacheClient: DependencyKey {
  static let liveValue: TranscriptCacheClient = {
    // Resolve the base lazily so an unavailable Application Support dir degrades to
    // a quiet miss rather than crashing at launch.
    guard let base = try? TranscriptCache.baseDirectory() else {
      return TranscriptCacheClient(
        lookup: { _ in nil },
        store: { _, plan, url in CachedTranscription(editPlan: plan, canonicalAudioURL: url) },
        clear: {}, totalSize: { 0 })
    }
    return .onDisk(base: base)
  }()
}

extension TranscriptCacheClient: TestDependencyKey {
  /// Default: a quiet always-miss (models overriding `\.transcription` never reach it).
  static let testValue = TranscriptCacheClient(
    lookup: { _ in nil },
    store: { _, plan, url in CachedTranscription(editPlan: plan, canonicalAudioURL: url) },
    clear: {}, totalSize: { 0 })
}

extension DependencyValues {
  var transcriptCache: TranscriptCacheClient {
    get { self[TranscriptCacheClient.self] }
    set { self[TranscriptCacheClient.self] = newValue }
  }
}
