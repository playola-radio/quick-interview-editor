import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

@MainActor
struct TranscriptDocumentTests {
  private func word(_ id: Int, _ text: String) -> Word {
    Word(id: id, text: text, start: 0, end: nil, startSample: nil, endSample: nil)
  }

  private func paragraph(_ wordIDs: [Int]) -> TranscriptParagraph {
    TranscriptParagraph(
      id: "pause-\(wordIDs.first ?? 0)", kind: .pauseParagraph, speakerID: nil, title: nil,
      wordIDs: wordIDs)
  }

  @Test func buildsSpaceJoinedTextAndUTF16Ranges() {
    let doc = TranscriptDocument(words: [word(1, "Hello"), word(2, "world")])
    expectNoDifference(doc.text, "Hello world")
    expectNoDifference(
      doc.wordRanges,
      [
        TranscriptWordRange(wordID: 1, range: NSRange(location: 0, length: 5)),
        TranscriptWordRange(wordID: 2, range: NSRange(location: 6, length: 5)),
      ])
  }

  @Test func offsetInsideWordResolvesToThatWord() {
    let doc = TranscriptDocument(words: [word(1, "Hello"), word(2, "world")])
    expectNoDifference(doc.wordID(atUTF16Offset: 0), 1)
    expectNoDifference(doc.wordID(atUTF16Offset: 4), 1)
    expectNoDifference(doc.wordID(atUTF16Offset: 6), 2)
  }

  @Test func offsetOnSeparatorResolvesToPrecedingWord() {
    let doc = TranscriptDocument(words: [word(1, "Hello"), word(2, "world")])
    expectNoDifference(doc.wordID(atUTF16Offset: 5), 1)  // the space
  }

  @Test func offsetPastEndResolvesToLastWord() {
    let doc = TranscriptDocument(words: [word(1, "Hello"), word(2, "world")])
    expectNoDifference(doc.wordID(atUTF16Offset: 999), 2)
  }

  @Test func emptyWordsProducesEmptyDocument() {
    let doc = TranscriptDocument(words: [])
    expectNoDifference(doc.text, "")
    expectNoDifference(doc.wordRanges, [])
    expectNoDifference(doc.wordID(atUTF16Offset: 0), nil)
  }

  // MARK: - Paragraph breaks

  @Test func singleParagraphRendersLikeSpaceJoined() {
    let words = [word(1, "Hello"), word(2, "world")]
    let doc = TranscriptDocument(words: words, paragraphs: [paragraph([1, 2])])
    expectNoDifference(doc.text, "Hello world")
    expectNoDifference(doc, TranscriptDocument(words: words))
  }

  @Test func multipleParagraphsSeparateWithNewline() {
    let doc = TranscriptDocument(
      words: [word(1, "Hello"), word(2, "world"), word(3, "Foo"), word(4, "bar")],
      paragraphs: [paragraph([1, 2]), paragraph([3, 4])])
    expectNoDifference(doc.text, "Hello world\nFoo bar")
  }

  /// The crux of the PR: an inserted paragraph break must not shift any word's UTF-16
  /// range. A newline is one UTF-16 unit, exactly like the space it replaces, so every
  /// word after the break still maps to its correct location.
  @Test func paragraphBreakPreservesWordRanges() {
    let words = [word(1, "Hello"), word(2, "world"), word(3, "Foo"), word(4, "bar")]
    let broken = TranscriptDocument(
      words: words, paragraphs: [paragraph([1, 2]), paragraph([3, 4])])
    expectNoDifference(broken.wordRanges, TranscriptDocument(words: words).wordRanges)
    expectNoDifference(
      broken.wordRanges,
      [
        TranscriptWordRange(wordID: 1, range: NSRange(location: 0, length: 5)),
        TranscriptWordRange(wordID: 2, range: NSRange(location: 6, length: 5)),
        TranscriptWordRange(wordID: 3, range: NSRange(location: 12, length: 3)),
        TranscriptWordRange(wordID: 4, range: NSRange(location: 16, length: 3)),
      ])
  }

  @Test func wordAfterBreakResolvesByOffset() {
    let doc = TranscriptDocument(
      words: [word(1, "Hello"), word(2, "world"), word(3, "Foo"), word(4, "bar")],
      paragraphs: [paragraph([1, 2]), paragraph([3, 4])])
    expectNoDifference(doc.wordID(atUTF16Offset: 12), 3)  // first char of "Foo"
    expectNoDifference(doc.wordID(atUTF16Offset: 16), 4)  // first char of "bar"
    expectNoDifference(doc.wordID(atUTF16Offset: 11), 2)  // the newline → preceding word
  }

  /// A duplicate word ID must not create a spurious break: breaks are placed by word
  /// position, not by ID. Here word 1 appears twice, but the only break is after the
  /// first paragraph's last word (position 1), not at every occurrence of ID 1.
  @Test func duplicateWordIDDoesNotCauseSpuriousBreak() {
    let doc = TranscriptDocument(
      words: [word(1, "a"), word(2, "b"), word(1, "c"), word(3, "d")],
      paragraphs: [paragraph([1, 2]), paragraph([1, 3])])
    expectNoDifference(doc.text, "a b\nc d")
  }
}
