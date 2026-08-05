import Foundation

struct TranscriptWordRange: Equatable {
  let wordID: Word.ID
  let range: NSRange
}

/// The transcript as one string plus a word → UTF-16 range map. Built once from the
/// plan's words (space-joined). Offsets use UTF-16 because that is what TextKit hit
/// testing returns; keeping the map in UTF-16 avoids String.Index conversions.
struct TranscriptDocument: Equatable {
  let text: String
  let wordRanges: [TranscriptWordRange]

  init(words: [Word]) {
    var pieces: [String] = []
    var ranges: [TranscriptWordRange] = []
    var location = 0
    for (index, word) in words.enumerated() {
      if index > 0 { location += 1 }  // the joining space
      let length = (word.text as NSString).length
      ranges.append(
        TranscriptWordRange(wordID: word.id, range: NSRange(location: location, length: length)))
      location += length
      pieces.append(word.text)
    }
    text = pieces.joined(separator: " ")
    wordRanges = ranges
  }

  /// The word an offset lands in, or the nearest preceding word when the offset is on a
  /// separator or past the end. Nil only when there are no words.
  ///
  /// `wordRanges` is sorted by ascending, non-overlapping `range.location`, so the answer is
  /// always the rightmost word whose range starts at or before `offset` (that word either
  /// contains the offset or is the nearest preceding one). Binary search finds it without a
  /// linear scan; when the offset is before the first word we fall back to the first word.
  func wordID(atUTF16Offset offset: Int) -> Word.ID? {
    guard let first = wordRanges.first else { return nil }
    var low = 0
    var high = wordRanges.count - 1
    var candidate = -1
    while low <= high {
      let mid = (low + high) / 2
      if wordRanges[mid].range.location <= offset {
        candidate = mid
        low = mid + 1
      } else {
        high = mid - 1
      }
    }
    return candidate >= 0 ? wordRanges[candidate].wordID : first.wordID
  }
}
