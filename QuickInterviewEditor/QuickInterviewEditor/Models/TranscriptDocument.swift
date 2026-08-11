import Foundation

struct TranscriptWordRange: Equatable {
  let wordID: Word.ID
  let range: NSRange
}

/// The transcript as one string plus a word → UTF-16 range map. Built once from the
/// plan's words. Words within a paragraph are space-joined; consecutive paragraphs are
/// separated by a single newline so the renderer can lay them out as distinct blocks.
/// A space and a newline are both one UTF-16 unit, so the range arithmetic is identical
/// either way — a paragraph break shifts no offsets relative to the all-spaces layout.
/// Offsets use UTF-16 because that is what TextKit hit testing returns; keeping the map
/// in UTF-16 avoids String.Index conversions.
struct TranscriptDocument: Equatable {
  let text: String
  let wordRanges: [TranscriptWordRange]

  /// `paragraphs` are the load-time pause-paragraphs (empty or a single paragraph render
  /// exactly as before — no breaks). Breaks are placed by word POSITION, not word ID:
  /// paragraphs partition `words` in order, so the last word of each non-final paragraph
  /// is a break point. Position, not ID, is used because word IDs are not guaranteed
  /// unique (a duplicate ID must not introduce a spurious break).
  init(words: [Word], paragraphs: [TranscriptParagraph] = []) {
    let breakAfterIndices = Self.breakAfterIndices(paragraphs: paragraphs)
    var pieces: [String] = []
    var ranges: [TranscriptWordRange] = []
    var location = 0
    for (index, word) in words.enumerated() {
      if index > 0 {
        pieces.append(breakAfterIndices.contains(index - 1) ? "\n" : " ")
        location += 1  // the joining separator (space or newline) is one UTF-16 unit
      }
      let length = (word.text as NSString).length
      ranges.append(
        TranscriptWordRange(wordID: word.id, range: NSRange(location: location, length: length)))
      location += length
      pieces.append(word.text)
    }
    text = pieces.joined()
    wordRanges = ranges
  }

  /// The `words` indices after which a paragraph break falls: the last-word position of
  /// every paragraph except the final one. Derived positionally by accumulating paragraph
  /// word counts, so it is correct even when word IDs repeat.
  private static func breakAfterIndices(paragraphs: [TranscriptParagraph]) -> Set<Int> {
    var indices: Set<Int> = []
    var cursor = 0
    for paragraph in paragraphs.dropLast() {
      cursor += paragraph.wordIDs.count
      indices.insert(cursor - 1)
    }
    return indices
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
