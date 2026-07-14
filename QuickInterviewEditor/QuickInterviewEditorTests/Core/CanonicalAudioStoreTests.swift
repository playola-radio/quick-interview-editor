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

  @Test func pruneAllRemovesEveryJobDir() throws {
    let (base, plan) = try makeSandbox()
    defer { try? FileManager.default.removeItem(at: base.deletingLastPathComponent()) }

    _ = try CanonicalAudioStore.store(planAIFF: plan, in: base)
    _ = try CanonicalAudioStore.store(planAIFF: plan, in: base)
    CanonicalAudioStore.pruneAll(in: base)

    #expect(!FileManager.default.fileExists(atPath: base.path))
  }
}
