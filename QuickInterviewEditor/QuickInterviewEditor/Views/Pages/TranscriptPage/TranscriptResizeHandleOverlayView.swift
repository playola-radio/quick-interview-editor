import AppKit

/// Transparent overlay inside the transcript document view. Owns the resize
/// cursor and edge hit-testing; forwards drags to the model. Returns nil from
/// `hitTest` outside a grab zone so word-select underneath keeps working. Since
/// `hitTest` claims points inside a grab zone even before a drag threshold is
/// crossed, a plain (or Shift-)click there never reaches `HitTestingTextView` —
/// `mouseUp` forwards a no-drag click through the same
/// `utf16Offset(at:)` → `transcriptClicked(atUTF16Offset:extending:)` path the
/// text view uses, so clicking near an edge still selects/extends normally.
final class TranscriptResizeHandleOverlayView: NSView {
  weak var coordinator: TranscriptTextView.Coordinator?

  private var activeHandle: TranscriptResizeHandleTarget?
  private var downPoint: NSPoint?
  private var didBeginResize = false
  private var trackingArea: NSTrackingArea?

  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    return coordinator?.resizeHandle(at: local) == nil ? nil : self
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [
        .cursorUpdate, .mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect,
      ],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    trackingArea = area
  }

  override func cursorUpdate(with event: NSEvent) { setCursor(for: event) }
  override func mouseMoved(with event: NSEvent) { setCursor(for: event) }
  override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

  private func setCursor(for event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if coordinator?.resizeHandle(at: point) != nil {
      NSCursor.resizeLeftRight.set()
    } else {
      NSCursor.arrow.set()
    }
  }

  override func mouseDown(with event: NSEvent) {
    endActiveTextEditing()
    let point = convert(event.locationInWindow, from: nil)
    activeHandle = coordinator?.resizeHandle(at: point)
    downPoint = point
    didBeginResize = false
  }

  override func mouseDragged(with event: NSEvent) {
    guard let handle = activeHandle, let down = downPoint, let coordinator else { return }
    let point = convert(event.locationInWindow, from: nil)
    if !didBeginResize {
      guard abs(point.x - down.x) >= TranscriptResizeMetrics.dragThreshold else { return }
      guard
        coordinator.model.transcriptResizeBegan(
          handle.identity, handle.edge, occurrence: handle.occurrence)
      else {
        return
      }
      didBeginResize = true
    }
    if let occurrence = coordinator.wordOccurrenceForResize(at: point) {
      coordinator.model.transcriptResizeDragged(to: occurrence)
    }
  }

  override func mouseUp(with event: NSEvent) {
    if didBeginResize {
      coordinator?.model.transcriptResizeEnded()
    } else if let coordinator, let down = downPoint,
      let offset = coordinator.utf16Offset(at: down)
    {
      coordinator.model.transcriptClicked(
        atUTF16Offset: offset, extending: event.modifierFlags.contains(.shift))
    }
    activeHandle = nil
    downPoint = nil
    didBeginResize = false
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    if newWindow == nil, didBeginResize {
      coordinator?.model.transcriptResizeCancelled()
      didBeginResize = false
      activeHandle = nil
    }
  }
}
