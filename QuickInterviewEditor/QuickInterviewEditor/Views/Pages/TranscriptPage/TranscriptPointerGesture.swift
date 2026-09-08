import CoreGraphics
import Foundation

/// Classifies pointer movement in window coordinates, independent of transcript
/// scrolling or TextKit hit resolution. Crossing the threshold begins exactly once.
struct TranscriptPointerGesture {
  enum Result: Equatable {
    case click(count: Int)
    case dragEnded
    case none
  }

  private var origin: CGPoint?
  private(set) var isDragging = false

  mutating func began(at point: CGPoint) {
    origin = point
    isDragging = false
  }

  mutating func moved(to point: CGPoint) -> Bool {
    guard let origin, !isDragging else { return false }
    let deltaX = point.x - origin.x
    let deltaY = point.y - origin.y
    guard deltaX * deltaX + deltaY * deltaY >= 16 else { return false }
    isDragging = true
    return true
  }

  mutating func ended(clickCount: Int) -> Result {
    defer { cancelled() }
    guard origin != nil else { return .none }
    return isDragging ? .dragEnded : .click(count: clickCount)
  }

  mutating func cancelled() {
    origin = nil
    isDragging = false
  }
}

/// AppKit supplies event timing; the editor decides what the hit selects or opens.
struct TranscriptClick {
  let wordID: Word.ID?
  let extending: Bool
  let count: Int
  let timestamp: TimeInterval
  let doubleClickInterval: TimeInterval
  var utf16Offset: Int?
}

struct TranscriptClickCapture {
  let selection: EditorSelection
  let range: Range<Int>
  let timestamp: TimeInterval
}
