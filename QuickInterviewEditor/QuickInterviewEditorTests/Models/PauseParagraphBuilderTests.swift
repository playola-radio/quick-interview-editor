import CustomDump
import Testing

@testable import QuickInterviewEditor

struct PauseParagraphBuilderTests {
  private func word(_ id: Int, _ text: String, _ start: Double, _ end: Double) -> Word {
    Word(id: id, text: text, start: start, end: end, startSample: nil, endSample: nil)
  }

  private func segment(_ id: Int, _ wordIDs: [Int], _ text: String) -> EditPlan.TranscriptSegment {
    EditPlan.TranscriptSegment(id: id, wordIDs: wordIDs, text: text)
  }

  @Test func splitsAtLongGapsSnappedToSentenceEnds() {
    let plan = Fixtures.editPlanV2()
    let paragraphs = PauseParagraphBuilder.paragraphs(
      words: plan.words, transcriptSegments: plan.transcriptSegments)
    // Breaks land after "Hayes." (word 4) and "concert." (word 9); the 900 ms
    // silence mid-sentence between "waits" (6) and "around" (7) is ignored
    // because word 6 does not end a sentence.
    expectNoDifference(
      paragraphs,
      [
        TranscriptParagraph(
          id: "pause-1", kind: .pauseParagraph, speakerID: nil, title: nil,
          wordIDs: [1, 2, 3, 4]),
        TranscriptParagraph(
          id: "pause-5", kind: .pauseParagraph, speakerID: nil, title: nil,
          wordIDs: [5, 6, 7, 8, 9]),
        TranscriptParagraph(
          id: "pause-10", kind: .pauseParagraph, speakerID: nil, title: nil,
          wordIDs: [10, 11, 12]),
      ])
  }

  @Test func noQualifyingGapYieldsSingleParagraph() {
    // Two sentences separated by only a short (200 ms) gap stay in one paragraph.
    let words = [
      word(1, "One.", 0.0, 0.4),
      word(2, "Two.", 0.6, 1.0),
    ]
    let segments = [segment(1, [1], "One."), segment(2, [2], "Two.")]
    let paragraphs = PauseParagraphBuilder.paragraphs(
      words: words, transcriptSegments: segments)
    expectNoDifference(paragraphs.map(\.wordIDs), [[1, 2]])
  }

  @Test func longGapMidSentenceDoesNotSplit() {
    // A 900 ms silence falls between words 1 and 2, but neither ends the single
    // sentence, so the paragraph stays whole.
    let words = [
      word(1, "A", 0.0, 0.2),
      word(2, "long", 1.1, 1.3),
      word(3, "pause.", 1.34, 1.6),
    ]
    let segments = [segment(1, [1, 2, 3], "A long pause.")]
    let paragraphs = PauseParagraphBuilder.paragraphs(
      words: words, transcriptSegments: segments)
    expectNoDifference(paragraphs.map(\.wordIDs), [[1, 2, 3]])
  }

  @Test func sentenceEndRequiresALongGapToSplit() {
    let words = [
      word(1, "Here.", 0.0, 0.3),
      word(2, "There.", 0.4, 0.7),
    ]
    let segments = [segment(1, [1], "Here."), segment(2, [2], "There.")]
    // 100 ms gap → no split.
    expectNoDifference(
      PauseParagraphBuilder.paragraphs(words: words, transcriptSegments: segments)
        .map(\.wordIDs),
      [[1, 2]])
    // A long gap at the same sentence end → split.
    let spaced = [word(1, "Here.", 0.0, 0.3), word(2, "There.", 1.2, 1.5)]
    expectNoDifference(
      PauseParagraphBuilder.paragraphs(words: spaced, transcriptSegments: segments)
        .map(\.wordIDs),
      [[1], [2]])
  }

  @Test func fallsBackToTrailingPunctuationWithoutTranscriptSegments() {
    // v1-style plan: no transcript_segments, so sentence ends come from the
    // trailing "." on "done." and "Next."
    let words = [
      word(1, "All", 0.0, 0.2),
      word(2, "done.", 0.24, 0.5),
      word(3, "Next.", 1.4, 1.7),
    ]
    let paragraphs = PauseParagraphBuilder.paragraphs(words: words, transcriptSegments: nil)
    expectNoDifference(paragraphs.map(\.wordIDs), [[1, 2], [3]])
  }

  @Test func emptyWordsYieldNoParagraphs() {
    expectNoDifference(
      PauseParagraphBuilder.paragraphs(words: [], transcriptSegments: nil), [])
  }

  @Test func endsSentenceToleratesTrailingQuote() {
    expectNoDifference(PauseParagraphBuilder.endsSentence("hero.\""), true)
    expectNoDifference(PauseParagraphBuilder.endsSentence("hero"), false)
    expectNoDifference(PauseParagraphBuilder.endsSentence("wait,"), false)
  }
}
