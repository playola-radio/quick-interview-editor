import AppKit
import SwiftUI

/// The read + interaction surface ``WaveformLaneView`` needs from whatever drives it. Both the
/// source-axis ``WaveformModel`` (the slice-edit sheet, pinned to a slice's sub-range) and the
/// edited/collapsed ``EditedWaveformAdapter`` (the main editor) conform, so the ONE reusable lane
/// renders either axis without knowing which. Every member is pure geometry the concrete type
/// already owns; this only erases which axis is in play. The `forSource:` names are a literal
/// source↔edited mapping for the adapter and identities for the source-axis model (there, a source
/// sample IS a plan sample).
@MainActor
protocol WaveformLaneDriving: AnyObject {
  var showsLoading: Bool { get }
  var showsEmpty: Bool { get }
  var loadingMessage: String { get }
  var emptyMessage: String { get }
  /// Vertical zoom: multiplies rendered peak height. Purely a rendering scale — see
  /// ``WaveformModel/amplitudeScale``, which every conformer ultimately reads from.
  var amplitudeScale: CGFloat { get }
  func viewportResized(width: CGFloat)
  func visibleColumns() -> [WaveformColumn]
  func laneSpan(forSource sourceRange: Range<Int>) -> WaveformSpan?
  /// View-x of a SOURCE sample — for source-anchored geometry like the selection edge handles.
  func laneX(forSource sourceSample: Int) -> CGFloat?
  /// View-x of the persistent cursor. `cursorSample` is in the DRIVER's presentation axis —
  /// EDITED samples for ``EditedWaveformAdapter`` (the main editor), plan/source samples for
  /// ``WaveformModel`` (the slice-edit sheet, where source IS the presented axis).
  func lanePlayheadX(forCursor cursorSample: Int) -> CGFloat?
  // swiftlint:disable:next function_parameter_count
  func scrolled(
    deltaX: CGFloat, deltaY: CGFloat, hasPreciseDeltas: Bool,
    optionDown: Bool, commandDown: Bool, atX positionX: CGFloat)
}

/// The reusable waveform lane: a Logic-style ruler strip stacked over the read-only waveform band.
/// It is driven by any ``WaveformLaneDriving`` — the EDITED/collapsed axis in the main editor, or a
/// source-axis, slice-pinned ``WaveformModel`` in the slice-edit sheet — plus injected
/// values and callbacks — it decides nothing. The editor mounts it with its own `EditorModel`
/// methods for clicks/marquee/ruler and its own audition overlay. ⌘+scroll zoom and plain-scroll
/// pan are handled by the interaction layers, which call
/// ``EditedWaveformAdapter/scrolled(deltaX:deltaY:hasPreciseDeltas:optionDown:commandDown:atX:)``
/// directly.
///
/// Redraw isolation is preserved from the original in-editor waveform: the expensive
/// ``WaveformCanvas`` reads `waveform.visibleColumns()` in its own body (so zoom/pan auto-redraw via
/// Observation, and a playback tick — which leaves those columns unchanged — skips it via view
/// equality), while the moving ``WaveformPlayhead``/``RulerPlayhead`` read
/// `waveform.playheadX(for:)` in their own bodies so only they reposition on a tick.
struct WaveformLaneView<Overlay: View>: View {
  let waveform: any WaveformLaneDriving
  let playhead: () -> Int?
  let highlightRange: Range<Int>?
  let onRulerMove: (CGFloat) -> Void
  let onBodyClick: (CGFloat, Bool) -> Void
  let onAreaSelectBegan: (CGFloat, Bool) -> Void
  let onAreaSelectChanged: (CGFloat) -> Void
  let onAreaSelectEnded: (CGFloat) -> Void
  /// Crossfade seams to draw as bowtie X's over the band, each carrying its selected state. Defaults
  /// to `[]` so every existing call site (e.g. the slice-edit sheet) compiles unchanged. This lane
  /// only draws whatever overlays it's handed.
  var seams: [SeamOverlay] = []
  /// The right-click menu for a band position, keyed by view-x. The model decides whether the x
  /// hits a seam and what the menu contains; returning `[]` shows no menu. Default no-op so call
  /// sites without a seam menu (the slice-edit sheet) compile unchanged.
  var onContextMenu: (CGFloat) -> [WaveformMenuItem] = { _ in [] }
  /// Drag handles on the highlighted range's edges. A grab within a few points of the left/right edge
  /// of `highlightRange` fires these; a mouse-down anywhere else falls through to the marquee below.
  /// Default no-ops so the slice-edit sheet (which doesn't offer edge drag) compiles unchanged.
  var onEdgeDragBegan: (SelectionEdge) -> Void = { _ in }
  var onEdgeDragged: (SelectionEdge, CGFloat) -> Void = { _, _ in }
  var onEdgeDragEnded: (SelectionEdge) -> Void = { _ in }
  /// Whether the highlight's edges offer drag-to-resize. The main editor turns this on (its selection
  /// boundary is draggable); the slice-edit sheet leaves it off so its no-op edge layer is never
  /// mounted and never shadows the seam-stretch handles beneath at the highlight's boundary.
  var supportsEdgeDrag = true
  /// Stretch handles on each crossfade bowtie's two edges. A grab within a few points of a bowtie's
  /// leading/trailing edge fires these to lengthen/shorten that seam's fade; a mouse-down elsewhere
  /// falls through to the marquee below. Default no-ops so call sites without seam stretching (the
  /// slice-edit sheet, until Stage 4) compile unchanged.
  var onSeamStretchBegan: (UUID) -> Void = { _ in }
  var onSeamStretched: (CrossfadeEdge, CGFloat) -> Void = { _, _ in }
  var onSeamStretchEnded: () -> Void = {}
  @ViewBuilder let auditionOverlay: (WaveformSpan) -> Overlay

