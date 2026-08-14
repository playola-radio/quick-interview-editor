import SwiftUI

/// The clip-state colors from the spec. Color is the ONLY thing the view decides — the model
/// hands it a `ClipState` + currentness, and this maps state → the exact hex value.
extension Color {
  /// #cc6666 — the brand red used for the current/selected clip treatment.
  static let clipSelected = Color(red: 0.8, green: 0.4, blue: 0.4)
  /// #5fb98f — approved (will export).
  static let clipApproved = Color(red: 0.373, green: 0.725, blue: 0.561)
  /// #d0a45f — suggested (undecided).
  static let clipSuggested = Color(red: 0.816, green: 0.643, blue: 0.373)
  /// #4a4a4a — rejected (dimmed + struck).
  static let clipRejected = Color(white: 0.29)

  /// The dot / rail / footer color for a clip's own state (never the current-red treatment).
  static func clipState(_ state: ClipState) -> Color {
    switch state {
    case .approved: return .clipApproved
    case .suggested: return .clipSuggested
    case .rejected: return .clipRejected
    }
  }
}

/// The clip gestures the transcript surface routes up to `EditorModel` (decision B: an
/// EditorModel-derived actions object passed in, not a back-reference). Closures because the
/// render data (`ClipBlockVM`) is the Equatable part; these are just invoked.
struct TranscriptBlockActions {
  /// A rail segment (or a bare click on a clip's end word) selects that clip.
  var railTapped: (EditorClip.ID) -> Void
  var select: (EditorClip.ID) -> Void
  /// A plain click on a word inside a clip (focus it, or pull the nearer boundary if current).
  var interiorClicked: (EditorClip.ID, Word.ID) -> Void
  /// The block edge-drag: grab a clip's first/last word, drag to the nearest word, release.
  var boundaryDragBegan: (EditorClip.ID, SliceEdge) -> Void
  var boundaryDragged: (Word.ID) -> Void
  var boundaryDragEnded: () -> Void
  var boundaryDragCancelled: () -> Void
}

/// The full-width clip-map rail above the transcript: one clickable band per clip in its state
/// color (the current clip gets the red ring), with the `N approved · N suggested · N rejected`
/// summary beside it.
struct ClipMapRailView: View {
  let segments: [ClipMapSegment]
  let counts: String
  let onSegmentTapped: (EditorClip.ID) -> Void

  var body: some View {
    HStack(spacing: 12) {
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.07))
          ForEach(segments) { segment in
            RoundedRectangle(cornerRadius: 3)
              .fill(Color.clipState(segment.state))
              .frame(width: max(2, geo.size.width * segment.widthFraction))
              .overlay(
                RoundedRectangle(cornerRadius: 3)
                  .stroke(Color.clipSelected, lineWidth: segment.isCurrent ? 2 : 0)
              )
              .offset(x: geo.size.width * segment.startFraction)
              .onTapGesture { onSegmentTapped(segment.id) }
          }
        }
      }
      .frame(height: 24)
      Text(counts)
        .font(.system(size: 11)).foregroundStyle(Color(white: 0.5))
        .fixedSize().lineLimit(1)
    }
  }
}

/// The transcript footer: the current clip's state dot, its `N · Title · duration · word count`
/// line, and a live hint on the right. Hidden by the caller when no clip is current.
struct CurrentClipFooterView: View {
  let footer: CurrentClipFooterVM

  var body: some View {
    HStack(spacing: 10) {
      RoundedRectangle(cornerRadius: 2)
        .fill(Color.clipState(footer.state))
        .frame(width: 8, height: 8)
      Text(footer.line)
        .font(.system(size: 11, weight: .bold)).textCase(.uppercase).tracking(0.7)
        .foregroundStyle(Color.clipState(footer.state))
        .lineLimit(1)
      Spacer(minLength: 12)
      Text(footer.hint)
        .font(.system(size: 11)).foregroundStyle(Color(white: 0.34))
        .lineLimit(1)
    }
  }
}
