import SwiftUI

/// One magnified boundary inset: silhouette, safe-zone shading, kept/discarded fill, a
/// draggable cut line, and ±10 ms nudges. Takes only concrete values + closures, so it holds
/// no logic and doesn't know which boundary it renders. Shared by ``FineTuneView`` (the
/// dormant in-editor pane) and ``EditSliceView`` (the slice-detail sheet).
struct BoundaryInset: View {
  let label: String
  let timeLabel: String
  let width: CGFloat
  let columns: [WaveformColumn]
  let safeZones: [WaveformSpan]
  let keptSpan: WaveformSpan?
  let discardedSpan: WaveformSpan?
  let lineX: CGFloat?
  let nudgeBackLabel: String
  let nudgeForwardLabel: String
  let onNudgeBack: () -> Void
  let onNudgeForward: () -> Void
  let onDrag: (CGFloat) -> Void

  private let boxHeight: CGFloat = 86
  private let cutLineHandle: CGFloat = 9
  private let waveColor = Color(white: 0.42)
  private let keptColor = Color(red: 0.8, green: 0.4, blue: 0.4)
  private let safeColor = Color(red: 0.96, green: 0.86, blue: 0.4)

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(label)
          .font(.system(size: 10.5, weight: .semibold)).tracking(0.8)
          .foregroundStyle(Color(white: 0.48))
        Spacer()
        Text(timeLabel)
          .font(.system(size: 11).monospacedDigit())
          .foregroundStyle(keptColor)
      }
      .frame(width: width)
      ZStack(alignment: .leading) {
        Color(white: 0.03)
        ForEach(Array(safeZones.enumerated()), id: \.offset) { _, zone in
          Rectangle().fill(safeColor.opacity(0.10))
            .frame(width: zone.width, height: boxHeight).offset(x: zone.positionX)
        }
        InsetSilhouette(
          columns: columns, keptSpan: keptSpan, waveColor: waveColor, keptColor: keptColor)
        if let discardedSpan {
          Rectangle().fill(Color.black.opacity(0.45))
            .frame(width: discardedSpan.width, height: boxHeight).offset(x: discardedSpan.positionX)
        }
        Rectangle().fill(Color(white: 0.16)).frame(width: 1, height: boxHeight)
          .offset(x: width / 2)
        if let lineX {
          // The handle is `cutLineHandle` wide and centered in its ZStack, so shift left by half
          // its width to sit the visible line exactly on the boundary rather than 4.5pt right.
          CutLine(handleSize: cutLineHandle).offset(x: lineX - cutLineHandle / 2)
        }
      }
      .frame(width: width, height: boxHeight)
      .clipShape(RoundedRectangle(cornerRadius: 7))
      .overlay(
        RoundedRectangle(cornerRadius: 7)
          .stroke(Color(white: 0.11), lineWidth: 1)
      )
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
          .onChanged { onDrag($0.location.x) }
      )
      HStack(spacing: 6) {
        Button(nudgeBackLabel) { onNudgeBack() }
        Button(nudgeForwardLabel) { onNudgeForward() }
      }
      .font(.system(size: 11)).buttonStyle(.borderless)
      .foregroundStyle(Color(white: 0.7))
    }
  }
}

/// The mirrored min/max silhouette, gray with the kept side tinted red. Also reused
/// standalone (no `keptSpan`) as the edge-to-edge overview band in ``EditSliceView``.
struct InsetSilhouette: View {
  let columns: [WaveformColumn]
  let keptSpan: WaveformSpan?
  let waveColor: Color
  let keptColor: Color

  var body: some View {
    Canvas { context, size in
      let midY = size.height / 2
      let scale = size.height / 2 * 0.9
      var path = Path()
      for column in columns {
        let top = midY - CGFloat(column.max) * scale
        let bottom = midY - CGFloat(column.min) * scale
        path.move(to: CGPoint(x: column.positionX + 0.5, y: top))
        path.addLine(to: CGPoint(x: column.positionX + 0.5, y: Swift.max(bottom, top + 0.75)))
      }
      context.stroke(path, with: .color(waveColor), lineWidth: 1)
      if let keptSpan {
        let clip = CGRect(x: keptSpan.positionX, y: 0, width: keptSpan.width, height: size.height)
        context.clip(to: Path(clip))
        context.stroke(path, with: .color(keptColor), lineWidth: 1)
      }
    }
  }
}

/// The draggable white cut line with a red-ringed handle dot. `handleSize` is the dot diameter,
/// which sets the view's width; the caller shifts by half of it to center the line on the cut.
private struct CutLine: View {
  let handleSize: CGFloat

  var body: some View {
    ZStack(alignment: .top) {
      Rectangle().fill(Color.white).frame(width: 2)
      Circle().fill(Color.white)
        .frame(width: handleSize, height: handleSize)
        .overlay(Circle().stroke(Color(red: 0.8, green: 0.4, blue: 0.4), lineWidth: 2))
        .offset(y: -2)
    }
    .frame(maxHeight: .infinity)
  }
}
