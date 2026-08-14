import AppKit
import SwiftUI

/// A dumb NSTextAttachment cell that reserves a fixed block of vertical space for a clip card
/// but draws nothing — the interactive card is a separately-positioned `NSHostingView` overlay
/// (decision C: no attachment view-providers for interactive controls).
final class ClipPlaceholderCell: NSTextAttachmentCell {
  var reservedSize: NSSize = .zero
  override func cellSize() -> NSSize { reservedSize }
  override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {}
  override func cellBaselineOffset() -> NSPoint { .zero }
}

/// TextKit-1 renderer, C3 hybrid: the transcript text is one document, and each clip lifts out of
/// flow as a placeholder attachment that reserves vertical space with a positioned SwiftUI card
/// (`NSHostingView`) drawn over it. Text measurement, the word→UTF-16 map, scroll-to-word, and
/// long-transcript layout stay in TextKit; every decision lives in the model. Model-derived
/// values are explicit inputs so SwiftUI calls `updateNSView` when they change.
struct TranscriptTextView: NSViewRepresentable {
  let model: TranscriptPageModel
  let text: String
  let fontSize: Double
  let paragraphSpacing: Double
  let selected: Set<Word.ID>
  let scrollTarget: Word.ID?
  let followMode: TranscriptFollowMode
  let reveal: TranscriptReveal?
  let cards: [ClipCardVM]
  let clipsOnly: Bool
  let armedAddSide: ArmedAddSide?
  let clipActions: TranscriptClipActions

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

    scroll.documentView = textView

