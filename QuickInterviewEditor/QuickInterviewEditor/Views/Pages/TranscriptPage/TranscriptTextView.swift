import AppKit
import SwiftUI

/// Dumb TextKit-1 renderer. Owns the AppKit objects and converts points to UTF-16
/// offsets; every decision (which word, selection, follow) lives in the model. The
/// model-derived values it repaints from are passed in as explicit inputs so SwiftUI
/// registers them as dependencies and calls `updateNSView` when they change.
struct TranscriptTextView: NSViewRepresentable {
  let model: TranscriptPageModel
  let text: String
  let fontSize: Double
  let selected: Set<Word.ID>
  let runTogether: Set<Word.ID>
  let scrollTarget: Word.ID?
  let followMode: TranscriptFollowMode

  func makeCoordinator() -> Coordinator { Coordinator(model: model) }

  func makeNSView(context: Context) -> NSScrollView {
    let textView = HitTestingTextView()
    textView.coordinator = context.coordinator
    textView.isEditable = false
    textView.isSelectable = false
    textView.drawsBackground = true
    textView.backgroundColor = .black
    textView.textContainerInset = NSSize(width: 4, height: 8)
    textView.autoresizingMask = [.width]

    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.documentView = textView

    context.coordinator.model = model
    context.coordinator.textView = textView
    context.coordinator.scrollView = scroll
    context.coordinator.observeScroll()
    context.coordinator.rebuildText(
      text: text, fontSize: fontSize, selected: selected, runTogether: runTogether)
    return scroll
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    context.coordinator.model = model
    context.coordinator.apply(
      text: text, fontSize: fontSize, selected: selected, runTogether: runTogether,
      scrollTarget: scrollTarget, followMode: followMode)
  }

  @MainActor
  final class Coordinator: NSObject {
    var model: TranscriptPageModel
    weak var textView: NSTextView?
    weak var scrollView: NSScrollView?
    private var lastText = ""
    private var lastSelected: Set<Word.ID> = []
    private var lastRunTogether: Set<Word.ID> = []
    private var lastFontSize: Double = 0
    private var lastScrollTarget: Word.ID?

    init(model: TranscriptPageModel) { self.model = model }

    deinit { NotificationCenter.default.removeObserver(self) }

    private static let selectedBG = NSColor(
      calibratedRed: 0.80, green: 0.40, blue: 0.40, alpha: 0.30)
    private static let selectedFG = NSColor.white
    private static let runTogetherFG = NSColor(
      calibratedRed: 0.89, green: 0.58, blue: 0.58, alpha: 1)
    private static let normalFG = NSColor(calibratedWhite: 0.56, alpha: 1)

    func rebuildText(
      text: String, fontSize: Double, selected: Set<Word.ID>, runTogether: Set<Word.ID>
    ) {
      guard let storage = textView?.textStorage else { return }
      let attr = NSMutableAttributedString(string: text)
      let full = NSRange(location: 0, length: attr.length)
      attr.addAttribute(.font, value: NSFont.systemFont(ofSize: fontSize), range: full)
      attr.addAttribute(.foregroundColor, value: Self.normalFG, range: full)
      storage.setAttributedString(attr)
      lastText = text
      lastFontSize = fontSize
      lastSelected = []
      lastRunTogether = []
      applyWordColors(added: runTogether, role: .runTogether, currentSelected: selected)
      applySelection(added: selected, removed: [], currentRunTogether: runTogether)
      lastRunTogether = runTogether
      lastSelected = selected
    }

    // swiftlint:disable:next function_parameter_count
    func apply(
      text: String, fontSize: Double, selected: Set<Word.ID>, runTogether: Set<Word.ID>,
      scrollTarget: Word.ID?, followMode: TranscriptFollowMode
    ) {
      guard let storage = textView?.textStorage, let textView else { return }

      if text != lastText {
        rebuildText(text: text, fontSize: fontSize, selected: selected, runTogether: runTogether)
        return
      }

      if fontSize != lastFontSize {
        storage.addAttribute(
          .font, value: NSFont.systemFont(ofSize: fontSize),
          range: NSRange(location: 0, length: storage.length))
        lastFontSize = fontSize
      }

      let rtAdded = runTogether.subtracting(lastRunTogether)
      let rtRemoved = lastRunTogether.subtracting(runTogether)
      applyWordColors(added: rtAdded, role: .runTogether, currentSelected: selected)
      applyWordColors(
        added: rtRemoved.subtracting(selected), role: .normal, currentSelected: selected)
      lastRunTogether = runTogether

      let selAdded = selected.subtracting(lastSelected)
      let selRemoved = lastSelected.subtracting(selected)
      applySelection(added: selAdded, removed: selRemoved, currentRunTogether: runTogether)
      lastSelected = selected

      if let target = scrollTarget, target != lastScrollTarget,
        followMode == .following, let range = range(for: target)
      {
        // Programmatic auto-scroll goes through neither `scrollWheel` nor live-scroll,
        // so it can never be mistaken for a user scroll — no guard flag needed.
        textView.scrollRangeToVisible(range)
        lastScrollTarget = target
      }
    }

