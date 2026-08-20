import Foundation

enum CrossfadeCurve: String, Equatable, Codable, Sendable {
  case equalPower
  case linear
}

struct Crossfade: Equatable, Codable, Sendable {
  var lengthSamples: Int
  var curve: CrossfadeCurve
  /// Logic-parity fade curve shaping, -1.0...1.0. The DSP that applies this lands in
  /// PR5 — for now this is just the stored field.
  var curveAmount: Double
  /// Logic-parity: offsets the crossfade's center within its window. The DSP that
  /// applies this lands in PR5 — for now this is just the stored field.
  var centerOffsetSamples: Int

  init(
    lengthSamples: Int, curve: CrossfadeCurve = .equalPower, curveAmount: Double = 0,
    centerOffsetSamples: Int = 0
  ) {
    self.lengthSamples = max(0, lengthSamples)
    self.curve = curve
    self.curveAmount = curveAmount
    self.centerOffsetSamples = centerOffsetSamples
  }

  enum CodingKeys: String, CodingKey {
    case lengthSamples, curve, curveAmount, centerOffsetSamples
  }

  /// Lenient decode: a sidecar persisted before `curveAmount`/`centerOffsetSamples` existed is
  /// missing those keys — default them to 0 rather than failing the whole decode.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.lengthSamples = max(0, try container.decode(Int.self, forKey: .lengthSamples))
    self.curve = try container.decode(CrossfadeCurve.self, forKey: .curve)
    self.curveAmount = try container.decodeIfPresent(Double.self, forKey: .curveAmount) ?? 0
    self.centerOffsetSamples =
      try container.decodeIfPresent(Int.self, forKey: .centerOffsetSamples) ?? 0
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
