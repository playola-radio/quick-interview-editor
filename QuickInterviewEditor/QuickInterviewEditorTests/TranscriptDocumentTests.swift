import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

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

  // MARK: - words(startingWithin:)

  /// The bounded lookup must return exactly the words whose start location falls inside the
  /// character range — the same predicate the clip-container foreground pass used to evaluate
  /// with a full scan, now used per container on the resize hot path.
  @Test func wordsStartingWithinReturnsCoveredWords() {
    // "Hello world Foo bar" → ranges: 1@0..5, 2@6..11, 3@12..15, 4@16..19
    let doc = TranscriptDocument(words: [
      word(1, "Hello"), word(2, "world"), word(3, "Foo"), word(4, "bar"),
    ])
    let covered = doc.words(startingWithin: NSRange(location: 6, length: 10)).map(\.wordID)
    expectNoDifference(covered, [2, 3])  // starts 6 and 12 are inside [6, 16); 16 (bar) is not
  }

  @Test func wordsStartingWithinIsInclusiveOfRangeStartExclusiveOfEnd() {
    let doc = TranscriptDocument(words: [
      word(1, "Hello"), word(2, "world"), word(3, "Foo"),
    ])
    // Range starting exactly at word 2's location includes it.
    expectNoDifference(
      doc.words(startingWithin: NSRange(location: 6, length: 1)).map(\.wordID), [2])
    // Whole document.
    expectNoDifference(
      doc.words(startingWithin: NSRange(location: 0, length: 100)).map(\.wordID), [1, 2, 3])
  }

  @Test func wordsStartingWithinEmptyOrOutOfRangeIsEmpty() {
    let doc = TranscriptDocument(words: [word(1, "Hello"), word(2, "world")])
    expectNoDifference(doc.words(startingWithin: NSRange(location: 6, length: 0)).isEmpty, true)
    expectNoDifference(doc.words(startingWithin: NSRange(location: 100, length: 5)).isEmpty, true)
    expectNoDifference(
      TranscriptDocument(words: []).words(startingWithin: NSRange(location: 0, length: 5)).isEmpty,
      true)
  }

  /// The bounded lookup must agree with the full-scan predicate it replaced across every
  /// sub-range, so the optimization can never drop or add a word versus the original behavior.
  @Test func wordsStartingWithinMatchesFullScanPredicate() {
    let words = (0..<40).map { word($0, "w\($0)") }
    let doc = TranscriptDocument(words: words)
    let total = doc.text.utf16.count
    for start in stride(from: 0, through: total, by: 3) {
      for length in stride(from: 0, through: total - start + 5, by: 5) {
        let range = NSRange(location: start, length: length)
        let bounded = Set(doc.words(startingWithin: range).map(\.wordID))
        let scanned = Set(
          doc.wordRanges.filter { NSLocationInRange($0.range.location, range) }.map(\.wordID))
        expectNoDifference(bounded, scanned)
      }
    }
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

  // MARK: - selectionRuns(for:)

  /// Adjacent selected words merge into one gapless run that spans the interior separator, so
  /// the selection sweep draws as a single sweep behind the run instead of per-word boxes.
  @Test func selectionRunsMergesAdjacentWords() {
    let doc = TranscriptDocument(
      words: [word(1, "Hello"), word(2, "world"), word(3, "Foo"), word(4, "bar")])
    expectNoDifference(doc.selectionRuns(for: [1, 2]), [NSRange(location: 0, length: 11)])
  }

  /// An unselected word between two selected words splits the sweep into two runs.
  @Test func selectionRunsSplitsOnGap() {
    let doc = TranscriptDocument(
      words: [word(1, "Hello"), word(2, "world"), word(3, "Foo"), word(4, "bar")])
    expectNoDifference(
      doc.selectionRuns(for: [1, 3]),
      [NSRange(location: 0, length: 5), NSRange(location: 12, length: 3)])
  }

  @Test func selectionRunsEmptyForNoSelection() {
    let doc = TranscriptDocument(
      words: [word(1, "Hello"), word(2, "world"), word(3, "Foo"), word(4, "bar")])
    expectNoDifference(doc.selectionRuns(for: []), [])
  }

  @Test func selectionRunsSingleWordIsItsRange() {
    let doc = TranscriptDocument(
      words: [word(1, "Hello"), word(2, "world"), word(3, "Foo"), word(4, "bar")])
    expectNoDifference(doc.selectionRuns(for: [2]), [NSRange(location: 6, length: 5)])
  }

  /// Words adjacent across a paragraph break still merge into one run; the layout manager draws
  /// the sweep per line fragment, so spanning the newline stays gapless within each line.
  @Test func selectionRunsMergesAcrossParagraphBreak() {
    let doc = TranscriptDocument(
      words: [word(1, "Hello"), word(2, "world"), word(3, "Foo"), word(4, "bar")],
      paragraphs: [paragraph([1, 2]), paragraph([3, 4])])
    expectNoDifference(doc.selectionRuns(for: [2, 3]), [NSRange(location: 6, length: 9)])
  }
}
