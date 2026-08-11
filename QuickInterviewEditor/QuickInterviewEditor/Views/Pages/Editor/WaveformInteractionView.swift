import AppKit
import SwiftUI

/// A transparent AppKit layer over the waveform `Canvas`. It owns all waveform mouse
/// input — scroll (zoom/pan), click (select / Shift-extend), and drag (pan) — and forwards
/// only raw facts to `EditorModel`. The `Canvas` beneath stays a pure renderer.
struct WaveformInteractionLayer: NSViewRepresentable {
  let model: EditorModel

  func makeNSView(context: Context) -> InteractionView {
    let view = InteractionView()
    view.model = model
    return view
  }

  func updateNSView(_ nsView: InteractionView, context: Context) {
    nsView.model = model
  }

  final class InteractionView: NSView {
    var model: EditorModel?
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
      let dx = localX(event) - start
      if !didDrag {
        guard abs(dx) >= dragThreshold else { return }
        didDrag = true
        model?.waveform.dragScrollBegan()
      }
      model?.waveform.dragScrolled(byPixels: dx)
    }

    override func mouseUp(with event: NSEvent) {
      if !didDrag, let start = dragStartX {
        model?.waveformClicked(atX: start, extending: event.modifierFlags.contains(.shift))
      }
      dragStartX = nil
      didDrag = false
    }

    override func scrollWheel(with event: NSEvent) {
      let flags = event.modifierFlags
      model?.waveformScrolled(
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
