import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct TranscriptResizeMathTests {
  // Words a=1, b=2, c=3, d=4, e=5 in transcript order. (Word.ID is Int, not
  // String — see EditPlan.Word — so letters are represented by their index.)
  let order: [Word.ID] = [1, 2, 3, 4, 5]

  @Test func startEdgeGrowsLeftToTargetWord() {
    let result = TranscriptResizeMath.resized(
      itemWordIDs: [3, 4], edge: .start, toTargetWord: 1, transcriptOrder: order)
    expectNoDifference(result, [1, 2, 3, 4])
  }

  @Test func startEdgeShrinksRightButCannotCrossEnd() {
    // Dragging the start past the end pins it to the end word (min one word).
    let result = TranscriptResizeMath.resized(
      itemWordIDs: [2, 3, 4], edge: .start, toTargetWord: 5, transcriptOrder: order)
    expectNoDifference(result, [4])
  }

  @Test func endEdgeGrowsRightToTargetWord() {
    let result = TranscriptResizeMath.resized(
      itemWordIDs: [2, 3], edge: .end, toTargetWord: 5, transcriptOrder: order)
    expectNoDifference(result, [2, 3, 4, 5])
  }

  @Test func endEdgeShrinksLeftButCannotCrossStart() {
    let result = TranscriptResizeMath.resized(
      itemWordIDs: [2, 3, 4], edge: .end, toTargetWord: 1, transcriptOrder: order)
    expectNoDifference(result, [2])
  }

  @Test func targetNotInOrderReturnsNil() {
    let result = TranscriptResizeMath.resized(
      itemWordIDs: [2, 3], edge: .end, toTargetWord: 99, transcriptOrder: order)
    expectNoDifference(result, nil)
  }

  @Test func emptyItemReturnsNil() {
    let result = TranscriptResizeMath.resized(
      itemWordIDs: [], edge: .start, toTargetWord: 1, transcriptOrder: order)
    expectNoDifference(result, nil)
  }

  @Test func startEdgeUsesLaterDuplicateOccurrence() {
    let item = TranscriptResizeItem(
      identity: .selection,
      wordOccurrences: [
        TranscriptWordOccurrence(wordID: 2, transcriptIndex: 1),
        TranscriptWordOccurrence(wordID: 1, transcriptIndex: 2),
      ])
    let result = TranscriptResizeMath.resized(
      item: item, edge: .start,
      toTarget: TranscriptWordOccurrence(wordID: 1, transcriptIndex: 2),
      transcriptOrder: [1, 2, 1, 3])
    expectNoDifference(result, [1])
  }

  @Test func identityPriorityOrder() {
    expectNoDifference(TranscriptResizeItemIdentity.selection.priority, 3)
    expectNoDifference(TranscriptResizeItemIdentity.clip(UUID()).priority, 2)
    expectNoDifference(TranscriptResizeItemIdentity.suggestion(UUID()).priority, 1)
  }

  // MARK: - D2 hit resolution

  private func zone(
    _ identity: TranscriptResizeItemIdentity, _ edge: TranscriptResizeEdge, minX: CGFloat,
    width: CGFloat = 20
  ) -> TranscriptResizeHandleZone {
    TranscriptResizeHandleZone(
      identity: identity, edge: edge,
      occurrence: TranscriptWordOccurrence(wordID: 1, transcriptIndex: 0),
      rect: CGRect(x: minX, y: 0, width: width, height: 10), priority: identity.priority)
  }

  @Test func noZoneContainingPointResolvesNil() {
    let zones = [zone(.selection, .start, minX: 0)]
    let result = TranscriptResizeMath.resolveHandle(
      hitting: CGPoint(x: 100, y: 5), in: zones)
    expectNoDifference(result == nil, true)
  }

  /// D2: when a selection and a clip handle overlap the same point, the selection wins.
  @Test func selectionOutranksClipAtSamePoint() {
    let zones = [
      zone(.clip(UUID()), .start, minX: 0),
      zone(.selection, .start, minX: 0),
    ]
    let result = TranscriptResizeMath.resolveHandle(hitting: CGPoint(x: 10, y: 5), in: zones)
    expectNoDifference(result?.identity, .selection)
    expectNoDifference(result?.edge, .start)
  }

  /// D2: a clip outranks a suggestion at the same point.
  @Test func clipOutranksSuggestionAtSamePoint() {
    let clipID = UUID()
    let zones = [
      zone(.suggestion(UUID()), .end, minX: 0),
      zone(.clip(clipID), .end, minX: 0),
    ]
    let result = TranscriptResizeMath.resolveHandle(hitting: CGPoint(x: 10, y: 5), in: zones)
    expectNoDifference(result?.identity, .clip(clipID))
    expectNoDifference(result?.edge, .end)
  }

  /// Equal priority (two clips): the nearer edge-x breaks the tie. midX 10 vs midX 15,
  /// point at x=9 sits inside both but closer to the first.
  @Test func equalPriorityBreaksTieByNearestEdge() {
    let nearID = UUID()
    let zones = [
      zone(.clip(nearID), .start, minX: 0),  // midX 10
      zone(.clip(UUID()), .start, minX: 5),  // midX 15
    ]
    let result = TranscriptResizeMath.resolveHandle(hitting: CGPoint(x: 9, y: 5), in: zones)
    expectNoDifference(result?.identity, .clip(nearID))
  }

  /// Same item (selection), start and end zones equidistant from the point: the edge tie-break
  /// resolves to `.end`, preserving the pre-extraction string-key ordering (`"…end" < "…start"`).
  @Test func sameItemEdgeTieResolvesToEnd() {
    let zones = [
      zone(.selection, .start, minX: 0, width: 24),  // midX 12
      zone(.selection, .end, minX: 16, width: 24),  // midX 28
    ]
    let result = TranscriptResizeMath.resolveHandle(hitting: CGPoint(x: 20, y: 5), in: zones)
    expectNoDifference(result?.identity, .selection)
    expectNoDifference(result?.edge, .end)
  }

  /// Full tie (same priority, same edge-distance): resolution is deterministic — the same
  /// input never flickers between the two equally-eligible zones.
  @Test func fullTieResolvesDeterministically() {
    let zones = [
      zone(.clip(UUID()), .start, minX: 0),
      zone(.clip(UUID()), .start, minX: 0),
    ]
    let point = CGPoint(x: 10, y: 5)
    let first = TranscriptResizeMath.resolveHandle(hitting: point, in: zones)
    let second = TranscriptResizeMath.resolveHandle(hitting: point, in: zones)
    expectNoDifference(first?.identity, second?.identity)
    expectNoDifference(first?.edge, second?.edge)
  }
}
