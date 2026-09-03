import SwiftUI

/// Two buttons pinned to the highlighted region's edges. Labels (and their keys) and active state
/// come from the caller; this view only positions the buttons and clamps so they don't overlap on
/// a narrow span.
struct AuditionEdgeButtons: View {
  let span: WaveformSpan
  let inLabel: String
  let outLabel: String
  let isInActive: Bool
  let isOutActive: Bool
  let onIn: () -> Void
  let onOut: () -> Void

  private let buttonWidth: CGFloat = 74
  private let gap: CGFloat = 4

  var body: some View {
    GeometryReader { geo in
      let width = geo.size.width
      // In on the left edge, Out on the right edge; keep both within the band and never
      // overlapping — a narrow or right-clipped span collapses them to a side-by-side pair.
      let maxLeft = max(0, width - (buttonWidth * 2 + gap))
      let left = min(max(0, span.positionX), maxLeft)
      let rightIdeal = span.positionX + span.width - buttonWidth
      let right = min(max(rightIdeal, left + buttonWidth + gap), max(0, width - buttonWidth))
      ZStack(alignment: .topLeading) {
        button(inLabel, active: isInActive, action: onIn)
          .offset(x: left, y: 8)
        button(outLabel, active: isOutActive, action: onOut)
          .offset(x: right, y: 8)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  private func button(_ label: String, active: Bool, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Text(label)
        .font(.system(size: 11, weight: .semibold))
        .frame(width: buttonWidth)
        .padding(.vertical, 3)
    }
    .buttonStyle(.borderless)
    .background(
      RoundedRectangle(cornerRadius: 4)
        .fill(
          active
            ? Color(red: 0.96, green: 0.86, blue: 0.4).opacity(0.28)
            : Color.white.opacity(0.12))
    )
    .foregroundStyle(active ? Color(red: 0.96, green: 0.86, blue: 0.4) : Color(white: 0.85))
  }
}
