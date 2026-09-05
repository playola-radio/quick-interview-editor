import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

struct ProjectFileTests {
  @Test func projectFileRoundTrips() throws {
    let file = Fixtures.projectFile()
    let data = try JSONEncoder().encode(file)
    expectNoDifference(try JSONDecoder().decode(ProjectFile.self, from: data), file)
  }

  @Test func currentSchemaVersionIsOne() {
    expectNoDifference(ProjectFile.currentSchemaVersion, 1)
  }

  @Test func decodesLeniently_missingOriginalPath() throws {
    let json = Data(
      """
      {
        "schemaVersion": 1,
        "source": {
          "originalFileName": "interview.mp3",
          "originalFingerprint": "orig-fp",
          "canonicalFingerprint": "canonical-fp",
          "canonicalByteCount": 4096,
          "importedAt": 1700000000,
          "sampleRate": 44100,
          "channels": 1,
          "durationSamples": 441000
        },
        "engine": { "engineFingerprint": "engine-fp" },
        "content": { "slices": [], "timelineRemovals": [] }
      }
      """.utf8)
    let file = try JSONDecoder().decode(ProjectFile.self, from: json)
    expectNoDifference(file.source.originalPath, nil)
  }
}
