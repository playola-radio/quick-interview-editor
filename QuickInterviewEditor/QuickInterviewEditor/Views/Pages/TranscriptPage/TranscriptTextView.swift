import AppKit
import SwiftUI

/// The role a word plays in a clip block, derived from the block's word run by transcript
/// position: the run's first word is the START drag handle, its last word the END handle, the
/// rest interior (click-to-pull targets). A single-word clip's sole word is its START handle.
enum ClipWordRole: Equatable {
  case start(EditorClip.ID)
  case end(EditorClip.ID)
  case interior(EditorClip.ID)
}

/// Dumb TextKit-1 renderer. Owns the AppKit objects and converts points to UTF-16 offsets; every
/// decision (which word, which clip, which boundary) lives in the model. Clips render inline as
/// tinted blocks over their existing word glyphs — no words are moved, inserted, or lifted out of
/// the flow, so a boundary edit changes only attributes + custom drawing (spec §5).
struct TranscriptTextView: NSViewRepresentable {
  let model: TranscriptPageModel
  let text: String
  let fontSize: Double
  let paragraphSpacing: Double
  let selected: Set<Word.ID>
  let scrollTarget: Word.ID?
  let followMode: TranscriptFollowMode
  let reveal: TranscriptReveal?
  let blocks: [ClipBlockVM]
  let clipsOnly: Bool
  let blockActions: TranscriptBlockActions

  func makeCoordinator() -> Coordinator { Coordinator(model: model) }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false

    let contentSize = scroll.contentSize
    let textView = HitTestingTextView()
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
    textView.frame = NSRect(origin: .zero, size: contentSize)
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(
      width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)

    // Swap in the ring-drawing layout manager (keeps the storage + container; forces the same
    // TextKit-1 stack the rest of the renderer relies on).
    let blockLayoutManager = ClipBlockLayoutManager()
    textView.textContainer?.replaceLayoutManager(blockLayoutManager)
    context.coordinator.blockLayoutManager = blockLayoutManager

    scroll.documentView = textView

