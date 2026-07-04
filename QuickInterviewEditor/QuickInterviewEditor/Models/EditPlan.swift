import Foundation

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

  // NOTE: engine emits SAMPLES here (not seconds). Decoded but unused in Step 1.
  struct Silence: Codable, Equatable {
    var start: Double
    var end: Double
  }

  // Decoded but unused in Step 1.
  struct Segment: Codable, Equatable, Identifiable {
    var index: Int
    var outputName: String
    var wordIDs: [Int]
    var startStatus: String
    var endStatus: String
    var id: Int { index }
    enum CodingKeys: String, CodingKey {
      case index, warnings
      case outputName = "output_name"
      case wordIDs = "word_ids"
      case startStatus = "start_status"
      case endStatus = "end_status"
    }
    // Only decode the fields Step 1 needs; ignore the rest.
    var warnings: [String] = []
  }
}

typealias Word = EditPlan.Word

extension EditPlan {
  static func decoded(from url: URL) throws -> EditPlan {
    try JSONDecoder().decode(EditPlan.self, from: Data(contentsOf: url))
  }
  /// App-runtime fixture (previews / default engine). Loads from the app bundle.
  static var fixture: EditPlan {
    let url = Bundle.main.url(forResource: "edit-plan", withExtension: "json")!
    return try! decoded(from: url)
  }
}
