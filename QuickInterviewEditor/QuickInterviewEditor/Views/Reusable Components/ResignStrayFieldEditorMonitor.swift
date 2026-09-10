import AppKit
import SwiftUI

/// Resigns a lingering text-field field editor when the user clicks outside it.
///
/// A SwiftUI `TextField` (the slice-name and cut-suggestion-title rename fields) edits through an
/// AppKit field editor — an editable `NSText` that becomes the window's first responder while the
/// field is focused. Clicking a blank area of a right-side panel, or the Slices/Suggestions tab
/// `Picker`, does not resign that field editor on its own, so it lingers. While it lingers:
///
/// * `AuditionKeyMonitor` / `EditorKeyMonitor` stand down (they bail when `firstResponder` is an
///   editable `NSText`), so the space bar and the audition keys go dead.
/// * `EditUndoCommands` routes ⌘Z to the field editor's own (empty) undo manager, so its command
///   button disables itself and ⌘Z becomes a silent no-op.
///
/// The editor's content layers (waveform, ruler, handles, the non-editable transcript) already
/// resign the editor in their own `mouseDown` via `endActiveTextEditing()` — this monitor closes
/// the gap for every OTHER click in the window (blank panel space, the tab picker, buttons that
/// aren't the rename field). It watches the window's mouse-downs and resigns the field editor
/// whenever the click lands outside the field being edited, so any normal click commits the rename
/// and restores the keys — matching how a Mac canvas ends an inline edit when you click away.
struct ResignStrayFieldEditorMonitor: NSViewRepresentable {
  func makeNSView(context: Context) -> TrackingView {
    let view = TrackingView()
    context.coordinator.install(host: view)
    return view
  }

  func updateNSView(_ nsView: TrackingView, context: Context) {}

  static func dismantleNSView(_ nsView: TrackingView, coordinator: Coordinator) {
    coordinator.remove()
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  /// A zero-size marker view; its only job is to give the coordinator a handle on the window.
  final class TrackingView: NSView {}

  @MainActor
  final class Coordinator {
    private weak var host: NSView?
    private var monitor: Any?

    func install(host: NSView) {
      self.host = host
      // A local mouse-down monitor always fires on the main thread, but its handler is a bare
      // `@Sendable` closure and `NSEvent` is not `Sendable`. So read only `Sendable` values — the
      // click point (`NSPoint`) and the event's window number (`Int`) — here, and hop to the main
      // actor carrying only those. The event itself never crosses the isolation boundary. (Same
      // pattern as `AuditionKeyMonitor`.)
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
        [weak self] event in
        let point = event.locationInWindow
        let windowNumber = event.windowNumber
        MainActor.assumeIsolated {
          self?.resignIfClickIsOutsideEditingField(at: point, eventWindowNumber: windowNumber)
        }
        return event
      }
    }

    func remove() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }

    /// Resigns the window's field editor when `point` (in window base coordinates) lands outside
    /// the field being edited. Main-actor: reads AppKit window / first-responder state.
    func resignIfClickIsOutsideEditingField(at point: NSPoint, eventWindowNumber: Int) {
      // A local monitor sees every window's clicks (including child sheets/popovers). Act only on a
      // click that belongs to our own key window — matched by identity, not just `isKeyWindow`.
      guard let window = window(matching: eventWindowNumber),
        let editor = window.firstResponder as? NSText, editor.isEditable
      else { return }
      guard Self.shouldResign(clickInWindow: point, fieldEditor: editor) else { return }
      window.makeFirstResponder(nil)
    }

    /// Our own key window, but only when the click belongs to it — matched by identity, not just
    /// `isKeyWindow`, so a click in a child sheet/popover (a separate window) never misfires.
    private func window(matching eventWindowNumber: Int) -> NSWindow? {
      guard let window = host?.window, window.isKeyWindow,
        window.windowNumber == eventWindowNumber
      else { return nil }
      return window
    }

    /// The resign decision, kept free of monitor/event plumbing so it's testable against a real
    /// offscreen field editor. A click inside the frame of the control being edited (bezel and
    /// padding included) keeps editing; anything else resigns. Resigns when no owning control
    /// resolves — a stray editable field editor with no control should un-stick the keys, not linger.
    /// Uses `bounds` (the control's own frame), not `visibleRect`: an unclipped field's `visibleRect`
    /// balloons to its superview's area, which would swallow the whole panel and never resign.
    static func shouldResign(clickInWindow point: NSPoint, fieldEditor: NSText?) -> Bool {
      guard let control = editingControl(for: fieldEditor),
        control.window != nil
      else { return true }
      return !control.convert(control.bounds, to: nil).contains(point)
    }

    /// The control the field editor actually belongs to: walk up from the field editor and return
    /// the nearest ancestor `NSControl` whose `currentEditor()` *is* this field editor. Matching on
    /// editor identity (not just "first `NSControl` ancestor") means an unrelated wrapper control in
    /// the hierarchy can't be mistaken for the edited field, and a field editor with no owning
    /// control resolves to `nil` (→ resign) rather than to its inset immediate superview.
    static func editingControl(for fieldEditor: NSText?) -> NSView? {
      guard let fieldEditor else { return nil }
      var view = fieldEditor.superview
      while let current = view {
        if let control = current as? NSControl, control.currentEditor() === fieldEditor {
          return control
        }
        view = current.superview
      }
      return nil
    }
  }
}