    context.coordinator.model = model
    context.coordinator.textView = textView
    context.coordinator.scrollView = scroll
    context.coordinator.blockActions = blockActions
    context.coordinator.paragraphSpacing = paragraphSpacing
    context.coordinator.observeScroll()
    context.coordinator.rebuildText(text: text, fontSize: fontSize)
    context.coordinator.applyBlocks(blocks: blocks, selected: selected, clipsOnly: clipsOnly)
    return scroll
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    context.coordinator.model = model
    context.coordinator.blockActions = blockActions
    context.coordinator.paragraphSpacing = paragraphSpacing
    context.coordinator.apply(
      text: text, fontSize: fontSize,
      scrollTarget: scrollTarget, followMode: followMode, reveal: reveal)
    context.coordinator.applyBlocks(blocks: blocks, selected: selected, clipsOnly: clipsOnly)
  }

  @MainActor
  final class Coordinator: NSObject {
    var model: TranscriptPageModel
    weak var textView: NSTextView?
    weak var scrollView: NSScrollView?
    weak var blockLayoutManager: ClipBlockLayoutManager?
    var blockActions = TranscriptBlockActions(
      railTapped: { _ in }, select: { _ in }, interiorClicked: { _, _ in },
      boundaryDragBegan: { _, _ in }, boundaryDragged: { _ in },
      boundaryDragEnded: {}, boundaryDragCancelled: {})
    var paragraphSpacing: Double = 0
    private var lastText = ""
    private var lastFontSize: Double = 0
    private var lastScrollTarget: Word.ID?
    private var lastFollowMode: TranscriptFollowMode = .following
    private var lastReveal: TranscriptReveal?

    // Block coloring state.
    private var currentBlocks: [ClipBlockVM] = []
    private var currentSelected: Set<Word.ID> = []
    private var currentClipsOnly = false
    private var lastClipsOnly = false
    /// The exact word ranges tinted last pass, reset to base before the next re-tint. A list (not
    /// a bounding union) so clips far apart don't force a re-color of the whole gap between them.
    private var lastAffectedRanges: [NSRange] = []
    /// Set after a text rebuild (colors were wiped) to force the next `applyBlocks` to recolor the
    /// whole document base rather than only the previously tinted ranges.
    private var needsFullRecolor = true
    /// The clip end word the pointer is over (its fill brightens), or nil. View-local — hover
    /// never touches model state, so a re-tint on hover is triggered here, not via `updateNSView`.
    private var hoveredWordID: Word.ID?
    /// wordID → its role in a clip block, rebuilt each `applyBlocks`. Drives both hit-testing
    /// (which gesture a mousedown starts) and the hover cursor.
    private(set) var wordRoles: [Word.ID: ClipWordRole] = [:]

    init(model: TranscriptPageModel) { self.model = model }

    deinit { NotificationCenter.default.removeObserver(self) }

    private static let normalFG = NSColor(calibratedWhite: 0.56, alpha: 1)
    private static let dimFG = NSColor(calibratedWhite: 0.2, alpha: 1)
    private static let clipFG = NSColor(calibratedWhite: 0.96, alpha: 1)
    private static let rejectedFG = NSColor(calibratedWhite: 0.29, alpha: 1)
    private static let selectedFG = NSColor.white
    private static let freeSelectionBG = NSColor(calibratedWhite: 0.85, alpha: 0.22)

    struct BlockStyle {
      var fill: NSColor
      var hoverFill: NSColor
      var ring: NSColor
      var fg: NSColor
      var strike: Bool
    }

    /// Maps a clip's STATE + currentness to its exact draw colors — the one place the renderer
    /// turns clip meaning into pixels. Current is always red; a rejected (non-current) clip dims
    /// and strikes through.
    private static func tint(state: ClipState, isCurrent: Bool) -> BlockStyle {
      let base: NSColor
      if isCurrent {
        base = NSColor(calibratedRed: 0.8, green: 0.4, blue: 0.4, alpha: 1)
      } else {
        switch state {
        case .approved: base = NSColor(calibratedRed: 0.373, green: 0.725, blue: 0.561, alpha: 1)
        case .suggested: base = NSColor(calibratedRed: 0.816, green: 0.643, blue: 0.373, alpha: 1)
        case .rejected: base = NSColor(calibratedWhite: 0.29, alpha: 1)
        }
      }
      let isRejected = state == .rejected && !isCurrent
      return BlockStyle(
        fill: base.withAlphaComponent(0.17),
        hoverFill: base.withAlphaComponent(0.30),
        ring: base.withAlphaComponent(0.45),
        fg: isRejected ? rejectedFG : clipFG,
        strike: isRejected)
    }

    func rebuildText(text: String, fontSize: Double) {
      guard let storage = textView?.textStorage else { return }
      let attr = NSMutableAttributedString(string: text)
      let full = NSRange(location: 0, length: attr.length)
      attr.addAttribute(.font, value: NSFont.systemFont(ofSize: fontSize), range: full)
      attr.addAttribute(.foregroundColor, value: Self.normalFG, range: full)
      let paragraphStyle = NSMutableParagraphStyle()
      paragraphStyle.paragraphSpacing = paragraphSpacing
      attr.addAttribute(.paragraphStyle, value: paragraphStyle, range: full)
      storage.setAttributedString(attr)
      lastText = text
      lastFontSize = fontSize
      // The colors were reset with the text; force `applyBlocks` to recolor the whole document.
      needsFullRecolor = true
      lastAffectedRanges = []
    }

    func apply(
      text: String, fontSize: Double,
      scrollTarget: Word.ID?, followMode: TranscriptFollowMode, reveal: TranscriptReveal?
    ) {
      guard let storage = textView?.textStorage, let textView else { return }

      if text != lastText {
        rebuildText(text: text, fontSize: fontSize)
      }

      if fontSize != lastFontSize {
        storage.addAttribute(
          .font, value: NSFont.systemFont(ofSize: fontSize),
          range: NSRange(location: 0, length: storage.length))
        lastFontSize = fontSize
      }

      if followMode == .following, lastFollowMode == .userPaused {
        lastScrollTarget = nil
      }
      lastFollowMode = followMode

      if let target = scrollTarget, target != lastScrollTarget,
        followMode == .following, let range = range(for: target)
      {
        textView.scrollRangeToVisible(range)
        lastScrollTarget = target
      }

      if let reveal, reveal != lastReveal {
        if let range = range(for: reveal.wordID) {
          textView.scrollRangeToVisible(range)
        }
        lastReveal = reveal
      }
    }

    /// Recolors the transcript for the current clip blocks + free selection. Clip words take their
    /// state fill/ring/foreground (the hovered end brightens); non-clip words stay base body color
    /// (dimmed under Clips only); a selection outside any clip gets the neutral new-slice highlight.
    /// Only the previously + currently tinted ranges are touched (a full recolor only when the base
    /// color changes), so a live drag re-tints just the clip whose boundary moved.
    func applyBlocks(blocks: [ClipBlockVM], selected: Set<Word.ID>, clipsOnly: Bool) {
      guard let storage = textView?.textStorage else { return }
      currentBlocks = blocks
      currentSelected = selected
      currentClipsOnly = clipsOnly
      let base = clipsOnly ? Self.dimFG : Self.normalFG

      storage.beginEditing()
      clearPreviousTint(storage: storage, base: base, clipsOnly: clipsOnly)

      let ranges = wordRangeLookup()
      var roles: [Word.ID: ClipWordRole] = [:]
      var draws: [ClipBlockDraw] = []
      var affected: [NSRange] = []
      let blockWordIDs = Set(blocks.flatMap(\.wordIDs))

      for block in blocks {
        guard let run = span(for: block.wordIDs, ranges: ranges) else { continue }
        let style = Self.tint(state: block.state, isCurrent: block.isCurrent)
        tintBlock(storage: storage, run: run, style: style, ranges: ranges)
        recordRoles(&roles, block: block, first: run.first, last: run.last)
        draws.append(ClipBlockDraw(charRange: run.span, ringColor: style.ring))
        affected.append(run.span)
      }

      for id in selected where !blockWordIDs.contains(id) {
        guard let range = ranges[id] else { continue }
        storage.addAttribute(.backgroundColor, value: Self.freeSelectionBG, range: range)
        storage.addAttribute(.foregroundColor, value: Self.selectedFG, range: range)
        affected.append(range)
      }
      storage.endEditing()

      wordRoles = roles
      lastAffectedRanges = affected
      blockLayoutManager?.blocks = draws
    }

    /// Resets the previously tinted ranges (or the whole document when the base color changed) back
    /// to plain body text, so the next pass re-tints from a clean slate.
    private func clearPreviousTint(storage: NSTextStorage, base: NSColor, clipsOnly: Bool) {
      let full = NSRange(location: 0, length: storage.length)
      if needsFullRecolor || clipsOnly != lastClipsOnly {
        storage.removeAttribute(.backgroundColor, range: full)
        storage.removeAttribute(.strikethroughStyle, range: full)
        storage.addAttribute(.foregroundColor, value: base, range: full)
      } else {
        for range in lastAffectedRanges {
          storage.removeAttribute(.backgroundColor, range: range)
          storage.removeAttribute(.strikethroughStyle, range: range)
          storage.addAttribute(.foregroundColor, value: base, range: range)
        }
      }
      needsFullRecolor = false
      lastClipsOnly = clipsOnly
    }

    /// Tints one clip's contiguous run: the continuous state fill + foreground (+ strikethrough
    /// when rejected), then brightens the run's hovered end word.
    private func tintBlock(
      storage: NSTextStorage, run: ClipRun, style: BlockStyle, ranges: [Word.ID: NSRange]
    ) {
      storage.addAttribute(.backgroundColor, value: style.fill, range: run.span)
      storage.addAttribute(.foregroundColor, value: style.fg, range: run.span)
      if style.strike {
        storage.addAttribute(
          .strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: run.span)
      }
      if let hovered = hoveredWordID, hovered == run.first || hovered == run.last,
        let hoverRange = ranges[hovered]
      {
        storage.addAttribute(.backgroundColor, value: style.hoverFill, range: hoverRange)
      }
    }

    private func recordRoles(
      _ roles: inout [Word.ID: ClipWordRole], block: ClipBlockVM, first: Word.ID, last: Word.ID
    ) {
      roles[first] = .start(block.id)
      if last != first { roles[last] = .end(block.id) }
      for id in block.wordIDs where id != first && id != last {
        roles[id] = .interior(block.id)
      }
    }

    private func wordRangeLookup() -> [Word.ID: NSRange] {
      Dictionary(
        model.document.wordRanges.map { ($0.wordID, $0.range) },
        uniquingKeysWith: { first, _ in first })
    }

    /// A clip's contiguous UTF-16 span (first word's start to last word's end, so the in-between
    /// separators are inside it → a continuous fill) plus which word is the run's first/last by
    /// transcript position.
    struct ClipRun {
      var span: NSRange
      var first: Word.ID
      var last: Word.ID
    }

    /// The `ClipRun` covering a clip's words, or nil when none of them resolve to a range.
    private func span(for wordIDs: [Word.ID], ranges: [Word.ID: NSRange]) -> ClipRun? {
      let present = wordIDs.compactMap { id in ranges[id].map { (id, $0) } }
      guard let firstByLoc = present.min(by: { $0.1.location < $1.1.location }),
        let lastByLoc = present.max(by: { $0.1.location < $1.1.location })
      else { return nil }
      let start = firstByLoc.1.location
      let end = lastByLoc.1.location + lastByLoc.1.length
      return ClipRun(
        span: NSRange(location: start, length: end - start), first: firstByLoc.0, last: lastByLoc.0)
    }

    // MARK: - Hover
    /// The pointer moved over the transcript: set the boundary-drag cursor over a clip's end word
    /// and brighten that end, an arrow otherwise. Re-tints only when the hovered end changes.
    func hoverMoved(to point: NSPoint) {
      let role = clipWord(at: point)?.role
      let end: Word.ID?
      switch role {
      case .start, .end:
        NSCursor.resizeLeftRight.set()
        end = clipWord(at: point)?.wordID
      default:
        NSCursor.arrow.set()
        end = nil
      }
      guard end != hoveredWordID else { return }
      hoveredWordID = end
      applyBlocks(blocks: currentBlocks, selected: currentSelected, clipsOnly: currentClipsOnly)
    }

    func hoverEnded() {
      NSCursor.arrow.set()
      guard hoveredWordID != nil else { return }
      hoveredWordID = nil
      applyBlocks(blocks: currentBlocks, selected: currentSelected, clipsOnly: currentClipsOnly)
    }

    private func range(for id: Word.ID) -> NSRange? {
      model.document.wordRanges.first { $0.wordID == id }?.range
    }

    // MARK: Scroll observation
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
    /// The word (and its clip role, if any) under a point, gated to a real glyph hit — nil on
    /// blank space. Used for clicks and hover.
    func clipWord(at point: NSPoint) -> (wordID: Word.ID, role: ClipWordRole?)? {
      guard let offset = utf16Offset(at: point),
        let id = model.document.wordID(atUTF16Offset: offset)
      else { return nil }
      return (id, wordRoles[id])
    }

    /// The word nearest a point, clamping to the closest glyph rather than gating on a hit — so a
    /// boundary drag past the text still resolves the nearest word (spec §4's "word whose box
    /// center is nearest the pointer").
    func nearestWordID(at point: NSPoint) -> Word.ID? {
      guard let textView, let lm = textView.layoutManager, let container = textView.textContainer
      else { return nil }
      lm.ensureLayout(for: container)
      guard lm.numberOfGlyphs > 0 else { return nil }
      let local = NSPoint(
        x: point.x - textView.textContainerInset.width,
        y: point.y - textView.textContainerInset.height)
      let glyph = lm.glyphIndex(for: local, in: container)
      return model.document.wordID(atUTF16Offset: lm.characterIndexForGlyph(at: glyph))
    }

    func utf16Offset(at point: NSPoint) -> Int? {
      guard let textView, let lm = textView.layoutManager, let container = textView.textContainer
      else { return nil }
      lm.ensureLayout(for: container)
      guard lm.numberOfGlyphs > 0 else { return nil }
      let local = NSPoint(
        x: point.x - textView.textContainerInset.width,
        y: point.y - textView.textContainerInset.height)
      let glyph = lm.glyphIndex(for: local, in: container)
      let lineRect = lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
      guard lineRect.contains(local) else { return nil }
      return lm.characterIndexForGlyph(at: glyph)
    }
  }
}

