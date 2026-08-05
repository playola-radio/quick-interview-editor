import SwiftUI

struct TranscriptPageView: View {
  @Bindable var model: TranscriptPageModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      TranscriptTextView(
        model: model,
        text: model.plainTranscriptText,
        fontSize: model.fontSize,
        selected: model.selectedWordIDSet,
        runTogether: model.runTogetherWordIDSet,
        scrollTarget: model.scrollTargetWordID,
        followMode: model.followMode
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      controls
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color.black)
    .background { zoomShortcuts }
    .task { await model.viewAppeared() }
  }

  private var zoomShortcuts: some View {
    // Hidden buttons carry the ⌘+/⌘-/⌘0 shortcuts without cluttering the UI. ⌘+ is
    // physically ⌘-shift-=, so zoom-in is bound to both "=" and "+".
    Group {
      Button("", action: model.zoomInTapped).keyboardShortcut("=", modifiers: .command)
      Button("", action: model.zoomInTapped).keyboardShortcut("+", modifiers: .command)
      Button("", action: model.zoomOutTapped).keyboardShortcut("-", modifiers: .command)
      Button("", action: model.zoomResetTapped).keyboardShortcut("0", modifiers: .command)
    }
    .opacity(0)
    .frame(width: 0, height: 0)
  }

  private var header: some View {
    HStack {
      Text(model.transcriptCaption)
        .font(.system(size: 11, weight: .semibold)).tracking(1.5)
        .foregroundStyle(Color(white: 0.44))
      Spacer()
      zoomControls
      Text(model.runTogetherLegend)
        .font(.system(size: 11)).foregroundStyle(Color(white: 0.48))
    }
  }

  private var zoomControls: some View {
    HStack(spacing: 6) {
      Button { model.zoomOutTapped() } label: { Image(systemName: "textformat.size.smaller") }
        .disabled(!model.canZoomOut)
      Slider(
        value: Binding(get: { model.fontSize }, set: { model.zoomChanged($0) }),
        in: model.minFontSize...model.maxFontSize
      )
      .frame(width: 120)
      Button { model.zoomInTapped() } label: { Image(systemName: "textformat.size.larger") }
        .disabled(!model.canZoomIn)
    }
    .buttonStyle(.borderless)
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
        value: Binding(get: { model.draftGapMs }, set: { model.sensitivityDragChanged($0) }),
        in: model.sensitivityMinMs...model.sensitivityMaxMs
      )
      .frame(width: 180)
    }
    .font(.system(size: 12))
  }
}

// Retained (unused) until Task 8 removes the eager word-chip layout. The transcript now
// renders via `TranscriptTextView`; this no longer participates in the view hierarchy.
struct FlowLayout: Layout {
  var spacing: CGFloat = 4
  var lineSpacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    var cursorX: CGFloat = 0
    var cursorY: CGFloat = 0
    var lineHeight: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if cursorX + size.width > maxWidth, cursorX > 0 {
        cursorX = 0
        cursorY += lineHeight + lineSpacing
        lineHeight = 0
      }
      cursorX += size.width + spacing
      lineHeight = max(lineHeight, size.height)
    }
    return CGSize(width: maxWidth == .infinity ? cursorX : maxWidth, height: cursorY + lineHeight)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var cursorX = bounds.minX
    var cursorY = bounds.minY
    var lineHeight: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if cursorX + size.width > bounds.maxX, cursorX > bounds.minX {
        cursorX = bounds.minX
        cursorY += lineHeight + lineSpacing
        lineHeight = 0
      }
      view.place(at: CGPoint(x: cursorX, y: cursorY), proposal: ProposedViewSize(size))
      cursorX += size.width + spacing
      lineHeight = max(lineHeight, size.height)
    }
  }
}