    private enum Role { case selected, runTogether, normal }

    private func range(for id: Word.ID) -> NSRange? {
      model.document.wordRanges.first { $0.wordID == id }?.range
    }

    private func applyWordColors(
      added: Set<Word.ID>, role: Role, currentSelected: Set<Word.ID>
    ) {
      guard let storage = textView?.textStorage else { return }
      let color = role == .runTogether ? Self.runTogetherFG : Self.normalFG
      for id in added where !currentSelected.contains(id) {
        if let wordRange = range(for: id) {
          storage.addAttribute(.foregroundColor, value: color, range: wordRange)
        }
      }
    }

    private func applySelection(
      added: Set<Word.ID>, removed: Set<Word.ID>, currentRunTogether: Set<Word.ID>
    ) {
      guard let storage = textView?.textStorage else { return }
      for id in removed {
        guard let wordRange = range(for: id) else { continue }
        storage.removeAttribute(.backgroundColor, range: wordRange)
        let fg = currentRunTogether.contains(id) ? Self.runTogetherFG : Self.normalFG
        storage.addAttribute(.foregroundColor, value: fg, range: wordRange)
      }
      for id in added {
        guard let wordRange = range(for: id) else { continue }
        storage.addAttribute(.backgroundColor, value: Self.selectedBG, range: wordRange)
        storage.addAttribute(.foregroundColor, value: Self.selectedFG, range: wordRange)
      }
    }

    // MARK: Scroll observation
    // User scroll is detected from actual user input, not bounds changes: `scrollWheel`
    // (trackpad/mouse-wheel) is forwarded from the text view, and live-scroll (trackpad
    // gesture / scroller drag) is observed here. TextKit's deferred layout can post bounds
    // changes after a programmatic auto-scroll, so bounds are NOT a reliable user signal.
    func observeScroll() {
      guard let scrollView else { return }
      NotificationCenter.default.addObserver(
        self, selector: #selector(userDidLiveScroll),
        name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
    }

    @objc private func userDidLiveScroll() {
      model.transcriptUserScrolled()
    }

    // MARK: Hit testing (point → UTF-16 offset → model)
    func utf16Offset(at point: NSPoint) -> Int? {
      guard let textView, let lm = textView.layoutManager, let container = textView.textContainer
      else { return nil }
      let local = NSPoint(
        x: point.x - textView.textContainerInset.width,
        y: point.y - textView.textContainerInset.height)
      let glyph = lm.glyphIndex(for: local, in: container)
      return lm.characterIndexForGlyph(at: glyph)
    }
  }
}

/// Forwards mouse events to the coordinator as UTF-16 offsets and classifies click vs
/// drag from the raw event stream. No selection decisions here — those live in the model.
final class HitTestingTextView: NSTextView {
  weak var coordinator: TranscriptTextView.Coordinator?
  private var anchorOffset: Int?
  private var didDrag = false

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    anchorOffset = coordinator?.utf16Offset(at: point)
    didDrag = false
  }

  override func mouseDragged(with event: NSEvent) {
    guard let coordinator, let anchor = anchorOffset else { return }
    let point = convert(event.locationInWindow, from: nil)
    guard let offset = coordinator.utf16Offset(at: point) else { return }
    if !didDrag {
      didDrag = true
      coordinator.model.transcriptDragBegan(atUTF16Offset: anchor)
    }
    coordinator.model.transcriptDragged(toUTF16Offset: offset)
  }

  override func mouseUp(with event: NSEvent) {
    guard let coordinator else { return }
    if !didDrag, let anchor = anchorOffset {
      coordinator.model.transcriptClicked(atUTF16Offset: anchor)
    }
    coordinator.model.transcriptDragEnded()
    anchorOffset = nil
    didDrag = false
  }

  override func scrollWheel(with event: NSEvent) {
    coordinator?.model.transcriptUserScrolled()
    super.scrollWheel(with: event)
  }
}
