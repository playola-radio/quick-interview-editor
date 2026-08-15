import AppKit
import SwiftUI

/// Dumb TextKit-1 renderer. Owns the AppKit objects and converts points to UTF-16
/// offsets; every decision (which word, selection, follow, clip state) lives in the model.
/// The model-derived values it repaints from are passed in as explicit inputs so SwiftUI
/// registers them as dependencies and calls `updateNSView` when they change.
struct TranscriptTextView: NSViewRepresentable {
  let model: TranscriptPageModel
  let text: String
  let fontSize: Double
  let paragraphSpacing: Double
  let selected: Set<Word.ID>
  let clipContainers: [TranscriptClipContainer]
  let scrollTarget: Word.ID?
  let followMode: TranscriptFollowMode
  let reveal: TranscriptReveal?

  func makeCoordinator() -> Coordinator { Coordinator(model: model) }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false

    // Canonical TextKit-1 "text view in a scroll view" configuration, built by hand so a
    // custom layout manager (the clip-container renderer) can be installed on the stack: the
    // text view grows vertically with its content while its width tracks the clip view, so a
    // long transcript wraps to the viewport width and scrolls instead of being clipped.
    let contentSize = scroll.contentSize
    let textStorage = NSTextStorage()
    let layoutManager = ClipContainerLayoutManager()
    textStorage.addLayoutManager(layoutManager)
    let textContainer = NSTextContainer(
      containerSize: NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude))
    textContainer.widthTracksTextView = true
    layoutManager.addTextContainer(textContainer)

    let textView = HitTestingTextView(
      frame: NSRect(origin: .zero, size: contentSize), textContainer: textContainer)
    textView.coordinator = context.coordinator
    textView.isEditable = false
    textView.isSelectable = false
    textView.drawsBackground = true
    textView.backgroundColor = .black
    textView.textContainerInset = NSSize(width: 4, height: 8)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

    scroll.documentView = textView

    context.coordinator.model = model
    context.coordinator.textView = textView
    context.coordinator.scrollView = scroll
    context.coordinator.paragraphSpacing = paragraphSpacing
    context.coordinator.observeScroll()
    context.coordinator.rebuildText(
      text: text, fontSize: fontSize, selected: selected, clipContainers: clipContainers)
    return scroll
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    context.coordinator.model = model
    context.coordinator.paragraphSpacing = paragraphSpacing
    context.coordinator.apply(
      text: text, fontSize: fontSize, selected: selected, clipContainers: clipContainers,
      scrollTarget: scrollTarget, followMode: followMode, reveal: reveal)
  }

  @MainActor
  final class Coordinator: NSObject {
    var model: TranscriptPageModel
    weak var textView: NSTextView?
    weak var scrollView: NSScrollView?
    var paragraphSpacing: Double = 0
    private var lastText = ""
    private var lastSelected: Set<Word.ID> = []
    private var lastClipContainers: [TranscriptClipContainer] = []
    private var lastFontSize: Double = 0
    private var lastScrollTarget: Word.ID?
    private var lastFollowMode: TranscriptFollowMode = .following
    private var lastReveal: TranscriptReveal?

    init(model: TranscriptPageModel) { self.model = model }

    deinit { NotificationCenter.default.removeObserver(self) }

    private static let selectedBG = NSColor(
      calibratedRed: 0.80, green: 0.40, blue: 0.40, alpha: 0.30)
    private static let selectedFG = NSColor.white
    private static let normalFG = NSColor(calibratedWhite: 0.56, alpha: 1)

    private static func nsColor(_ color: ClipStyleColor) -> NSColor {
      NSColor(
        calibratedRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    private var clipLayoutManager: ClipContainerLayoutManager? {
      textView?.layoutManager as? ClipContainerLayoutManager
    }

    func rebuildText(
      text: String, fontSize: Double, selected: Set<Word.ID>,
      clipContainers: [TranscriptClipContainer]
    ) {
      guard let storage = textView?.textStorage else { return }
      let attr = NSMutableAttributedString(string: text)
      let full = NSRange(location: 0, length: attr.length)
      attr.addAttribute(.font, value: NSFont.systemFont(ofSize: fontSize), range: full)
      attr.addAttribute(.foregroundColor, value: Self.normalFG, range: full)
      // The newline between paragraphs makes each pause-paragraph its own TextKit
      // paragraph; this spacing renders the break as a visible vertical gap. Applied
      // over the full range so it survives the incremental color/selection updates.
      let paragraphStyle = NSMutableParagraphStyle()
      paragraphStyle.paragraphSpacing = paragraphSpacing
      attr.addAttribute(.paragraphStyle, value: paragraphStyle, range: full)
      storage.setAttributedString(attr)
      lastText = text
      lastFontSize = fontSize
      lastSelected = []
      lastClipContainers = []
      // Clips first (they colour their words white/dim), then selection paints the red
      // highlight + white text on top of whichever words are selected.
      applyClipContainers(clipContainers)
      lastClipContainers = clipContainers
      lastSelected = selected
      applySelection(added: selected, removed: [])
    }

    // swiftlint:disable:next function_parameter_count
    func apply(
      text: String, fontSize: Double, selected: Set<Word.ID>,
      clipContainers: [TranscriptClipContainer], scrollTarget: Word.ID?,
      followMode: TranscriptFollowMode, reveal: TranscriptReveal?
    ) {
      guard let storage = textView?.textStorage, let textView else { return }

      if text != lastText {
        rebuildText(
          text: text, fontSize: fontSize, selected: selected, clipContainers: clipContainers)
        return
      }

      if fontSize != lastFontSize {
        storage.addAttribute(
          .font, value: NSFont.systemFont(ofSize: fontSize),
          range: NSRange(location: 0, length: storage.length))
        lastFontSize = fontSize
      }

      if clipContainers != lastClipContainers {
        applyClipContainers(clipContainers)
        lastClipContainers = clipContainers
      }

      let selAdded = selected.subtracting(lastSelected)
      let selRemoved = lastSelected.subtracting(selected)
      lastSelected = selected
      applySelection(added: selAdded, removed: selRemoved)

      // Resuming follow (userPaused → following) must re-scroll to the current target
      // even if its ID is unchanged: playback can stop and restart while the playhead
      // sits in the same word, and without this the view would stay parked where the
      // user left it. Clearing `lastScrollTarget` lets the guard below re-apply.
      if followMode == .following, lastFollowMode == .userPaused {
        lastScrollTarget = nil
      }
      lastFollowMode = followMode

      if let target = scrollTarget, target != lastScrollTarget,
        followMode == .following, let range = range(for: target)
      {
        // Programmatic auto-scroll goes through neither `scrollWheel` nor live-scroll,
        // so it can never be mistaken for a user scroll — no guard flag needed.
        textView.scrollRangeToVisible(range)
        lastScrollTarget = target
      }

      // An explicit reveal (clicking a suggestion or clip) scrolls regardless of `followMode` —
      // the user asked to jump here, so a prior manual scroll must not suppress it. The token in
      // `TranscriptReveal` changes on every request, so re-revealing the same word re-scrolls.
      if let reveal, reveal != lastReveal {
        if let range = range(for: reveal.wordID) {
          textView.scrollRangeToVisible(range)
        }
        lastReveal = reveal
      }
    }

    private func range(for id: Word.ID) -> NSRange? {
      model.document.wordRanges.first { $0.wordID == id }?.range
    }

    /// The single source of truth for a word's text colour: selected wins (white), then a
    /// clip's own colour (white for live clips, dim grey for rejected), else the body grey.
    /// Both the selection diff and the clip diff route foreground through here so neither
    /// stomps the other when a word is both selected and inside a clip.
    private func foregroundColor(selected: Bool, kind: TranscriptClipKind?) -> NSColor {
      if selected { return Self.selectedFG }
      guard let kind else { return Self.normalFG }
      return Self.nsColor(TranscriptClipStyle.style(for: kind).text)
    }

    private func clipKind(atLocation location: Int) -> TranscriptClipKind? {
      lastClipContainers.first { NSLocationInRange(location, $0.range) }?.kind
    }

    private func setForeground(storage: NSTextStorage, wordRange: NSRange, wordID: Word.ID) {
      let kind = clipKind(atLocation: wordRange.location)
      storage.addAttribute(
        .foregroundColor,
        value: foregroundColor(selected: lastSelected.contains(wordID), kind: kind),
        range: wordRange)
      if kind == .rejected {
        storage.addAttribute(
          .strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: wordRange)
      } else {
        storage.removeAttribute(.strikethroughStyle, range: wordRange)
      }
    }

    /// Repaints the clip layer: hands the resolved fill/ring runs to the layout manager and
    /// refreshes text colour/strikethrough for every word an added OR removed container
    /// touched. `lastClipContainers` is updated first so `clipKind` reflects the new state
    /// (a removed container's words fall back to selection/body colour).
    private func applyClipContainers(_ new: [TranscriptClipContainer]) {
      guard let storage = textView?.textStorage, let layoutManager = clipLayoutManager else {
        return
      }
      let affected = lastClipContainers + new
      lastClipContainers = new
      layoutManager.containerRuns = new.map { container in
        let style = TranscriptClipStyle.style(for: container.kind)
        return ClipContainerRun(
          range: container.range, fill: Self.nsColor(style.fill), ring: Self.nsColor(style.ring))
      }
      storage.beginEditing()
      for container in affected {
        for wordRange in model.document.wordRanges
        where NSLocationInRange(wordRange.range.location, container.range) {
          setForeground(storage: storage, wordRange: wordRange.range, wordID: wordRange.wordID)
        }
      }
      storage.endEditing()
      if let union = Self.unionRange(affected) {
        layoutManager.invalidateDisplay(forCharacterRange: union)
      }
    }

    private static func unionRange(_ containers: [TranscriptClipContainer]) -> NSRange? {
      guard let first = containers.first else { return nil }
      var lower = first.range.location
      var upper = NSMaxRange(first.range)
      for container in containers.dropFirst() {
        lower = min(lower, container.range.location)
        upper = max(upper, NSMaxRange(container.range))
      }
      return NSRange(location: lower, length: upper - lower)
    }

    private func applySelection(added: Set<Word.ID>, removed: Set<Word.ID>) {
      guard let storage = textView?.textStorage else { return }
      storage.beginEditing()
      for id in removed {
        guard let wordRange = range(for: id) else { continue }
        storage.removeAttribute(.backgroundColor, range: wordRange)
      }
      for id in added {
        guard let wordRange = range(for: id) else { continue }
        storage.addAttribute(.backgroundColor, value: Self.selectedBG, range: wordRange)
      }
      // Foreground respects both selection and clip state, so recompute it (not just reset to
      // grey) for every word whose selection changed — a deselected clip word stays white/dim.
      for id in removed.union(added) {
        guard let wordRange = range(for: id) else { continue }
        setForeground(storage: storage, wordRange: wordRange, wordID: id)
      }
      storage.endEditing()
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
      lm.ensureLayout(for: container)
      // Empty/failed-load document: no glyphs means `glyphIndex(for:)` returns 0 and
      // `characterIndexForGlyph(at: 0)` would trap. Returning nil no-ops the handlers.
      guard lm.numberOfGlyphs > 0 else { return nil }
      let local = NSPoint(
        x: point.x - textView.textContainerInset.width,
        y: point.y - textView.textContainerInset.height)
      let glyph = lm.glyphIndex(for: local, in: container)
      // TextKit clamps out-of-bounds points to the nearest glyph, so a click on blank
      // space (below the last line, above the first, or in the left inset / right of a
      // ragged line's end) would toggle a stray word. Require the point to fall inside the
      // resolved line fragment's drawn text so only genuine word clicks resolve.
      let lineRect = lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
      guard lineRect.contains(local) else { return nil }
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
      coordinator.model.transcriptClicked(
        atUTF16Offset: anchor, extending: event.modifierFlags.contains(.shift))
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