/// Forwards mouse events to the coordinator, classifying each gesture from the word under the
/// pointer: a clip's end word starts a boundary drag (or bare-click selects the clip), an interior
/// word is a focus/pull click, a non-clip word is a plain transcript selection. No clip decisions
/// here — those live in the model.
final class HitTestingTextView: NSTextView {
  weak var coordinator: TranscriptTextView.Coordinator?

  private enum Gesture {
    case none
    case boundary(EditorClip.ID, side: SliceEdge, began: Bool)
    case interior(EditorClip.ID, Word.ID)
    case free(anchor: Int, began: Bool)
  }
  private var gesture: Gesture = .none
  private var escMonitor: Any?
  private var hoverTrackingArea: NSTrackingArea?

  override func mouseDown(with event: NSEvent) {
    guard let coordinator else { return }
    let point = convert(event.locationInWindow, from: nil)
    if let (wordID, role) = coordinator.clipWord(at: point) {
      switch role {
      case .start(let id): gesture = .boundary(id, side: .start, began: false)
      case .end(let id): gesture = .boundary(id, side: .end, began: false)
      case .interior(let id): gesture = .interior(id, wordID)
      case nil:
        gesture =
          coordinator.utf16Offset(at: point).map { .free(anchor: $0, began: false) } ?? .none
      }
    } else {
      gesture = .none
    }
  }

