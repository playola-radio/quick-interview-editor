import AppKit

/// One clip container resolved for drawing: a contiguous UTF-16 range plus its already
/// state-mapped fill and ring colours. Built by the coordinator from the model's
/// `TranscriptClipContainer`s; this layer stays a dumb renderer of model-derived data.
struct ClipContainerRun: Equatable {
  let range: NSRange
  let fill: NSColor
  let ring: NSColor
  /// A dashed ring marks a tentative container (a suggestion); a solid ring a committed one.
  var dashed = false
  var ringWidth: Double = 1
}

/// A TextKit-1 layout manager that paints clip containers behind the text: one continuous
/// tinted, rounded, ringed shape running through each clip's words. It draws containers
/// FIRST, then the current-word band, then the selection sweep, then calls `super` (glyphs
/// draw last, above all).
///
/// It owns no state decisions: `containerRuns`, `currentWordRange`, and `selectionRuns` are
/// handed in by the coordinator. Rounded caps sit only at a run's true ends (computed from
/// the full run, never the clipped dirty range), and a run that wraps is drawn as one
/// square-jointed segment per line fragment so the ring closes across the wrap without a seam.
final class ClipContainerLayoutManager: NSLayoutManager {

  var containerRuns: [ClipContainerRun] = []
  /// The word under the playhead while listening, or nil. Drawn as a soft light band ("current
  /// word" highlight) above the clip fills but below the selection.
  var currentWordRange: NSRange?
  /// The selected words as gapless UTF-16 runs (from `TranscriptDocument.selectionRuns`). Drawn
  /// as one continuous rounded sweep per run — no per-word boxes, no inter-word gaps — above the
  /// clip fills and the current word, below the glyphs.
  var selectionRuns: [NSRange] = []

  private let cornerRadius: CGFloat = 6
  /// Symmetric breathing room above/below the glyph box (the mockup's `padding: 4px 0`); kept
  /// small because the font's ascender/descender box already includes some leading.
  private let verticalPadding: CGFloat = 3
  /// Soft white glow for the current word — distinct from the clip hues and the selection sweep.
  private let currentWordColor = NSColor(calibratedWhite: 1, alpha: 0.14)
  /// Crisp text-selection-style sweep: the emphasized selected-content colour, which is designed
  /// for white text on top (the selected words use the white foreground).
  private let selectionColor = NSColor.selectedContentBackgroundColor

  override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
    drawClipContainers(forGlyphRange: glyphsToShow, at: origin)
    fillRoundedSweep(
      currentWordRange.map { [$0] } ?? [], color: currentWordColor, forGlyphRange: glyphsToShow,
      at: origin)
    fillRoundedSweep(
      selectionRuns, color: selectionColor, forGlyphRange: glyphsToShow, at: origin)
    super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
  }

  /// Fills each range as a rounded sweep, one rounded rect per line fragment (so a wrapping run
  /// stays gapless within each line). Shared by the current-word band and the selection sweep.
  private func fillRoundedSweep(
    _ ranges: [NSRange], color: NSColor, forGlyphRange glyphsToShow: NSRange, at origin: NSPoint
  ) {
    guard !ranges.isEmpty, let textContainer = textContainers.first else { return }
    color.setFill()
    for range in ranges {
      let fullGlyphRange = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
      let visible = NSIntersectionRange(fullGlyphRange, glyphsToShow)
      guard visible.length > 0 else { continue }
      enumerateLineFragments(forGlyphRange: visible) { [self] lineRect, _, _, lineGlyphRange, _ in
        let segment = NSIntersectionRange(fullGlyphRange, lineGlyphRange)
        guard segment.length > 0 else { return }
        let horizontal = boundingRect(forGlyphRange: segment, in: textContainer)
        let font = glyphFont(atGlyph: segment.location)
        let baselineY = lineRect.minY + location(forGlyphAt: segment.location).y
        let rect = CGRect(
          x: horizontal.minX + origin.x,
          y: baselineY - font.ascender + origin.y - verticalPadding,
          width: horizontal.width,
          height: (font.ascender - font.descender) + verticalPadding * 2)
        let radius = min(cornerRadius, rect.height / 2, rect.width / 2)
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
      }
    }
  }

  private struct ContainerSegment {
    let fill: NSBezierPath
    let ring: NSBezierPath
    let run: ClipContainerRun
  }

  private func drawClipContainers(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
    guard !containerRuns.isEmpty, let textContainer = textContainers.first else { return }

    var segments: [ContainerSegment] = []
    for run in containerRuns {
      let fullGlyphRange = glyphRange(forCharacterRange: run.range, actualCharacterRange: nil)
      let visible = NSIntersectionRange(fullGlyphRange, glyphsToShow)
      guard visible.length > 0 else { continue }

      enumerateLineFragments(forGlyphRange: visible) {
        [self] lineRect, usedRect, _, lineGlyphRange, _ in
        let segment = NSIntersectionRange(fullGlyphRange, lineGlyphRange)
        guard segment.length > 0 else { return }

        // Caps come from the WHOLE run, not the visible slice: a run scrolled half-off must
        // still round only its true first/last line-fragment segments.
        let roundedLeft = segment.location == fullGlyphRange.location
        let roundedRight = NSMaxRange(segment) == NSMaxRange(fullGlyphRange)

        // Every edge stops at the TEXT (`usedRect`), never the line box margin. A real clip end
        // (`roundedLeft`/`roundedRight`) gets a rounded cap at its word; a wrap-cut edge stays
        // OPEN — squared, no vertical rule — at the line's last word, so it reads as "the clip
        // continues past the line", not "the clip ends here".
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

        let paths = containerPaths(
          in: rect, roundedLeft: roundedLeft, roundedRight: roundedRight, dashed: run.dashed,
          ringWidth: run.ringWidth)
        segments.append(ContainerSegment(fill: paths.fill, ring: paths.ring, run: run))
      }
    }
    // All fills precede all outlines: a foreground fill must not wash out an overlapping
    // group's boundary. Run order still puts the selected object's outline on top.
    for segment in segments {
      segment.run.fill.setFill()
      segment.fill.fill()
    }
    for segment in segments {
      segment.run.ring.setStroke()
      segment.ring.stroke()
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

  private func containerPaths(
    in rect: CGRect, roundedLeft: Bool, roundedRight: Bool, dashed: Bool, ringWidth: Double
  ) -> (fill: NSBezierPath, ring: NSBezierPath) {
    let radius = min(cornerRadius, rect.height / 2, rect.width / 2)
    let fill = fillPath(
      rect: rect, radius: radius, roundedLeft: roundedLeft, roundedRight: roundedRight)
    let ring = ringPath(
      rect: rect, radius: radius, roundedLeft: roundedLeft, roundedRight: roundedRight,
      ringWidth: ringWidth)
    ring.lineWidth = ringWidth
    if dashed {
      // A short dash so the tentative outline reads clearly on the transcript's short clip runs
      // without shimmering into a solid line. Phase 0: dashes start crisp at each segment origin.
      ring.setLineDash([4, 3], count: 2, phase: 0)
    }
    return (fill, ring)
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
  private func ringPath(
    rect: CGRect, radius: CGFloat, roundedLeft: Bool, roundedRight: Bool, ringWidth: Double
  )
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
