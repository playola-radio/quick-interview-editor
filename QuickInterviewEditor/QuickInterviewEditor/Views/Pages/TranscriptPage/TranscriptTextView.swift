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
  let lineSpacing: Double
  let selected: Set<Word.ID>
  let clipContainers: [TranscriptClipContainer]
  let currentWordID: Word.ID?
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
    context.coordinator.lineSpacing = lineSpacing
    context.coordinator.observeScroll()
    context.coordinator.rebuildText(
      text: text, fontSize: fontSize, selected: selected, clipContainers: clipContainers)
    return scroll
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    context.coordinator.model = model
    context.coordinator.paragraphSpacing = paragraphSpacing
    context.coordinator.lineSpacing = lineSpacing
    context.coordinator.apply(
      text: text, fontSize: fontSize, selected: selected, clipContainers: clipContainers,
      currentWordID: currentWordID, scrollTarget: scrollTarget, followMode: followMode,
      reveal: reveal)
  }

  @MainActor
  final class Coordinator: NSObject {
    var model: TranscriptPageModel
    weak var textView: NSTextView?
    weak var scrollView: NSScrollView?
    var paragraphSpacing: Double = 0
    var lineSpacing: Double = 0
    private var lastText = ""
    private var lastSelected: Set<Word.ID> = []
    private var lastClipContainers: [TranscriptClipContainer] = []
    private var lastCurrentWordID: Word.ID?
    private var lastFontSize: Double = 0
    private var lastScrollTarget: Word.ID?
    private var lastFollowMode: TranscriptFollowMode = .following
    private var lastReveal: TranscriptReveal?
    private var scrollTimer: Timer?
    private var scrollFromY: CGFloat = 0
    private var scrollToY: CGFloat = 0
    private var scrollStartedAt = Date()
    private let scrollDuration: TimeInterval = 0.3

    init(model: TranscriptPageModel) { self.model = model }

    // The reveal scroll timer isn't invalidated here (a nonisolated deinit can't touch the
    // non-Sendable Timer): it self-invalidates when the 0.3s animation completes or the scroll
    // view goes away, retaining this coordinator only for that short window.
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
      // Same gap within a paragraph as between paragraphs, so line spacing reads uniform and a
      // clip container has vertical room and never overlaps the next line's container.
      paragraphStyle.lineSpacing = lineSpacing
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
      clipContainers: [TranscriptClipContainer], currentWordID: Word.ID?, scrollTarget: Word.ID?,
      followMode: TranscriptFollowMode, reveal: TranscriptReveal?
    ) {
      guard let storage = textView?.textStorage, let textView else { return }

      let didRebuild = text != lastText
      if didRebuild {
        rebuildText(
          text: text, fontSize: fontSize, selected: selected, clipContainers: clipContainers)
        lastCurrentWordID = nil
      }

      // The current-word highlight is a light band the layout manager draws (not a text
      // attribute), so moving it is a repaint, never a reflow. Applied after a rebuild too.
      if currentWordID != lastCurrentWordID {
        clipLayoutManager?.currentWordRange = currentWordID.flatMap { range(for: $0) }
        lastCurrentWordID = currentWordID
        textView.needsDisplay = true
      }

      if didRebuild { return }

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

      // An explicit reveal (scroll-to-current-word, clicking a suggestion or clip) scrolls
      // regardless of `followMode` — the user asked to jump here, so a prior manual scroll must
      // not suppress it. It animates, centring the focus word, so the jump reads as movement
      // rather than a teleport. The token in `TranscriptReveal` changes on every request, so
      // re-revealing the same word re-scrolls.
      if let reveal, reveal != lastReveal {
        if let range = range(for: reveal.wordID) {
          animatedScroll(toRange: range)
        }
        lastReveal = reveal
      }
    }

    /// Smoothly scrolls the range to the vertical centre of the viewport, interpolating from the
    /// CURRENT scroll position (animating `NSClipView.bounds` via `.animator()` jumps to the top
    /// first, so it's driven by hand). Programmatic scrolling goes through neither `scrollWheel`
    /// nor live-scroll, so it is never mistaken for a user scroll (which pauses follow).
    private func animatedScroll(toRange range: NSRange) {
      guard let textView, let scrollView, let layoutManager = textView.layoutManager,
        let container = textView.textContainer
      else { return }
      layoutManager.ensureLayout(for: container)
      let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
      let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
      let clip = scrollView.contentView
      let viewportHeight = clip.bounds.height
      let center = rect.midY + textView.textContainerInset.height - viewportHeight / 2
      let maxY = max(0, textView.frame.height - viewportHeight)
      let targetY = min(max(0, center), maxY)
      let startY = clip.bounds.origin.y
      guard abs(targetY - startY) > 0.5 else { return }

      scrollTimer?.invalidate()
      scrollFromY = startY
      scrollToY = targetY
      scrollStartedAt = Date()
      // Target-action (not a `@Sendable` closure) so the per-frame main-actor scroll work is
      // concurrency-clean; the timer runs on the main run loop.
      scrollTimer = Timer.scheduledTimer(
        timeInterval: 1 / 60, target: self, selector: #selector(stepScrollAnimation),
        userInfo: nil, repeats: true)
    }

    @objc private func stepScrollAnimation() {
      guard let scrollView else {
        scrollTimer?.invalidate()
        scrollTimer = nil
        return
      }
      let fraction = min(1, Date().timeIntervalSince(scrollStartedAt) / scrollDuration)
      // ease-in-out cubic
      let eased =
        fraction < 0.5
        ? 4 * fraction * fraction * fraction
        : 1 - pow(-2 * fraction + 2, 3) / 2
      let content = scrollView.contentView
      content.setBoundsOrigin(
        NSPoint(x: content.bounds.origin.x, y: scrollFromY + (scrollToY - scrollFromY) * eased))
      scrollView.reflectScrolledClipView(content)
      if fraction >= 1 {
        scrollTimer?.invalidate()
        scrollTimer = nil
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
      // The clip's own `colorIndex` is the palette variant, so every run of one clip shares a
      // colour while adjacent clips differ.
      layoutManager.containerRuns = new.map { container in
        let style = TranscriptClipStyle.style(for: container.kind, variant: container.colorIndex)
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
      // The container fill/ring paints beyond the glyph bounds (vertical padding, line-edge
      // fills), so a character-range invalidation would leave stale ring pixels after a band
      // add/remove. Band changes are infrequent (a clip is created/accepted/rejected), so a
      // full redraw is cheap and correct.
      textView?.needsDisplay = true
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
