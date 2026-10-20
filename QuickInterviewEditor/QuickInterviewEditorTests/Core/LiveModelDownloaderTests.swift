import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

@Suite struct LiveModelDownloaderTests {
  private func makeDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("qie-downloader-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  @Test func replaceItemSwapsSourceOverExistingDestination() throws {
    let dir = try makeDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("source.bin")
    let destination = dir.appendingPathComponent("model.bin")
    try Data("new".utf8).write(to: source)
    try Data("old".utf8).write(to: destination)

    try LiveModelDownloader.replaceItem(at: destination, with: source, label: "model.bin")

    expectNoDifference(try Data(contentsOf: destination), Data("new".utf8))
  }

  @Test func replaceItemFailureKeepsFileDestinationAndCause() throws {
    let dir = try makeDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let missingSource = dir.appendingPathComponent("gone.bin")
    let destination = dir.appendingPathComponent("model.bin")

    do {
      try LiveModelDownloader.replaceItem(at: destination, with: missingSource, label: "model.bin")
      Issue.record("expected the swap to fail")
    } catch let error as ModelDownloadError {
      guard case .couldNotStoreDownload(let file, let path, let reason) = error else {
        Issue.record("unexpected error \(error)")
        return
      }
      expectNoDifference(file, "model.bin")
      expectNoDifference(path, destination.path)
      #expect(reason.contains("NSCocoaErrorDomain"))
    }
  }
}