  private let bandHeight: CGFloat = 148
  private let stripHeight: CGFloat = 18

  var body: some View {
    let highlight = highlightRange.flatMap { waveform.laneSpan(forSource: $0) }
    VStack(alignment: .leading, spacing: 8) {
      rulerStrip
      ZStack(alignment: .leading) {
        Color(white: 0.024)
        content(highlight: highlight)
      }
      .frame(height: bandHeight)
      .clipShape(RoundedRectangle(cornerRadius: 4))
      .overlay(
        WaveformInteractionLayer(
          waveform: waveform,
          onBodyClick: onBodyClick,
          onAreaSelectBegan: onAreaSelectBegan,
          onAreaSelectChanged: onAreaSelectChanged,
          onAreaSelectEnded: onAreaSelectEnded,
          onContextMenu: onContextMenu)
      )
      // Sits above the marquee and BELOW the selection-edge layer, so a selection-edge grab keeps
      // priority where the two coincide. Claims only the points at each bowtie edge; every other
      // mouse-down falls through to the marquee.
      .overlay(
        SeamStretchHandleLayer(
          seams: seams,
          onStretchBegan: onSeamStretchBegan,
          onStretched: onSeamStretched,
          onStretchEnded: onSeamStretchEnded,
          onBodyClick: onBodyClick,
          onContextMenu: onContextMenu)
      )
      // Sits ABOVE the marquee layer: it claims only the few points at each edge of the highlight, so
      // an edge grab starts a boundary drag while every other mouse-down falls through to the marquee.
      // Only mounted where edge drag is supported, so a no-op edge layer never shadows the seam-stretch
      // handles beneath (the slice-edit sheet shows a highlight it can't resize).
      .overlay {
        if supportsEdgeDrag {
          WaveformEdgeHandleLayer(
            startX: highlightRange.flatMap { waveform.laneX(forSource: $0.lowerBound) },
            endX: highlightRange.flatMap { waveform.laneX(forSource: $0.upperBound) },
            onEdgeDragBegan: onEdgeDragBegan,
            onEdgeDragged: onEdgeDragged,
            onEdgeDragEnded: onEdgeDragEnded,
            onContextMenu: onContextMenu)
        }
      }
      .overlay(alignment: .topLeading) {
        if let highlight {
          auditionOverlay(highlight)
        }
      }
      .onGeometryChange(for: CGFloat.self) {
        $0.size.width
      } action: {
        waveform.viewportResized(width: $0)
      }
    }
  }

