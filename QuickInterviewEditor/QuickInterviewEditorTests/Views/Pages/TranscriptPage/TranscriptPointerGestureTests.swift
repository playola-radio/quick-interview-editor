import CoreGraphics
import CustomDump
import Testing

@testable import PlayolaInterviewEditor

struct TranscriptPointerGestureTests {
  @Test func jitterRemainsAClickAndRealDragNeverOpens() {
    var gesture = TranscriptPointerGesture()
    gesture.began(at: .zero)
    expectNoDifference(gesture.moved(to: CGPoint(x: 2, y: 1)), false)
    expectNoDifference(gesture.ended(clickCount: 2), .click(count: 2))
    gesture.began(at: .zero)
    expectNoDifference(gesture.moved(to: CGPoint(x: 4, y: 0)), true)
    expectNoDifference(gesture.ended(clickCount: 2), .dragEnded)
  }

  @Test func returningToOriginDoesNotTurnADragIntoAClick() {
    var gesture = TranscriptPointerGesture()
    gesture.began(at: .zero)
    expectNoDifference(gesture.moved(to: CGPoint(x: 10, y: 0)), true)
    expectNoDifference(gesture.moved(to: .zero), false)
    expectNoDifference(gesture.ended(clickCount: 1), .dragEnded)
    expectNoDifference(gesture.ended(clickCount: 1), .none)
  }

  @Test func cancellationPreventsClickAndNextPressStartsCleanly() {
    var gesture = TranscriptPointerGesture()
    gesture.began(at: .zero)
    _ = gesture.moved(to: CGPoint(x: 10, y: 0))
    gesture.cancelled()
    expectNoDifference(gesture.ended(clickCount: 2), .none)
    gesture.began(at: .zero)
    expectNoDifference(gesture.ended(clickCount: 1), .click(count: 1))
  }
}
