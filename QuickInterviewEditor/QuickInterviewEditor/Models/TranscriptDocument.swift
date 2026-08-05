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
      ranges.append(TranscriptWordRange(wordID: word.id, range: NSRange(location: location, length: length)))
      location += length
      pieces.append(word.text)
    }
    text = pieces.joined(separator: " ")
    wordRanges = ranges
  }

  /// The word an offset lands in, or the nearest preceding word when the offset is on a
  /// separator or past the end. Nil only when there are no words.
  func wordID(atUTF16Offset offset: Int) -> Word.ID? {
    guard !wordRanges.isEmpty else { return nil }
    var candidate: Word.ID?
    for entry in wordRanges {
      if NSLocationInRange(offset, entry.range) { return entry.wordID }
      if entry.range.location <= offset { candidate = entry.wordID } else { break }
    }
    return candidate ?? wordRanges.first?.wordID
  }
}