  override func mouseDragged(with event: NSEvent) {
    guard let coordinator else { return }
    let point = convert(event.locationInWindow, from: nil)
    switch gesture {
    case .boundary(let id, let side, let began):
      if !began {
        coordinator.blockActions.boundaryDragBegan(id, side)
        installEscMonitor()
        gesture = .boundary(id, side: side, began: true)
      }
      if let wordID = coordinator.nearestWordID(at: point) {
        coordinator.blockActions.boundaryDragged(wordID)
      }
    case .free(let anchor, let began):
      if !began { coordinator.model.transcriptDragBegan(atUTF16Offset: anchor) }
      gesture = .free(anchor: anchor, began: true)
      if let offset = coordinator.utf16Offset(at: point) {
        coordinator.model.transcriptDragged(toUTF16Offset: offset)
      }
    case .interior, .none:
      break
    }
  }

  override func mouseUp(with event: NSEvent) {
    guard let coordinator else { return }
    switch gesture {
    case .boundary(let id, _, let began):
      if began {
        coordinator.blockActions.boundaryDragEnded()
        removeEscMonitor()
      } else {
        coordinator.blockActions.select(id)
      }
    case .interior(let id, let wordID):
      coordinator.blockActions.interiorClicked(id, wordID)
    case .free(let anchor, let began):
      if !began {
        coordinator.model.transcriptClicked(
          atUTF16Offset: anchor, extending: event.modifierFlags.contains(.shift))
      }
      coordinator.model.transcriptDragEnded()
    case .none:
      break
    }
    gesture = .none
  }

  override func mouseMoved(with event: NSEvent) {
    coordinator?.hoverMoved(to: convert(event.locationInWindow, from: nil))
  }

  override func mouseExited(with event: NSEvent) {
    coordinator?.hoverEnded()
  }

  override func scrollWheel(with event: NSEvent) {
    coordinator?.model.transcriptUserScrolled()
    super.scrollWheel(with: event)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    hoverTrackingArea = area
  }

  /// A local key monitor active only during a boundary drag: Esc cancels the drag (restoring the
  /// pre-drag boundary) and swallows the key. Fires on the main thread; carries no `NSEvent`.
  private func installEscMonitor() {
    escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard event.keyCode == 53 else { return event }  // Escape
      let handled = MainActor.assumeIsolated { () -> Bool in
        guard let self, case .boundary(_, _, true) = self.gesture else { return false }
        self.coordinator?.blockActions.boundaryDragCancelled()
        self.gesture = .none
        self.removeEscMonitor()
        return true
      }
      return handled ? nil : event
    }
  }

  private func removeEscMonitor() {
    if let escMonitor { NSEvent.removeMonitor(escMonitor) }
    escMonitor = nil
  }
}