  private var rulerStrip: some View {
    ZStack(alignment: .leading) {
      Color(white: 0.1)
      RulerPlayhead(waveform: waveform, playhead: playhead)
    }
    .frame(maxWidth: .infinity)
    .frame(height: stripHeight)
    .clipShape(RoundedRectangle(cornerRadius: 3))
    .overlay(
      RoundedRectangle(cornerRadius: 3).stroke(Color(white: 0.18), lineWidth: 1)
    )
    .overlay(WaveformRulerInteractionLayer(waveform: waveform, onRulerMove: onRulerMove))
  }

  @ViewBuilder private func content(highlight: WaveformSpan?) -> some View {
    if waveform.showsLoading {
      centeredMessage(waveform.loadingMessage)
    } else if waveform.showsEmpty {
      centeredMessage(waveform.emptyMessage)
    } else {
      ZStack(alignment: .leading) {
        WaveformCanvas(waveform: waveform, highlight: highlight)
        SeamBowtieOverlay(seams: seams)
        WaveformPlayhead(waveform: waveform, playhead: playhead)
      }
    }
  }

  private func centeredMessage(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 12)).foregroundStyle(Color(white: 0.4))
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Draws the min/max columns plus the highlight rect. Reads only geometry + the injected highlight
/// (never the playhead), so playhead ticks don't force it to redraw.
private struct WaveformCanvas: View {
  let waveform: any WaveformLaneDriving
  let highlight: WaveformSpan?

  private let waveColor = Color(white: 0.62)
  private let highlightColor = Color.white.opacity(0.14)

  var body: some View {
    // Read observed model output here so SwiftUI re-renders on change; the Canvas
    // closure then draws the captured values.
    let columns = waveform.visibleColumns()
    let amplitudeScale = waveform.amplitudeScale
    Canvas { context, size in
      let midY = size.height / 2
      let scale = size.height / 2 * 0.9 * amplitudeScale
      if let highlight {
        context.fill(
          Path(CGRect(x: highlight.positionX, y: 0, width: highlight.width, height: size.height)),
          with: .color(highlightColor))
      }
      var path = Path()
      for column in columns {
        let top = midY - CGFloat(column.max) * scale
        let bottom = midY - CGFloat(column.min) * scale
        path.move(to: CGPoint(x: column.positionX + 0.5, y: top))
        path.addLine(to: CGPoint(x: column.positionX + 0.5, y: Swift.max(bottom, top + 0.75)))
      }
      context.stroke(path, with: .color(waveColor), lineWidth: 1)
    }
  }
}

/// Draws a Logic-style crossfade "bowtie" — two crossing lines — inside each given span rect.
/// Purely a renderer: it decides nothing about which seams exist or where they sit: the model
/// hands it spans, this draws them.
private struct SeamBowtieOverlay: View {
  let seams: [SeamOverlay]

  private let strokeColor = Color.white.opacity(0.4)
  private let selectedColor = Color(red: 0.96, green: 0.86, blue: 0.4)

  var body: some View {
    Canvas { context, size in
      for seam in seams {
        let rect = CGRect(
          x: seam.span.positionX, y: 0, width: seam.span.width, height: size.height)
        if seam.isSelected {
          context.fill(Path(rect), with: .color(selectedColor.opacity(0.16)))
        }
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        context.stroke(
          path, with: .color(seam.isSelected ? selectedColor : strokeColor),
          lineWidth: seam.isSelected ? 2 : 1)
      }
    }
  }
}

/// The playback playhead over the band, isolated in its own view so it redraws without touching the
/// waveform canvas.
private struct WaveformPlayhead: View {
  let waveform: any WaveformLaneDriving
  let playhead: () -> Int?

  var body: some View {
    if let sample = playhead(), let positionX = waveform.lanePlayheadX(forCursor: sample) {
      Rectangle()
        .fill(Color(red: 0.96, green: 0.86, blue: 0.4))
        .frame(width: 1.5)
        .frame(maxHeight: .infinity)
        .offset(x: positionX)
    }
  }
}

/// The playhead marker inside the ruler, isolated in its own view so its ~30 Hz updates during
/// playback don't invalidate the strip background or the interaction layer. Reads the same cursor
/// geometry as the band's playhead, so the two read as one continuous line.
private struct RulerPlayhead: View {
  let waveform: any WaveformLaneDriving
  let playhead: () -> Int?

