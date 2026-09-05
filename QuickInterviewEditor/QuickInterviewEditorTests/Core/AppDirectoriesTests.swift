import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

struct AppDirectoriesTests {

  private let fm = FileManager.default

  private func makeTempParent() throws -> URL {
    let dir = fm.temporaryDirectory.appending(
      component: UUID().uuidString, directoryHint: .isDirectory)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func writeFile(_ contents: String, at url: URL) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
  }

  private func read(_ url: URL) -> String? {
    (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
  }

  @Test func renamesSingleLegacyFolderWhenDestinationAbsent() throws {
    let parent = try makeTempParent()
    defer { try? fm.removeItem(at: parent) }
    try writeFile("plan", at: parent.appending(path: "QuickInterviewEditor/TranscriptCache/a.json"))
    try writeFile("side", at: parent.appending(path: "QuickInterviewEditor/Projects/x.json"))

    AppDirectories.migrate(
      parent: parent, legacyNames: ["QuickInterviewEditor"], newName: "Playola Interview Editor",
      fileManager: fm)

    expectNoDifference(
      read(parent.appending(path: "Playola Interview Editor/TranscriptCache/a.json")), "plan")
    expectNoDifference(
      read(parent.appending(path: "Playola Interview Editor/Projects/x.json")), "side")
    expectNoDifference(
      fm.fileExists(atPath: parent.appending(path: "QuickInterviewEditor").path), false)
  }

  @Test func mergesTwoLegacyRootsIntoOne() throws {
    let parent = try makeTempParent()
    defer { try? fm.removeItem(at: parent) }
    try writeFile("plan", at: parent.appending(path: "QuickInterviewEditor/TranscriptCache/a.json"))
    try writeFile("log", at: parent.appending(path: "Quick Interview Editor/Logs/run.log"))

    AppDirectories.migrate(
      parent: parent, legacyNames: ["QuickInterviewEditor", "Quick Interview Editor"],
      newName: "Playola Interview Editor", fileManager: fm)

    expectNoDifference(
      read(parent.appending(path: "Playola Interview Editor/TranscriptCache/a.json")), "plan")
    expectNoDifference(
      read(parent.appending(path: "Playola Interview Editor/Logs/run.log")), "log")
    expectNoDifference(
      fm.fileExists(atPath: parent.appending(path: "QuickInterviewEditor").path), false)
    expectNoDifference(
      fm.fileExists(atPath: parent.appending(path: "Quick Interview Editor").path), false)
  }

  @Test func isIdempotent() throws {
    let parent = try makeTempParent()
    defer { try? fm.removeItem(at: parent) }
    try writeFile("plan", at: parent.appending(path: "QuickInterviewEditor/TranscriptCache/a.json"))

    AppDirectories.migrate(
      parent: parent, legacyNames: ["QuickInterviewEditor"], newName: "Playola Interview Editor",
      fileManager: fm)
    AppDirectories.migrate(
      parent: parent, legacyNames: ["QuickInterviewEditor"], newName: "Playola Interview Editor",
      fileManager: fm)

    expectNoDifference(
      read(parent.appending(path: "Playola Interview Editor/TranscriptCache/a.json")), "plan")
  }

  @Test func doesNotClobberExistingDestinationEntries() throws {
    let parent = try makeTempParent()
    defer { try? fm.removeItem(at: parent) }
    // Destination already has a TranscriptCache (newer); legacy has a colliding one.
    try writeFile(
      "new", at: parent.appending(path: "Playola Interview Editor/TranscriptCache/a.json"))
    try writeFile("old", at: parent.appending(path: "QuickInterviewEditor/TranscriptCache/a.json"))
    try writeFile("side", at: parent.appending(path: "QuickInterviewEditor/Projects/x.json"))

    AppDirectories.migrate(
      parent: parent, legacyNames: ["QuickInterviewEditor"], newName: "Playola Interview Editor",
      fileManager: fm)

    // Collision: destination TranscriptCache untouched; non-colliding Projects moved in.
    expectNoDifference(
      read(parent.appending(path: "Playola Interview Editor/TranscriptCache/a.json")), "new")
    expectNoDifference(
      read(parent.appending(path: "Playola Interview Editor/Projects/x.json")), "side")
    // The legacy folder keeps its colliding child (not clobbered, not moved).
    expectNoDifference(
      read(parent.appending(path: "QuickInterviewEditor/TranscriptCache/a.json")), "old")
  }

  @Test func deepMergesNonCollidingNestedEntriesUnderExistingDestinationFolder() throws {
    let parent = try makeTempParent()
    defer { try? fm.removeItem(at: parent) }
    // Destination already has a TranscriptCache with one entry; the legacy folder has a
    // colliding entry (a.json) AND a non-colliding nested one (b.json). A shallow merge
    // would skip the whole TranscriptCache and strand b.json forever.
    try writeFile(
      "new", at: parent.appending(path: "Playola Interview Editor/TranscriptCache/a.json"))
    try writeFile("old", at: parent.appending(path: "QuickInterviewEditor/TranscriptCache/a.json"))
    try writeFile(
      "extra", at: parent.appending(path: "QuickInterviewEditor/TranscriptCache/b.json"))

    AppDirectories.migrate(
      parent: parent, legacyNames: ["QuickInterviewEditor"], newName: "Playola Interview Editor",
      fileManager: fm)

    // Colliding leaf keeps the destination copy; non-colliding nested entry migrates in.
    expectNoDifference(
      read(parent.appending(path: "Playola Interview Editor/TranscriptCache/a.json")), "new")
    expectNoDifference(
      read(parent.appending(path: "Playola Interview Editor/TranscriptCache/b.json")), "extra")
    // The legacy folder keeps only its colliding leaf (b.json moved out, a.json stayed).
    expectNoDifference(
      read(parent.appending(path: "QuickInterviewEditor/TranscriptCache/a.json")), "old")
    let legacyB = parent.appending(path: "QuickInterviewEditor/TranscriptCache/b.json")
    expectNoDifference(fm.fileExists(atPath: legacyB.path), false)
  }

  @Test func fallsBackToMergeWhenAtomicRenameFailsAndDestinationIsAbsent() throws {
    let parent = try makeTempParent()
    defer { try? fm.removeItem(at: parent) }
    try writeFile("plan", at: parent.appending(path: "QuickInterviewEditor/TranscriptCache/a.json"))

    // Force the fast-path root rename to fail while the destination does not exist.
    let failing = FailFirstMoveFileManager()

    AppDirectories.migrate(
      parent: parent, legacyNames: ["QuickInterviewEditor"], newName: "Playola Interview Editor",
      fileManager: failing)

    // The fallback merge must still land the data under the new folder, not strand it.
    expectNoDifference(
      read(parent.appending(path: "Playola Interview Editor/TranscriptCache/a.json")), "plan")
    expectNoDifference(
      fm.fileExists(atPath: parent.appending(path: "QuickInterviewEditor").path), false)
  }

  @Test func noLegacyFoldersIsANoOp() throws {
    let parent = try makeTempParent()
    defer { try? fm.removeItem(at: parent) }

    AppDirectories.migrate(
      parent: parent, legacyNames: ["QuickInterviewEditor", "Quick Interview Editor"],
      newName: "Playola Interview Editor", fileManager: fm)

    expectNoDifference(
      fm.fileExists(atPath: parent.appending(path: "Playola Interview Editor").path), false)
  }
}

/// A `FileManager` whose first `moveItem` throws, then behaves normally — used to force
/// the migration's fast-path atomic rename to fail so the merge fallback is exercised.
private final class FailFirstMoveFileManager: FileManager, @unchecked Sendable {
  private var didFailFirstMove = false
  override func moveItem(at srcURL: URL, to dstURL: URL) throws {
    if !didFailFirstMove {
      didFailFirstMove = true
      throw CocoaError(.fileWriteUnknown)
    }
    try super.moveItem(at: srcURL, to: dstURL)
  }
}
