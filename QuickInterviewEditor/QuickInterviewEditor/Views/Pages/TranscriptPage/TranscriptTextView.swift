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
  let lineHeightMultiple: Double
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
    context.coordinator.lineHeightMultiple = lineHeightMultiple
    context.coordinator.observeScroll()
    context.coordinator.rebuildText(text: text, fontSize: fontSize)
    context.coordinator.applyBlocks(blocks: blocks, selected: selected, clipsOnly: clipsOnly)
    return scroll
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    context.coordinator.model = model
    context.coordinator.blockActions = blockActions
    context.coordinator.paragraphSpacing = paragraphSpacing
    context.coordinator.lineHeightMultiple = lineHeightMultiple
    context.coordinator.apply(
      text: text, fontSize: fontSize,
      scrollTarget: scrollTarget, followMode: followMode, reveal: reveal)
    context.coordinator.applyBlocks(blocks: blocks, selected: selected, clipsOnly: clipsOnly)
  }

  /// If SwiftUI tears the view down mid-drag (tab switch / editor close), remove the Esc monitor
  /// and cancel any in-flight boundary drag so neither the global monitor nor the model's
  /// coalescing flag is left dangling.
  static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
    (nsView.documentView as? HitTestingTextView)?.tearDown()
  }

  @MainActor
  final class Coordinator: NSObject {
    var model: TranscriptPageModel
    weak var textView: NSTextView?
    weak var scrollView: NSScrollView?
    weak var blockLayoutManager: ClipBlockLayoutManager?
    var blockActions = TranscriptBlockActions(
      railTapped: { _ in }, select: { _ in }, interiorClicked: { _, _ in },
      canBeginBoundaryEdit: { _ in false }, boundaryDragBegan: {}, boundaryDragEnded: {},
      boundaryCommit: { _, _, _ in })
    var paragraphSpacing: Double = 0
    var lineHeightMultiple: Double = 1
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
    /// The UTF-16 run currently forced to the clip foreground by a live boundary-drag preview, so
    /// the next preview step (or the release) can reset it before re-tinting. Nil when no drag is
    /// previewing. View-local — a preview never mutates the model, so it repaints from here.
    private var previewForegroundRange: NSRange?

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
      paragraphStyle.lineHeightMultiple = lineHeightMultiple
      attr.addAttribute(.paragraphStyle, value: paragraphStyle, range: full)
      storage.setAttributedString(attr)
      lastText = text
      lastFontSize = fontSize
      // The colors were reset with the text; force `applyBlocks` to recolor the whole document.
      // Also drop the old rings so a rebuild can't briefly draw them over the fresh (untinted)
      // glyphs before the next `applyBlocks` runs.
      needsFullRecolor = true
      lastAffectedRanges = []
      cachedWordRanges = nil
      blockLayoutManager?.blocks = []
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
      // Render (and assign hit roles for) the current clip LAST so that where clips overlap it
      // wins the tint, the ring, and the boundary/interior gestures — the edit target should
      // never be usurped by a lower-ranked clip that happens to share a word.
      let ordered = blocks.filter { !$0.isCurrent } + blocks.filter { $0.isCurrent }

      for block in ordered {
        guard let run = span(for: block.wordIDs, ranges: ranges) else { continue }
        let style = Self.tint(state: block.state, isCurrent: block.isCurrent)
        tintBlock(storage: storage, run: run, style: style)
        recordRoles(&roles, block: block, first: run.first, last: run.last)
        let hoverRange = hoveredWordID.flatMap { hovered in
          (hovered == run.first || hovered == run.last) ? ranges[hovered] : nil
        }
        // Per-word ranges (in transcript order) let the layout manager band each line to its own
        // words' extent, so the fill/ring hug the text and never bleed a wrap-boundary space out.
        let wordRanges = block.wordIDs.compactMap { ranges[$0] }
          .sorted { $0.location < $1.location }
        draws.append(
          ClipBlockDraw(
            charRange: run.span, wordRanges: wordRanges, fillColor: style.fill,
            ringColor: style.ring, hoverCharRange: hoverRange, hoverColor: style.hoverFill))
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

    /// Applies the run's text attributes only: foreground color and, for a rejected clip,
    /// strikethrough (cleared otherwise so a later non-rejected overlap wins). The fill, ring, and
    /// hovered-end brightening are DRAWN by `ClipBlockLayoutManager` from the glyphs' enclosing
    /// rects, so they hug the words exactly instead of bleeding a wrap-boundary space to the edge.
    private func tintBlock(storage: NSTextStorage, run: ClipRun, style: BlockStyle) {
      storage.addAttribute(.foregroundColor, value: style.fg, range: run.span)
      if style.strike {
        storage.addAttribute(
          .strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: run.span)
      } else {
        storage.removeAttribute(.strikethroughStyle, range: run.span)
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

    /// wordID → UTF-16 range, cached across re-tints (rebuilt only when the text changes) so a
    /// live drag's per-step re-tint doesn't re-hash every word each mouse move.
    private var cachedWordRanges: [Word.ID: NSRange]?
    private func wordRangeLookup() -> [Word.ID: NSRange] {
      if let cachedWordRanges { return cachedWordRanges }
      let map = Dictionary(
        model.document.wordRanges.map { ($0.wordID, $0.range) },
        uniquingKeysWith: { first, _ in first })
      cachedWordRanges = map
      return map
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

    // MARK: - Boundary-drag preview (view-only; never mutates the model)
    /// The clip's FIXED endpoint word for a drag on `side`: dragging the START keeps the clip's
    /// last word fixed; dragging the END keeps its first word fixed. Nil when the clip isn't laid
    /// out. Resolved from the block's word ranges so it's the true first/last by transcript
    /// position, not by array order.
    func fixedWord(forClip id: EditorClip.ID, draggingSide side: SliceEdge) -> Word.ID? {
      guard let block = currentBlocks.first(where: { $0.id == id }),
        let run = span(for: block.wordIDs, ranges: wordRangeLookup())
      else { return nil }
      return side == .start ? run.last : run.first
    }

    /// Start a preview: remember the dragged clip's committed run as the region to reset before the
    /// first re-tint (its words are already at clip foreground), so a drag that shrinks the clip
    /// dims the trimmed tail correctly.
    func beginBoundaryPreview(clip id: EditorClip.ID) {
      previewForegroundRange = currentBlocks.first { $0.id == id }
        .flatMap { span(for: $0.wordIDs, ranges: wordRangeLookup())?.span }
    }

    /// One preview step: repaint the dragged clip's band to span the fixed word through the dragged
    /// word (the pointer's nearest word), reusing the clip's colors, with the previewed run at clip
    /// foreground. Drives `ClipBlockLayoutManager.blocks` directly + a scoped foreground attribute —
    /// no model call, no `applyBlocks`, so the waveform/insets/cards don't move until release.
    func previewBoundary(
      clip id: EditorClip.ID, side: SliceEdge, fixedWordID: Word.ID, draggedWordID: Word.ID
    ) {
      guard let storage = textView?.textStorage else { return }
      let ranges = wordRangeLookup()
      guard let fixedRange = ranges[fixedWordID], let draggedRange = ranges[draggedWordID] else {
        return
      }
      // Clamp so the dragged edge can't cross the fixed one (an END never before the START word,
      // and vice versa) — the band would otherwise flip; the model applies the same clamp on commit.
      let draggedLocation =
        side == .end
        ? max(draggedRange.location, fixedRange.location)
        : min(draggedRange.location, fixedRange.location)
      let low = min(fixedRange.location, draggedLocation)
      let high = max(fixedRange.location, draggedLocation)
      let previewWordIDs = model.document.wordRanges
        .filter { $0.range.location >= low && $0.range.location <= high }
        .map(\.wordID)

      blockLayoutManager?.blocks = previewDraws(
        overriding: id, withWordIDs: previewWordIDs, ranges: ranges, maxLength: storage.length)
      setPreviewForeground(previewWordIDs, ranges: ranges, storage: storage)
    }

    /// End a preview (mouse-up commit or Esc): drop the preview foreground bookkeeping and repaint
    /// authoritatively from the (still current) model with a full recolor, wiping any run the
    /// preview forced white. On commit the following model mutation re-runs `applyBlocks` with the
    /// new blocks; on Esc this restore is the final state.
    func endBoundaryPreview() {
      previewForegroundRange = nil
      needsFullRecolor = true
      applyBlocks(blocks: currentBlocks, selected: currentSelected, clipsOnly: currentClipsOnly)
    }

    /// The full block-draw set with one clip's word run overridden by the preview's, ordered so the
    /// current clip draws last (it wins the tint + ring where clips overlap), mirroring `applyBlocks`.
    /// Every range is intersected with `maxLength` (the live storage extent) before it goes into a
    /// `ClipBlockDraw`, so the layout manager's `glyphRange(forCharacterRange:)` can never be handed
    /// an out-of-bounds range even from a stale cache.
    private func previewDraws(
      overriding clipID: EditorClip.ID, withWordIDs previewWordIDs: [Word.ID],
      ranges: [Word.ID: NSRange], maxLength: Int
    ) -> [ClipBlockDraw] {
      let full = NSRange(location: 0, length: maxLength)
      let ordered = currentBlocks.filter { !$0.isCurrent } + currentBlocks.filter { $0.isCurrent }
      var draws: [ClipBlockDraw] = []
      for block in ordered {
        let wordIDs = block.id == clipID ? previewWordIDs : block.wordIDs
        guard let run = span(for: wordIDs, ranges: ranges) else { continue }
        let charRange = NSIntersectionRange(run.span, full)
        guard charRange.length > 0 else { continue }
        let style = Self.tint(state: block.state, isCurrent: block.isCurrent)
        let wordRanges = wordIDs.compactMap { ranges[$0] }
          .map { NSIntersectionRange($0, full) }
          .filter { $0.length > 0 }
          .sorted { $0.location < $1.location }
        draws.append(
          ClipBlockDraw(
            charRange: charRange, wordRanges: wordRanges, fillColor: style.fill,
            ringColor: style.ring, hoverCharRange: nil, hoverColor: style.hoverFill))
      }
      return draws
    }

    /// Forces the previewed run to clip foreground: reset the previous preview run to base first so
    /// a shrinking drag re-dims the words it dropped, then whiten the new run. Bounded to the drag's
    /// own words; `endBoundaryPreview` does the authoritative full reset on release. Every range is
    /// intersected with the live storage extent before it's applied, so a stale cached range can
    /// never index out of bounds even if the text were to change under a preview.
    private func setPreviewForeground(
      _ previewWordIDs: [Word.ID], ranges: [Word.ID: NSRange], storage: NSTextStorage
    ) {
      let base = currentClipsOnly ? Self.dimFG : Self.normalFG
      let previewRanges = previewWordIDs.compactMap { ranges[$0] }
      guard let low = previewRanges.map(\.location).min(),
        let high = previewRanges.map({ $0.location + $0.length }).max()
      else { return }
      let full = NSRange(location: 0, length: storage.length)
      storage.beginEditing()
      if let previous = previewForegroundRange {
        let clamped = NSIntersectionRange(previous, full)
        if clamped.length > 0 {
          storage.addAttribute(.foregroundColor, value: base, range: clamped)
        }
      }
      let run = NSIntersectionRange(NSRange(location: low, length: high - low), full)
      if run.length > 0 {
        storage.addAttribute(.foregroundColor, value: Self.clipFG, range: run)
      }
      storage.endEditing()
      previewForegroundRange = run.length > 0 ? run : nil
    }

    // MARK: - Hover
    /// The pointer moved over the transcript: set the boundary-drag cursor over a clip's end word
    /// and brighten that end, an arrow otherwise. Re-tints only when the hovered end changes.
    func hoverMoved(to point: NSPoint) {
      let hit = clipWord(at: point)
      let end: Word.ID?
      switch hit?.role {
      case .start, .end:
        NSCursor.resizeLeftRight.set()
        end = hit?.wordID
      default:
        NSCursor.arrow.set()
        end = nil
      }
      // Only re-tint when the hovered end actually changes (cursor is set every move regardless),
      // so plain hover motion doesn't repaint the whole transcript.
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

    /// The word under a point, clamping to the closest glyph rather than gating on a hit — so a
    /// boundary drag past the text still resolves a word. This approximates spec §4's "word whose
    /// box center is nearest the pointer" with the word the pointer is over (nearest glyph): a true
    /// per-word center scan would be O(words) on every drag step, the exact per-move cost the block
    /// design exists to avoid, and the two agree except within a sub-word sliver at word edges. A
    /// separator glyph maps to its preceding word (see `TranscriptDocument.wordID(atUTF16Offset:)`),
    /// so dragging through the space between words is deterministic, never punctuation-only.
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
    case boundary(EditorClip.ID, side: SliceEdge, fixedWordID: Word.ID?, previewing: Bool)
    case interior(EditorClip.ID, Word.ID)
    case free(anchor: Int, began: Bool)
  }
  private var gesture: Gesture = .none
  private var escMonitor: Any?
  private var hoverTrackingArea: NSTrackingArea?
  /// The word the boundary preview last snapped to, so an intra-word mouse move (many per word)
  /// fires no repaint — the preview only re-tints when it crosses into a different word. Also the
  /// word the edge commits to on mouse-up.
  private var lastDraggedWordID: Word.ID?

  override func mouseDown(with event: NSEvent) {
    guard let coordinator else { return }
    // Clear any word snapped by a prior boundary preview so a fresh gesture can never commit to it.
    lastDraggedWordID = nil
    let point = convert(event.locationInWindow, from: nil)
    if let (wordID, role) = coordinator.clipWord(at: point) {
      switch role {
      case .start(let id):
        gesture = .boundary(
          id, side: .start,
          fixedWordID: coordinator.fixedWord(forClip: id, draggingSide: .start), previewing: false)
      case .end(let id):
        gesture = .boundary(
          id, side: .end,
          fixedWordID: coordinator.fixedWord(forClip: id, draggingSide: .end), previewing: false)
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
    case .boundary(let id, let side, let fixedWordID, let previewing):
      // Without a resolvable fixed word there's nothing to anchor the band to — drop the gesture.
      guard let fixed = fixedWordID else {
        gesture = .none
        return
      }
      if !previewing {
        // The drag is a pure view-only preview; only arm it (and the Esc monitor) if the eventual
        // mouse-up commit would be accepted, so a refused edit never shows a band that snaps back.
        guard coordinator.blockActions.canBeginBoundaryEdit(id) else {
          gesture = .none
          return
        }
        coordinator.blockActions.boundaryDragBegan()
        coordinator.beginBoundaryPreview(clip: id)
        installEscMonitor()
        lastDraggedWordID = nil
        gesture = .boundary(id, side: side, fixedWordID: fixed, previewing: true)
      }
      if let wordID = coordinator.nearestWordID(at: point), wordID != lastDraggedWordID {
        lastDraggedWordID = wordID
        coordinator.previewBoundary(
          clip: id, side: side, fixedWordID: fixed, draggedWordID: wordID)
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
    case .boundary(let id, let side, _, let previewing):
      if previewing {
        // Drop the preview first (repaints the pre-commit state), then commit ONCE — the model
        // mutation re-runs `applyBlocks` with the committed blocks for a seamless handoff. A drag
        // that never crossed a word has nothing to commit. Clear the drag flag before committing so
        // the commit's funnel isn't itself refused as a "mid-drag" edit.
        removeEscMonitor()
        coordinator.blockActions.boundaryDragEnded()
        coordinator.endBoundaryPreview()
        if let wordID = lastDraggedWordID {
          coordinator.blockActions.boundaryCommit(id, side, wordID)
        }
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

  /// A local key monitor active only during a boundary-drag preview: Esc drops the preview
  /// (repainting the pre-drag state) WITHOUT committing, and swallows the key. Fires on the main
  /// thread; carries no `NSEvent`.
  private func installEscMonitor() {
    escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard event.keyCode == 53 else { return event }  // Escape
      let handled = MainActor.assumeIsolated { () -> Bool in
        guard let self, case .boundary(_, _, _, true) = self.gesture else { return false }
        self.coordinator?.blockActions.boundaryDragEnded()
        self.coordinator?.endBoundaryPreview()
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

  /// Called from `dismantleNSView` when the view goes away mid-gesture: drop the Esc monitor and
  /// the live preview (no commit). The drag never touched the model, so there's nothing to unwind
  /// there.
  func tearDown() {
    removeEscMonitor()
    if case .boundary(_, _, _, true) = gesture {
      coordinator?.blockActions.boundaryDragEnded()
      coordinator?.endBoundaryPreview()
    }
    gesture = .none
  }
}
