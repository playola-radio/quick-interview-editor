import SwiftUI

struct TranscriptPageView: View {
  @Bindable var model: TranscriptPageModel
  /// EditorModel-derived clip render data + actions (decision B: passed in, not a back-reference).
  let blocks: [ClipBlockVM]
  let rail: [ClipMapSegment]
  let counts: String
  let footer: CurrentClipFooterVM?
  let clipActions: TranscriptBlockActions

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      if !rail.isEmpty {
        ClipMapRailView(segments: rail, counts: counts, onSegmentTapped: clipActions.railTapped)
      }
      TranscriptTextView(
        model: model,
        text: model.plainTranscriptText,
        fontSize: model.fontSize,
        paragraphSpacing: model.paragraphSpacing,
        lineHeightMultiple: model.lineHeightMultiple,
        selected: model.selectedWordIDSet,
        scrollTarget: model.scrollTargetWordID,
        followMode: model.followMode,
        reveal: model.reveal,
        blocks: blocks,
        clipsOnly: model.clipsOnly,
        blockActions: clipActions
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      if let footer {
        CurrentClipFooterView(footer: footer)
      }
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
    HStack(spacing: 12) {
      Text(model.transcriptCaption)
        .font(.system(size: 11, weight: .semibold)).tracking(1.5)
        .foregroundStyle(Color(white: 0.44))
      Picker(model.clipFilterPickerLabel, selection: $model.clipFilter) {
        ForEach(model.clipFilters) { filter in
          Text(filter.label).tag(filter)
        }
      }
      .pickerStyle(.segmented).labelsHidden().fixedSize()
      Toggle(model.clipsOnlyLabel, isOn: $model.clipsOnly)
        .toggleStyle(.checkbox).font(.system(size: 11))
      Spacer()
      zoomControls
    }
  }

  private var zoomControls: some View {
    HStack(spacing: 6) {
      Button {
        model.zoomOutTapped()
      } label: {
        Image(systemName: "textformat.size.smaller")
      }
      .disabled(!model.canZoomOut)
      Slider(
        value: Binding(get: { model.fontSize }, set: { model.zoomChanged($0) }),
        in: model.minFontSize...model.maxFontSize
      )
      .frame(width: 120)
      Button {
        model.zoomInTapped()
      } label: {
        Image(systemName: "textformat.size.larger")
      }
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
    }
    .font(.system(size: 12))
  }
}
