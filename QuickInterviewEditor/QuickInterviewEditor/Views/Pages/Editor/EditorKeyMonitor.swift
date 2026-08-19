import AppKit
import SwiftUI

/// A logic-free bridge: installs an app-local key-down monitor while it's mounted and forwards
/// the editor's global zoom keys (⌘← / ⌘→ step-zoom, Z zoom-to-fit) to `EditorModel`. It stands
/// down while a text field is being edited (the field editor is first responder), so slice
/// renaming keeps those keys. The transcript is a non-editable NSTextView, so it never blocks
/// the shortcuts. Mirrors ``AuditionKeyMonitor`` so both survive Swift 6 strict concurrency.
struct EditorKeyMonitor: NSViewRepresentable {
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
        guard
          let key = Self.editorKey(
            forKeyCode: event.keyCode,
            modifiers: event.modifierFlags,
            characters: event.charactersIgnoringModifiers)
        else { return event }
        let isARepeat = event.isARepeat
        let consumed = MainActor.assumeIsolated { self?.handle(key, isARepeat: isARepeat) ?? false }
        return consumed ? nil : event
      }
    }

    func remove() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }

    /// Exactly ⌘← / ⌘→ ⇒ zoom out/in; Z with no modifiers ⇒ zoom-to-fit. Any extra modifier
    /// (Shift, Option, Control) falls through, as do ⌘Z (undo) and ⌥Z. Pure and `Sendable`, so
    /// it runs in the monitor's nonisolated handler (only `Sendable` values in and out).
    static func editorKey(
      forKeyCode keyCode: UInt16, modifiers rawModifiers: NSEvent.ModifierFlags,
      characters: String?
    ) -> EditorKey? {
      let relevant: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
      let modifiers = rawModifiers.intersection(relevant)
      switch keyCode {
      case 123 where modifiers == .command: return .zoomOut  // ⌘←
      case 124 where modifiers == .command: return .zoomIn  // ⌘→
      // `<` / `>` (Shift-comma / Shift-period) step the playback speed down / up. Matched by
      // physical key + Shift rather than `charactersIgnoringModifiers`, whose Shift handling is
      // ambiguous across layouts — the comma/period keys are 43/47, mirroring the arrow keyCodes.
      case 43 where modifiers == .shift: return .speedDown  // <
      case 47 where modifiers == .shift: return .speedUp  // >
      case 51 where modifiers.isEmpty: return .removeSection  // ⌫ (⌘⌫/⌥⌫ fall through)
      default: break
      }
      if modifiers.isEmpty, characters?.lowercased() == "z" { return .zoomFit }
      return nil
    }

    /// Performs `key` if focus allows it. Returns whether the key was consumed (so the caller
    /// swallows it instead of letting it beep). Main-actor: touches AppKit window/first-responder
    /// state and the model.
    private func handle(_ key: EditorKey, isARepeat: Bool) -> Bool {
      // Only act when this view's window is key (a local monitor sees every window's keys).
      guard let window = host?.window, window.isKeyWindow else { return false }
      // Stand down while a text field is being edited (e.g. renaming a slice).
      if let responder = window.firstResponder as? NSText, responder.isEditable { return false }
      // Z is a toggle, the speed keys step discrete presets, and ⌫ removes a section; swallow
      // auto-repeat on all three so holding one doesn't flicker fit↔restore, blow through every
      // speed, or fire multiple removals (and doesn't beep). The arrow zoom keys intentionally
      // keep repeating.
      if isARepeat, key == .zoomFit || key == .speedUp || key == .speedDown || key == .removeSection
      {
        return true
      }
      return model?.editorKeyDown(key) ?? false
    }
  }
}
