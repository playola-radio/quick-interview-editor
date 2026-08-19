import AppKit
import SwiftUI

/// A logic-free bridge, sibling to ``EditorKeyMonitor``: while the slice-edit sheet is the key
/// window, it forwards the zoom keys (⌘← / ⌘→ step-zoom, Z zoom-to-fit) to the sheet's
/// ``EditSliceModel`` lane and Space to its Play/Pause transport (otherwise Space would beep — the
/// sheet mounts no other key handler). The main editor's own monitors stand down while the sheet is
/// up (their window is not key), so nothing double-fires. It reuses ``EditorKeyMonitor``'s pure key
/// classifier so the zoom keys stay in lockstep, and stands down while a text field is being edited
/// (e.g. renaming). Mirrors the concurrency shape of ``EditorKeyMonitor`` / ``AuditionKeyMonitor``
/// so it survives Swift 6 strict concurrency.
struct SliceEditKeyMonitor: NSViewRepresentable {
  let model: EditSliceModel

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
    var model: EditSliceModel?
    private weak var host: NSView?
    private var monitor: Any?

    func install(host: NSView) {
      self.host = host
      // The handler is a bare `@Sendable` closure and `NSEvent` is not `Sendable`. Read every value
      // we need here (all `Sendable`) and hop to the main actor carrying only those.
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        let zoomKey = EditorKeyMonitor.Coordinator.editorKey(
          forKeyCode: event.keyCode,
          modifiers: event.modifierFlags,
          characters: event.charactersIgnoringModifiers)
        // Space (no modifiers, not auto-repeating) is the Play/Pause transport — keyCode 49, the
        // same physical key ``AuditionKeyMonitor`` uses in the main editor.
        let isSpace =
          event.keyCode == 49 && !event.isARepeat
          && event.modifierFlags.isDisjoint(with: [.command, .control, .option])
        guard zoomKey != nil || isSpace else { return event }
        let isARepeat = event.isARepeat
        let consumed = MainActor.assumeIsolated {
          self?.handle(zoomKey: zoomKey, isSpace: isSpace, isARepeat: isARepeat) ?? false
        }
        return consumed ? nil : event
      }
    }

    func remove() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }

    /// Performs the classified key if focus allows it. Returns whether the key was consumed (so the
    /// caller swallows it instead of letting it beep). Only the zoom keys and Space act here; the
    /// speed keys are a main-editor concern and fall through untouched.
    private func handle(zoomKey: EditorKey?, isSpace: Bool, isARepeat: Bool) -> Bool {
      // Only act when this sheet's window is key (a local monitor sees every window's keys).
      guard let window = host?.window, window.isKeyWindow else { return false }
      // Stand down while a text field is being edited (e.g. renaming a slice inside the sheet).
      if let responder = window.firstResponder as? NSText, responder.isEditable { return false }
      guard let model else { return false }
      if let zoomKey {
        switch zoomKey {
        case .zoomOut:
          model.zoomOutTapped()
          return true
        case .zoomIn:
          model.zoomInTapped()
          return true
        case .zoomFit:
          // Z is a toggle; swallow auto-repeat so holding it doesn't flicker fit↔restore (or beep).
          if isARepeat { return true }
          model.zoomFitTapped()
          return true
        case .speedUp, .speedDown:
          return false
        }
      }
      if isSpace {
        // Space activates a focused control (button) via Full Keyboard Access; don't hijack it
        // there — fire Play/Pause only when focus is on the sheet's content, matching how
        // ``AuditionKeyMonitor`` treats Space in the main editor.
        if window.firstResponder is NSControl { return false }
        Task { await model.playPauseTapped() }
        return true
      }
      return false
    }
  }
}
