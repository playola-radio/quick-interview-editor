import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

@MainActor
struct TranscriptDocumentTests {
  private func word(_ id: Int, _ text: String) -> Word {
    Word(id: id, text: text, start: 0, end: nil, startSample: nil, endSample: nil)
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
}
