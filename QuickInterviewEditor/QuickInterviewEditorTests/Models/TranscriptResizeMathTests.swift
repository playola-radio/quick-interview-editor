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

  @Test func identityPriorityOrder() {
    expectNoDifference(TranscriptResizeItemIdentity.selection.priority, 3)
    expectNoDifference(TranscriptResizeItemIdentity.clip(UUID()).priority, 2)
    expectNoDifference(TranscriptResizeItemIdentity.suggestion(UUID()).priority, 1)
  }
}
