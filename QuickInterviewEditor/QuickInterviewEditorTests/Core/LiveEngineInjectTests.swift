import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

/// Pure coverage for the Swift↔Python `inject-markers` wire: the request JSON
/// `LiveEngine` writes must carry the snake-cased keys `logic_markers.cli
/// inject-markers` expects (top-level `files`, each with `path`/`markers`, each
/// marker with `position`/`name`), and the result decode must fail loud on a
/// short/incomplete result. No subprocess.
struct LiveEngineInjectTests {

  // MARK: - encodedInjectRequest

  private func encodedObject(_ files: [MarkerInjectionFile]) throws -> [String: Any] {
    let data = try LiveEngine.encodedInjectRequest(files)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @Test func encodesTopLevelFilesArray() throws {
    let files = [
      MarkerInjectionFile(
        url: URL(fileURLWithPath: "/tmp/slice-1.aiff"),
        markers: [RenderMarker(position: 0, name: "Hello")])
    ]
    let object = try encodedObject(files)
    let wireFiles = try #require(object["files"] as? [[String: Any]])
    #expect(wireFiles.count == 1)
  }

  @Test func encodesFilePathAndMarkersSnakeCased() throws {
    let files = [
      MarkerInjectionFile(
        url: URL(fileURLWithPath: "/tmp/slice-1.aiff"),
        markers: [
          RenderMarker(position: 0, name: "Hello"),
          RenderMarker(position: 44100, name: "world"),
        ])
    ]
    let object = try encodedObject(files)
    let wireFiles = try #require(object["files"] as? [[String: Any]])
    let file = try #require(wireFiles.first)
    expectNoDifference(file["path"] as? String, "/tmp/slice-1.aiff")
    let markers = try #require(file["markers"] as? [[String: Any]])
    expectNoDifference(markers.map { $0["position"] as? Int }, [0, 44100])
    expectNoDifference(markers.map { $0["name"] as? String }, ["Hello", "world"])
  }

  @Test func encodesMultipleFilesInOrder() throws {
    let files = [
      MarkerInjectionFile(url: URL(fileURLWithPath: "/tmp/a.aiff"), markers: []),
      MarkerInjectionFile(url: URL(fileURLWithPath: "/tmp/b.aiff"), markers: []),
    ]
    let object = try encodedObject(files)
    let wireFiles = try #require(object["files"] as? [[String: Any]])
    expectNoDifference(wireFiles.map { $0["path"] as? String }, ["/tmp/a.aiff", "/tmp/b.aiff"])
  }

  // MARK: - decodeInjectResult

  /// A throwaway file the "engine" reports success for, so the on-disk
  /// existence check in `decodeInjectResult` can pass.
  private func makeTempFile() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("qie-inject-test-\(UUID().uuidString).aiff")
    try Data("aiff-bytes".utf8).write(to: url)
    return url
  }

  private func resultJSON(paths: [String]) throws -> Data {
    let files = paths.map { ["path": $0, "marker_count": 2] as [String: Any] }
    let object = ["files": files]
    return try JSONSerialization.data(withJSONObject: object)
  }

  @Test func decodeSucceedsWhenEveryRequestedPathIsPresentAndOnDisk() throws {
    let url = try makeTempFile()
    defer { try? FileManager.default.removeItem(at: url) }

    let out = try resultJSON(paths: [url.path])
    try LiveEngine.decodeInjectResult(out, expectedPaths: [url.path])
  }

  @Test func decodeThrowsWhenAFileIsMissingFromTheResult() throws {
    let first = try makeTempFile()
    let second = try makeTempFile()
    defer {
      try? FileManager.default.removeItem(at: first)
      try? FileManager.default.removeItem(at: second)
    }

    // The engine only reports back the first file — the second is silently missing.
    let out = try resultJSON(paths: [first.path])
    #expect(throws: EngineClientError.self) {
      try LiveEngine.decodeInjectResult(out, expectedPaths: [first.path, second.path])
    }
  }

  @Test func decodeThrowsWhenAReportedFileNoLongerExistsOnDisk() throws {
    // Never written to disk — the engine claims success for a file that isn't there.
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("qie-inject-test-missing-\(UUID().uuidString).aiff")

    let out = try resultJSON(paths: [missing.path])
    #expect(throws: EngineClientError.self) {
      try LiveEngine.decodeInjectResult(out, expectedPaths: [missing.path])
    }
  }

  @Test func decodeThrowsOnMalformedJSON() throws {
    let out = Data("not json".utf8)
    #expect(throws: EngineClientError.self) {
      try LiveEngine.decodeInjectResult(out, expectedPaths: ["/tmp/anything.aiff"])
    }
  }
}
