import AppKit

extension NSView {
  /// Ends an in-progress text edit before this view handles a content click.
  ///
  /// The slice-name control is a live `TextField`; while it's edited its field editor (an editable
  /// `NSText`) is the window's first responder, and `AuditionKeyMonitor` stands down there so the
  /// slice keeps the space / `[` / `]` keys. The editor's content layers (the waveform body, ruler,
  /// edge/seam/amplitude handles, and the non-editable transcript) all return
  /// `acceptsFirstResponder == false`, so clicking them never resigns that field editor on its own —
  /// it lingers, and the transport keys stay dead until another real control is clicked.
  ///
  /// Content `mouseDown` handlers call this so a click in the editor commits the rename and restores
  /// the transport keys, matching how any Mac canvas ends an inline edit when you click away. It's a
  /// no-op unless an editable field editor is currently first responder, so a normal click is
  /// untouched.
  func endActiveTextEditing() {
    guard let window, let text = window.firstResponder as? NSText, text.isEditable else { return }
    window.makeFirstResponder(nil)
  }
}
