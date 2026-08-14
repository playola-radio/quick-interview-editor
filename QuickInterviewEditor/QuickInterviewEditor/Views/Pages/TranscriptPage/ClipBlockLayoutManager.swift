import AppKit

/// One clip's block to draw over its word glyphs: the contiguous UTF-16 span (word glyphs + the
/// trailing spaces between them, so the band reads as one shape), the state fill + ring colors,
/// and an optional hovered-end sub-range that brightens. The fill is drawn HERE from the glyphs'
/// enclosing rects (not the `.backgroundColor` attribute) so it hugs the text exactly and never
/// bleeds a trailing space out to the container edge on a wrapped line.
struct ClipBlockDraw: Equatable {
  var charRange: NSRange
  var fillColor: NSColor
  var ringColor: NSColor
  var hoverCharRange: NSRange?
  var hoverColor: NSColor
}

/// A TextKit-1 layout manager that paints each clip's block: a text-hugging fill with rounded
/// ends, an optional brightened hovered end, and a 1px ring. The ring is on the top and bottom of
/// every line the run covers, capped (rounded) only on the run's very first and last edges — so a
/// block reads as one continuous shape that stays closed across line wraps (the native equivalent
/// of `box-decoration-break: clone`). It holds no clip logic: the coordinator hands it
/// fully-resolved draws + colors.
final class ClipBlockLayoutManager: NSLayoutManager {
  var blocks: [ClipBlockDraw] = [] {
    didSet { if blocks != oldValue { invalidateBlockDisplay() } }
  }

  /// The corner radius at a run's two ends (spec: 6px), clamped per line height + width when drawn.
  private let cornerRadius: CGFloat = 6

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
      // Skip blocks with no glyphs in the range being drawn (off-screen while scrolled).
      let glyphRange = self.glyphRange(
        forCharacterRange: block.charRange, actualCharacterRange: nil)
      guard glyphRange.length > 0, NSIntersectionRange(glyphRange, glyphsToShow).length > 0
      else { continue }
      let rects = enclosingRects(forCharRange: block.charRange, origin: origin, in: container)
      guard !rects.isEmpty else { continue }
      draw(block: block, rects: rects, origin: origin, container: container, context: context)
    }
    context.restoreGState()
  }

  private func draw(
    block: ClipBlockDraw, rects: [CGRect], origin: NSPoint, container: NSTextContainer,
    context: CGContext
  ) {
    // Fill (rounded only at the run's two ends) + the brightened hovered end, then the ring.
    let fill = CGMutablePath()
    for (index, rect) in rects.enumerated() {
      addFilledSegment(
        to: fill, rect: rect, roundLeft: index == 0, roundRight: index == rects.count - 1)
    }
    context.addPath(fill)
    context.setFillColor(block.fillColor.cgColor)
    context.fillPath()

    if let hoverRange = block.hoverCharRange {
      let hoverRects = enclosingRects(forCharRange: hoverRange, origin: origin, in: container)
      let hover = CGMutablePath()
      for rect in hoverRects { hover.addRect(rect) }
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

  /// The per-line rectangles enclosing a character range's glyphs, in view coordinates. Uses
  /// `enumerateEnclosingRects`, which hugs the glyphs (a trailing space at a wrap contributes only
  /// its own advance, never the whole container width).
  private func enclosingRects(
    forCharRange charRange: NSRange, origin: NSPoint, in container: NSTextContainer
  ) -> [CGRect] {
    let glyphRange = self.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
    guard glyphRange.length > 0 else { return [] }
    var rects: [CGRect] = []
    enumerateEnclosingRects(
      forGlyphRange: glyphRange, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
      in: container
    ) { rect, _ in
      rects.append(rect.offsetBy(dx: origin.x, dy: origin.y))
    }
    return rects
  }

  /// Adds one line fragment's fill: a closed rectangle rounded only on capped (run-start /
  /// run-end) corners. Adjacent line rects abut, so the run reads as one continuous filled band.
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

  /// Adds one line fragment's ring contribution: always the top and bottom edges; a rounded,
  /// closed vertical only on the capped (run-start / run-end) sides, so uncapped sides stay open
  /// where the block continues onto the next line.
  private func addRingSegment(to path: CGMutablePath, rect: CGRect, capLeft: Bool, capRight: Bool) {
    let leftX = rect.minX + 0.5
    let rightX = rect.maxX - 0.5
    let topY = rect.minY + 0.5
    let bottomY = rect.maxY - 0.5
    guard rightX > leftX, bottomY > topY else { return }
    // Clamp the corner radius by BOTH half-height and half-width so a narrow single-letter word
    // (width < 2·radius) can't produce crossed top/bottom segments or overlapping caps — the
    // inner endpoints collapse to the center instead, drawing a tidy pill.
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
