import Foundation

/// Word IDs whose ENTIRE `[startSample, endSample)` lies inside `range` — the spec's
/// strikethrough predicate ("no audio of this word survives the removal"). Inclusive on
/// both bounds: a word touching the removal edges exactly is still fully contained.
/// Words missing sample bounds or with a non-positive span are skipped. Transcript order.
func wordIDs(fullyContainedIn range: Range<Int>, words: [Word]) -> [Word.ID] {
  words.compactMap { word in
    guard let start = word.startSample, let end = word.endSample, start < end else { return nil }
    return (range.lowerBound <= start && end <= range.upperBound) ? word.id : nil
  }
}

/// Word IDs whose audio intersects `range` at all — the spec's highlight / clip-membership
/// predicate ("is any of this word still heard?"). Half-open: a range abutting a word's edge
/// does not overlap it. Words missing sample bounds or with a non-positive span are skipped.
func wordIDs(anyOverlap range: Range<Int>, words: [Word]) -> [Word.ID] {
  words.compactMap { word in
    guard let start = word.startSample, let end = word.endSample, start < end else { return nil }
    return (start < range.upperBound && end > range.lowerBound) ? word.id : nil
  }
}

func wordIDs(anyOverlap ranges: [Range<Int>], words: [Word]) -> [Word.ID] {
  let ranges = ranges.sorted { $0.lowerBound < $1.lowerBound }
  var rangeIndex = 0

  return words.compactMap { word in
    guard let start = word.startSample, let end = word.endSample, start < end else { return nil }
    while rangeIndex < ranges.count, ranges[rangeIndex].upperBound <= start {
      rangeIndex += 1
    }
    guard rangeIndex < ranges.count, ranges[rangeIndex].lowerBound < end else { return nil }
    return word.id
  }
}
