import SwiftUI

/// The read-only waveform band under the transcript. Binds entirely to model output and
/// forwards taps/zoom to the model — it decides nothing. The waveform strokes and overlays
/// live in ``WaveformCanvas``; the moving playhead is a separate layer so its frequent
/// updates never invalidate the canvas.
struct WaveformView: View {
  @Bindable var model: EditorModel

  private let bandHeight: CGFloat = 148

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      ZStack(alignment: .leading) {
        Color(white: 0.024)
        content
      }
      .frame(height: bandHeight)
      .clipShape(RoundedRectangle(cornerRadius: 4))
      .contentShape(Rectangle())
      .onTapGesture(coordinateSpace: .local) { model.waveformTapped(atX: $0.x) }
      .onGeometryChange(for: CGFloat.self) {
        $0.size.width
      } action: {
        model.waveform.viewportResized(width: $0)
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
    .background(Color.black)
  }

  private var header: some View {
    HStack(spacing: 12) {
      Text(model.waveform.caption)
        .font(.system(size: 11, weight: .semibold)).tracking(1.5)
        .foregroundStyle(Color(white: 0.44))
      Spacer()
      Button {
        model.waveform.zoomOutTapped()
      } label: {
        Image(systemName: "minus.magnifyingglass")
      }
      .disabled(!model.waveform.canZoomOut)
      .help(model.waveform.zoomOutLabel)
      Button {
        model.waveform.zoomInTapped()
      } label: {
        Image(systemName: "plus.magnifyingglass")
      }
      .disabled(!model.waveform.canZoomIn)
      .help(model.waveform.zoomInLabel)
    }
    .buttonStyle(.borderless)
    .foregroundStyle(Color(white: 0.6))
  }

  @ViewBuilder private var content: some View {
    if model.waveform.showsLoading {
      centeredMessage(model.waveform.loadingMessage)
    } else if model.waveform.showsEmpty {
      centeredMessage(model.waveform.emptyMessage)
    } else {
      ZStack(alignment: .leading) {
        WaveformCanvas(model: model)
        WaveformPlayhead(model: model)
      }
    }
  }

  private func centeredMessage(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 12)).foregroundStyle(Color(white: 0.4))
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Draws the min/max columns plus the highlight and red overlays. Reads only geometry +
/// selection state (never the playhead), so playhead ticks don't force it to redraw.
private struct WaveformCanvas: View {
  let model: EditorModel

  private let waveColor = Color(white: 0.62)
  private let highlightColor = Color.white.opacity(0.14)
  private let redColor = Color(red: 0.8, green: 0.4, blue: 0.4)

  var body: some View {
    // Read observed model output here so SwiftUI re-renders on change; the Canvas
    // closure then draws the captured values.
    let columns = model.waveform.visibleColumns()
    let highlight = model.waveformHighlightSpan
    let reds = model.waveformRedSpans
    Canvas { context, size in
      let midY = size.height / 2
      let scale = size.height / 2 * 0.9
      if let highlight {
        context.fill(
          Path(CGRect(x: highlight.positionX, y: 0, width: highlight.width, height: size.height)),
          with: .color(highlightColor))
      }
      for red in reds {
        context.fill(
          Path(CGRect(x: red.positionX, y: 0, width: red.width, height: size.height)),
          with: .color(redColor.opacity(0.28)))
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

/// The playback playhead, isolated in its own view so it redraws without touching the
/// waveform canvas.
private struct WaveformPlayhead: View {
  let model: EditorModel

  var body: some View {
    if let positionX = model.waveform.playheadX {
      Rectangle()
        .fill(Color(red: 0.96, green: 0.86, blue: 0.4))
        .frame(width: 1.5)
        .frame(maxHeight: .infinity)
        .offset(x: positionX)
    }
  }
}
