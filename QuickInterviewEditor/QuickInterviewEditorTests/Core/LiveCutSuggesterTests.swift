import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

/// Pure coverage for the Swift→Python request wire: the JSON `LiveCutSuggester`
/// writes must carry the snake-cased keys `cut_suggester.cli` expects, and must plumb
/// the canonical sample rate the cutter needs to derive durations. No subprocess.
struct LiveCutSuggesterTests {

  private static func request(sampleRate: Int = 44100) -> CutSuggestRequest {
    CutSuggestRequest(
      transcriptUnits: [
        TranscriptUnit(
          id: 3, text: "So a young Hayes Carll", wordIDs: [7, 8, 9],
          startSample: 88200, endSample: 132300, startSec: 2.0, endSec: 3.0,
          speakerID: "SPEAKER_00")
      ],
      diarization: DiarizationEvidence(diarizationHash: "sha256:diar"),
      productSpecs: [.spotlight],
      options: CutSuggestOptions(model: "claude-sonnet-5"),
      transcriptHash: "sha256:t", sourceFingerprint: "fp", sampleRate: sampleRate)
  }

  private func encodedObject(_ request: CutSuggestRequest) throws -> [String: Any] {
    let data = try LiveCutSuggester.encodedRequest(request)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @Test func encodesSnakeCasedTranscriptUnits() throws {
    let object = try encodedObject(Self.request())
    let units = try #require(object["transcript_units"] as? [[String: Any]])
    let unit = try #require(units.first)
    expectNoDifference(unit["id"] as? Int, 3)
    expectNoDifference(unit["word_ids"] as? [Int], [7, 8, 9])
    expectNoDifference(unit["start_sample"] as? Int, 88200)
    expectNoDifference(unit["end_sample"] as? Int, 132300)
    expectNoDifference(unit["speaker_id"] as? String, "SPEAKER_00")
  }

  @Test func encodesOptionsWithSampleRateFromRequest() throws {
    let object = try encodedObject(Self.request(sampleRate: 48000))
    let options = try #require(object["options"] as? [String: Any])
    expectNoDifference(options["model"] as? String, "claude-sonnet-5")
    expectNoDifference(options["prompt_version"] as? String, "v2")
    expectNoDifference(options["stage1_window"] as? Int, 130)
    expectNoDifference(options["stage1_step"] as? Int, 110)
    // The canonical rate the units' samples are expressed in — required so Python
    // derives duration from samples/rate correctly.
    expectNoDifference(options["sample_rate"] as? Int, 48000)
  }

  @Test func encodesProductSpecsAndDiarization() throws {
    let object = try encodedObject(Self.request())
    let specs = try #require(object["product_specs"] as? [[String: Any]])
    let spec = try #require(specs.first)
    expectNoDifference(spec["product_type"] as? String, "spotlight")
    expectNoDifference(spec["hard_min_sec"] as? Double, 15)
    let diar = try #require(object["diarization"] as? [String: Any])
    expectNoDifference(diar["diarization_hash"] as? String, "sha256:diar")
  }

  @Test func omitsDiarizationWhenAbsent() throws {
    var req = Self.request()
    req.diarization = nil
    let object = try encodedObject(req)
    #expect(object["diarization"] == nil || object["diarization"] is NSNull)
  }
}
