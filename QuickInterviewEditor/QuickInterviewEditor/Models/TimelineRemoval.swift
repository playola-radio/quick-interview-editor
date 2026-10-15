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
  /// missing those keys — default them to 0 rather than failing the whole decode. Likewise an
  /// unknown or missing `curve` (a future app version's value, or a hand-edited sidecar) falls
  /// back to `.equalPower` instead of poisoning the entire `ProjectState` decode.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.lengthSamples = max(0, try container.decode(Int.self, forKey: .lengthSamples))
    self.curve =
      (try? container.decodeIfPresent(String.self, forKey: .curve))
      .flatMap { CrossfadeCurve(rawValue: $0) } ?? .equalPower
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

  /// The removal spans for selected SOURCE pieces: touching pieces merge, then each absorbs every
  /// existing removal it strictly overlaps (abutting removals stay separate). One existing removal
  /// can bridge two pieces into one span.
  static func mergedSpans(
    removing ranges: [Range<Int>], existing: [TimelineRemoval]
  ) -> (spans: [Range<Int>], absorbedIDs: Set<TimelineRemoval.ID>) {
    // Single-pass absorption relies on existing removals being pairwise non-overlapping (the normalize invariant).
    var absorbedIDs: Set<TimelineRemoval.ID> = []
    let extended = ranges.filter { !$0.isEmpty }.mergingTouching().map { piece in
      let absorbed = existing.filter { $0.removedRange.overlaps(piece) }
      absorbedIDs.formUnion(absorbed.map(\.id))
      return absorbed.reduce(piece) { hull, removal in
        min(
          hull.lowerBound, removal.removedRange.lowerBound)..<max(
            hull.upperBound, removal.removedRange.upperBound)
      }
    }
    return (extended.mergingTouching(), absorbedIDs)
  }
}

extension Array where Element == Range<Int> {
  /// Sorted by lower bound, with overlapping or abutting ranges merged.
  func mergingTouching() -> [Range<Int>] {
    var merged: [Range<Int>] = []
    for range in sorted(by: { $0.lowerBound < $1.lowerBound }) {
      if let last = merged.last, range.lowerBound <= last.upperBound {
        merged[merged.count - 1] = last.lowerBound..<Swift.max(last.upperBound, range.upperBound)
      } else {
        merged.append(range)
      }
    }
    return merged
  }
}