  var body: some View {
    if let sample = playhead(), let positionX = waveform.lanePlayheadX(forCursor: sample) {
      Rectangle()
        .fill(Color(red: 0.96, green: 0.86, blue: 0.4))
        .frame(width: 1.5)
        .frame(maxHeight: .infinity)
        .offset(x: positionX)
    }
  }
}

/// A transparent AppKit layer over the ruler strip. Sibling to `WaveformInteractionLayer` (the body
/// layer): it claims the strip's points and forwards raw gesture x to `onRulerMove`, which maps
/// x → plan sample and moves the playhead. Click and drag are identical — both position the cursor —
/// so `mouseDown` and `mouseDragged` route to the same callback. Scroll is forwarded to the shared
/// zoom/pan handler on the model so the gesture stays continuous across the strip and the body.
private struct WaveformRulerInteractionLayer: NSViewRepresentable {
  let waveform: any WaveformLaneDriving
  let onRulerMove: (CGFloat) -> Void

  func makeNSView(context: Context) -> RulerView {
    let view = RulerView()
    apply(to: view)
    return view
  }

  func updateNSView(_ nsView: RulerView, context: Context) {
    apply(to: nsView)
  }

  private func apply(to view: RulerView) {
    view.waveform = waveform
    view.onRulerMove = onRulerMove
  }

  final class RulerView: NSView {
    var waveform: (any WaveformLaneDriving)?
    var onRulerMove: ((CGFloat) -> Void)?

    override var acceptsFirstResponder: Bool { false }

    /// Claim points inside the strip so clicks/drags/scroll come here, not the SwiftUI content
    /// beneath. `point` arrives in the superview's coordinate system; convert into our own bounds
    /// before testing so we claim exactly the strip regardless of our frame origin.
    override func hitTest(_ point: NSPoint) -> NSView? {
      bounds.contains(convert(point, from: superview)) ? self : nil
    }

    private func localX(_ event: NSEvent) -> CGFloat {
      convert(event.locationInWindow, from: nil).x
    }

    override func mouseDown(with event: NSEvent) {
      onRulerMove?(localX(event))
    }

    override func mouseDragged(with event: NSEvent) {
      onRulerMove?(localX(event))
    }

    override func scrollWheel(with event: NSEvent) {
      let flags = event.modifierFlags
      waveform?.scrolled(
        deltaX: event.scrollingDeltaX,
        deltaY: event.scrollingDeltaY,
        hasPreciseDeltas: event.hasPreciseScrollingDeltas,
        optionDown: flags.contains(.option),
        commandDown: flags.contains(.command),
        atX: localX(event))
      // Consume: do NOT call super, so an enclosing ScrollView never double-scrolls.
    }
  }
}

/// A transparent AppKit layer over the waveform `Canvas`. It owns all waveform mouse
/// input — scroll (zoom/pan), click (select / Shift-extend), and drag (a Logic-style marquee
/// area-selection) — and forwards only raw facts to the injected callbacks. Panning the view is on
/// scroll/swipe (matching Logic, where a workspace drag marquee-selects rather than pans). The
/// `Canvas` beneath stays a pure renderer.
private struct WaveformInteractionLayer: NSViewRepresentable {
  let waveform: any WaveformLaneDriving
  let onBodyClick: (CGFloat, Bool) -> Void
  let onAreaSelectBegan: (CGFloat, Bool) -> Void
  let onAreaSelectChanged: (CGFloat) -> Void
  let onAreaSelectEnded: (CGFloat) -> Void
  let onContextMenu: (CGFloat) -> [WaveformMenuItem]

  func makeNSView(context: Context) -> InteractionView {
    let view = InteractionView()
    apply(to: view)
    return view
  }

  func updateNSView(_ nsView: InteractionView, context: Context) {
    apply(to: nsView)
  }

  private func apply(to view: InteractionView) {
    view.waveform = waveform
    view.onBodyClick = onBodyClick
    view.onAreaSelectBegan = onAreaSelectBegan
    view.onAreaSelectChanged = onAreaSelectChanged
    view.onAreaSelectEnded = onAreaSelectEnded
    view.onContextMenu = onContextMenu
  }

