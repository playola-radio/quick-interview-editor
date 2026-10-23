import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

struct LiveEngineJobLogTests {
  private func logsDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  @Test func unreadableTranscriptionResultErrorNeverEchoesEngineOutput() {
    let out = Data("confidential harbour".utf8)
    do {
      _ = try LiveEngine.decodeTranscriptionPlan(out, logURL: nil)
      Issue.record("Expected decode failure")
    } catch {
      expectNoDifference(
        error.localizedDescription,
        "Could not read the transcription result: not valid JSON (20 bytes of output)")
    }
  }

  @Test func jobLogNeverContainsTranscriptTextFromStdout() throws {
    let directory = try logsDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stdout = Data(#"{"words":[{"text":"confidential"},{"text":"harbour"}]}"#.utf8)
    let stderr = "QIE_ERROR {\"message\":\"boom\"}"

    let url = try #require(
      LiveEngine.writeJobLog(
        kind: "transcribe", audio: URL(fileURLWithPath: "/tmp/interview.wav"), exitCode: 3,
        stdout: stdout, stderr: stderr, logsDirectory: directory))

    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(!text.contains("confidential"))
    #expect(!text.contains("harbour"))
    #expect(text.contains("exit: 3"))
    #expect(text.contains("audio: /tmp/interview.wav"))
    #expect(text.contains("STDOUT (\(stdout.count) bytes, 1 lines"))
    #expect(text.contains(stderr))
  }

  @Test func jobLogCountsBlankLinesAndTrailingNewlinesInStdout() throws {
    let directory = try logsDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cases: [(Data, Int)] = [
      (Data(), 0),
      (Data("\n".utf8), 1),
      (Data("a\n\nb".utf8), 3),
      (Data("a\n".utf8), 1),
    ]

    for item in cases {
      let url = try #require(
        LiveEngine.writeJobLog(
          kind: "transcribe", audio: URL(fileURLWithPath: "/tmp/interview.wav"), exitCode: 3,
          stdout: item.0, stderr: "", logsDirectory: directory))

      let text = try String(contentsOf: url, encoding: .utf8)
      #expect(text.contains("STDOUT (\(item.0.count) bytes, \(item.1) lines"))
      try FileManager.default.removeItem(at: url)
    }
  }
}
