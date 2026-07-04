import SwiftUI

struct TranscriptPageView: View {
  @Bindable var model: TranscriptPageModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      transcriptFlow
      Spacer()
      controls
    }
    .padding(20)
    .frame(minWidth: 900, minHeight: 600, alignment: .topLeading)
    .background(Color.black)
    .task { await model.viewAppeared() }
  }

  private var header: some View {
    HStack {
      Text(model.transcriptCaption)
        .font(.system(size: 11, weight: .semibold)).tracking(1.5)
        .foregroundStyle(Color(white: 0.44))
      Spacer()
      Text(model.runTogetherLegend)
        .font(.system(size: 11)).foregroundStyle(Color(white: 0.48))
    }
  }

  private var transcriptFlow: some View {
    // Simple wrapping layout of tappable word chips.
    FlowLayout(spacing: 4, lineSpacing: 8) {
      ForEach(model.words) { word in
        Text(word.text)
          .font(.system(size: 17))
          .foregroundStyle(color(for: word))
          .padding(.horizontal, 3).padding(.vertical, 1)
          .background(word.isSelected ? Color(red: 0.80, green: 0.40, blue: 0.40).opacity(0.30) : .clear)
          .clipShape(RoundedRectangle(cornerRadius: 3))
          .onTapGesture { model.wordTapped(word.id) }
      }
    }
  }

  // Color is data on the model, not a view decision: selected > run-together > default.
  private func color(for word: WordViewState) -> Color {
    if word.isSelected { return .white }
    if word.isRunTogether { return Color(red: 0.89, green: 0.58, blue: 0.58) }
    return Color(white: 0.56)
  }

  private var controls: some View {
    HStack(spacing: 16) {
      Button(model.clearButtonLabel) { model.clearSelectionTapped() }
        .disabled(!model.hasSelection)
      Text(model.selectionSummary).foregroundStyle(Color(white: 0.6))
      Spacer()
      Text(model.runTogetherCountLabel).foregroundStyle(Color(white: 0.6))
      Text(model.sensitivityLabel).foregroundStyle(Color(white: 0.6))
      Slider(
        value: Binding(
          get: { model.runTogetherMaxGapMs },
          set: { model.sensitivityChanged($0) }
        ),
        in: model.sensitivityMinMs...model.sensitivityMaxMs
      )
      .frame(width: 180)
    }
    .font(.system(size: 12))
  }
}

struct FlowLayout: Layout {
  var spacing: CGFloat = 4
  var lineSpacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
    for view in subviews {
      let s = view.sizeThatFits(.unspecified)
      if x + s.width > maxWidth, x > 0 { x = 0; y += lineHeight + lineSpacing; lineHeight = 0 }
      x += s.width + spacing
      lineHeight = max(lineHeight, s.height)
    }
    return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + lineHeight)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
    for view in subviews {
      let s = view.sizeThatFits(.unspecified)
      if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += lineHeight + lineSpacing; lineHeight = 0 }
      view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
      x += s.width + spacing
      lineHeight = max(lineHeight, s.height)
    }
  }
}
