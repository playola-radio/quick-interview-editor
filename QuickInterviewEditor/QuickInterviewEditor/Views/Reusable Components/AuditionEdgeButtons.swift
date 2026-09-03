import SwiftUI

/// Two buttons pinned to the highlighted region's edges. Titles, hotkeys, and active state come
/// from the caller; this view only positions the buttons and clamps so they don't overlap on a
/// narrow span. Each hotkey renders as a keycap chip (a small bordered square, like a menu
/// shortcut) on the side facing the cut it plays toward, so it reads as "press this key".
struct AuditionEdgeButtons: View {
  let span: WaveformSpan
  let inTitle: String
  let inHotkey: String
  let outTitle: String
  let outHotkey: String
  let isInActive: Bool
  let isOutActive: Bool
  let onIn: () -> Void
  let onOut: () -> Void

  private let buttonWidth: CGFloat = 74
  private let gap: CGFloat = 4
  private let activeYellow = Color(red: 0.96, green: 0.86, blue: 0.4)

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
        button(
          title: inTitle, hotkey: inHotkey, keycapEdge: .trailing, active: isInActive,
          action: onIn
        )
        .offset(x: left, y: 8)
        button(
          title: outTitle, hotkey: outHotkey, keycapEdge: .leading, active: isOutActive,
          action: onOut
        )
        .offset(x: right, y: 8)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  private func button(
    title: String, hotkey: String, keycapEdge: HorizontalEdge, active: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 5) {
        if keycapEdge == .leading { keycap(hotkey, active: active) }
        Text(title)
          .font(.system(size: 11, weight: .semibold))
        if keycapEdge == .trailing { keycap(hotkey, active: active) }
      }
      .frame(width: buttonWidth)
      .padding(.vertical, 3)
    }
    .buttonStyle(.borderless)
    .background(
      RoundedRectangle(cornerRadius: 4)
        .fill(active ? activeYellow.opacity(0.28) : Color.white.opacity(0.12))
    )
    .foregroundStyle(active ? activeYellow : Color(white: 0.85))
  }

  private func keycap(_ key: String, active: Bool) -> some View {
    Text(key)
      .font(.system(size: 10, weight: .bold, design: .monospaced))
      .frame(width: 15, height: 15)
      .background(
        RoundedRectangle(cornerRadius: 3.5)
          .fill(Color.black.opacity(active ? 0.25 : 0.35))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 3.5)
          .strokeBorder(
            active ? activeYellow.opacity(0.7) : Color.white.opacity(0.4), lineWidth: 1)
      )
  }
}
