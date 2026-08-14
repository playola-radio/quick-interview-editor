import AppKit

/// One clip's block to draw over its word glyphs. `wordRanges` are the clip's individual word
/// UTF-16 ranges in transcript order — the layout manager bands each line to just its words'
/// horizontal extent (never a trailing space out to the container edge) at the text's own height,
/// so the fill + ring hug the words exactly. `charRange` is the whole run, kept only for the
/// on-screen intersection test. The fill/ring/hover are drawn HERE (not via `.backgroundColor`).
struct ClipBlockDraw: Equatable {
  var charRange: NSRange
  var wordRanges: [NSRange]
  var fillColor: NSColor
  var ringColor: NSColor
  var hoverCharRange: NSRange?
  var hoverColor: NSColor
}

/// A TextKit-1 layout manager that paints each clip's block: a text-hugging fill with rounded
/// ends, an optional brightened hovered end, and a 1px ring. Each line the run covers becomes one
/// pill sized to that line's words (width) and the font's cap-to-descender height (so airy line
/// spacing shows a gap between lines); the run's very first and last edges are rounded + padded so
/// the block starts just before the first word and ends just after the last. It holds no clip
/// logic: the coordinator hands it fully-resolved draws + colors.
final class ClipBlockLayoutManager: NSLayoutManager {
  var blocks: [ClipBlockDraw] = [] {
    didSet { if blocks != oldValue { invalidateBlockDisplay() } }
  }

  /// Corner radius at the run's two ends (spec: 6px), clamped per rect when drawn.
  private let cornerRadius: CGFloat = 6
  /// Horizontal padding added only at the run's outer ends ("just before/after" the words).
  private let endPadding: CGFloat = 4
  /// Vertical padding above + below the text (spec §3: `4px 0`), making the pill a touch taller.
  private let verticalPadding: CGFloat = 4

  private func invalidateBlockDisplay() {
    guard let textView = textContainers.first?.textView else { return }
    textView.needsDisplay = true
  }

  override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
    super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    guard !blocks.isEmpty, let container = textContainers.first,
      let context = NSGraphicsContext.current?.cgContext
    else { return }