  final class InteractionView: NSView {
    var waveform: (any WaveformLaneDriving)?
    var onBodyClick: ((CGFloat, Bool) -> Void)?
    var onAreaSelectBegan: ((CGFloat, Bool) -> Void)?
    var onAreaSelectChanged: ((CGFloat) -> Void)?
    var onAreaSelectEnded: ((CGFloat) -> Void)?
    var onContextMenu: ((CGFloat) -> [WaveformMenuItem])?

    private var dragStartX: CGFloat?
    private var didDrag = false
    private let dragThreshold: CGFloat = 6

    override var acceptsFirstResponder: Bool { false }

    /// Claim points inside the band so clicks/drags/scroll come here, not the Canvas.
    /// `point` arrives in the superview's coordinate system; convert into our own
    /// bounds before testing so we claim exactly the waveform band (and nothing
    /// outside it), regardless of our frame origin.
    override func hitTest(_ point: NSPoint) -> NSView? {
      bounds.contains(convert(point, from: superview)) ? self : nil
    }

    private func localX(_ event: NSEvent) -> CGFloat {
      convert(event.locationInWindow, from: nil).x
    }

    override func mouseDown(with event: NSEvent) {
      dragStartX = localX(event)
      didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
      guard let start = dragStartX else { return }
      let currentX = localX(event)
      if !didDrag {
        guard abs(currentX - start) >= dragThreshold else { return }
        didDrag = true
        // Shift is read at the moment the marquee begins so a mid-drag key change can't retarget it.
        onAreaSelectBegan?(start, event.modifierFlags.contains(.shift))
      }
      onAreaSelectChanged?(currentX)
    }

    override func mouseUp(with event: NSEvent) {
      if didDrag {
        onAreaSelectEnded?(localX(event))
      } else if let start = dragStartX {
        onBodyClick?(start, event.modifierFlags.contains(.shift))
      }
      dragStartX = nil
      didDrag = false
    }

    override func scrollWheel(with event: NSEvent) {
      let flags = event.modifierFlags
      waveform?.scrolled(
        deltaX: event.scrollingDeltaX,
        deltaY: event.scrollingDeltaY,
        hasPreciseDeltas: event.hasPreciseScrollingDeltas,
        optionDown: flags.contains(.option),
        commandDown: flags.contains(.command),
        atX: localX(event))
      // Consume: do NOT call super, so an enclosing ScrollView never double-scrolls.
    }

    /// Right-click: ask the model what (if anything) sits under the pointer. An empty result
    /// (no seam) shows no menu; the model both selects the seam and supplies its actions.
    override func menu(for event: NSEvent) -> NSMenu? {
      waveformContextMenu(from: onContextMenu?(localX(event)) ?? [])
    }
  }
}

/// Builds the AppKit menu the model asked for from plain title+action pairs, or nil when the model
/// reported nothing under the pointer. Shared by every waveform layer that can surface the seam
/// menu, so the edge-handle layer and the marquee layer resolve a right-click identically.
@MainActor
private func waveformContextMenu(from items: [WaveformMenuItem]) -> NSMenu? {
  guard !items.isEmpty else { return nil }
  let menu = NSMenu()
  for item in items {
    menu.addItem(ClosureMenuItem(title: item.title, action: item.action))
  }
  return menu
}

/// An `NSMenuItem` that runs a closure when picked, so the model can hand the waveform menu plain
/// title+action pairs without a target/selector dance.
private final class ClosureMenuItem: NSMenuItem {
  private let handler: () -> Void

