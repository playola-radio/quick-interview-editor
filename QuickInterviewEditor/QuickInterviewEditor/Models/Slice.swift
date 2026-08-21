import Foundation

// `Codable`'s synthesized decoder ignores unrecognized JSON keys, so a per-file sidecar
// persisted before the tight-join concept was retired (which still has a top-level
// "warnings" array on each slice) decodes cleanly here without any custom `init(from:)` —
// see `SliceLegacySidecarDecodingTests` for the regression coverage.
struct Slice: Identifiable, Equatable, Codable {
  var id: UUID
  var name: String
  var startSample: Int  // inclusive
  var endSample: Int  // exclusive
  var wordIDs: [Word.ID]
  var snippet: String
}
