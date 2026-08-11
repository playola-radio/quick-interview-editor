import AppKit
import SwiftUI

/// A zero-size bridge that installs a window-scoped keyDown monitor for the editor's
/// global shortcuts (⌘←/⌘→ zoom, Z zoom-to-fit) and forwards them to `EditorModel`.
/// It consumes only those keys, only in its own window, and never while a text-entry
/// field is first responder. All behavior lives on the model; this just translates events.
struct EditorKeyMonitor: NSViewRepresentable {
  let model: EditorModel

  func makeNSView(context: Context) -> MonitorView {
    let view = MonitorView()
    view.model = model
    return view
  }

  func updateNSView(_ nsView: MonitorView, context: Context) {
    nsView.model = model
  }

  final class MonitorView: NSView {
    var model: EditorModel?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      removeMonitor()
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        self?.handle(event) ?? event
      }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
      guard let window, event.window === window else { return event }
      guard !Self.isTextEntryActive(in: window) else { return event }
      guard let key = Self.editorKey(for: event), let model else { return event }
      return model.editorKeyDown(key) ? nil : event
    }

    /// Exactly ⌘← / ⌘→ ⇒ zoom out/in; Z with no modifiers ⇒ zoom-to-fit. Any extra
    /// modifier (Shift, Option, Control) falls through, as do ⌘Z (undo) and ⌥Z.
    static func editorKey(for event: NSEvent) -> EditorKey? {
      let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      switch event.keyCode {
      case 123 where modifiers == .command: return .zoomOut  // ⌘←
      case 124 where modifiers == .command: return .zoomIn  // ⌘→
      default: break
      }
      if modifiers.isEmpty, event.charactersIgnoringModifiers?.lowercased() == "z" {
        return .zoomFit
      }
      return nil
    }

    static func isTextEntryActive(in window: NSWindow) -> Bool {
      guard let responder = window.firstResponder else { return false }
      if let textView = responder as? NSTextView, textView.isFieldEditor { return true }
      if responder is NSTextField { return true }
      return false
    }

    private func removeMonitor() {
      if let monitor {
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
      }
    }

    deinit { removeMonitor() }
  }
}
