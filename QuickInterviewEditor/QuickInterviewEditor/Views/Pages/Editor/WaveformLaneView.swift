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
  func viewportResized(width: CGFloat)
  func visibleColumns() -> [WaveformColumn]
  func laneSpan(forSource sourceRange: Range<Int>) -> WaveformSpan?
  func lanePlayheadX(forSource sourceSample: Int) -> CGFloat?
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
  /// Crossfade seams to draw as bowtie X's over the band. Defaults to `[]` so every existing call
  /// site compiles unchanged. Positioning these on the collapsed edited waveform is a later step —
  /// this lane only draws whatever spans it's handed.
  var seams: [WaveformSpan] = []
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
  let seams: [WaveformSpan]

  private let strokeColor = Color.white.opacity(0.4)

  var body: some View {
    Canvas { context, size in
      var path = Path()
      for seam in seams {
        let rect = CGRect(x: seam.positionX, y: 0, width: seam.width, height: size.height)
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
      }
      context.stroke(path, with: .color(strokeColor), lineWidth: 1)
    }
  }
}

/// The playback playhead over the band, isolated in its own view so it redraws without touching the
/// waveform canvas.
private struct WaveformPlayhead: View {
  let waveform: any WaveformLaneDriving
  let playhead: () -> Int?

  var body: some View {
    if let sample = playhead(), let positionX = waveform.lanePlayheadX(forSource: sample) {
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
    if let sample = playhead(), let positionX = waveform.lanePlayheadX(forSource: sample) {
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
    var waveform: (any WaveformLaneDriving)?
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
      .accessibilityAction(named: Text("Reset")) { waveform.amplitudeZoomResetTapped() }
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
