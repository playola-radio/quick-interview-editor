import AppKit
import SwiftUI

/// A logic-free bridge, sibling to ``EditorKeyMonitor``: while the slice-edit sheet is the key
/// window, it forwards the zoom keys (⌘← / ⌘→ step-zoom, Z zoom-to-fit) to the sheet's
/// ``EditSliceModel`` lane, Space to its Play/Pause transport, and `[` / `]` to its audition
/// In/Out (otherwise these would beep — the sheet mounts no other key handler). The main editor's
/// own monitors stand down while the sheet is up (their window is not key), so nothing
/// double-fires. It reuses ``EditorKeyMonitor``'s pure key classifier so the zoom keys stay in
/// lockstep, and stands down while a text field is being edited (e.g. renaming). Mirrors the
/// concurrency shape of ``EditorKeyMonitor`` / ``AuditionKeyMonitor`` so it survives Swift 6 strict
/// concurrency.
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

  /// The one key this monitor recognizes, collapsed by `sliceEditKey` from the event's raw values
  /// so `handle` can switch on a single value instead of juggling a pile of booleans. Internal
  /// (not `private`) so the key-mapping tests can exercise the classifier, matching
  /// ``EditorKeyMonitor``'s `editorKey`.
  enum SliceEditKey: Equatable {
    case zoom(EditorKey)
    case space
    case undo
    case redo
    case auditionIn
    case auditionOut
  }

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
        guard
          let key = Self.sliceEditKey(
            forKeyCode: event.keyCode,
            modifiers: event.modifierFlags,
            characters: event.charactersIgnoringModifiers)
        else { return event }
        let isARepeat = event.isARepeat
        let consumed = MainActor.assumeIsolated {
          self?.handle(key, isARepeat: isARepeat) ?? false
        }
        return consumed ? nil : event
      }
    }

    func remove() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }

    /// Collapses the event's raw values into the one key this monitor recognizes, or `nil` if it
    /// recognizes none of them. Pure and `Sendable`, so it runs in the monitor's nonisolated
    /// handler (only `Sendable` values in and out).
    static func sliceEditKey(
      forKeyCode keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?
    ) -> SliceEditKey? {
      // The zoom keys reuse ``EditorKeyMonitor``'s classifier so they stay in lockstep with the
      // main editor.
      if let zoomKey = EditorKeyMonitor.Coordinator.editorKey(
        forKeyCode: keyCode, modifiers: modifiers, characters: characters)
      {
        return .zoom(zoomKey)
      }
      let hasActionModifier = !modifiers.isDisjoint(with: [.command, .control, .option])
      // Space (no ⌘/⌃/⌥) is the Play/Pause transport — keyCode 49, the same physical key
      // ``AuditionKeyMonitor`` uses in the main editor. Auto-repeat is classified here too (so it
      // gets swallowed in `handle` rather than beeping) but only the first press acts.
      if keyCode == 49, !hasActionModifier { return .space }
      // ⌘Z undo / ⌘⇧Z redo. The main editor's undo shortcut lives on a `SlicesPanelView` button in
      // a window that is not key while this sheet is up, so a modal removal (a document edit on the
      // shared undo stack) would otherwise be un-undoable from inside the sheet. `charactersIgnoring-
      // Modifiers` keeps Shift/Caps-Lock, so ⌘⇧Z reads as "Z" — lowercase before comparing.
      if characters?.lowercased() == "z" {
        let modifierKeys: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let activeModifiers = modifiers.intersection(modifierKeys)
        if activeModifiers == .command { return .undo }
        if activeModifiers == [.command, .shift] { return .redo }
      }
      // [ / ] audition the cut edges (Logic parity with `AuditionKeyMonitor` in the main
      // editor) — keyCode 33/30, same physical keys.
      if keyCode == 33, !hasActionModifier { return .auditionIn }
      if keyCode == 30, !hasActionModifier { return .auditionOut }
      return nil
    }

    /// Performs the classified key if focus allows it. Returns whether the key was consumed (so the
    /// caller swallows it instead of letting it beep). The zoom keys, Space (transport), ⌫ (remove
    /// the marquee selection / restore the selected seam), `[` / `]` (audition the In/Out cut
    /// edges), and ⌘Z/⌘⇧Z (undo/redo of the shared document) act here; the speed keys and the
    /// removal boundary-nudge keys (Task 9) are
    /// main-editor concerns and fall through untouched — this sheet edits an existing slice's cut
    /// points via its own scoped `EditSliceModel`, not the removal-only
    /// `fineTune.target == .pendingSelection` session.
    private func handle(_ key: SliceEditKey, isARepeat: Bool) -> Bool {
      // Only act when this sheet's window is key (a local monitor sees every window's keys).
      guard let window = host?.window, window.isKeyWindow else { return false }
      // Stand down while a text field is being edited (e.g. renaming a slice inside the sheet) so its
      // own ⌘Z field-undo still works.
      if let responder = window.firstResponder as? NSText, responder.isEditable { return false }
      guard let model else { return false }
      switch key {
      case .zoom(let zoomKey):
        return handleZoom(zoomKey, isARepeat: isARepeat, model: model)
      case .space:
        return handleSpace(isARepeat: isARepeat, window: window, model: model)
      // Swallow auto-repeat so holding ⌘Z / [ / ] fires once per press (matching the main
      // editor's single-fire shortcuts). The model's own guards no-op when there is nothing to
      // undo/redo or audition.
      case .undo:
        return fireOnce(isARepeat: isARepeat) { await model.undoTapped() }
      case .redo:
        return fireOnce(isARepeat: isARepeat) { await model.redoTapped() }
      case .auditionIn:
        return fireOnce(isARepeat: isARepeat) { await model.auditionInTapped() }
      case .auditionOut:
        return fireOnce(isARepeat: isARepeat) { await model.auditionOutTapped() }
      }
    }

    private func fireOnce(isARepeat: Bool, _ action: @escaping () async -> Void) -> Bool {
      if !isARepeat { Task { await action() } }
      return true
    }

    private func handleZoom(_ key: EditorKey, isARepeat: Bool, model: EditSliceModel) -> Bool {
      switch key {
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
      case .removeSection:
        // ⌫ removes the marquee selection or restores the selected seam — a document edit on the
        // shared undo stack, like ⌘Z below. Swallow auto-repeat so holding it fires once per press;
        // the model no-ops when nothing is selected (so ⌫ never beeps in the sheet).
        if !isARepeat { Task { await model.removeSectionKeyPressed() } }
        return true
      case .speedUp, .speedDown, .escape, .nudgeCutInEarlier, .nudgeCutInLater,
        .nudgeCutOutEarlier, .nudgeCutOutLater:
        return false
      }
    }

    private func handleSpace(isARepeat: Bool, window: NSWindow, model: EditSliceModel) -> Bool {
      // Space activates a focused control (button) via Full Keyboard Access; don't hijack it there —
      // fire Play/Pause only when focus is on the sheet's content, matching how ``AuditionKeyMonitor``
      // treats Space in the main editor.
      if window.firstResponder is NSControl { return false }
      // Swallow auto-repeat so holding Space doesn't retrigger the transport (or beep).
      if isARepeat { return true }
      Task { await model.playPauseTapped() }
      return true
    }
  }
}
