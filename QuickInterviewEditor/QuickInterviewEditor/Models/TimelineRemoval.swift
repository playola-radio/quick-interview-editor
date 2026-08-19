import Foundation

enum CrossfadeCurve: String, Equatable, Codable, Sendable {
  case equalPower
  case linear
}

struct Crossfade: Equatable, Codable, Sendable {
  var lengthSamples: Int
  var curve: CrossfadeCurve

  init(lengthSamples: Int, curve: CrossfadeCurve = .equalPower) {
    self.lengthSamples = max(0, lengthSamples)
    self.curve = curve
  }
}

struct TimelineRemoval: Identifiable, Equatable, Codable, Sendable {
  var id: UUID
  var removedRange: Range<Int>  // SOURCE samples [a, b)
  var crossfade: Crossfade
}

enum TimelineRemovals {
  /// Returns removals sorted by `removedRange.lowerBound`, or `nil` if any two overlap.
  /// Abutting ranges (a.upper == b.lower) are allowed.
  static func normalize(_ removals: [TimelineRemoval]) -> [TimelineRemoval]? {
    let sorted = removals.sorted { $0.removedRange.lowerBound < $1.removedRange.lowerBound }
    for (prev, next) in zip(sorted, sorted.dropFirst())
    where next.removedRange.lowerBound < prev.removedRange.upperBound {
      return nil
    }
    return sorted
  }
}
