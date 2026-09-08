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
  let removedWordIDs: Set<Word.ID>
  let currentWordID: Word.ID?
  let scrollTarget: Word.ID?
  let followMode: TranscriptFollowMode
  let reveal: TranscriptReveal?
  var overlapPresentation: String = ""
  let resizeItems: [TranscriptResizeItem]

  static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
    coordinator.overlapPresenter.dismantle()
  }

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

    let overlay = TranscriptResizeHandleOverlayView(frame: textView.bounds)
    overlay.coordinator = context.coordinator
    overlay.autoresizingMask = [.width, .height]
    textView.addSubview(overlay)

    context.coordinator.model = model
    context.coordinator.textView = textView
    context.coordinator.scrollView = scroll
    context.coordinator.paragraphSpacing = paragraphSpacing
    context.coordinator.lineSpacing = lineSpacing
    context.coordinator.resizeOverlay = overlay
    context.coordinator.observeScroll()
    context.coordinator.rebuildText(
      text: text, fontSize: fontSize, selected: selected, clipContainers: clipContainers,
      removedWordIDs: removedWordIDs)
    return scroll
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    context.coordinator.model = model
    context.coordinator.paragraphSpacing = paragraphSpacing
    context.coordinator.lineSpacing = lineSpacing
    context.coordinator.apply(
      text: text, fontSize: fontSize, selected: selected, clipContainers: clipContainers,
      removedWordIDs: removedWordIDs, currentWordID: currentWordID, scrollTarget: scrollTarget,
      followMode: followMode, reveal: reveal, resizeItems: resizeItems)
    context.coordinator.updateOverlap()
  }

  @MainActor
  final class Coordinator: NSObject {
    let overlapPresenter: TranscriptOverlapPresenter
    var model: TranscriptPageModel
    weak var textView: NSTextView?
    weak var scrollView: NSScrollView?
    weak var resizeOverlay: TranscriptResizeHandleOverlayView?
    var paragraphSpacing: Double = 0
    var lineSpacing: Double = 0
    private var lastText = ""
    private var lastSelected: Set<Word.ID> = []
    private var lastClipContainers: [TranscriptClipContainer] = []
    private var lastRemovedWordIDs: Set<Word.ID> = []
    private var lastCurrentWordID: Word.ID?
    private var lastFontSize: Double = 0
    private var lastScrollTarget: Word.ID?
    private var lastFollowMode: TranscriptFollowMode = .following
    private var lastReveal: TranscriptReveal?
    // `resizeZones()` forces TextKit glyph geometry for every resize item and is called from the
    // overlay's `hitTest`/`cursorUpdate` — i.e. on every mouse-move and, as content scrolls under a
    // stationary pointer, on every scroll tick. Memoize it: zones are in document-view coordinates
    // (scroll-independent), so they only change when `apply(...)` receives changed resize items,
    // when text/font changes, or when the container rewraps on a width change (checked live in
    // `resizeZones()`).
    private var resizeItems: [TranscriptResizeItem] = []
    private var cachedResizeZones: [TranscriptResizeHandleZone]?
    private var cachedResizeZonesWidth: CGFloat?
    private var scrollTimer: Timer?
    private var scrollFromY: CGFloat = 0
    private var scrollToY: CGFloat = 0
    private var scrollStartedAt = Date()
    private let scrollDuration: TimeInterval = 0.3

    init(model: TranscriptPageModel) {
      self.model = model
      overlapPresenter = TranscriptOverlapPresenter(model: model.overlap)
    }

    func updateOverlap() {
      guard let textView else { return }
      overlapPresenter.update(textView: textView, document: model.document)
    }

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
      clipContainers: [TranscriptClipContainer], removedWordIDs: Set<Word.ID>
    ) {
      guard let storage = textView?.textStorage else { return }
      cachedResizeZones = nil
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
      lastRemovedWordIDs = []
      // Clips first (they colour their words white/dim), then removed words get their
      // strikethrough, then selection paints the red highlight + white text on top of
      // whichever words are selected — each pass recomputes through `setForeground`, so a
      // later pass never gets stomped by an earlier one.
      applyClipContainers(clipContainers)
      lastClipContainers = clipContainers
      lastRemovedWordIDs = removedWordIDs
      applyRemovedWordIDs(added: removedWordIDs, removed: [])
      lastSelected = selected
      applySelection(added: selected, removed: [])
    }

    // swiftlint:disable:next function_parameter_count
    func apply(
      text: String, fontSize: Double, selected: Set<Word.ID>,
      clipContainers: [TranscriptClipContainer], removedWordIDs: Set<Word.ID>,
      currentWordID: Word.ID?, scrollTarget: Word.ID?,
      followMode: TranscriptFollowMode, reveal: TranscriptReveal?,
      resizeItems: [TranscriptResizeItem]
    ) {
      guard let storage = textView?.textStorage, let textView else { return }

      let didRebuild = text != lastText
      if didRebuild {
        updateResizeItems(resizeItems)
        rebuildText(
          text: text, fontSize: fontSize, selected: selected, clipContainers: clipContainers,
          removedWordIDs: removedWordIDs)
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
        cachedResizeZones = nil
      }

      updateResizeItems(resizeItems)

      if clipContainers != lastClipContainers {
        applyClipContainers(clipContainers)
        lastClipContainers = clipContainers
      }

      let removedAdded = removedWordIDs.subtracting(lastRemovedWordIDs)
      let removedRemoved = lastRemovedWordIDs.subtracting(removedWordIDs)
      lastRemovedWordIDs = removedWordIDs
      applyRemovedWordIDs(added: removedAdded, removed: removedRemoved)

      let selAdded = selected.subtracting(lastSelected)
      let selRemoved = lastSelected.subtracting(selected)
      lastSelected = selected
      applySelection(added: selAdded, removed: selRemoved)

      applyScrollTarget(scrollTarget: scrollTarget, followMode: followMode, reveal: reveal)
    }

    private func updateResizeItems(_ newItems: [TranscriptResizeItem]) {
      guard newItems != resizeItems else { return }
      resizeItems = newItems
      cachedResizeZones = nil
    }

    private func applyScrollTarget(
      scrollTarget: Word.ID?, followMode: TranscriptFollowMode, reveal: TranscriptReveal?
    ) {
      guard let textView else { return }
      if followMode == .following, lastFollowMode == .userPaused {
        lastScrollTarget = nil
      }
      lastFollowMode = followMode

      let hasNewReveal = reveal != nil && reveal != lastReveal
      if hasNewReveal {
        lastScrollTarget = scrollTarget
        if let reveal, let range = range(for: reveal.wordID) {
          animatedScroll(toRange: range)
        }
        lastReveal = reveal
      } else if let target = scrollTarget, target != lastScrollTarget,
        followMode == .following, let range = range(for: target)
      {
        // Programmatic auto-scroll goes through neither `scrollWheel` nor live-scroll,
        // so it can never be mistaken for a user scroll — no guard flag needed.
        textView.scrollRangeToVisible(range)
        lastScrollTarget = target
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

    private func range(for occurrence: TranscriptWordOccurrence) -> NSRange? {
      guard model.document.wordRanges.indices.contains(occurrence.transcriptIndex),
        model.document.wordRanges[occurrence.transcriptIndex].wordID == occurrence.wordID
      else { return nil }
      return model.document.wordRanges[occurrence.transcriptIndex].range
    }

    /// The single source of truth for a word's text colour: selected wins (white), then a
    /// clip's own colour (white for live clips, dim grey for rejected), else the body grey.
    /// Both the selection diff and the clip diff route foreground through here so neither
    /// stomps the other when a word is both selected and inside a clip.
    private func foregroundColor(selected: Bool, container: TranscriptClipContainer?) -> NSColor {
      if selected { return Self.selectedFG }
      guard let container else { return Self.normalFG }
      return Self.nsColor(container.style.text)
    }

    /// The single authority for both a word's text colour AND its strikethrough. Strikethrough
    /// is the UNION of "inside a rejected clip" and "inside a removed section" — every diff
    /// (selection, clip, removed-words) routes through here so none of them can stomp the
    /// others when a word is affected by more than one.
    private func setForeground(storage: NSTextStorage, wordRange: NSRange, wordID: Word.ID) {
      let container = lastClipContainers.first { NSLocationInRange(wordRange.location, $0.range) }
      let kind = container?.kind
      storage.addAttribute(
        .foregroundColor,
        value: foregroundColor(selected: lastSelected.contains(wordID), container: container),
        range: wordRange)
      let struck = kind == .rejected || lastRemovedWordIDs.contains(wordID)
      if struck {
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
      let affected = TranscriptClipContainer.changed(from: lastClipContainers, to: new)
      lastClipContainers = new
      // The clip's own `colorIndex` is the palette variant, so every run of one clip shares a
      // colour while adjacent clips differ.
      layoutManager.containerRuns = new.reversed().map { container in
        let style = container.style
        return ClipContainerRun(
          range: container.range, fill: Self.nsColor(style.fill), ring: Self.nsColor(style.ring),
          dashed: style.dashed, ringWidth: style.ringWidth)
      }
      layoutManager.containerRuns += new.filter(\.isPreviewed).map { container in
        ClipContainerRun(
          range: container.range, fill: .clear, ring: Self.nsColor(container.style.ring),
          dashed: container.style.dashed, ringWidth: 2)
      }
      storage.beginEditing()
      for container in affected {
        for wordRange in model.document.words(startingWithin: container.range) {
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

    /// Refreshes strikethrough (and, incidentally, foreground colour) for every word whose
    /// removed-section membership just changed — `lastRemovedWordIDs` is already updated by the
    /// caller, so `setForeground` reads the new state. Words entering `removedWordIDs` gain the
    /// strike; words leaving it lose it unless a rejected clip still covers them.
    private func applyRemovedWordIDs(added: Set<Word.ID>, removed: Set<Word.ID>) {
      guard let storage = textView?.textStorage else { return }
      storage.beginEditing()
      for id in added.union(removed) {
        guard let wordRange = range(for: id) else { continue }
        setForeground(storage: storage, wordRange: wordRange, wordID: id)
      }
      storage.endEditing()
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
      scrollView.contentView.postsBoundsChangedNotifications = true
      NotificationCenter.default.addObserver(
        self, selector: #selector(viewportChanged),
        name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
      NotificationCenter.default.addObserver(
        self, selector: #selector(userDidLiveScroll),
        name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
    }

    @objc private func viewportChanged() { updateOverlap() }

    @objc private func userDidLiveScroll() {
      model.overlap.dismiss()
      updateOverlap()
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
      guard glyph < lm.numberOfGlyphs else { return nil }
      // TextKit clamps out-of-bounds points to the nearest glyph, so a click on blank
      // space (below the last line, above the first, or in the left inset / right of a
      // ragged line's end) would toggle a stray word. Require the point to fall inside the
      // resolved line fragment's drawn text so only genuine word clicks resolve.
      let lineRect = lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
      guard lineRect.contains(local) else { return nil }
      let character = lm.characterIndexForGlyph(at: glyph)
      let font =
        textView.textStorage?.attribute(.font, at: character, effectiveRange: nil) as? NSFont
        ?? .systemFont(ofSize: NSFont.systemFontSize)
      let fragment = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      let baseline = fragment.minY + lm.location(forGlyphAt: glyph).y
      guard local.y >= baseline - font.ascender - 3,
        local.y <= baseline - font.descender + 3
      else { return nil }
      return character
    }

    // MARK: Resize handle geometry (Task 3 — cursor/geometry only, no mutation)

    /// Start/end grab rects for every resizable item's true first/last word, in
    /// document-view coordinates (text-container coords plus `textContainerInset`, matching
    /// `utf16Offset(at:)`'s inset handling so zones and the lenient hit-test agree).
    func resizeZones() -> [TranscriptResizeHandleZone] {
      guard let textView, let layoutManager = textView.layoutManager,
        let textContainer = textView.textContainer
      else { return [] }
      // A width change rewraps the text (new line fragments → new zone rects) without an `apply`
      // call, so validate the cache against the current width before returning it.
      let width = textView.bounds.width
      if let cached = cachedResizeZones, cachedResizeZonesWidth == width {
        return cached
      }
      layoutManager.ensureLayout(for: textContainer)
      let inset = textView.textContainerInset
      var zones: [TranscriptResizeHandleZone] = []
      for (index, item) in resizeItems.enumerated() {
        guard let first = item.wordOccurrences.first, let last = item.wordOccurrences.last,
          let firstRange = range(for: first), let lastRange = range(for: last)
        else { continue }
        func zone(
          _ nsRange: NSRange, _ edge: TranscriptResizeEdge,
          _ occurrence: TranscriptWordOccurrence
        ) -> TranscriptResizeHandleZone? {
          let glyphRange = layoutManager.glyphRange(
            forCharacterRange: nsRange, actualCharacterRange: nil)
          var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
          rect.origin.x += inset.width
          rect.origin.y += inset.height
          let edgeX = edge == .start ? rect.minX : rect.maxX
          let grab = CGRect(
            x: edgeX - TranscriptResizeMetrics.grabTolerance, y: rect.minY,
            width: TranscriptResizeMetrics.grabTolerance * 2, height: rect.height)
          return TranscriptResizeHandleZone(
            identity: item.identity, edge: edge, occurrence: occurrence, rect: grab,
            priority: item.identity == .selection
              ? resizeItems.count + 1 : resizeItems.count - index)
        }
        if let handleZone = zone(firstRange, .start, first) { zones.append(handleZone) }
        if let handleZone = zone(lastRange, .end, last) { zones.append(handleZone) }
      }
      cachedResizeZones = zones
      cachedResizeZonesWidth = width
      return zones
    }

    /// D2 priority resolution among the zones containing `point` (highest `priority` wins,
    /// ties by nearest edge-x, then a deterministic key). Pure logic lives in
    /// `TranscriptResizeMath.resolveHandle`; the coordinator only supplies the live zone geometry.
    func resizeHandle(at point: NSPoint) -> TranscriptResizeHandleTarget? {
      TranscriptResizeMath.resolveHandle(hitting: point, in: resizeZones())
    }

    /// Lenient word hit-test for resize dragging: like `utf16Offset(at:)` but drops the
    /// "point inside the used line rect" rejection, clamping x into the resolved line
    /// fragment before resolving the character index. This lets a drag that strays above/
    /// below/beyond the exact glyph bounds still resolve to the nearest word on that line.
    func wordOccurrenceForResize(at point: NSPoint) -> TranscriptWordOccurrence? {
      guard let textView, let layoutManager = textView.layoutManager,
        let textContainer = textView.textContainer
      else { return nil }
      layoutManager.ensureLayout(for: textContainer)
      guard layoutManager.numberOfGlyphs > 0 else { return nil }
      let inset = textView.textContainerInset
      let local = NSPoint(x: point.x - inset.width, y: point.y - inset.height)
      let glyphIndex = layoutManager.glyphIndex(for: local, in: textContainer)
      var lineRange = NSRange()
      let lineRect = layoutManager.lineFragmentUsedRect(
        forGlyphAt: glyphIndex, effectiveRange: &lineRange)
      let clampedX = min(max(local.x, lineRect.minX), lineRect.maxX - 0.5)
      let clamped = NSPoint(x: clampedX, y: lineRect.midY)
      let idx = layoutManager.glyphIndex(for: clamped, in: textContainer)
      let charIndex = layoutManager.characterIndexForGlyph(at: idx)
      return wordOccurrence(atUTF16Offset: charIndex)
    }

    private func wordOccurrence(atUTF16Offset offset: Int) -> TranscriptWordOccurrence? {
      guard let first = model.document.wordRanges.first else { return nil }
      var low = 0
      var high = model.document.wordRanges.count - 1
      var candidate = -1
      while low <= high {
        let mid = (low + high) / 2
        if model.document.wordRanges[mid].range.location <= offset {
          candidate = mid
          low = mid + 1
        } else {
          high = mid - 1
        }
      }
      let index = candidate >= 0 ? candidate : 0
      let wordID = candidate >= 0 ? model.document.wordRanges[index].wordID : first.wordID
      return TranscriptWordOccurrence(wordID: wordID, transcriptIndex: index)
    }
  }
}

/// Forwards mouse events to the coordinator as UTF-16 offsets and classifies click vs
/// drag from the raw event stream. No selection decisions here — those live in the model.
final class HitTestingTextView: NSTextView {
  weak var coordinator: TranscriptTextView.Coordinator?
  private var anchorOffset: Int?
  private var pointer = TranscriptPointerGesture()
  private var beganWordDrag = false

  override func accessibilityChildren() -> [Any]? {
    var children = super.accessibilityChildren() ?? []
    if let button = coordinator?.overlapPresenter.button, !button.isHidden {
      children.append(button)
    }
    return children
  }

  override func mouseDown(with event: NSEvent) {
    endActiveTextEditing()
    anchorOffset = coordinator?.utf16Offset(at: convert(event.locationInWindow, from: nil))
    pointer.began(at: event.locationInWindow)
    beganWordDrag = false
  }

  override func mouseDragged(with event: NSEvent) {
    _ = pointer.moved(to: event.locationInWindow)
    guard pointer.isDragging, let coordinator else { return }
    let point = convert(event.locationInWindow, from: nil)
    let offset = coordinator.utf16Offset(at: point)
    if !beganWordDrag {
      beganWordDrag = coordinator.model.transcriptDragBegan(atUTF16Offset: anchorOffset ?? offset)
    }
    if beganWordDrag, let offset { coordinator.model.transcriptDragged(toUTF16Offset: offset) }
  }

  override func mouseUp(with event: NSEvent) {
    defer {
      anchorOffset = nil
      beganWordDrag = false
    }
    guard let coordinator else {
      pointer.cancelled()
      return
    }
    switch pointer.ended(clickCount: event.clickCount) {
    case .click(let count):
      coordinator.model.transcriptClicked(
        atUTF16Offset: anchorOffset, extending: event.modifierFlags.contains(.shift),
        clickCount: count, timestamp: event.timestamp,
        doubleClickInterval: NSEvent.doubleClickInterval)
    case .dragEnded:
      coordinator.model.transcriptDragEnded()
    case .none: break
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    NotificationCenter.default.removeObserver(
      self, name: NSWindow.didResignKeyNotification, object: nil)
    if let window {
      NotificationCenter.default.addObserver(
        self, selector: #selector(windowResignedKey),
        name: NSWindow.didResignKeyNotification, object: window)
    } else {
      cancelPointerTracking()
    }
  }

  deinit { NotificationCenter.default.removeObserver(self) }

  @objc private func windowResignedKey() { cancelPointerTracking() }

  override func cancelOperation(_ sender: Any?) {
    cancelPointerTracking()
  }

  private func cancelPointerTracking() {
    pointer.cancelled()
    anchorOffset = nil
    beganWordDrag = false
    coordinator?.model.clickCapture = nil
  }

  override func scrollWheel(with event: NSEvent) {
    coordinator?.model.transcriptUserScrolled()
    coordinator?.model.overlap.dismiss()
    super.scrollWheel(with: event)
    coordinator?.updateOverlap()
  }
}
