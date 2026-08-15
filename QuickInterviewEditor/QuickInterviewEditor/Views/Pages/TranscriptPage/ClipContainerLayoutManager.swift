import AppKit

/// One clip container resolved for drawing: a contiguous UTF-16 range plus its already
/// state-mapped fill and ring colours. Built by the coordinator from the model's
/// `TranscriptClipContainer`s; this layer stays a dumb renderer of model-derived data.
struct ClipContainerRun: Equatable {
  let range: NSRange
  let fill: NSColor
  let ring: NSColor
}

/// A TextKit-1 layout manager that paints clip containers behind the text: one continuous
/// tinted, rounded, ringed shape running through each clip's words. It draws containers
/// FIRST, then calls `super` so the standard `.backgroundColor` pass (the red text
/// selection) lands on top — glyphs draw last, above both.
///
/// It owns no state decisions: `containerRuns` is handed in by the coordinator. Rounded
/// caps sit only at a run's true ends (computed from the full run, never the clipped dirty
/// range), and a run that wraps is drawn as one square-jointed segment per line fragment so
/// the ring closes across the wrap without a seam.
final class ClipContainerLayoutManager: NSLayoutManager {

  var containerRuns: [ClipContainerRun] = []

  private let cornerRadius: CGFloat = 6
  private let ringWidth: CGFloat = 1
  /// Symmetric breathing room above/below the glyph box (the mockup's `padding: 4px 0`); kept
  /// small because the font's ascender/descender box already includes some leading.
  private let verticalPadding: CGFloat = 3

