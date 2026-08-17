import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

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

  /// Adjacent same-kind words merge into ONE range that spans their interior separator but
  /// stops at the last word's end (no trailing space). "Hello world" = [0, 11).
  @Test func adjacentWordsMergeIntoOneContainer() {
    let bands = [TranscriptClipBand(id: Fixtures.uuid(1), wordIDs: [1, 2], kind: .approved)]
    expectNoDifference(
      model(clipBands: bands).clipContainers,
      [
        TranscriptClipContainer(
          range: NSRange(location: 0, length: 11), kind: .approved, colorIndex: 0)
      ])
  }

  /// Two disjoint bands become two containers, in transcript order, each carrying its kind.
  @Test func disjointBandsBecomeSeparateContainers() {
    let bands = [
      TranscriptClipBand(id: Fixtures.uuid(1), wordIDs: [1, 2], kind: .approved),
      TranscriptClipBand(id: Fixtures.uuid(2), wordIDs: [4, 5], kind: .suggested),
    ]
    expectNoDifference(
      model(clipBands: bands).clipContainers,
      [
        TranscriptClipContainer(
          range: NSRange(location: 0, length: 11), kind: .approved, colorIndex: 0),
        // "bar baz" starts at "Hello world Foo " = 16, ends at 23.
        TranscriptClipContainer(
          range: NSRange(location: 16, length: 7), kind: .suggested, colorIndex: 1),
      ])
  }

  /// A different-kind word between same-kind words splits the run: a green word sitting inside
  /// an amber span (the precedence-hole case) yields three separate containers.
  @Test func aStateChangeBetweenWordsSplitsTheRun() {
    let bands = [
      TranscriptClipBand(id: Fixtures.uuid(1), wordIDs: [2], kind: .approved),
      TranscriptClipBand(id: Fixtures.uuid(2), wordIDs: [1, 3], kind: .suggested),
    ]
    expectNoDifference(
      model(clipBands: bands).clipContainers,
      [
        // Hello and Foo are the same band, so they share colorIndex 0; world is a different clip.
        TranscriptClipContainer(
          range: NSRange(location: 0, length: 5), kind: .suggested, colorIndex: 0),  // Hello
        TranscriptClipContainer(
          range: NSRange(location: 6, length: 5), kind: .approved, colorIndex: 1),  // world
        TranscriptClipContainer(
          range: NSRange(location: 12, length: 3), kind: .suggested, colorIndex: 0),  // Foo
      ])
  }

  /// Two distinct bands of the SAME kind that sit back-to-back stay separate containers, each
  /// with its own caps — merging them would erase the per-clip boundary.
  @Test func adjacentSameKindBandsStaySeparate() {
    let bands = [
      TranscriptClipBand(id: Fixtures.uuid(1), wordIDs: [1, 2], kind: .approved),
      TranscriptClipBand(id: Fixtures.uuid(2), wordIDs: [3, 4], kind: .approved),
    ]
    expectNoDifference(
      model(clipBands: bands).clipContainers,
      [
        // Hello world
        TranscriptClipContainer(
          range: NSRange(location: 0, length: 11), kind: .approved, colorIndex: 0),
        // Foo bar — a different clip, so a different colour.
        TranscriptClipContainer(
          range: NSRange(location: 12, length: 7), kind: .approved, colorIndex: 1),
      ])
  }

  /// A clip that spans a paragraph break splits into one capped container per paragraph — a
  /// single container can't bridge the vertical gap between paragraphs — but BOTH pieces keep
  /// the same `colorIndex`, so the one clip draws in a single colour.
  @Test func aClipSpanningAParagraphBreakSplits() {
    let model = TranscriptPageModel(planURL: nil)
    // "Hello world\nFoo bar baz" — the break falls after word 2.
    model.document = TranscriptDocument(
      words: [
        word(1, "Hello"), word(2, "world"), word(3, "Foo"), word(4, "bar"), word(5, "baz"),
      ],
      paragraphs: [paragraph([1, 2]), paragraph([3, 4, 5])])
    model.clipBands = [
      TranscriptClipBand(id: Fixtures.uuid(1), wordIDs: [1, 2, 3, 4], kind: .approved)
    ]
    expectNoDifference(
      model.clipContainers,
      [
        // Hello world
        TranscriptClipContainer(
          range: NSRange(location: 0, length: 11), kind: .approved, colorIndex: 0),
        // Foo bar — same clip, so the SAME colorIndex.
        TranscriptClipContainer(
          range: NSRange(location: 12, length: 7), kind: .approved, colorIndex: 0),
      ])
  }

  /// Bands handed in out of transcript order still yield position-ordered containers.
  @Test func containersFollowTranscriptOrderNotBandOrder() {
    let bands = [
      TranscriptClipBand(id: Fixtures.uuid(2), wordIDs: [5], kind: .suggested),
      TranscriptClipBand(id: Fixtures.uuid(1), wordIDs: [1], kind: .approved),
    ]
    let containers = model(clipBands: bands).clipContainers
    expectNoDifference(containers.map(\.range.location), [0, 20])
  }
}