    context.coordinator.model = model
    context.coordinator.textView = textView
    context.coordinator.scrollView = scroll
    context.coordinator.paragraphSpacing = paragraphSpacing
    context.coordinator.clipActions = clipActions
    context.coordinator.observeScroll()
    context.coordinator.apply(
      text: text, fontSize: fontSize, selected: selected, scrollTarget: scrollTarget,
      followMode: followMode, reveal: reveal, cards: cards, clipsOnly: clipsOnly,
      armedAddSide: armedAddSide)
    return scroll
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    context.coordinator.model = model
    context.coordinator.paragraphSpacing = paragraphSpacing
    context.coordinator.clipActions = clipActions
    context.coordinator.apply(
      text: text, fontSize: fontSize, selected: selected, scrollTarget: scrollTarget,
      followMode: followMode, reveal: reveal, cards: cards, clipsOnly: clipsOnly,
      armedAddSide: armedAddSide)
  }

  @MainActor
  final class Coordinator: NSObject {
    var model: TranscriptPageModel
    weak var textView: NSTextView?
    weak var scrollView: NSScrollView?
    var paragraphSpacing: Double = 0
    var clipActions: TranscriptClipActions?
    var armedAddSide: ArmedAddSide?

    private var lastText = ""
    private var lastSelected: Set<Word.ID> = []
    private var lastFontSize: Double = 0
    private var lastScrollTarget: Word.ID?
    private var lastFollowMode: TranscriptFollowMode = .following
    private var lastReveal: TranscriptReveal?
    private var lastCards: [ClipCardVM] = []
    private var lastClipsOnly = false
    private var lastWidth: CGFloat = 0

    /// Non-clip word → its UTF-16 range in the interleaved document, in transcript order.
    private var wordRanges: [TranscriptWordRange] = []
    /// Emitted clip → the placeholder attachment's character index (for card placement).
    private var cardAnchors: [(id: EditorClip.ID, location: Int)] = []
    /// A lifted clip word → the clip that owns it, so `range(for:)` can reveal the CARD when a
    /// scroll/reveal targets a word that's inside a card (it has no text range of its own).
    private var wordToShownClip: [Word.ID: EditorClip.ID] = [:]
    /// Emitted clip → its placeholder character location, for the reveal fallback above.
    private var anchorLocation: [EditorClip.ID: Int] = [:]
    /// Live hosting views for the placed cards, keyed by clip id (reused across updates).
    private var cardHosts: [EditorClip.ID: NSHostingView<ClipCardView>] = [:]

    init(model: TranscriptPageModel) { self.model = model }

    deinit { NotificationCenter.default.removeObserver(self) }

    private static let selectedBG = NSColor(
      calibratedRed: 0.80, green: 0.40, blue: 0.40, alpha: 0.30)
    private static let selectedFG = NSColor.white
    private static let normalFG = NSColor(calibratedWhite: 0.56, alpha: 1)
    private static let dimmedFG = NSColor(calibratedWhite: 0.20, alpha: 1)  // clips-only #333

    // MARK: - Apply
    // swiftlint:disable:next function_parameter_count
    func apply(
      text: String, fontSize: Double, selected: Set<Word.ID>, scrollTarget: Word.ID?,
      followMode: TranscriptFollowMode, reveal: TranscriptReveal?, cards: [ClipCardVM],
      clipsOnly: Bool, armedAddSide: ArmedAddSide?
    ) {
      self.armedAddSide = armedAddSide
      guard let textView else { return }
      let width = cardWidth()

      // A structural change (text, the set/geometry of cards, clips-only dim, font, or a width
      // that reflows the cards) rebuilds the interleaved document + repositions the card overlays.
      let structural =
        text != lastText || cards != lastCards || clipsOnly != lastClipsOnly
        || fontSize != lastFontSize || abs(width - lastWidth) > 0.5
      if structural {
        rebuild(text: text, fontSize: fontSize, cards: cards, clipsOnly: clipsOnly, width: width)
        lastText = text
        lastCards = cards
        lastClipsOnly = clipsOnly
        lastFontSize = fontSize
        lastWidth = width
        lastSelected = []
      }

      let selAdded = selected.subtracting(lastSelected)
      let selRemoved = lastSelected.subtracting(selected)
      applySelection(added: selAdded, removed: selRemoved, clipsOnly: clipsOnly)
      lastSelected = selected

      if followMode == .following, lastFollowMode == .userPaused { lastScrollTarget = nil }
      lastFollowMode = followMode

      if let target = scrollTarget, target != lastScrollTarget,
        followMode == .following, let range = range(for: target)
      {
        textView.scrollRangeToVisible(range)
        lastScrollTarget = target
      }

      if let reveal, reveal != lastReveal {
        if let range = range(for: reveal.wordID) { textView.scrollRangeToVisible(range) }
        lastReveal = reveal
      }
    }

    /// The pixel width a card (and its placeholder) should occupy — the text container's usable
    /// width. Cards fill the reading column edge-to-edge.
    private func cardWidth() -> CGFloat {
      guard let textView else { return 0 }
      let inset = textView.textContainerInset.width
      let padding = textView.textContainer?.lineFragmentPadding ?? 0
      return max(0, textView.bounds.width - inset * 2 - padding * 2)
    }

    // MARK: - Rebuild (interleave text + card placeholders)
    private func rebuild(
      text: String, fontSize: Double, cards: [ClipCardVM], clipsOnly: Bool, width: CGFloat
    ) {
      guard let storage = textView?.textStorage else { return }
      let orderedWords = self.orderedWords(in: text)
      let placement = clipPlacement(cards: cards, orderedWords: orderedWords)

      let cardHeights = measuredCardHeights(cards: cards, width: width)
      let baseFG = clipsOnly ? Self.dimmedFG : Self.normalFG
      let paragraph = NSMutableParagraphStyle()
      paragraph.paragraphSpacing = paragraphSpacing

      let attr = NSMutableAttributedString()
      var ranges: [TranscriptWordRange] = []
      var anchors: [(id: EditorClip.ID, location: Int)] = []
      var anchorByClip: [EditorClip.ID: Int] = [:]
      var emitted = Set<EditorClip.ID>()
      var pendingSeparator = false

      for (index, word) in orderedWords.enumerated() {
        // Emit every card anchored at this index BEFORE the word — driven by index, not by which
        // clip claims the word, so a clip fully contained in another still gets its own placeholder.
        for clipID in placement.clipsByIndex[index] ?? [] where !emitted.contains(clipID) {
          if attr.length > 0 { attr.append(NSAttributedString(string: "\n")) }
          let cell = ClipPlaceholderCell()
          cell.reservedSize = NSSize(
            width: width, height: (cardHeights[clipID] ?? 0) + Self.cardMarginV * 2)
          let attachment = NSTextAttachment()
          attachment.attachmentCell = cell
          anchors.append((clipID, attr.length))
          anchorByClip[clipID] = attr.length
          attr.append(NSAttributedString(attachment: attachment))
          attr.append(NSAttributedString(string: "\n"))
          emitted.insert(clipID)
          pendingSeparator = false
        }
        if placement.wordToClip[word.id] != nil { continue }  // lifted into a card; skip its text
        if pendingSeparator { attr.append(NSAttributedString(string: " ")) }
        let start = attr.length
        let piece = NSAttributedString(string: word.text)
        attr.append(piece)
        ranges.append(
          TranscriptWordRange(
            wordID: word.id, range: NSRange(location: start, length: piece.length))
        )
        pendingSeparator = true
      }

      let full = NSRange(location: 0, length: attr.length)
      attr.addAttribute(.font, value: NSFont.systemFont(ofSize: fontSize), range: full)
      attr.addAttribute(.foregroundColor, value: baseFG, range: full)
      attr.addAttribute(.paragraphStyle, value: paragraph, range: full)
      storage.setAttributedString(attr)
      wordRanges = ranges
      cardAnchors = anchors
      wordToShownClip = placement.wordToClip
      anchorLocation = anchorByClip

      placeCards(cards: cards, heights: cardHeights, width: width)
    }

    private static let cardMarginV: CGFloat = 13

    /// The ordered non-attachment words (id + text), reconstructed from the model's document map
    /// (the source of truth for order + ids) against the plain text.
    private func orderedWords(in text: String) -> [(id: Word.ID, text: String)] {
      let ns = text as NSString
      return model.document.wordRanges.compactMap { entry in
        guard entry.range.location + entry.range.length <= ns.length else { return nil }
        return (entry.wordID, ns.substring(with: entry.range))
      }
    }

    private struct ClipPlacement {
      /// Any word lifted into a card → the (first, for text-skipping) clip that owns it.
      var wordToClip: [Word.ID: EditorClip.ID]
      /// Transcript-order index → the clips whose card anchors there, in card order. A clip's
      /// anchor index is its earliest word's position, computed INDEPENDENTLY so a clip fully
      /// contained in another still gets a placeholder (both anchor, possibly at the same index).
      var clipsByIndex: [Int: [EditorClip.ID]]
    }

    private func clipPlacement(
      cards: [ClipCardVM], orderedWords: [(id: Word.ID, text: String)]
    ) -> ClipPlacement {
      var wordToClip: [Word.ID: EditorClip.ID] = [:]
      for card in cards {
        for wordID in card.wordIDs where wordToClip[wordID] == nil {
          wordToClip[wordID] = card.id
        }
      }
      var docIndex: [Word.ID: Int] = [:]
      for (index, word) in orderedWords.enumerated() where docIndex[word.id] == nil {
        docIndex[word.id] = index
      }
      var clipsByIndex: [Int: [EditorClip.ID]] = [:]
      for card in cards {
        guard let anchor = card.wordIDs.compactMap({ docIndex[$0] }).min() else { continue }
        clipsByIndex[anchor, default: []].append(card.id)
      }
      return ClipPlacement(wordToClip: wordToClip, clipsByIndex: clipsByIndex)
    }

    /// Width-constrained height for each card, measured with a throwaway hosting view so the
    /// placeholder reserves exactly the card's laid-out height.
    private func measuredCardHeights(cards: [ClipCardVM], width: CGFloat) -> [EditorClip.ID:
      CGFloat]
    {
      guard width > 0, let actions = clipActions else { return [:] }
      var heights: [EditorClip.ID: CGFloat] = [:]
      for card in cards {
        let host = NSHostingView(rootView: ClipCardView(card: card, actions: actions))
        host.translatesAutoresizingMaskIntoConstraints = false
        let constraint = host.widthAnchor.constraint(equalToConstant: width)
        constraint.isActive = true
        host.layoutSubtreeIfNeeded()
        heights[card.id] = host.fittingSize.height
        constraint.isActive = false
      }
      return heights
    }

    /// Positions (creating/reusing) an `NSHostingView` card over each placeholder's line rect, and
    /// removes hosts for clips no longer shown.
    private func placeCards(
      cards: [ClipCardVM], heights: [EditorClip.ID: CGFloat], width: CGFloat
    ) {
      guard let textView, let layoutManager = textView.layoutManager,
        let container = textView.textContainer, let actions = clipActions
      else { return }
      layoutManager.ensureLayout(for: container)
      let cardsByID = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      let shown = Set(cardAnchors.map(\.id))
      for (id, host) in cardHosts where !shown.contains(id) {
        host.removeFromSuperview()
        cardHosts[id] = nil
      }
      let inset = textView.textContainerInset
      for anchor in cardAnchors {
        guard let card = cardsByID[anchor.id] else { continue }
        let glyphRange = layoutManager.glyphRange(
          forCharacterRange: NSRange(location: anchor.location, length: 1),
          actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        let host: NSHostingView<ClipCardView>
        if let existing = cardHosts[anchor.id] {
          existing.rootView = ClipCardView(card: card, actions: actions)
          host = existing
        } else {
          host = NSHostingView(rootView: ClipCardView(card: card, actions: actions))
          host.translatesAutoresizingMaskIntoConstraints = true
          textView.addSubview(host)
          cardHosts[anchor.id] = host
        }
        let height = heights[anchor.id] ?? rect.height
        host.frame = NSRect(
          x: rect.minX + inset.width,
          y: rect.minY + inset.height + Self.cardMarginV,
          width: width, height: height)
      }
    }

    // MARK: - Selection
    /// The text range for a word, or — when the word has been lifted into a card and has no text of
    /// its own — the card's placeholder location, so a reveal/scroll that targets an in-clip word
    /// scrolls to the card instead of failing silently.
    private func range(for id: Word.ID) -> NSRange? {
      if let range = wordRanges.first(where: { $0.wordID == id })?.range { return range }
      if let clipID = wordToShownClip[id], let location = anchorLocation[clipID] {
        return NSRange(location: location, length: 1)
      }
      return nil
    }

    private func applySelection(added: Set<Word.ID>, removed: Set<Word.ID>, clipsOnly: Bool) {
      guard let storage = textView?.textStorage else { return }
      let baseFG = clipsOnly ? Self.dimmedFG : Self.normalFG
      for id in removed {
        guard let wordRange = range(for: id) else { continue }
        storage.removeAttribute(.backgroundColor, range: wordRange)
        storage.addAttribute(.foregroundColor, value: baseFG, range: wordRange)
      }
      for id in added {
        guard let wordRange = range(for: id) else { continue }
        storage.addAttribute(.backgroundColor, value: Self.selectedBG, range: wordRange)
        storage.addAttribute(.foregroundColor, value: Self.selectedFG, range: wordRange)
      }
    }

    // MARK: - Scroll observation
    func observeScroll() {
      guard let scrollView else { return }
      NotificationCenter.default.addObserver(
        self, selector: #selector(userDidLiveScroll),
        name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
    }

    @objc private func userDidLiveScroll() {
      model.transcriptUserScrolled()
    }

    // MARK: - Hit testing (point → word)
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

    /// The non-clip word an offset lands in (rightmost word starting at/before it), or nil.
    func wordID(atUTF16Offset offset: Int) -> Word.ID? {
      var candidate: Word.ID?
      for entry in wordRanges {
        if entry.range.location <= offset { candidate = entry.wordID } else { break }
      }
      return candidate
    }

    /// A click resolved to a UTF-16 offset. While a point-and-add side is armed, a word click sets
    /// that boundary (via the clip actions) instead of changing the selection; otherwise it's a
    /// normal transcript selection.
    func clicked(atUTF16Offset offset: Int, extending: Bool) {
      guard let wordID = wordID(atUTF16Offset: offset) else { return }
      if armedAddSide != nil {
        clipActions?.wordPicked(wordID)
      } else {
        model.wordClicked(wordID, extending: extending)
      }
    }

    func dragBegan(atUTF16Offset offset: Int) {
      guard armedAddSide == nil, let wordID = wordID(atUTF16Offset: offset) else { return }
      model.selectionAnchorID = wordID
      model.selectionFocusID = wordID
    }

    func dragged(toUTF16Offset offset: Int) {
      guard armedAddSide == nil, let wordID = wordID(atUTF16Offset: offset) else { return }
      model.selectionFocusID = wordID
    }
  }
}

/// Forwards mouse events to the coordinator as UTF-16 offsets and classifies click vs drag from
/// the raw event stream. No selection decisions here — those live in the model/coordinator.
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
      coordinator.dragBegan(atUTF16Offset: anchor)
    }
    coordinator.dragged(toUTF16Offset: offset)
  }

  override func mouseUp(with event: NSEvent) {
    guard let coordinator else { return }
    if !didDrag, let anchor = anchorOffset {
      coordinator.clicked(atUTF16Offset: anchor, extending: event.modifierFlags.contains(.shift))
    }
    anchorOffset = nil
    didDrag = false
  }

  override func scrollWheel(with event: NSEvent) {
    coordinator?.model.transcriptUserScrolled()
    super.scrollWheel(with: event)
  }
}