    context.saveGState()
    context.setLineWidth(1)
    context.setLineJoin(.round)
    for block in blocks {
      guard block.charRange.length > 0 else { continue }
      let glyphRange = self.glyphRange(
        forCharacterRange: block.charRange, actualCharacterRange: nil)
      guard glyphRange.length > 0, NSIntersectionRange(glyphRange, glyphsToShow).length > 0
      else { continue }
      let rects = bandRects(for: block.wordRanges, padEnds: true, origin: origin, in: container)
      guard !rects.isEmpty else { continue }
      draw(block: block, rects: rects, origin: origin, container: container, context: context)
    }
    context.restoreGState()
  }

  private func draw(
    block: ClipBlockDraw, rects: [CGRect], origin: NSPoint, container: NSTextContainer,
    context: CGContext
  ) {
    let fill = CGMutablePath()
    for (index, rect) in rects.enumerated() {
      addFilledSegment(
        to: fill, rect: rect, roundLeft: index == 0, roundRight: index == rects.count - 1)
    }
    context.addPath(fill)
    context.setFillColor(block.fillColor.cgColor)
    context.fillPath()

    if let hoverRange = block.hoverCharRange {
      let hoverRects = bandRects(for: [hoverRange], padEnds: true, origin: origin, in: container)
      let hover = CGMutablePath()
      for (index, rect) in hoverRects.enumerated() {
        addFilledSegment(
          to: hover, rect: rect, roundLeft: index == 0, roundRight: index == hoverRects.count - 1)
      }
      context.addPath(hover)
      context.setFillColor(block.hoverColor.cgColor)
      context.fillPath()
    }

    let ring = CGMutablePath()
    for (index, rect) in rects.enumerated() {
      addRingSegment(
        to: ring, rect: rect, capLeft: index == 0, capRight: index == rects.count - 1)
    }
    context.addPath(ring)
    context.setStrokeColor(block.ringColor.cgColor)
    context.strokePath()
  }

  /// One accumulating line: its glyph baseline (to group words) + text-height band + x-extent.
  private struct LineBand {
    var baselineY: CGFloat
    var top: CGFloat
    var height: CGFloat
    var minX: CGFloat
    var maxX: CGFloat
  }

  /// The per-line band rectangles hugging a set of word ranges: each line's rect spans from its
  /// first word's left to its last word's right (never a trailing space), at the font's
  /// text height. `padEnds` adds a little horizontal room before the run's first word and after
  /// its last. Returned top-to-bottom (words are in transcript order).
  private func bandRects(
    for wordRanges: [NSRange], padEnds: Bool, origin: NSPoint, in container: NSTextContainer
  ) -> [CGRect] {
    var lines: [LineBand] = []
    for wordRange in wordRanges {
      let glyphRange = self.glyphRange(forCharacterRange: wordRange, actualCharacterRange: nil)
      guard glyphRange.length > 0 else { continue }
      let wordRect = boundingRect(forGlyphRange: glyphRange, in: container)
      let fragment = lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
      let baselineY = fragment.minY + location(forGlyphAt: glyphRange.location).y
      let font = wordFont(atCharacter: wordRange.location)
      let top = baselineY - font.ascender - verticalPadding
      let height = font.ascender - font.descender + verticalPadding * 2
      if let index = lines.firstIndex(where: { abs($0.baselineY - baselineY) < 0.5 }) {
        lines[index].minX = min(lines[index].minX, wordRect.minX)
        lines[index].maxX = max(lines[index].maxX, wordRect.maxX)
      } else {
        lines.append(
          LineBand(
            baselineY: baselineY, top: top, height: height, minX: wordRect.minX,
            maxX: wordRect.maxX))
      }
    }

    return lines.enumerated().map { index, line in
      let padLeft = padEnds && index == 0 ? endPadding : 0
      let padRight = padEnds && index == lines.count - 1 ? endPadding : 0
      return CGRect(
        x: line.minX - padLeft, y: line.top,
        width: (line.maxX - line.minX) + padLeft + padRight, height: line.height
      ).offsetBy(dx: origin.x, dy: origin.y)
    }
  }

  /// The font at a character (for band height), falling back to the system font.
  private func wordFont(atCharacter index: Int) -> NSFont {
    guard let storage = textStorage, index < storage.length,
      let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont
    else { return NSFont.systemFont(ofSize: NSFont.systemFontSize) }
    return font
  }

  /// Adds one line's fill: a closed rectangle rounded only on capped (run-start / run-end) corners.
  private func addFilledSegment(
    to path: CGMutablePath, rect: CGRect, roundLeft: Bool, roundRight: Bool
  ) {
    let minX = rect.minX
    let maxX = rect.maxX
    let minY = rect.minY
    let maxY = rect.maxY
    guard maxX > minX, maxY > minY else { return }
    let radius = min(cornerRadius, (maxY - minY) / 2, (maxX - minX) / 2)

    path.move(to: CGPoint(x: roundLeft ? minX + radius : minX, y: minY))
    if roundRight {
      path.addLine(to: CGPoint(x: maxX - radius, y: minY))
      path.addArc(
        tangent1End: CGPoint(x: maxX, y: minY), tangent2End: CGPoint(x: maxX, y: minY + radius),
        radius: radius)
      path.addLine(to: CGPoint(x: maxX, y: maxY - radius))
      path.addArc(
        tangent1End: CGPoint(x: maxX, y: maxY), tangent2End: CGPoint(x: maxX - radius, y: maxY),
        radius: radius)
    } else {
      path.addLine(to: CGPoint(x: maxX, y: minY))
      path.addLine(to: CGPoint(x: maxX, y: maxY))
    }
    if roundLeft {
      path.addLine(to: CGPoint(x: minX + radius, y: maxY))
      path.addArc(
        tangent1End: CGPoint(x: minX, y: maxY), tangent2End: CGPoint(x: minX, y: maxY - radius),
        radius: radius)
      path.addLine(to: CGPoint(x: minX, y: minY + radius))
      path.addArc(
        tangent1End: CGPoint(x: minX, y: minY), tangent2End: CGPoint(x: minX + radius, y: minY),
        radius: radius)
    } else {
      path.addLine(to: CGPoint(x: minX, y: maxY))
      path.addLine(to: CGPoint(x: minX, y: minY))
    }
    path.closeSubpath()
  }

  /// Adds one line's ring contribution: always the top and bottom edges; a rounded, closed
  /// vertical only on the capped (run-start / run-end) sides, so uncapped sides stay open where the
  /// block continues onto the next line.
  private func addRingSegment(to path: CGMutablePath, rect: CGRect, capLeft: Bool, capRight: Bool) {
    let leftX = rect.minX + 0.5
    let rightX = rect.maxX - 0.5
    let topY = rect.minY + 0.5
    let bottomY = rect.maxY - 0.5
    guard rightX > leftX, bottomY > topY else { return }
    let radius = min(cornerRadius, (bottomY - topY) / 2, (rightX - leftX) / 2)
    let innerLeft = capLeft ? leftX + radius : leftX
    let innerRight = capRight ? rightX - radius : rightX

    path.move(to: CGPoint(x: innerLeft, y: topY))
    path.addLine(to: CGPoint(x: innerRight, y: topY))
    path.move(to: CGPoint(x: innerLeft, y: bottomY))
    path.addLine(to: CGPoint(x: innerRight, y: bottomY))

    if capLeft {
      path.move(to: CGPoint(x: innerLeft, y: topY))
      path.addArc(
        tangent1End: CGPoint(x: leftX, y: topY), tangent2End: CGPoint(x: leftX, y: topY + radius),
        radius: radius)
      path.addLine(to: CGPoint(x: leftX, y: bottomY - radius))
      path.addArc(
        tangent1End: CGPoint(x: leftX, y: bottomY),
        tangent2End: CGPoint(x: innerLeft, y: bottomY), radius: radius)
    }
    if capRight {
      path.move(to: CGPoint(x: innerRight, y: topY))
      path.addArc(
        tangent1End: CGPoint(x: rightX, y: topY), tangent2End: CGPoint(x: rightX, y: topY + radius),
        radius: radius)
      path.addLine(to: CGPoint(x: rightX, y: bottomY - radius))
      path.addArc(
        tangent1End: CGPoint(x: rightX, y: bottomY),
        tangent2End: CGPoint(x: innerRight, y: bottomY), radius: radius)
    }
  }
}
