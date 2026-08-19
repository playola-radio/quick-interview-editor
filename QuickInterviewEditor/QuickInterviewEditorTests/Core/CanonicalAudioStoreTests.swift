import Foundation
import Testing

@testable import QuickInterviewEditor

struct CanonicalAudioStoreTests {

  /// A throwaway base dir standing in for `Caches/.../Canonical`, plus a source
  /// "plan.aiff" to copy from. Both are cleaned up by the caller.
  private func makeSandbox() throws -> (base: URL, planAIFF: URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("qie-canonical-test-\(UUID().uuidString)")
    let base = root.appendingPathComponent("Canonical")
    let work = root.appendingPathComponent("work")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let plan = work.appendingPathComponent("clip.plan.aiff")
    try Data("canonical-bytes".utf8).write(to: plan)
    return (base, plan)
  }

  @Test func storeCopiesIntoAFreshPerJobDir() throws {
    let (base, plan) = try makeSandbox()
    defer { try? FileManager.default.removeItem(at: base.deletingLastPathComponent()) }

    let first = try CanonicalAudioStore.store(planAIFF: plan, in: base)
    let second = try CanonicalAudioStore.store(planAIFF: plan, in: base)

    #expect(FileManager.default.fileExists(atPath: first.path))
    #expect(FileManager.default.fileExists(atPath: second.path))
    #expect(first.lastPathComponent == CanonicalAudioStore.fileName)
    // Each job gets its own dir, so two stores don't collide.
    #expect(first.deletingLastPathComponent() != second.deletingLastPathComponent())
    let bytes = try Data(contentsOf: first)
    #expect(String(bytes: bytes, encoding: .utf8) == "canonical-bytes")
  }

  @Test func removeDeletesOnlyThatJobDir() throws {
    let (base, plan) = try makeSandbox()
    defer { try? FileManager.default.removeItem(at: base.deletingLastPathComponent()) }

    let first = try CanonicalAudioStore.store(planAIFF: plan, in: base)
    let second = try CanonicalAudioStore.store(planAIFF: plan, in: base)
    CanonicalAudioStore.remove(first, in: base)

    #expect(!FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path))
    #expect(FileManager.default.fileExists(atPath: second.path))  // sibling untouched
  }

  @Test func removeIgnoresURLsOutsideTheCache() throws {
    let (base, plan) = try makeSandbox()
    defer { try? FileManager.default.removeItem(at: base.deletingLastPathComponent()) }

    // A URL whose parent isn't `base` (e.g. the original source folder) must never
    // have its directory removed.
    CanonicalAudioStore.remove(plan, in: base)
    #expect(FileManager.default.fileExists(atPath: plan.path))
  }

  /// Ages a job dir by back-dating its modification time, so reap tests are deterministic
  /// without sleeping. Reaping keys on the dir's `contentModificationDate`.
  private func age(_ jobDir: URL, to date: Date) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: jobDir.path)
  }

  @Test func reapStaleRemovesAgedDirsAndKeepsFreshOnes() throws {
    let (base, plan) = try makeSandbox()
    defer { try? FileManager.default.removeItem(at: base.deletingLastPathComponent()) }

    let now = Date(timeIntervalSince1970: 1_000_000_000)
    let stale = try CanonicalAudioStore.store(planAIFF: plan, in: base).deletingLastPathComponent()
    let fresh = try CanonicalAudioStore.store(planAIFF: plan, in: base).deletingLastPathComponent()
    try age(stale, to: now.addingTimeInterval(-8 * 24 * 60 * 60))  // 8 days old
    try age(fresh, to: now.addingTimeInterval(-60 * 60))  // 1 hour old

    CanonicalAudioStore.reapStale(olderThan: 7 * 24 * 60 * 60, in: base, now: now)

    #expect(!FileManager.default.fileExists(atPath: stale.path))
    #expect(FileManager.default.fileExists(atPath: fresh.path))  // a live session's dir survives
  }

  @Test func reapStaleLeavesEveryRecentDir() throws {
    let (base, plan) = try makeSandbox()
    defer { try? FileManager.default.removeItem(at: base.deletingLastPathComponent()) }

    let now = Date(timeIntervalSince1970: 1_000_000_000)
    let dir = try CanonicalAudioStore.store(planAIFF: plan, in: base).deletingLastPathComponent()
    try age(dir, to: now.addingTimeInterval(-6 * 24 * 60 * 60))  // 6 days old, under the cutoff

    CanonicalAudioStore.reapStale(olderThan: 7 * 24 * 60 * 60, in: base, now: now)

    #expect(FileManager.default.fileExists(atPath: dir.path))
  }

  @Test func reapStaleOnMissingBaseIsSafe() {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("qie-canonical-missing-\(UUID().uuidString)")
    CanonicalAudioStore.reapStale(in: base)  // must not throw or crash
    #expect(!FileManager.default.fileExists(atPath: base.path))
  }
}
