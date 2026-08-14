import AppKit
import SwiftUI

/// A logic-free bridge: installs an app-local key-down monitor while it's mounted and forwards the
/// bare clip-navigation keys (J/K step, ⏎ approve, ⌫ reject, F focus) to `EditorModel`. It stands
/// down while a text field is being edited (slice renaming) and while a control has focus (so ⏎/⌫
/// still activate a focused button), and only acts when its window is key. Space is deliberately
/// NOT handled here — the transport monitor owns it. Mirrors ``EditorKeyMonitor`` /
/// ``AuditionKeyMonitor`` so all three survive Swift 6 strict concurrency.
struct ClipKeyMonitor: NSViewRepresentable {
  let model: EditorModel

  func makeNSView(context: Context) -> TrackingView {
    let view = TrackingView()
    context.coordinator.model = model
    context.coordinator.install(host: view)
    return view
  }

  func updateNSView(_ nsView: TrackingView, context: Context) {
    context.coordinator.model = model
  }

  static func dismantleNSView(_ nsView: TrackingView, coordinator: Coordinator) {
    coordinator.remove()
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  /// A zero-size marker view; its only job is to give the coordinator a handle on the window.
  final class TrackingView: NSView {}

  @MainActor
  final class Coordinator {
    var model: EditorModel?
    private weak var host: NSView?
    private var monitor: Any?

    func install(host: NSView) {
      self.host = host
      // The local key-down monitor always fires on the main thread, but its handler is a bare
      // `@Sendable` closure and `NSEvent` is not `Sendable`. Read every value we need here (all
      // `Sendable`) and hop to the main actor carrying only those — the event never crosses.
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        // Ignore auto-repeat: holding ⏎ would otherwise approve then immediately toggle back off
        // (and holding ⌫/F would fire repeatedly). One physical press = one clip action.
        guard !event.isARepeat,
          event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
          let key = Self.clipKey(forKeyCode: event.keyCode)
        else { return event }
        let consumed = MainActor.assumeIsolated { self?.handle(key) ?? false }
        return consumed ? nil : event
      }
    }

    func remove() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }

    /// Maps a physical key code to a clip action. `nil` for keys we don't handle. Pure and
    /// `Sendable`, so it runs in the monitor's nonisolated handler.
    static func clipKey(forKeyCode keyCode: UInt16) -> ClipKey? {
      switch keyCode {
      case 38: return .next  // J
      case 40: return .previous  // K
      case 3: return .focus  // F
      case 36: return .approve  // Return
      case 51, 117: return .reject  // Delete / forward-delete
      default: return nil
      }
    }

    /// Performs `key` if focus allows it. Returns whether the key was consumed (so the caller
    /// swallows it instead of letting it beep). Main-actor: touches AppKit window/first-responder
    /// state and the model.
    private func handle(_ key: ClipKey) -> Bool {
      // Only act when this view's window is key (a local monitor sees every window's keys).
      guard let window = host?.window, window.isKeyWindow else { return false }
      // Stand down while a text field is being edited (e.g. renaming a slice).
      if let responder = window.firstResponder as? NSText, responder.isEditable { return false }
      // Stand down when a control has focus so ⏎/⌫ still activate the focused button, not a clip.
      if window.firstResponder is NSControl { return false }
      return model?.clipKeyDown(key) ?? false
    }
  }
}
