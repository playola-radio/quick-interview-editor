import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct TranscriptClipContainersTests {

  private func word(_ id: Int, _ text: String) -> Word {
    Word(id: id, text: text, start: 0, end: nil, startSample: nil, endSample: nil)
  }

  private func paragraph(_ wordIDs: [Int]) -> TranscriptParagraph {
    TranscriptParagraph(
      id: "pause-\(wordIDs.first ?? 0)", kind: .pauseParagraph, speakerID: nil, title: nil,
      wordIDs: wordIDs)
  }

  /// A model whose document is "Hello world Foo bar baz" (ids 1…5) with no plan, so the
  /// container derivation can be exercised in isolation from slices/suggestions.
  private func model(clipBands: [TranscriptClipBand]) -> TranscriptPageModel {
    let model = TranscriptPageModel(planURL: nil)
    model.document = TranscriptDocument(words: [
      word(1, "Hello"), word(2, "world"), word(3, "Foo"), word(4, "bar"), word(5, "baz"),
    ])
    model.clipBands = clipBands
    return model
  }

  @Test func noBandsProducesNoContainers() {
    expectNoDifference(model(clipBands: []).clipContainers, [])
  }

  @Test func adjacentWordsMergeWithTypedIdentity() {
    let bands = [TranscriptClipBand(id: Fixtures.uuid(1), wordIDs: [1, 2], kind: .approved)]
    expectNoDifference(
      model(clipBands: bands).clipContainers,
      [
        TranscriptClipContainer(
          range: NSRange(location: 0, length: 11), kind: .approved,
          colorIndex: 0, objectID: .clip(Fixtures.uuid(1)))
      ])
  }

  @Test func identicalOverlappingBandsKeepBothFullContainers() {
    let id = Fixtures.uuid(1)
    let bands = [
      TranscriptClipBand(id: id, wordIDs: [1, 2, 3], kind: .approved),
      TranscriptClipBand(id: id, wordIDs: [1, 2, 3], kind: .suggested),
    ]
    let containers = model(clipBands: bands).clipContainers
    expectNoDifference(
      containers.map(\.range),
      [
        NSRange(location: 0, length: 15), NSRange(location: 0, length: 15),
      ])
    expectNoDifference(containers.map(\.objectID), [.clip(id), .suggestion(id)])
  }

  @Test func foregroundOrderDoesNotTruncateNestedOrPartialBands() {
    let bands = [
      TranscriptClipBand(id: Fixtures.uuid(1), wordIDs: [2], kind: .approved),
      TranscriptClipBand(id: Fixtures.uuid(2), wordIDs: [1, 2, 3, 4], kind: .suggested),
      TranscriptClipBand(id: Fixtures.uuid(3), wordIDs: [3, 4, 5], kind: .approved),
    ]
    expectNoDifference(
      model(clipBands: bands).clipContainers.map(\.range),
      [
        NSRange(location: 6, length: 5), NSRange(location: 0, length: 19),
        NSRange(location: 12, length: 11),
      ])
  }

  @Test func missingInteriorWordsSplitOnlyTheirOwnBand() {
    let bands = [
      TranscriptClipBand(id: Fixtures.uuid(1), wordIDs: [2], kind: .approved),
      TranscriptClipBand(id: Fixtures.uuid(2), wordIDs: [1, 3], kind: .suggested),
    ]
    let containers = model(clipBands: bands).clipContainers
    expectNoDifference(
      containers.map(\.range),
      [
        NSRange(location: 6, length: 5), NSRange(location: 0, length: 5),
        NSRange(location: 12, length: 3),
      ])
    expectNoDifference(containers.map(\.colorIndex), [0, 1, 1])
  }

  @Test func adjacentSameKindBandsStaySeparate() {
    let bands = [
      TranscriptClipBand(id: Fixtures.uuid(1), wordIDs: [1, 2], kind: .approved),
      TranscriptClipBand(id: Fixtures.uuid(2), wordIDs: [3, 4], kind: .approved),
    ]
    let containers = model(clipBands: bands).clipContainers
    expectNoDifference(
      containers.map(\.range),
      [
        NSRange(location: 0, length: 11), NSRange(location: 12, length: 7),
      ])
    expectNoDifference(containers.map(\.colorIndex), [0, 1])
  }

  @Test func paragraphBreakSplitsEachFullObjectWhileKeepingIdentityAndColor() {
    let model = TranscriptPageModel(planURL: nil)
    model.document = TranscriptDocument(
      words: [word(1, "Hello"), word(2, "world"), word(3, "Foo"), word(4, "bar")],
      paragraphs: [paragraph([1, 2]), paragraph([3, 4])])
    model.clipBands = [
      TranscriptClipBand(id: Fixtures.uuid(1), wordIDs: [1, 2, 3, 4], kind: .approved),
      TranscriptClipBand(id: Fixtures.uuid(2), wordIDs: [2, 3], kind: .suggested),
    ]
    expectNoDifference(
      model.clipContainers.map(\.range),
      [
        NSRange(location: 0, length: 11), NSRange(location: 12, length: 7),
        NSRange(location: 6, length: 5), NSRange(location: 12, length: 3),
      ])
    expectNoDifference(model.clipContainers.map(\.colorIndex), [0, 0, 1, 1])
    expectNoDifference(
      model.clipContainers.map(\.objectID),
      [
        .clip(Fixtures.uuid(1)), .clip(Fixtures.uuid(1)),
        .suggestion(Fixtures.uuid(2)), .suggestion(Fixtures.uuid(2)),
      ])
  }

  @Test func promotionPreservesExplicitColorAndSuggestionOutline() {
    let bands = [
      TranscriptClipBand(
        id: Fixtures.uuid(2), wordIDs: [1, 2], kind: .suggested,
        colorIndex: 3, isActive: true),
      TranscriptClipBand(
        id: Fixtures.uuid(1), wordIDs: [1, 2], kind: .approved,
        colorIndex: 1, isSubdued: true),
    ]
    let containers = model(clipBands: bands).clipContainers
    expectNoDifference(containers.map(\.colorIndex), [3, 1])
    #expect(containers[0].style.dashed)
    #expect(!containers[1].style.dashed)
    expectNoDifference(containers[0].style.ringWidth, 2)
    expectNoDifference(containers[1].style.ringWidth, 1)
  }
}
