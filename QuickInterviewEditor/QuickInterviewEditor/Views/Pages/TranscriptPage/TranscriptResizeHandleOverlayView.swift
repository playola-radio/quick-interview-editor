import AppKit

/// Transparent overlay inside the transcript document view. Owns the resize
/// cursor and edge hit-testing; forwards drags to the model. Returns nil from
/// `hitTest` outside a grab zone so word-select underneath keeps working.
final class TranscriptResizeHandleOverlayView: NSView {
  weak var coordinator: TranscriptTextView.Coordinator?

  private var activeHandle: (TranscriptResizeItemIdentity, TranscriptResizeEdge)?
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
      options: [.cursorUpdate, .mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    trackingArea = area
  }

  override func cursorUpdate(with event: NSEvent) { setCursor(for: event) }
  override func mouseMoved(with event: NSEvent) { setCursor(for: event) }
  override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

  private func setCursor(for event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    if coordinator?.resizeHandle(at: p) != nil { NSCursor.resizeLeftRight.set() }
    else { NSCursor.arrow.set() }
  }

  override func mouseDown(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    activeHandle = coordinator?.resizeHandle(at: p)
    downPoint = p
    didBeginResize = false
  }

  override func mouseDragged(with event: NSEvent) {
    guard let handle = activeHandle, let down = downPoint, let coordinator else { return }
    let p = convert(event.locationInWindow, from: nil)
    if !didBeginResize {
      guard abs(p.x - down.x) >= TranscriptResizeMetrics.dragThreshold else { return }
      didBeginResize = true
      coordinator.model.transcriptResizeBegan(handle.0, handle.1)
    }
    if let wordID = coordinator.wordIDForResize(at: p) {
      coordinator.model.transcriptResizeDragged(toWord: wordID)
    }
  }

  override func mouseUp(with event: NSEvent) {
    if didBeginResize { coordinator?.model.transcriptResizeEnded() }
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
