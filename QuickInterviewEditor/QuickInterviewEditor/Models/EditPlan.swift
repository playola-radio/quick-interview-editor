import Foundation
import IssueReporting

struct EditPlan: Codable, Equatable {
  var schemaVersion: Int
  var source: Source
  var words: [Word]
  var silences: [Silence]
  var segments: [Segment]

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case source, words, silences, segments
  }

  struct Source: Codable, Equatable {
    var path: String
    var sampleRate: Int
    var channels: Int
    var durationSamples: Int
    enum CodingKeys: String, CodingKey {
      case path, channels
      case sampleRate = "sample_rate"
      case durationSamples = "duration_samples"
    }
  }

  struct Word: Codable, Equatable, Identifiable {
    var id: Int
    var text: String
    var start: Double
    var end: Double?
    var startSample: Int?
    var endSample: Int?
    enum CodingKeys: String, CodingKey {
      case id, text, start, end
      case startSample = "start_sample"
      case endSample = "end_sample"
    }
  }

  /// Engine emits SAMPLE indices here (start inclusive, end exclusive), not seconds.
  struct Silence: Codable, Equatable {
    var startSample: Int
    var endSample: Int
    enum CodingKeys: String, CodingKey {
      case startSample = "start"
      case endSample = "end"
    }
  }

  // Decoded but unused in Step 1. Only the fields Step 1 needs are modeled;
  // every other key the engine emits (params, warnings, sample bounds, …) is
  // ignored by Decodable, so a plan omitting them still decodes.
  struct Segment: Codable, Equatable, Identifiable {
    var index: Int
    var outputName: String
    var wordIDs: [Int]
    var startStatus: String
    var endStatus: String
    var id: Int { index }
    enum CodingKeys: String, CodingKey {
      case index
      case outputName = "output_name"
      case wordIDs = "word_ids"
      case startStatus = "start_status"
      case endStatus = "end_status"
    }
  }
}

typealias Word = EditPlan.Word

extension EditPlan {
  static func decoded(from url: URL) throws -> EditPlan {
    try JSONDecoder().decode(EditPlan.self, from: Data(contentsOf: url))
  }
  /// App-runtime fixture (previews / default engine). Loads from the app bundle.
  /// Degrades to an empty plan (and reports the issue) rather than trapping if the
  /// bundled resource is ever missing or unreadable.
  static var fixture: EditPlan {
    guard let url = Bundle.main.url(forResource: "edit-plan", withExtension: "json"),
          let plan = try? decoded(from: url)
    else {
      reportIssue("Bundled edit-plan.json fixture is missing or unreadable")
      return EditPlan(
        schemaVersion: 1,
        source: Source(path: "", sampleRate: 44100, channels: 1, durationSamples: 0),
        words: [], silences: [], segments: [])
    }
    return plan
  }
}
