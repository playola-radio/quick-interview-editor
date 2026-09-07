import AppKit
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct NSViewEndTextEditingTests {
  /// Builds an offscreen window holding `responder` plus a bare content view, and makes `responder`
  /// the first responder — the same shape as a slice-rename field editor lingering over the editor.
  private func window(withFirstResponder responder: NSView) -> (window: NSWindow, content: NSView) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
      styleMask: [.titled], backing: .buffered, defer: true)
    let content = NSView(frame: .zero)
    window.contentView?.addSubview(responder)
    window.contentView?.addSubview(content)
    #expect(window.makeFirstResponder(responder))
    return (window, content)
  }

  @Test func resignsAnEditableFieldEditor() {
    let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
    field.isEditable = true
    let (window, content) = window(withFirstResponder: field)
    #expect(window.firstResponder === field)

    content.endActiveTextEditing()

    #expect(window.firstResponder !== field)
    #expect(!(window.firstResponder is NSText))
  }

  @Test func leavesANonEditableTextResponderAlone() {
    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
    text.isEditable = false
    text.isSelectable = true
    let (window, content) = window(withFirstResponder: text)
    #expect(window.firstResponder === text)

    content.endActiveTextEditing()

    #expect(window.firstResponder === text)
  }

  @Test func isANoOpWhenNoTextIsBeingEdited() {
    let content = NSView(frame: .zero)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
      styleMask: [.titled], backing: .buffered, defer: true)
    window.contentView?.addSubview(content)
    #expect(window.makeFirstResponder(nil))
    let before = window.firstResponder

    content.endActiveTextEditing()

    #expect(window.firstResponder === before)
  }
}
