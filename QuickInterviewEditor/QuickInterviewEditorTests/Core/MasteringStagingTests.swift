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

  @Test func invalidStagedNameIsReportedWithTheName() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("mastering-staging-name-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.wav")
    try Data("a".utf8).write(to: source)
    #expect(throws: MasteringStagingError.invalidFileName("../escape.wav")) {
      try MasteringStagingStore.adopt(source, as: "../escape.wav", in: root)
    }
  }

  @Test func leaseFailureNamesTheOperationPathAndErrno() {
    let error = MasteringStagingError.lease("open", path: "/tmp/x/.lease", errnoCode: ENOSPC)
    expectNoDifference(
      error.errorDescription,
      "Could not stage the file: open failed for /tmp/x/.lease: No space left on device (errno 28)"
    )
  }

  @Test func reaperLeavesAnUnremovableStaleDirectoryInPlaceWithoutFailing() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("mastering-staging-stuck-\(UUID().uuidString)")
    let stale = root.appendingPathComponent("stale")
    try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
    let now = Date(timeIntervalSince1970: 1_000_000_000)
    try FileManager.default.setAttributes(
      [.modificationDate: now.addingTimeInterval(-100)], ofItemAtPath: stale.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
      try? FileManager.default.removeItem(at: root)
    }
    MasteringStagingStore.reapStale(olderThan: 10, in: root, now: now)
    expectNoDifference(FileManager.default.fileExists(atPath: stale.path), true)
  }

  @Test func reaperIgnoresAMissingStagingFolder() {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("mastering-staging-missing-\(UUID().uuidString)")
    MasteringStagingStore.reapStale(in: missing)
    expectNoDifference(FileManager.default.fileExists(atPath: missing.path), false)
  }
}
