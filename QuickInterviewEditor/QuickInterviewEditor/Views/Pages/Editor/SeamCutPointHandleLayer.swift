import AppKit
import SwiftUI

/// Claims ⌥-drags in the OUTSIDE zones flanking each bowtie — left of `leadingHandleX`
/// (moves the left cut `cL`) and right of `trailingHandleX` (moves the right cut `cR`) — to move that
/// removal's cut point without changing the fade length. Sits ABOVE `SeamStretchHandleLayer`, but
/// claims ONLY ⌥-modified hits (read via `NSEvent.modifierFlags` in `hitTest`, i.e. at mouse-down),
/// so a plain drag on a bowtie edge still stretches length and every non-⌥ mouse-down falls through.
/// Auto-selects the seam on drag-begin (a ⌥-click with no drag just selects). Mirrors the
/// stretch layer's draft→preview→commit gesture handling.
struct SeamCutPointHandleLayer: NSViewRepresentable {
  let seams: [SeamOverlay]
  let waveform: any WaveformLaneDriving
  let onDragBegan: (UUID, RemovalBoundary, CGFloat) -> Void
  let onDragged: (CGFloat) -> Void
  let onDragEnded: () -> Void
  let onDragCancelled: () -> Void
  let onSelect: (UUID) -> Void

  func makeNSView(context: Context) -> HandleView {
    let view = HandleView()
    apply(to: view)
    return view
  }

  func updateNSView(_ nsView: HandleView, context: Context) { apply(to: nsView) }

  private func apply(to view: HandleView) {
    view.seams = seams
    view.waveform = waveform
    view.onDragBegan = onDragBegan
    view.onDragged = onDragged
    view.onDragEnded = onDragEnded
    view.onDragCancelled = onDragCancelled
    view.onSelect = onSelect
  }

  final class HandleView: NSView {
    var seams: [SeamOverlay] = []
    var waveform: (any WaveformLaneDriving)?
    var onDragBegan: ((UUID, RemovalBoundary, CGFloat) -> Void)?
    var onDragged: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    var onDragCancelled: (() -> Void)?
    var onSelect: ((UUID) -> Void)?

    /// Width of the outside grab zone flanking each bowtie edge for an UNSELECTED seam — just enough to
    /// bootstrap the first ⌥-grab (which auto-selects). Once a seam is selected its zones expand to the
    /// whole outside region (see `zone(nearestToX:)`): a ⌥-drag has no competing gesture on the waveform
    /// body, so a huge target is safe and makes trimming the selected crossfade's cuts effortless.
    private let zoneWidth: CGFloat = 32
    /// Minimum travel before a grab becomes a drag, so a ⌥-click never opens a draft / no-op undo.
    private let dragThreshold: CGFloat = 6
    private var active: (id: UUID, edge: RemovalBoundary)?
    private var downX: CGFloat?
    private var didDrag = false

    override var acceptsFirstResponder: Bool { false }

    /// Claim only ⌥-modified hits landing in an outside zone. `NSEvent.modifierFlags` reads the
    /// CURRENT flags — at mouse-down routing time — so the modifier is captured once at press; a
    /// non-⌥ mouse-down returns nil and falls through to the stretch/marquee layers beneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
      guard NSEvent.modifierFlags.contains(.option) else { return nil }
      let local = convert(point, from: superview)
      guard bounds.contains(local) else { return nil }
      return zone(nearestToX: local.x) != nil ? self : nil
    }

    /// The outside zone whose bowtie edge is nearest `x`: left of a seam's `leadingHandleX` moves
    /// `cL` (`.lower`), right of its `trailingHandleX` moves `cR` (`.upper`). A SELECTED seam's zones
    /// span the whole outside region (`bounds` edge → handle) so its cuts grab from anywhere on the
    /// correct side; an unselected seam keeps the narrow `zoneWidth` flank that bootstraps selection.
    /// Ties break to the nearest bowtie edge, so a huge selected-seam zone never steals a grab that
    /// lands right on another seam's flank. Nil when no zone covers `x`; off-screen handles are skipped.
    private func zone(nearestToX posX: CGFloat) -> (id: UUID, edge: RemovalBoundary)? {
      var best: (target: (id: UUID, edge: RemovalBoundary), distance: CGFloat)?
      for seam in seams {
        if let lead = seam.leadingHandleX {
          let leftEdge = seam.isSelected ? bounds.minX : lead - zoneWidth
          if posX >= leftEdge, posX < lead {
            let distance = lead - posX
            if best == nil || distance < best!.distance { best = ((seam.id, .lower), distance) }
          }
        }
        if let trail = seam.trailingHandleX {
          let rightEdge = seam.isSelected ? bounds.maxX : trail + zoneWidth
          if posX > trail, posX <= rightEdge {
            let distance = posX - trail
            if best == nil || distance < best!.distance { best = ((seam.id, .upper), distance) }
          }
        }
      }
      return best?.target
    }

    private func localX(_ event: NSEvent) -> CGFloat {
      convert(event.locationInWindow, from: nil).x
    }

    override func mouseDown(with event: NSEvent) {
      let posX = localX(event)
      active = zone(nearestToX: posX)
      downX = posX
      didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
      guard let active, let downX else { return }
      let currentX = localX(event)
      if !didDrag {
        guard abs(currentX - downX) >= dragThreshold else { return }
        didDrag = true
        onDragBegan?(active.id, active.edge, downX)  // seed drag math from the press position
      }
      onDragged?(currentX)
    }

    override func mouseUp(with event: NSEvent) {
      if didDrag {
        onDragEnded?()
      } else if let active {
        // A ⌥-click that never crossed the threshold selects the seam without seeking.
        onSelect?(active.id)
      }
      active = nil
      downX = nil
      didDrag = false
    }

    /// Torn down mid-drag (sheet dismissed, tab switched, lane removed): mouse-up never arrives, so
    /// cancel to avoid stranding the preview timeline + stale draft.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
      super.viewWillMove(toWindow: newWindow)
      if newWindow == nil, didDrag {
        onDragCancelled?()
        active = nil
        downX = nil
        didDrag = false
      }
    }

    /// Forward ⌘-scroll zoom / plain-scroll pan through, exactly like the stretch layer, so the grab
    /// zones don't swallow the gesture.
    override func scrollWheel(with event: NSEvent) {
      let flags = event.modifierFlags
      waveform?.scrolled(
        deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
        hasPreciseDeltas: event.hasPreciseScrollingDeltas,
        optionDown: flags.contains(.option), commandDown: flags.contains(.command),
        atX: localX(event))
    }
  }
}