  init(title: String, action: @escaping () -> Void) {
    handler = action
    super.init(title: title, action: #selector(fire), keyEquivalent: "")
    target = self
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @objc private func fire() {
    handler()
  }
}

/// A transparent AppKit layer over the band that claims ONLY the few points at each edge of the
/// highlighted range and turns a drag there into a boundary edit. It sits above the marquee layer, so
/// its `hitTest` returns `self` only inside a handle zone and `nil` everywhere else — a mouse-down
/// away from an edge falls through to the marquee/click layer beneath, unchanged. It reads nothing
/// from the model: the edge x-positions are handed in, and it forwards raw gesture x to the closures.
private struct WaveformEdgeHandleLayer: NSViewRepresentable {
  let startX: CGFloat?
  let endX: CGFloat?
  let onEdgeDragBegan: (SelectionEdge) -> Void
  let onEdgeDragged: (SelectionEdge, CGFloat) -> Void
  let onEdgeDragEnded: (SelectionEdge) -> Void
  /// Same seam menu the marquee layer offers. Because this layer sits above the marquee and claims
  /// the edge zones, a right-click on a selection edge that also lands on a seam would otherwise be
  /// swallowed here; forwarding it keeps the seam restorable even when its bowtie hugs an edge.
  let onContextMenu: (CGFloat) -> [WaveformMenuItem]

  func makeNSView(context: Context) -> HandleView {
    let view = HandleView()
    apply(to: view)
    return view
  }

  func updateNSView(_ nsView: HandleView, context: Context) {
    apply(to: nsView)
  }

  private func apply(to view: HandleView) {
    view.startX = startX
    view.endX = endX
    view.onEdgeDragBegan = onEdgeDragBegan
    view.onEdgeDragged = onEdgeDragged
    view.onEdgeDragEnded = onEdgeDragEnded
    view.onContextMenu = onContextMenu
    view.window?.invalidateCursorRects(for: view)
  }

  final class HandleView: NSView {
    var startX: CGFloat?
    var endX: CGFloat?
    var onEdgeDragBegan: ((SelectionEdge) -> Void)?
    var onEdgeDragged: ((SelectionEdge, CGFloat) -> Void)?
    var onEdgeDragEnded: ((SelectionEdge) -> Void)?
    var onContextMenu: ((CGFloat) -> [WaveformMenuItem])?

    /// Half-width of a grab zone: a mouse-down within this many points of an edge grabs it.
    private let grabTolerance: CGFloat = 6
    private var activeEdge: SelectionEdge?

    override var acceptsFirstResponder: Bool { false }

    /// Claim only the edge zones. `point` arrives in the superview's coordinates; convert into our own
    /// bounds before testing so the zones track our frame origin.
    override func hitTest(_ point: NSPoint) -> NSView? {
      let local = convert(point, from: superview)
      guard bounds.contains(local) else { return nil }
      return edge(nearestToX: local.x) != nil ? self : nil
    }

    /// The edge whose x is within `grabTolerance` of `x`, choosing the nearer one when both zones
    /// overlap on a narrow selection. Nil when no edge is in range (or there is no selection).
    private func edge(nearestToX posX: CGFloat) -> SelectionEdge? {
      var best: (edge: SelectionEdge, distance: CGFloat)?
      if let startX { best = (.start, abs(posX - startX)) }
      if let endX {
        let distance = abs(posX - endX)
        if best == nil || distance < best!.distance { best = (.end, distance) }
      }
      guard let best, best.distance <= grabTolerance else { return nil }
      return best.edge
    }

    private func localX(_ event: NSEvent) -> CGFloat {
      convert(event.locationInWindow, from: nil).x
    }

    override func resetCursorRects() {
      let cursor = NSCursor.resizeLeftRight
      if let startX {
        addCursorRect(
          CGRect(x: startX - grabTolerance, y: 0, width: grabTolerance * 2, height: bounds.height),
          cursor: cursor)
      }
      if let endX {
        addCursorRect(
          CGRect(x: endX - grabTolerance, y: 0, width: grabTolerance * 2, height: bounds.height),
          cursor: cursor)
      }
    }

    override func mouseDown(with event: NSEvent) {
      activeEdge = edge(nearestToX: localX(event))
      if let activeEdge { onEdgeDragBegan?(activeEdge) }
    }

    override func mouseDragged(with event: NSEvent) {
      guard let activeEdge else { return }
      onEdgeDragged?(activeEdge, localX(event))
    }

    override func mouseUp(with event: NSEvent) {
      if let activeEdge { onEdgeDragEnded?(activeEdge) }
      activeEdge = nil
    }

    /// Right-click on an edge zone: forward to the seam menu so a bowtie sitting under a selection
    /// edge stays restorable. Empty result (no seam here) shows no menu, same as the marquee layer.
    override func menu(for event: NSEvent) -> NSMenu? {
      waveformContextMenu(from: onContextMenu?(localX(event)) ?? [])
    }
  }
}

/// A transparent AppKit layer over the band that claims ONLY the few points at each edge of each
/// crossfade bowtie and turns a drag there into a fade-length stretch. Sits above the marquee (and
/// below the selection-edge layer, which keeps priority where a selection edge coincides), so its
/// `hitTest` returns `self` only inside a bowtie-edge zone and `nil` everywhere else — a mouse-down
/// away from a bowtie edge falls through to the layers beneath, unchanged. It reads nothing from the
/// model: the per-seam edge x-positions come from the same `SeamOverlay` spans the bowtie draws, and
/// it forwards the grabbed seam id, edge, and raw gesture x to the closures.
private struct SeamStretchHandleLayer: NSViewRepresentable {
  let seams: [SeamOverlay]
  let onStretchBegan: (UUID) -> Void
  let onStretched: (CrossfadeEdge, CGFloat) -> Void
  let onStretchEnded: () -> Void
  let onBodyClick: (CGFloat, Bool) -> Void
  let onContextMenu: (CGFloat) -> [WaveformMenuItem]

  func makeNSView(context: Context) -> HandleView {
    let view = HandleView()
    apply(to: view)
    return view
  }

  func updateNSView(_ nsView: HandleView, context: Context) {
    apply(to: nsView)
  }

  private func apply(to view: HandleView) {
    view.seams = seams
    view.onStretchBegan = onStretchBegan
    view.onStretched = onStretched
    view.onStretchEnded = onStretchEnded
    view.onBodyClick = onBodyClick
    view.onContextMenu = onContextMenu
    view.window?.invalidateCursorRects(for: view)
  }

  final class HandleView: NSView {
    var seams: [SeamOverlay] = []
    var onStretchBegan: ((UUID) -> Void)?
    var onStretched: ((CrossfadeEdge, CGFloat) -> Void)?
    var onStretchEnded: (() -> Void)?
    var onBodyClick: ((CGFloat, Bool) -> Void)?
    var onContextMenu: ((CGFloat) -> [WaveformMenuItem])?

    /// Half-width of a grab zone: a mouse-down within this many points of a bowtie edge grabs it.
    private let grabTolerance: CGFloat = 6
    /// Minimum travel before a grab becomes a stretch, so a click (or hair-trigger jitter) on a
    /// handle never opens a draft or commits a no-op undo entry. Matches the area-select layer.
    private let dragThreshold: CGFloat = 6
    private var active: (id: UUID, edge: CrossfadeEdge)?
    private var downX: CGFloat?
    private var didDrag = false

    override var acceptsFirstResponder: Bool { false }

    /// Claim only the bowtie-edge zones. `point` arrives in the superview's coordinates; convert into
    /// our own bounds before testing so the zones track our frame origin.
    override func hitTest(_ point: NSPoint) -> NSView? {
      let local = convert(point, from: superview)
      guard bounds.contains(local) else { return nil }
      return handle(nearestToX: local.x) != nil ? self : nil
    }

    /// The bowtie edge whose x is within `grabTolerance` of `x`, across every seam, choosing the
    /// nearest when zones overlap. Nil when no edge is in range. A hard-cut seam (zero-width bowtie)
    /// has both edges at the cut; the tie resolves to `.leading`, and dragging it out starts a fade.
    private func handle(nearestToX posX: CGFloat) -> (id: UUID, edge: CrossfadeEdge)? {
      var best: (handle: (id: UUID, edge: CrossfadeEdge), distance: CGFloat)?
      for seam in seams {
        for (edge, edgeX) in [
          (CrossfadeEdge.leading, seam.leadingHandleX), (.trailing, seam.trailingHandleX),
        ] {
          guard let edgeX else { continue }
          let distance = abs(posX - edgeX)
          if best == nil || distance < best!.distance {
            best = ((seam.id, edge), distance)
          }
        }
      }
      guard let best, best.distance <= grabTolerance else { return nil }
      return best.handle
    }

    private func localX(_ event: NSEvent) -> CGFloat {
      convert(event.locationInWindow, from: nil).x
    }

    override func resetCursorRects() {
      let cursor = NSCursor.resizeLeftRight
      for seam in seams {
        for edgeX in [seam.leadingHandleX, seam.trailingHandleX] {
          guard let edgeX else { continue }
          addCursorRect(
            CGRect(x: edgeX - grabTolerance, y: 0, width: grabTolerance * 2, height: bounds.height),
            cursor: cursor)
        }
      }
    }

    override func mouseDown(with event: NSEvent) {
      let posX = localX(event)
      active = handle(nearestToX: posX)
      downX = posX
      didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
      guard let active, let downX else { return }
      let currentX = localX(event)
      if !didDrag {
        guard abs(currentX - downX) >= dragThreshold else { return }
        didDrag = true
        onStretchBegan?(active.id)
      }
      onStretched?(active.edge, currentX)
    }

    override func mouseUp(with event: NSEvent) {
      if didDrag {
        onStretchEnded?()
      } else {
        // A click that never crossed the drag threshold isn't a stretch. Because we claimed the
        // mouse-down, the marquee/body layer beneath never sees it, so forward it to the same
        // body-click path — a plain click on a bowtie edge still selects the seam (Logic parity).
        onBodyClick?(localX(event), event.modifierFlags.contains(.shift))
      }
      active = nil
      downX = nil
      didDrag = false
    }

    /// Right-click on a bowtie-edge zone: forward to the seam menu so the restore/remove actions stay
    /// reachable at the exact pixels this layer claims from the marquee beneath. Empty result (no seam
    /// here) shows no menu, same as the marquee and selection-edge layers.
    override func menu(for event: NSEvent) -> NSMenu? {
      waveformContextMenu(from: onContextMenu?(localX(event)) ?? [])
    }
  }
}

/// Logic's "Waveform Zoom" control: click-and-hold, then drag vertically to scale the waveform's
/// amplitude; double-click resets to 1×. This mirrors Logic Pro's actual gesture — there is no
/// keyboard shortcut for vertical zoom. AppKit-backed because SwiftUI has no built-in
/// click-hold-drag gesture; all the math lives on the model, this view only forwards raw mouse facts.
struct WaveformAmplitudeZoomButton: View {
  let waveform: WaveformModel
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    Image(systemName: "arrow.up.and.down")
      .frame(width: 22, height: 22)
      .overlay(WaveformAmplitudeZoomDragArea(waveform: waveform))
      .help(waveform.amplitudeZoomLabel)
      .opacity(isEnabled ? 1 : 0.35)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(waveform.amplitudeZoomLabel)
      .accessibilityValue(waveform.amplitudeZoomAccessibilityValue)
      .accessibilityAdjustableAction { direction in
        switch direction {
        case .increment: waveform.amplitudeZoomIncremented()
        case .decrement: waveform.amplitudeZoomDecremented()
        @unknown default: break
        }
      }
      .accessibilityAction(named: Text(waveform.amplitudeZoomResetLabel)) {
        waveform.amplitudeZoomResetTapped()
      }
  }
}

private struct WaveformAmplitudeZoomDragArea: NSViewRepresentable {
  let waveform: WaveformModel

