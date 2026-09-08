import AppKit
import SwiftUI

/// Anchors an AppKit popover to an overlay button without changing TextKit layout.
@MainActor
final class TranscriptOverlapPresenter: NSObject, NSPopoverDelegate {
  let model: TranscriptOverlapModel
  weak var textView: NSTextView?
  let button = NSButton()
  let popover = NSPopover()
  private var keyMonitor: Any?

  init(model: TranscriptOverlapModel) {
    self.model = model
    super.init()
    button.target = self
    button.action = #selector(openChooser)
    button.setButtonType(.momentaryPushIn)
    button.isBordered = true
    button.bezelStyle = .rounded
    button.wantsLayer = true
    button.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    button.layer?.cornerRadius = 5
    button.setAccessibilityElement(true)
    button.setAccessibilityRole(.button)
    button.font = .systemFont(ofSize: 11)
    popover.behavior = .transient
    popover.delegate = self
    popover.contentViewController = NSHostingController(
      rootView: TranscriptOverlapView(model: model))
  }

  func update(textView: NSTextView, document: TranscriptDocument) {
    self.textView = textView
    if button.superview !== textView { textView.addSubview(button) }
    button.title = model.controlLabel
    button.setAccessibilityLabel(model.accessibilityLabel)
    button.sizeToFit()
    guard model.showsControl, let id = model.anchorWordID,
      let range = document.wordRanges.first(where: { $0.wordID == id })?.range,
      let layout = textView.layoutManager, let container = textView.textContainer
    else {
      button.isHidden = true
      popover.close()
      return
    }
    layout.ensureLayout(for: container)
    let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
    let word = layout.boundingRect(forGlyphRange: glyphs, in: container)
      .offsetBy(dx: textView.textContainerInset.width, dy: textView.textContainerInset.height)
    let viewport = textView.visibleRect
    guard viewport.intersects(word) else {
      button.isHidden = true
      popover.close()
      return
    }
    button.frame.origin = Self.buttonOrigin(word: word, size: button.frame.size, viewport: viewport)
    button.isHidden = false
    if !model.isPresented { popover.close() }
  }

  static func buttonOrigin(word: NSRect, size: NSSize, viewport: NSRect) -> NSPoint {
    let proposals = [
      NSPoint(x: word.maxX + 4, y: word.minY),
      NSPoint(x: word.minX - size.width - 4, y: word.minY),
      NSPoint(x: word.minX, y: word.maxY + 4),
      NSPoint(x: word.minX, y: word.minY - size.height - 4),
      viewport.origin,
    ]
    for proposal in proposals {
      let origin = NSPoint(
        x: min(max(viewport.minX, proposal.x), max(viewport.minX, viewport.maxX - size.width)),
        y: min(max(viewport.minY, proposal.y), max(viewport.minY, viewport.maxY - size.height)))
      if !NSRect(origin: origin, size: size).intersects(word) { return origin }
    }
    // A viewport smaller than the word/control cannot contain both; keep the word interactive.
    return NSPoint(x: viewport.maxX + 1, y: viewport.minY)
  }

  @objc private func openChooser() {
    model.present()
    guard model.isPresented else { return }
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    if keyMonitor == nil {
      keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        let consumed = MainActor.assumeIsolated { self?.model.keyDown(event.keyCode) ?? false }
        return consumed ? nil : event
      }
    }
  }

  func popoverDidClose(_ notification: Notification) {
    model.dismiss()
    removeKeyMonitor()
  }

  func dismantle() {
    popover.close()
    button.removeFromSuperview()
    removeKeyMonitor()
  }

  private func removeKeyMonitor() {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
  }
}
