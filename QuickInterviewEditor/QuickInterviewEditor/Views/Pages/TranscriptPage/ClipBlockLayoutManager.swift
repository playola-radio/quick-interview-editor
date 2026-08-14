import AppKit

/// One clip's ring to stroke over its word glyphs: the contiguous UTF-16 span (word glyphs +
/// the trailing spaces between them, so the ring encloses the whole run) and its state color.
/// The fill is drawn by the normal `.backgroundColor` attribute; this only adds the 1px ring +
/// rounded ends, which no text attribute can express.
struct ClipBlockDraw: Equatable {
  var charRange: NSRange
  var ringColor: NSColor
}

/// A TextKit-1 layout manager that draws each clip's ring after the standard background fills.
/// The ring is 1px on the top and bottom of every line the run covers, capped (with a rounded
/// corner) only on the run's very first and last edges — so a block reads as one continuous shape
/// that stays closed across line wraps (the native equivalent of `box-decoration-break: clone`).
/// It holds no clip logic: the coordinator hands it fully-resolved draws + colors.
final class ClipBlockLayoutManager: NSLayoutManager {
  var blocks: [ClipBlockDraw] = [] {
    didSet { if blocks != oldValue { invalidateBlockDisplay() } }
  }

  /// The corner radius at a run's two ends (spec: 6px), clamped per line height when drawing.
  private let cornerRadius: CGFloat = 6

  private func invalidateBlockDisplay() {
    guard let container = textContainers.first,
      let textView = container.textView as NSTextView?
    else { return }
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
      guard glyphRange.length > 0,
        NSIntersectionRange(glyphRange, glyphsToShow).length > 0
      else { continue }
      strokeRing(
        for: block, glyphRange: glyphRange, in: container, origin: origin, context: context)
    }
    context.restoreGState()
  }

  private func strokeRing(
    for block: ClipBlockDraw, glyphRange: NSRange, in container: NSTextContainer,
    origin: NSPoint, context: CGContext
  ) {
    var rects: [CGRect] = []
    enumerateEnclosingRects(
      forGlyphRange: glyphRange, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
      in: container
    ) { rect, _ in
      rects.append(rect.offsetBy(dx: origin.x, dy: origin.y))
    }
    guard !rects.isEmpty else { return }

    let path = CGMutablePath()
    for (index, rect) in rects.enumerated() {
      addRingSegment(
        to: path, rect: rect, capLeft: index == 0, capRight: index == rects.count - 1)
    }
    context.addPath(path)
    context.setStrokeColor(block.ringColor.cgColor)
    context.strokePath()
  }

  /// Adds one line fragment's ring contribution: always the top and bottom edges; a rounded,
  /// closed vertical only on the capped (run-start / run-end) sides, so uncapped sides stay open
  /// where the block continues onto the next line.
  private func addRingSegment(to path: CGMutablePath, rect: CGRect, capLeft: Bool, capRight: Bool) {
    let radius = min(cornerRadius, rect.height / 2)
    let leftX = rect.minX + 0.5
    let rightX = rect.maxX - 0.5
    let topY = rect.minY + 0.5
    let bottomY = rect.maxY - 0.5
    guard rightX > leftX, bottomY > topY else { return }
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