  func makeNSView(context: Context) -> DragView {
    let view = DragView()
    view.waveform = waveform
    view.isEnabled = context.environment.isEnabled
    return view
  }

  func updateNSView(_ nsView: DragView, context: Context) {
    nsView.waveform = waveform
    nsView.isEnabled = context.environment.isEnabled
  }

  final class DragView: NSView {
    var waveform: WaveformModel?
    var isEnabled = true

    private var dragStartY: CGFloat?

    override var acceptsFirstResponder: Bool { false }

    private func localY(_ event: NSEvent) -> CGFloat {
      convert(event.locationInWindow, from: nil).y
    }

    override func mouseDown(with event: NSEvent) {
      guard isEnabled else { return }
      if event.clickCount >= 2 {
        dragStartY = nil
        waveform?.amplitudeZoomResetTapped()
        return
      }
      waveform?.amplitudeZoomDragBegan()
      dragStartY = localY(event)
    }

    override func mouseDragged(with event: NSEvent) {
      guard isEnabled, let start = dragStartY else { return }
      // AppKit's bottom-left-origin coordinates already give "drag up = positive delta", matching
      // the model's up-increases-scale convention with no sign flip needed.
      waveform?.amplitudeZoomDragged(byPixels: localY(event) - start)
    }

    override func mouseUp(with event: NSEvent) {
      dragStartY = nil
    }
  }
}
