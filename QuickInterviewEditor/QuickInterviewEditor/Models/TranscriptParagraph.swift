import Foundation

/// One rendered paragraph of the transcript. A single abstraction backs both
/// content shapes: solo files group by long silences (`.pauseParagraph`), and
/// multi-speaker files (a later PR) group by diarization turn (`.speakerTurn`).
struct TranscriptParagraph: Identifiable, Equatable {
  var id: String
  var kind: Kind
  var speakerID: String?
  var title: String?
  var wordIDs: [Word.ID]

  enum Kind: Equatable {
    case pauseParagraph
    case speakerTurn
  }
}

/// Groups a solo interview's words into paragraphs at long silences, snapping
/// every break to a sentence end so a paragraph never splits mid-sentence.
///
/// A boundary is placed after word *W* only when both hold:
///   1. *W* ends a sentence — it's the last word of a `transcript_segment`
///      (WhisperX's sentence grouping), or, absent that evidence, its text ends
///      with sentence punctuation; and
///   2. the silence between *W* and the next word is at least the long-gap
///      threshold.
/// Requiring both means a long pause mid-sentence is ignored (we wait for the
/// sentence to finish), and a sentence end with no pause stays in the paragraph.
/// A solo file with no qualifying gap yields a single paragraph.
enum PauseParagraphBuilder {
  /// Starting long-silence threshold (ms). These are the "unheard interviewer
  /// question" gaps that separate answers in a solo recording. A starting value
  /// per the design spec's open question — tune against real solo files.
  static let defaultLongGapMs = 600.0

  private static let sentenceTerminators: Set<Character> = [".", "!", "?"]
  private static let trailingWrappers: Set<Character> = ["\"", "'", ")", "]", "”", "’", "»", "…"]

  static func paragraphs(
    words: [Word],
    transcriptSegments: [EditPlan.TranscriptSegment]?,
    longGapThresholdMs: Double = defaultLongGapMs
  ) -> [TranscriptParagraph] {
    guard !words.isEmpty else { return [] }

    // gaps[i] is the silence between words[i] and words[i + 1] (RunTogether math).
    let gaps = wordGaps(words)
    let sentenceEndIDs = sentenceEndWordIDs(words: words, transcriptSegments: transcriptSegments)

    var paragraphs: [TranscriptParagraph] = []
    var current: [Word.ID] = []
    for index in words.indices {
      current.append(words[index].id)
      let breaksHere =
        index < gaps.count
        && sentenceEndIDs.contains(words[index].id)
        && gaps[index].gapMs >= longGapThresholdMs
      if breaksHere {
        paragraphs.append(makeParagraph(current))
        current = []
      }
    }
    if !current.isEmpty { paragraphs.append(makeParagraph(current)) }
    return paragraphs
  }

  /// The word IDs that end a sentence. Prefer WhisperX's sentence grouping
  /// (`transcript_segments`); fall back to trailing punctuation for v1 plans or
  /// plans that carry no segments.
  static func sentenceEndWordIDs(
    words: [Word],
    transcriptSegments: [EditPlan.TranscriptSegment]?
  ) -> Set<Word.ID> {
    if let segments = transcriptSegments, !segments.isEmpty {
      return Set(segments.compactMap(\.wordIDs.last))
    }
    return Set(words.filter { endsSentence($0.text) }.map(\.id))
  }

  /// True when the word's text terminates a sentence, tolerating a trailing
  /// closing quote or bracket (e.g. `hero."`).
  static func endsSentence(_ text: String) -> Bool {
    for character in text.reversed() {
      if trailingWrappers.contains(character) { continue }
      return sentenceTerminators.contains(character)
    }
    return false
  }

  private static func makeParagraph(_ wordIDs: [Word.ID]) -> TranscriptParagraph {
    TranscriptParagraph(
      id: "pause-\(wordIDs.first ?? 0)",
      kind: .pauseParagraph,
      speakerID: nil,
      title: nil,
      wordIDs: wordIDs
    )
  }
}
