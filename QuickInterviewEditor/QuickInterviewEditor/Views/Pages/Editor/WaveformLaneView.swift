import AppKit
import SwiftUI

/// The reusable waveform lane: a Logic-style ruler strip stacked over the read-only waveform band.
/// It is driven entirely by a ``WaveformModel`` plus injected values and callbacks — it decides
/// nothing. The main editor and the modal both mount this same lane, differing only in the values
/// and adapters they pass (their own `EditorModel` methods for clicks/marquee/ruler, their own
/// audition overlay). ⌘+scroll zoom and plain-scroll pan are handled by the interaction layers,
/// which call ``WaveformModel/scrolled(deltaX:deltaY:hasPreciseDeltas:optionDown:commandDown:atX:)``
/// directly.
///
/// Redraw isolation is preserved from the original in-editor waveform: the expensive
/// ``WaveformCanvas`` reads `waveform.visibleColumns()` in its own body (so zoom/pan auto-redraw via
/// Observation, and a playback tick — which leaves those columns unchanged — skips it via view
/// equality), while the moving ``WaveformPlayhead``/``RulerPlayhead`` read
/// `waveform.playheadX(for:)` in their own bodies so only they reposition on a tick.
struct WaveformLaneView<Overlay: View>: View {
  let waveform: WaveformModel
  let playhead: () -> Int?
  let highlightRange: Range<Int>?
  let onRulerMove: (CGFloat) -> Void
  let onBodyClick: (CGFloat, Bool) -> Void
  let onAreaSelectBegan: (CGFloat, Bool) -> Void
  let onAreaSelectChanged: (CGFloat) -> Void
  let onAreaSelectEnded: (CGFloat) -> Void
  @ViewBuilder let auditionOverlay: (WaveformSpan) -> Overlay

  private let bandHeight: CGFloat = 148
  private let stripHeight: CGFloat = 18

  var body: some View {
    let highlight = highlightRange.flatMap(waveform.span(for:))
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
          onAreaSelectEnded: onAreaSelectEnded)
      )
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
  let waveform: WaveformModel
  let highlight: WaveformSpan?

  private let waveColor = Color(white: 0.62)
  private let highlightColor = Color.white.opacity(0.14)

  var body: some View {
    // Read observed model output here so SwiftUI re-renders on change; the Canvas
    // closure then draws the captured values.
    let columns = waveform.visibleColumns()
    Canvas { context, size in
      let midY = size.height / 2
      let scale = size.height / 2 * 0.9
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

/// The playback playhead over the band, isolated in its own view so it redraws without touching the
/// waveform canvas.
private struct WaveformPlayhead: View {
  let waveform: WaveformModel
  let playhead: () -> Int?

  var body: some View {
    if let sample = playhead(), let positionX = waveform.playheadX(for: sample) {
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
  let waveform: WaveformModel
  let playhead: () -> Int?

  var body: some View {
    if let sample = playhead(), let positionX = waveform.playheadX(for: sample) {
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
  let waveform: WaveformModel
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
    var waveform: WaveformModel?
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
  let waveform: WaveformModel
  let onBodyClick: (CGFloat, Bool) -> Void
  let onAreaSelectBegan: (CGFloat, Bool) -> Void
  let onAreaSelectChanged: (CGFloat) -> Void
  let onAreaSelectEnded: (CGFloat) -> Void

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
  }

  final class InteractionView: NSView {
    var waveform: WaveformModel?
    var onBodyClick: ((CGFloat, Bool) -> Void)?
    var onAreaSelectBegan: ((CGFloat, Bool) -> Void)?
    var onAreaSelectChanged: ((CGFloat) -> Void)?
    var onAreaSelectEnded: ((CGFloat) -> Void)?

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
  }
}
