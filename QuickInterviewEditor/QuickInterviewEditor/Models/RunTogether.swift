import Foundation

struct WordGap: Equatable {
  let leftID: Word.ID
  let rightID: Word.ID
  let gapMs: Double
}

/// Adjacent-word gaps in milliseconds. Consumed by pause-paragraph grouping to split
/// the transcript where the silence between words is long enough.
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
