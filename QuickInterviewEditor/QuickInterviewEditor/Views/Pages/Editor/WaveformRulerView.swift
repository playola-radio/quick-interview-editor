import AppKit
import SwiftUI

/// A thin Logic-style ruler strip above the waveform body. Clicking or dragging anywhere in it
/// positions the persistent playhead (Logic parity: a ruler click sets the play position); the
/// waveform body below keeps its own word/region selection because the ruler owns a *separate*
/// interaction layer. All decisions live on the model — this view only binds to its output and
/// forwards raw gesture x. (v1 divergence from Logic: a ruler interaction during playback stops and
/// repositions rather than scrubbing the audio; cycle/loop has no strip region here.)
struct WaveformRulerView: View {
  let model: EditorModel

  private let stripHeight: CGFloat = 18

  var body: some View {
    ZStack(alignment: .leading) {
      Color(white: 0.1)
      RulerPlayhead(model: model)
    }
    .frame(maxWidth: .infinity)
    .frame(height: stripHeight)
    .clipShape(RoundedRectangle(cornerRadius: 3))
    .overlay(
      RoundedRectangle(cornerRadius: 3).stroke(Color(white: 0.18), lineWidth: 1)
    )
    .overlay(WaveformRulerInteractionLayer(model: model))
  }
}

/// The playhead marker inside the ruler, isolated in its own view so its ~30 Hz updates during
/// playback don't invalidate the strip background or the interaction layer. Reads the same cursor
/// geometry as the body's playhead, so the two read as one continuous line.
private struct RulerPlayhead: View {
  let model: EditorModel

  var body: some View {
    if let positionX = model.playheadX {
      Rectangle()
        .fill(Color(red: 0.96, green: 0.86, blue: 0.4))
        .frame(width: 1.5)
        .frame(maxHeight: .infinity)
        .offset(x: positionX)
    }
  }
}

/// A transparent AppKit layer over the ruler strip. Sibling to `WaveformInteractionLayer` (the body
/// layer): it claims the strip's points and forwards raw gesture x to the model, which maps x → plan
/// sample and moves the playhead. Click and drag are identical — both position the cursor — so
/// `mouseDown` and `mouseDragged` route to the same action. Scroll is forwarded to the shared
/// zoom/pan handler so the gesture stays continuous across the strip and the body.
struct WaveformRulerInteractionLayer: NSViewRepresentable {
  let model: EditorModel

  func makeNSView(context: Context) -> RulerView {
    let view = RulerView()
    view.model = model
    return view
  }

  func updateNSView(_ nsView: RulerView, context: Context) {
    nsView.model = model
  }

  final class RulerView: NSView {
    var model: EditorModel?

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
      model?.rulerMovedPlayhead(toX: localX(event))
    }

    override func mouseDragged(with event: NSEvent) {
      model?.rulerMovedPlayhead(toX: localX(event))
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
