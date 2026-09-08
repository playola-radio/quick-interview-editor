import AppKit
import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct TranscriptOverlapTests {
  private let first = TranscriptObject(
    id: .clip(UUID()), name: "First", range: 0..<100,
    wordIDs: [1, 2], colorIndex: 0)
  private let second = TranscriptObject(
    id: .clip(UUID()), name: "Lower", range: 0..<100,
    wordIDs: [1, 2], colorIndex: 1)

  @Test func nativeButtonOpensChooser() {
    let model = TranscriptOverlapModel()
    model.update([first, second], anchor: 1, selected: first.id)
    let presenter = TranscriptOverlapPresenter(model: model)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let document = TranscriptDocument(words: [
      Word(
        id: 1, text: "Word", start: 0, end: 1,
        startSample: 0, endSample: 100)
    ])
    text.string = document.text
    window.contentView = text
    window.makeKeyAndOrderFront(nil)
    presenter.update(textView: text, document: document)
    defer {
      presenter.dismantle()
      window.close()
    }
    #expect(presenter.button.target === presenter)
    presenter.button.performClick(nil)
    #expect(model.isPresented)
    #expect(presenter.popover.isShown)
  }

  @Test func buttonNeverCoversClickedWordAtViewportEdges() {
    let viewport = NSRect(x: 0, y: 0, width: 400, height: 300)
    let size = NSSize(width: 70, height: 22)
    for word in [
      NSRect(x: 350, y: 275, width: 40, height: 20),
      NSRect(x: 0, y: 0, width: 60, height: 20),
      NSRect(x: 0, y: 278, width: 60, height: 20),
    ] {
      let origin = TranscriptOverlapPresenter.buttonOrigin(
        word: word, size: size, viewport: viewport)
      let button = NSRect(origin: origin, size: size)
      #expect(!button.intersects(word))
      #expect(viewport.contains(button))
    }
  }

  @Test func previewDoesNotChooseAndEscapePreservesSelection() {
    let model = TranscriptOverlapModel()
    var chosen: TranscriptObjectID?
    model.onChoose = { chosen = $0 }
    model.update([first, second], anchor: 1, selected: first.id)
    model.present()
    model.preview(second.id)
    expectNoDifference(model.selectedID, first.id)
    #expect(chosen == nil)
    #expect(model.keyDown(53))
    #expect(!model.isPresented)
    #expect(model.previewID == nil)
    expectNoDifference(model.selectedID, first.id)
  }

  @Test func keyboardChoosesFullyHiddenLowerObject() {
    let model = TranscriptOverlapModel()
    var chosen: TranscriptObjectID?
    model.onChoose = { chosen = $0 }
    model.update([first, second], anchor: 1, selected: first.id)
    model.present()
    #expect(model.keyDown(125))
    expectNoDifference(model.previewID, second.id)
    #expect(model.keyDown(51))
    #expect(chosen == nil)
    #expect(model.keyDown(36))
    expectNoDifference(chosen, second.id)
    #expect(!model.isPresented)
  }

  @Test func deletedCandidateCannotBeChosenAndClosesSingleItemChooser() {
    let model = TranscriptOverlapModel()
    var chosen: TranscriptObjectID?
    model.onChoose = { chosen = $0 }
    model.update([first, second], anchor: 1, selected: first.id)
    model.present()
    model.preview(second.id)
    model.update([first], anchor: 1, selected: first.id)
    model.choose(second.id)
    #expect(chosen == nil)
    #expect(!model.showsControl)
    #expect(!model.isPresented)
    #expect(model.previewID == nil)
  }
}
