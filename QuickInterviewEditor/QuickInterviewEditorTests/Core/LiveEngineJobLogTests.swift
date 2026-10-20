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
}
