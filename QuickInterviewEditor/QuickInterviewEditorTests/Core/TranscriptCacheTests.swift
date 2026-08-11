import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

@Suite struct TranscriptCacheTests {
  /// A unique temp base dir per test; caller removes it.
  private func makeBase() -> URL {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("qie-cache-tests/\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
  }

  /// A tiny stand-in AIFF payload on disk (content, not real audio).
  private func makeAIFF(_ base: URL, bytes: String = "AIFFDATA") -> URL {
    let url = base.appendingPathComponent("source-\(UUID().uuidString).aiff")
    try? Data(bytes.utf8).write(to: url)
    return url
  }

  @Test func storeThenLookupReturnsCachedPlanAndCacheOwnedAIFF() throws {
    let base = makeBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let cache = TranscriptCacheClient.onDisk(base: base)
    let plan = Fixtures.editPlan()
    let aiff = makeAIFF(base)

    let stored = try cache.store("key1", plan, aiff)
    // The stored AIFF is a cache-owned copy, not the source path.
    #expect(stored.canonicalAudioURL != aiff)
    #expect(FileManager.default.fileExists(atPath: stored.canonicalAudioURL.path))

    let hit = try #require(cache.lookup("key1"))
    expectNoDifference(hit.editPlan, plan)
    expectNoDifference(hit.canonicalAudioURL, stored.canonicalAudioURL)
  }

  @Test func lookupMissesForUnknownKey() {
    let base = makeBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let cache = TranscriptCacheClient.onDisk(base: base)
    #expect(cache.lookup("nope") == nil)
  }

  @Test func lookupMissesWhenManifestIsAbsent() throws {
    let base = makeBase()
    defer { try? FileManager.default.removeItem(at: base) }
    // Simulate a half-written entry: plan.json + canonical.aiff but no manifest.
    let dir = base.appendingPathComponent("partial")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try JSONEncoder().encode(Fixtures.editPlan()).write(to: dir.appendingPathComponent("plan.json"))
    try Data("x".utf8).write(to: dir.appendingPathComponent("canonical.aiff"))

    let cache = TranscriptCacheClient.onDisk(base: base)
    #expect(cache.lookup("partial") == nil)  // no manifest ⇒ not a committed entry
  }

  @Test func storeOverwritesExistingEntry() throws {
    let base = makeBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let cache = TranscriptCacheClient.onDisk(base: base)
    _ = try cache.store("k", Fixtures.editPlan(), makeAIFF(base, bytes: "one"))
    let second = try cache.store("k", Fixtures.editPlan(), makeAIFF(base, bytes: "two"))
    let hit = try #require(cache.lookup("k"))
    expectNoDifference(hit.canonicalAudioURL, second.canonicalAudioURL)
    #expect(try Data(contentsOf: hit.canonicalAudioURL) == Data("two".utf8))
  }

  @Test func totalSizeAndClear() throws {
    let base = makeBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let cache = TranscriptCacheClient.onDisk(base: base)
    _ = try cache.store("k", Fixtures.editPlan(), makeAIFF(base))
    #expect(cache.totalSize() > 0)
    try cache.clear()
    #expect(cache.totalSize() == 0)
    #expect(cache.lookup("k") == nil)
  }

  @Test func sweepStaleTempDirsRemovesOrphanedTempDirsButKeepsCommittedEntries() throws {
    let base = makeBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let cache = TranscriptCacheClient.onDisk(base: base)
    _ = try cache.store("key1", Fixtures.editPlan(), makeAIFF(base))

    let staleTempDir = base.appendingPathComponent("key1.tmp.\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: staleTempDir, withIntermediateDirectories: true)
    try Data("orphan".utf8).write(to: staleTempDir.appendingPathComponent("plan.json"))

    TranscriptCache.sweepStaleTempDirs(base: base)

    #expect(!FileManager.default.fileExists(atPath: staleTempDir.path))
    let hit = try #require(cache.lookup("key1"))
    expectNoDifference(hit.editPlan, Fixtures.editPlan())
  }
}
