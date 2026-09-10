import AppKit
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct ResignStrayFieldEditorMonitorTests {
  private typealias Coordinator = ResignStrayFieldEditorMonitor.Coordinator

  /// A live editing session: an offscreen window holding an editable field in edit mode, so its
  /// field editor is installed — the same shape as a lingering slice/suggestion rename field editor.
  /// The window is retained to keep the field (and its field editor) alive for the test's duration.
  private struct EditingFixture {
    let window: NSWindow
    let field: NSTextField
    let editor: NSText
  }

  private func editingField(frame: NSRect) throws -> EditingFixture {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled], backing: .buffered, defer: true)
    let field = NSTextField(frame: frame)
    field.isEditable = true
    window.contentView?.addSubview(field)
    #expect(window.makeFirstResponder(field))
    let editor = try #require(field.currentEditor())
    return EditingFixture(window: window, field: field, editor: editor)
  }

  @Test func keepsEditingWhenClickLandsInsideTheField() throws {
    let frame = NSRect(x: 50, y: 100, width: 120, height: 22)
    let fixture = try editingField(frame: frame)
    let inside = NSPoint(x: frame.midX, y: frame.midY)  // window coords, within the field
    #expect(!Coordinator.shouldResign(clickInWindow: inside, fieldEditor: fixture.editor))
  }

  @Test func resignsWhenClickLandsOutsideTheField() throws {
    let frame = NSRect(x: 50, y: 100, width: 120, height: 22)
    let fixture = try editingField(frame: frame)
    let outside = NSPoint(x: 300, y: 250)  // blank window area, well clear of the field
    #expect(Coordinator.shouldResign(clickInWindow: outside, fieldEditor: fixture.editor))
  }

  @Test func aClickOnTheFieldsPaddingEdgeStillCountsAsInside() throws {
    let frame = NSRect(x: 50, y: 100, width: 120, height: 22)
    let fixture = try editingField(frame: frame)
    // Just inside the top-left corner — the field's bezel/padding, not its glyph area. The field
    // editor's own superview is inset within the bezel, so this point lands outside it; resolving up
    // to the enclosing control (whose frame includes the bezel) is what keeps this counted as inside.
    let paddingEdge = NSPoint(x: frame.minX + 1, y: frame.minY + 1)
    #expect(!Coordinator.shouldResign(clickInWindow: paddingEdge, fieldEditor: fixture.editor))
  }

  @Test func resignsWhenTheEditingControlCannotBeResolved() {
    #expect(Coordinator.shouldResign(clickInWindow: NSPoint(x: 10, y: 10), fieldEditor: nil))
  }

  @Test func resolvesTheControlWhoseFieldEditorItIs() throws {
    // The field editor is installed *within* the control and its immediate superview is inset inside
    // the control's bezel, so the monitor walks up to the owning control — matched by editor
    // identity (`currentEditor() === editor`) so an unrelated wrapper control can't be picked.
    let frame = NSRect(x: 50, y: 100, width: 120, height: 22)
    let fixture = try editingField(frame: frame)
    let control = try #require(Coordinator.editingControl(for: fixture.editor))
    #expect(control === fixture.field)
  }

  @Test func resignsForAnEditableTextThatNoControlOwns() {
    // A stray editable `NSText` that isn't any control's field editor (no owning `NSControl` in its
    // ancestry) resolves to no control, so any click resigns it — un-sticking the keys rather than
    // leaving it lingering. The non-editable transcript view is already excluded upstream by the
    // `isEditable` gate, so this only affects a genuinely stuck bare editor.
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled], backing: .buffered, defer: true)
    let textView = NSTextView(frame: NSRect(x: 50, y: 100, width: 120, height: 40))
    textView.isEditable = true
    window.contentView?.addSubview(textView)
    #expect(window.makeFirstResponder(textView))
    #expect(Coordinator.editingControl(for: textView) == nil)
    let insideTheTextView = NSPoint(x: 60, y: 110)
    #expect(Coordinator.shouldResign(clickInWindow: insideTheTextView, fieldEditor: textView))
  }
}
