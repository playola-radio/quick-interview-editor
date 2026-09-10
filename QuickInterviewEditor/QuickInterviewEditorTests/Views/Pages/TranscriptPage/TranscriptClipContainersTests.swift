import AppKit
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

  // MARK: - changed(from:to:) — the resize-drag repaint diff

  private func container(_ location: Int, _ length: Int, _ kind: TranscriptClipKind = .approved)
    -> TranscriptClipContainer
  {
    TranscriptClipContainer(
      range: NSRange(location: location, length: length), kind: kind,
      colorIndex: 0)
  }

  /// Nothing moved between two renders, so no container needs repainting — the fast path a
  /// steady (non-drag) frame takes.
  @Test func changedIsEmptyWhenRendersMatch() {
    let same = [container(0, 11), container(16, 7, .suggested)]
    expectNoDifference(TranscriptClipContainer.changed(from: same, to: same), [])
  }

  /// A resize that grows one clip changes only that clip's container: the old span leaves and
  /// the new span enters, while every untouched clip/suggestion is omitted. This is the whole
  /// point — a drag over a 37-container transcript repaints 2 containers, not 37.
  @Test func changedReturnsOnlyTheMovedContainerBothWays() {
    let untouched = container(40, 5, .suggested)
    let old = [container(0, 11), untouched]
    let new = [container(0, 16), untouched]
    expectNoDifference(
      TranscriptClipContainer.changed(from: old, to: new),
      [container(0, 11), container(0, 16)])
  }

  /// A newly-created container (none removed) enters; a deleted one (none added) leaves.
  @Test func changedHandlesPureAddAndPureRemove() {
    let base = [container(0, 11)]
    expectNoDifference(
      TranscriptClipContainer.changed(from: base, to: base + [container(16, 7, .suggested)]),
      [container(16, 7, .suggested)])
    expectNoDifference(
      TranscriptClipContainer.changed(from: base + [container(16, 7, .suggested)], to: base),
      [container(16, 7, .suggested)])
  }

  /// A container whose only change is kind (same range) still counts as changed — its words
  /// need the new colour/strikethrough even though the span is identical.
  @Test func changedDetectsKindOnlyChange() {
    let old = [container(0, 11, .approved)]
    let new = [container(0, 11, .rejected)]
    expectNoDifference(
      TranscriptClipContainer.changed(from: old, to: new),
      [container(0, 11, .approved), container(0, 11, .rejected)])
  }

  @Test func changedRepaintsWhenOverlappingForegroundOrderChanges() {
    let clip = container(0, 11, .approved)
    let suggestion = container(0, 11, .suggested)
    expectNoDifference(
      TranscriptClipContainer.changed(from: [clip, suggestion], to: [suggestion, clip]),
      [clip, suggestion, suggestion, clip])
  }

  @Test func changedDetectsPreviewOnlyChange() {
    let original = container(0, 11, .suggested)
    var previewed = original
    previewed.isPreviewed = true
    expectNoDifference(
      TranscriptClipContainer.changed(from: [original], to: [previewed]),
      [original, previewed])
  }

  private func applyResizeItems(
    _ items: [TranscriptResizeItem], to coordinator: TranscriptTextView.Coordinator
  ) {
    coordinator.apply(
      text: coordinator.model.plainTranscriptText, fontSize: 17, selected: [],
      clipContainers: [], selectionRuns: [], removedWordIDs: [], currentWordID: nil,
      scrollTarget: nil, followMode: .following, reveal: nil, resizeItems: items)
  }

  @Test func coincidentResizeEdgesFollowForegroundObjectOrderAndFreeformWins() throws {
    let model = model(clipBands: [])
    let coordinator = TranscriptTextView.Coordinator(model: model)
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
    coordinator.textView = textView
    let occurrences = [
      TranscriptWordOccurrence(wordID: 1, transcriptIndex: 0),
      TranscriptWordOccurrence(wordID: 2, transcriptIndex: 1),
    ]
    let suggestion = TranscriptResizeItem(
      identity: .suggestion(Fixtures.uuid(1)), wordOccurrences: occurrences)
    let clip = TranscriptResizeItem(
      identity: .clip(Fixtures.uuid(2)), wordOccurrences: occurrences)
    applyResizeItems([suggestion, clip], to: coordinator)
    let zone = try #require(coordinator.resizeZones().first)
    let point = NSPoint(x: zone.rect.midX, y: zone.rect.midY)
    expectNoDifference(coordinator.resizeHandle(at: point)?.identity, suggestion.identity)
    let endZone = try #require(coordinator.resizeZones().first { $0.edge == .end })
    let bodyPoint = NSPoint(x: (zone.rect.midX + endZone.rect.midX) / 2, y: zone.rect.midY)
    #expect(coordinator.resizeHandle(at: bodyPoint) == nil)

    applyResizeItems([clip, suggestion], to: coordinator)
    expectNoDifference(coordinator.resizeHandle(at: point)?.identity, clip.identity)

    let selection = TranscriptResizeItem(identity: .selection, wordOccurrences: occurrences)
    applyResizeItems([suggestion, clip, selection], to: coordinator)
    expectNoDifference(coordinator.resizeHandle(at: point)?.identity, .selection)
  }

  @Test func rebuildingTextMovesCachedResizeEdgesWithoutChangingWordOccurrences() throws {
    let model = model(clipBands: [])
    let coordinator = TranscriptTextView.Coordinator(model: model)
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
    coordinator.textView = textView
    let item = TranscriptResizeItem(
      identity: .clip(Fixtures.uuid(1)),
      wordOccurrences: [TranscriptWordOccurrence(wordID: 1, transcriptIndex: 0)])
    applyResizeItems([item], to: coordinator)
    let originalEnd = try #require(coordinator.resizeZones().last).rect.midX

    model.document = TranscriptDocument(words: [word(1, "A significantly longer word")])
    applyResizeItems([item], to: coordinator)
    let rebuiltEnd = try #require(coordinator.resizeZones().last).rect.midX
    #expect(rebuiltEnd > originalEnd)
  }

}
