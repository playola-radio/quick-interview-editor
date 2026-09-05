import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

/// A per-file sidecar persisted before the tight-join concept was retired still has a
/// top-level "warnings" array on each slice. `Slice` no longer declares that property, but
/// `Codable`'s synthesized decoder ignores unrecognized JSON keys by default, so an old
/// sidecar must still decode cleanly with no custom `init(from:)`.
struct SliceLegacySidecarDecodingTests {
  @Test func legacySliceJSONWithAWarningsFieldDecodesCleanly() throws {
    let json = """
      {
        "id": "5F1F5C1E-2C1B-4B9A-9C1E-2C1B4B9A9C1E",
        "name": "Intro",
        "startSample": 1000,
        "endSample": 2000,
        "wordIDs": [1, 2, 3],
        "snippet": "hello there",
        "warnings": ["tightStart", "tightEnd"]
      }
      """
    let slice = try JSONDecoder().decode(Slice.self, from: Data(json.utf8))
    expectNoDifference(slice.name, "Intro")
    expectNoDifference(slice.startSample, 1000)
    expectNoDifference(slice.endSample, 2000)
    expectNoDifference(slice.wordIDs, [1, 2, 3])
    expectNoDifference(slice.snippet, "hello there")
  }
}
