import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

struct SourceFingerprintTests {

  @Test func hashesFileContentAndIsStableAcrossCalls() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("qie-fp-\(UUID().uuidString).bin")
    try Data("hello interview".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let first = SourceFingerprint.compute(for: url)
    let second = SourceFingerprint.compute(for: url)
    #expect(first.hasPrefix("sha256:"))
    expectNoDifference(first, second)
  }

  @Test func differentContentYieldsDifferentFingerprint() throws {
    let dir = FileManager.default.temporaryDirectory
    let fileA = dir.appendingPathComponent("qie-fp-a-\(UUID().uuidString).bin")
    let fileB = dir.appendingPathComponent("qie-fp-b-\(UUID().uuidString).bin")
    try Data("content A".utf8).write(to: fileA)
    try Data("content B".utf8).write(to: fileB)
    defer {
      try? FileManager.default.removeItem(at: fileA)
      try? FileManager.default.removeItem(at: fileB)
    }
    #expect(SourceFingerprint.compute(for: fileA) != SourceFingerprint.compute(for: fileB))
  }

  @Test func fallsBackToPathWhenUnreadable() {
    let missing = URL(fileURLWithPath: "/no/such/file-\(UUID().uuidString).bin")
    let fingerprint = SourceFingerprint.compute(for: missing)
    #expect(fingerprint.hasPrefix("path:"))
  }
}
