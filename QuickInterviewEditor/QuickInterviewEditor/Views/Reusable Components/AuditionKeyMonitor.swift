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

  @MainActor
  final class Coordinator {
    var onKey: ((EditorModel.AuditionKey) -> Void)?
    private weak var host: NSView?
    private var monitor: Any?

    func install(host: NSView) {
      self.host = host
      // The local key-down monitor always fires on the main thread, but on the current SDK its
      // handler is a bare `@Sendable` closure and `NSEvent` is not `Sendable`. So read every
      // value we need from the event here (all `Sendable`), and hop to the main actor carrying
      // only those — the event itself never crosses the isolation boundary.
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        // Bare, non-repeated key we care about — everything here is a pure value read.
        guard !event.isARepeat,
          event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
          let key = Self.auditionKey(forKeyCode: event.keyCode)
        else { return event }
        let consumed = MainActor.assumeIsolated { self?.fire(key) ?? false }
        return consumed ? nil : event
      }
    }

    func remove() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }

    /// Maps a physical key code to an audition action. `nil` for keys we don't handle.
    /// Pure and `Sendable`, so it runs in the monitor's nonisolated handler.
    private static func auditionKey(forKeyCode keyCode: UInt16) -> EditorModel.AuditionKey? {
      switch keyCode {
      case 33: return .cutIn  // [
      case 30: return .cutOut  // ]
      case 49: return .space  // space
      default: return nil
      }
    }

    /// Fires the audition transport for `key` if focus allows it. Returns whether the key was
    /// consumed (so the caller swallows it instead of letting it scroll / beep). Main-actor:
    /// touches AppKit window/first-responder state.
    private func fire(_ key: EditorModel.AuditionKey) -> Bool {
      // Only act when this view's window is key (a local monitor sees every window's keys).
      guard let window = host?.window, window.isKeyWindow else { return false }
      // Stand down while a text field is being edited.
      if let responder = window.firstResponder as? NSText, responder.isEditable {
        return false
      }
      // Space activates a focused control (button, checkbox, popup) via Full Keyboard Access;
      // don't hijack it there. Fire the audition transport only when focus is on the editor
      // content (the non-editable transcript NSTextView or the hosting view), not a control.
      if key == .space, window.firstResponder is NSControl {
        return false
      }
      onKey?(key)
      return true
    }
  }
}
