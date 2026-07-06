import Foundation

struct Slice: Identifiable, Equatable, Codable {
  var id: UUID
  var name: String
  var startSample: Int  // inclusive
  var endSample: Int  // exclusive
  var wordIDs: [Word.ID]
  var snippet: String
  var warnings: [SliceWarning]
}

enum SliceWarning: String, Equatable, Codable {
  case tightStart
  case tightEnd
}
