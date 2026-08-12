import AppKit
import SwiftUI

/// A logic-free bridge: installs an app-local key-down monitor while it's mounted and forwards
/// the audition keys ( [ ] space ) to the model. It stands down while a text field is being
/// edited (the field editor is first responder), so slice renaming and any future text input
/// keep the keys. The transcript is a non-editable NSTextView, so it never blocks auditions.
struct AuditionKeyMonitor: NSViewRepresentable {
  let onKey: (EditorModel.AuditionKey) -> Void

  func makeNSView(context: Context) -> TrackingView {
    let view = TrackingView()
    context.coordinator.onKey = onKey
    context.coordinator.install(host: view)
    return view
  }

  func updateNSView(_ nsView: TrackingView, context: Context) {
    context.coordinator.onKey = onKey
  }

  static func dismantleNSView(_ nsView: TrackingView, coordinator: Coordinator) {
    coordinator.remove()
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  /// A zero-size marker view; its only job is to give the coordinator a handle on the window.
  final class TrackingView: NSView {}

  final class Coordinator {
    var onKey: ((EditorModel.AuditionKey) -> Void)?
    private weak var host: NSView?
    private var monitor: Any?

    func install(host: NSView) {
      self.host = host
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        self?.handle(event) ?? event
      }
    }

    func remove() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
      // Only act for the window this view lives in, and only when it's key.
      guard let window = host?.window, window.isKeyWindow, event.window === window else {
        return event
      }
      // Stand down while a text field is being edited.
      if let responder = window.firstResponder as? NSText, responder.isEditable {
        return event
      }
      // Bare keys only — never swallow Cmd/Ctrl/Opt combinations (menu/system shortcuts).
      if !event.modifierFlags.isDisjoint(with: [.command, .control, .option]) {
        return event
      }
      // One transport action per physical press — ignore auto-repeat.
      if event.isARepeat { return event }
      let key: EditorModel.AuditionKey?
      switch event.keyCode {
      case 33: key = .cutIn  // [
      case 30: key = .cutOut  // ]
      case 49: key = .space  // space
      default: key = nil
      }
      guard let key else { return event }
      // Space activates a focused control (button, checkbox, popup) via Full Keyboard Access;
      // don't hijack it there. Fire the audition transport only when focus is on the editor
      // content (the non-editable transcript NSTextView or the hosting view), not a control.
      if key == .space, window.firstResponder is NSControl {
        return event
      }
      onKey?(key)
      return nil  // consume so the key doesn't also scroll / beep
    }
  }
}
