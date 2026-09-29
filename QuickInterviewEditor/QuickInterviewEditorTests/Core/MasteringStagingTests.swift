import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

// swiftlint:disable:next inclusive_language
struct MasteringStagingTests {
  @Test func ownerRetainsStagedFileUntilLastReferenceIsReleased() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("mastering-staging-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.wav")
    let bytes = Data("prepared bytes".utf8)
    try bytes.write(to: source)
    var owner: StagedMasteringArtifact? = try MasteringStagingStore.adopt(
      source, as: "prepared.wav", in: root)
    var retained = owner
    let url = try #require(owner?.url)
    owner = nil
    expectNoDifference(try Data(contentsOf: url), bytes)
    retained = nil
    expectNoDifference(FileManager.default.fileExists(atPath: url.path), false)
  }

  @Test func staleReaperKeepsLiveOwnerAndRemovesOrphan() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("mastering-staging-reap-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.wav")
    try Data("a".utf8).write(to: source)
    let owner = try MasteringStagingStore.adopt(source, as: "a.wav", in: root)
    let live = owner.url.deletingLastPathComponent()
    let orphan = root.appendingPathComponent("orphan")
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
    let now = Date(timeIntervalSince1970: 1_000_000_000)
    for dir in [live, orphan] {
      try FileManager.default.setAttributes(
        [.modificationDate: now.addingTimeInterval(-100)],
        ofItemAtPath: dir.path)
    }
    MasteringStagingStore.reapStale(olderThan: 10, in: root, now: now)
    expectNoDifference(FileManager.default.fileExists(atPath: live.path), true)
    expectNoDifference(FileManager.default.fileExists(atPath: orphan.path), false)
    withExtendedLifetime(owner) {}
  }
}