  override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
    drawClipContainers(forGlyphRange: glyphsToShow, at: origin)
    // Selection (`.backgroundColor`) draws on top of the container fills, then glyphs above all.
    super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
  }

  private func drawClipContainers(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
    guard !containerRuns.isEmpty, let textContainer = textContainers.first else { return }

    for run in containerRuns {
      let fullGlyphRange = glyphRange(forCharacterRange: run.range, actualCharacterRange: nil)
      let visible = NSIntersectionRange(fullGlyphRange, glyphsToShow)
      guard visible.length > 0 else { continue }

      run.fill.setFill()
      run.ring.setStroke()

      enumerateLineFragments(forGlyphRange: visible) {
        [self] lineRect, usedRect, _, lineGlyphRange, _ in
        let segment = NSIntersectionRange(fullGlyphRange, lineGlyphRange)
        guard segment.length > 0 else { return }

        // Caps come from the WHOLE run, not the visible slice: a run scrolled half-off must
        // still round only its true first/last line-fragment segments.
        let roundedLeft = segment.location == fullGlyphRange.location
        let roundedRight = NSMaxRange(segment) == NSMaxRange(fullGlyphRange)

        // Horizontal extent stops at the TEXT, never the line's right margin: a segment whose
        // clip continues to the next line fills to the line's text end (`usedRect.maxX`, the
        // wrap point); the clip's final segment stops at its last word (`boundingRect` clamped
        // to the used text). Continuation segments start at the line's left text edge.
        let horizontal = boundingRect(forGlyphRange: segment, in: textContainer)
        let leftX = roundedLeft ? horizontal.minX : usedRect.minX
        let rightX = roundedRight ? min(horizontal.maxX, usedRect.maxX) : usedRect.maxX

        // Vertical box hugs the glyphs, centered on the text BASELINE with symmetric padding —
        // NOT `usedRect`, whose line leading sits below the text and would push the fill down
        // into the next line (asymmetric bottom overhang, overlapping the next container).
        let font = glyphFont(atGlyph: segment.location)
        let baselineY = lineRect.minY + location(forGlyphAt: segment.location).y
        let top = baselineY - font.ascender
        let textHeight = font.ascender - font.descender  // descender is negative
        let rect = CGRect(
          x: leftX + origin.x,
          y: top + origin.y - verticalPadding,
          width: max(0, rightX - leftX),
          height: textHeight + verticalPadding * 2)

        drawContainerSegment(in: rect, roundedLeft: roundedLeft, roundedRight: roundedRight)
      }
    }
  }

  /// The font backing a glyph, so the container box can be sized from real ascender/descender
  /// metrics. Falls back to the system font if the storage has no font attribute there.
  private func glyphFont(atGlyph glyphIndex: Int) -> NSFont {
    guard let storage = textStorage, storage.length > 0 else {
      return .systemFont(ofSize: NSFont.systemFontSize)
    }
    let charIndex = min(characterIndexForGlyph(at: glyphIndex), storage.length - 1)
    return storage.attribute(.font, at: charIndex, effectiveRange: nil) as? NSFont
      ?? .systemFont(ofSize: NSFont.systemFontSize)
  }

  private func drawContainerSegment(in rect: CGRect, roundedLeft: Bool, roundedRight: Bool) {
    let radius = min(cornerRadius, rect.height / 2, rect.width / 2)
    fillPath(rect: rect, radius: radius, roundedLeft: roundedLeft, roundedRight: roundedRight)
      .fill()
    let ring = ringPath(
      rect: rect, radius: radius, roundedLeft: roundedLeft, roundedRight: roundedRight)
    ring.lineWidth = ringWidth
    ring.stroke()
  }

  /// The closed fill outline: left corners rounded only at a run's start, right corners only
  /// at its end; a wrap-cut edge stays square. Tangent arcs collapse to a sharp corner at
  /// radius 0, so square and rounded corners share one path builder.
  private func fillPath(rect: CGRect, radius: CGFloat, roundedLeft: Bool, roundedRight: Bool)
    -> NSBezierPath
  {
    let left = roundedLeft ? radius : 0
    let right = roundedRight ? radius : 0
    let path = NSBezierPath()
    path.move(to: CGPoint(x: rect.minX + left, y: rect.minY))
    path.line(to: CGPoint(x: rect.maxX - right, y: rect.minY))
    path.appendArc(
      from: CGPoint(x: rect.maxX, y: rect.minY),
      to: CGPoint(x: rect.maxX, y: rect.maxY), radius: right)
    path.appendArc(
      from: CGPoint(x: rect.maxX, y: rect.maxY),
      to: CGPoint(x: rect.minX, y: rect.maxY), radius: right)
    path.line(to: CGPoint(x: rect.minX + left, y: rect.maxY))
    path.appendArc(
      from: CGPoint(x: rect.minX, y: rect.maxY),
      to: CGPoint(x: rect.minX, y: rect.minY), radius: left)
    path.appendArc(
      from: CGPoint(x: rect.minX, y: rect.minY),
      to: CGPoint(x: rect.maxX, y: rect.minY), radius: left)
    path.close()
    return path
  }

  /// The 1px ring, stroked so top and bottom rules always show but a vertical rule (and its
  /// rounded corners) appear only at a real run end — a wrap-cut edge is left open so
  /// consecutive line fragments read as one continuous shape.
  private func ringPath(rect: CGRect, radius: CGFloat, roundedLeft: Bool, roundedRight: Bool)
    -> NSBezierPath
  {
    let inset = ringWidth / 2
    let minX = rect.minX + inset
    let maxX = rect.maxX - inset
    let minY = rect.minY + inset
    let maxY = rect.maxY - inset
    let left = roundedLeft ? radius : 0
    let right = roundedRight ? radius : 0
    let path = NSBezierPath()

    if roundedLeft && roundedRight {
      path.move(to: CGPoint(x: minX + left, y: minY))
      path.line(to: CGPoint(x: maxX - right, y: minY))
      path.appendArc(from: CGPoint(x: maxX, y: minY), to: CGPoint(x: maxX, y: maxY), radius: right)
      path.appendArc(from: CGPoint(x: maxX, y: maxY), to: CGPoint(x: minX, y: maxY), radius: right)
      path.line(to: CGPoint(x: minX + left, y: maxY))
      path.appendArc(from: CGPoint(x: minX, y: maxY), to: CGPoint(x: minX, y: minY), radius: left)
      path.appendArc(from: CGPoint(x: minX, y: minY), to: CGPoint(x: maxX, y: minY), radius: left)
      path.close()
    } else if roundedLeft {
      // Top + rounded left + bottom; right (wrap) edge open.
      path.move(to: CGPoint(x: maxX, y: minY))
      path.line(to: CGPoint(x: minX + left, y: minY))
      path.appendArc(from: CGPoint(x: minX, y: minY), to: CGPoint(x: minX, y: maxY), radius: left)
      path.line(to: CGPoint(x: minX, y: maxY - left))
      path.appendArc(from: CGPoint(x: minX, y: maxY), to: CGPoint(x: maxX, y: maxY), radius: left)
      path.line(to: CGPoint(x: maxX, y: maxY))
    } else if roundedRight {
      // Top + rounded right + bottom; left (wrap) edge open.
      path.move(to: CGPoint(x: minX, y: minY))
      path.line(to: CGPoint(x: maxX - right, y: minY))
      path.appendArc(from: CGPoint(x: maxX, y: minY), to: CGPoint(x: maxX, y: maxY), radius: right)
      path.line(to: CGPoint(x: maxX, y: maxY - right))
      path.appendArc(from: CGPoint(x: maxX, y: maxY), to: CGPoint(x: minX, y: maxY), radius: right)
      path.line(to: CGPoint(x: minX, y: maxY))
    } else {
      // Interior wrap segment: only top and bottom rules, both sides open.
      path.move(to: CGPoint(x: minX, y: minY))
      path.line(to: CGPoint(x: maxX, y: minY))
      path.move(to: CGPoint(x: minX, y: maxY))
      path.line(to: CGPoint(x: maxX, y: maxY))
    }
    return path
  }
}
