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

  /// The dot / border / header color for a clip's own state (never the current-red treatment).
  static func clipState(_ state: ClipState) -> Color {
    switch state {
    case .approved: return .clipApproved
    case .suggested: return .clipSuggested
    case .rejected: return .clipRejected
    }
  }
}

/// The clip actions the transcript surface routes up to `EditorModel` (decision B: an
/// EditorModel-derived actions object, not a back-reference). Closures because the render data
/// is the Equatable part; these are just invoked.
struct TranscriptClipActions {
  var cardTapped: (EditorClip.ID) -> Void
  var railTapped: (EditorClip.ID) -> Void
  var play: (EditorClip.ID) -> Void
  var armAddStart: (EditorClip.ID) -> Void
  var armAddEnd: (EditorClip.ID) -> Void
  var wordPicked: (Word.ID) -> Void
  var gripBegan: () -> Void
  var gripStep: (ClipBoundaryEdit) -> Void
  var gripEnded: () -> Void
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

/// One clip card, lifted out of the transcript flow. All text/flags come from the `ClipCardVM`;
/// this view only maps state → color and lays out pixels.
struct ClipCardView: View {
  let card: ClipCardVM
  let actions: TranscriptClipActions

  private var stateColor: Color { .clipState(card.state) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ClipGripHandle(
        isTop: true, actions: actions,
        help: "Drag up to pull in earlier words")
      header
      Text(card.body)
        .font(.system(size: 16)).lineSpacing(6)
        .foregroundStyle(card.state == .rejected ? Color(white: 0.42) : Color(white: 0.87))
        .strikethrough(card.state == .rejected)
        .frame(maxWidth: .infinity, alignment: .leading)
      footer
      ClipGripHandle(
        isTop: false, actions: actions,
        help: "Drag down to pull in later words")
    }
    .padding(EdgeInsets(top: 12, leading: 14, bottom: 13, trailing: 14))
    .background(
      card.isCurrent ? Color.clipSelected.opacity(0.09) : Color(white: 0.075)
    )
    .overlay(alignment: .leading) {
      Rectangle().fill(stateColor).frame(width: 3)
    }
    .clipShape(RoundedRectangle(cornerRadius: 11))
    .overlay(border)
    .contentShape(Rectangle())
    .onTapGesture { actions.cardTapped(card.id) }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Circle().fill(stateColor).frame(width: 8, height: 8)
      Text(card.headerLine)
        .font(.system(size: 10.5, weight: .bold)).textCase(.uppercase).tracking(0.84)
        .foregroundStyle(stateColor)
      Spacer()
    }
  }

  private var footer: some View {
    HStack(spacing: 12) {
      Button("▸ Play clip") { actions.play(card.id) }
      Button(card.addStartLabel) { actions.armAddStart(card.id) }
        .foregroundStyle(card.isArmedStart ? Color.clipApproved : Color(white: 0.6))
      Button(card.addEndLabel) { actions.armAddEnd(card.id) }
        .foregroundStyle(card.isArmedEnd ? Color.clipApproved : Color(white: 0.6))
      Spacer()
      Text(card.footerHint)
        .font(.system(size: 11))
        .foregroundStyle(
          (card.isArmedStart || card.isArmedEnd) ? Color.clipApproved : Color(white: 0.4))
    }
    .buttonStyle(.plain).font(.system(size: 12))
  }

  @ViewBuilder fileprivate var border: some View {
    let color =
      card.isCurrent ? Color.clipSelected.opacity(0.5) : Color(white: 0.137)
    if card.state == .suggested {
      RoundedRectangle(cornerRadius: 11)
        .strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
    } else {
      RoundedRectangle(cornerRadius: 11).strokeBorder(color, lineWidth: 1)
    }
  }
}

/// A card-width vertical grab handle above/below a clip card. Dragging it steps the boundary a
/// whole word every ~16px (top → start, bottom → end), coalesced into one undo entry by the model's
/// begin/step/end funnel. TOP: up pulls earlier words in, down gives back. BOTTOM: down pulls later
/// words in, up gives back.
private struct ClipGripHandle: View {
  let isTop: Bool
  let actions: TranscriptClipActions
  let help: String
  @State private var hovering = false
  @State private var dragging = false
  @State private var appliedSteps = 0

  private static let pixelsPerWord: CGFloat = 16

  var body: some View {
    ZStack {
      Rectangle().fill(Color.clipApproved.opacity(0.22)).frame(height: 1)
      pill
    }
    .frame(maxWidth: .infinity)
    .frame(height: 14)
    .contentShape(Rectangle())
    .opacity(hovering || dragging ? 1 : 0.72)
    .onHover { hovering = $0 }
    .help(help)
    .gesture(drag)
  }

  private var pill: some View {
    HStack(spacing: 3) {
      Circle().frame(width: 3, height: 3)
      Circle().frame(width: 3, height: 3)
      Circle().frame(width: 3, height: 3)
      Image(systemName: isTop ? "chevron.up" : "chevron.down")
        .font(.system(size: 7, weight: .bold))
    }
    .foregroundStyle(Color.clipApproved)
    .padding(.horizontal, 8).padding(.vertical, 2)
    .background(Capsule().fill(Color.clipApproved.opacity(0.14)))
    .overlay(Capsule().stroke(Color.clipApproved.opacity(0.55), lineWidth: 1))
  }

  private var drag: some Gesture {
    DragGesture(minimumDistance: 2)
      .onChanged { value in
        if !dragging {
          dragging = true
          appliedSteps = 0
          actions.gripBegan()
        }
        let steps = Int((value.translation.height / Self.pixelsPerWord).rounded(.towardZero))
        while appliedSteps < steps {
          actions.gripStep(isTop ? .startLater : .endLater)
          appliedSteps += 1
        }
        while appliedSteps > steps {
          actions.gripStep(isTop ? .startEarlier : .endEarlier)
          appliedSteps -= 1
        }
      }
      .onEnded { _ in
        dragging = false
        appliedSteps = 0
        actions.gripEnded()
      }
  }
}
