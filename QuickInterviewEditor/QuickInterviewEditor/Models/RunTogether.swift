import Foundation

struct WordViewState: Identifiable, Equatable {
  var id: Int
  var text: String
  var startSample: Int?
  var endSample: Int?
  var isSelected: Bool
  var isRunTogether: Bool
}

/// Word IDs that "run together" with a neighbor: any adjacent pair whose
/// inter-word gap is below `maxGapMs` flags BOTH of its words.
func runTogetherWordIDs(_ words: [Word], maxGapMs: Double) -> Set<Word.ID> {
  var ids: Set<Word.ID> = []
  for index in 0..<max(0, words.count - 1) {
    let cur = words[index]
    let next = words[index + 1]
    let curEnd = cur.end ?? cur.start
    let gapMs = (next.start - curEnd) * 1000
    if gapMs < maxGapMs {
      ids.insert(cur.id)
      ids.insert(next.id)
    }
  }
  return ids
}
