import Foundation

struct WordViewState: Identifiable, Equatable {
  var id: Int
  var text: String
  var startSample: Int?
  var endSample: Int?
  var isSelected: Bool
  var isRunTogether: Bool
}

enum WordDisplayRole {
  case selected
  case runTogether
  case normal
}

extension WordViewState {
  var displayRole: WordDisplayRole {
    if isSelected { return .selected }
    if isRunTogether { return .runTogether }
    return .normal
  }
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

struct WordGap: Equatable {
  let leftID: Word.ID
  let rightID: Word.ID
  let gapMs: Double
}

/// Adjacent-word gaps in milliseconds, computed once so sensitivity changes filter
/// records instead of re-walking every word's timestamps.
func wordGaps(_ words: [Word]) -> [WordGap] {
  var gaps: [WordGap] = []
  for index in 0..<max(0, words.count - 1) {
    let cur = words[index]
    let next = words[index + 1]
    let curEnd = cur.end ?? cur.start
    let rawGapMs = (next.start - curEnd) * 1000
    // Round away Double subtraction noise (e.g. 19.999999999999996) so gaps
    // that are conceptually whole milliseconds compare/display exactly.
    let gapMs = (rawGapMs * 1_000_000).rounded() / 1_000_000
    gaps.append(WordGap(leftID: cur.id, rightID: next.id, gapMs: gapMs))
  }
  return gaps
}

func runTogetherWordIDs(gaps: [WordGap], maxGapMs: Double) -> Set<Word.ID> {
  var ids: Set<Word.ID> = []
  for gap in gaps where gap.gapMs < maxGapMs {
    ids.insert(gap.leftID)
    ids.insert(gap.rightID)
  }
  return ids
}
