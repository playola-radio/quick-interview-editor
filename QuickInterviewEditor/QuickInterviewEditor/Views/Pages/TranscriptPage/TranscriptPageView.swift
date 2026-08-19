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
        paragraphSpacing: model.paragraphSpacing,
        lineSpacing: model.lineSpacing,
        selected: model.selectedWordIDSet,
        clipContainers: model.clipContainers,
        removedWordIDs: model.removedWordIDs,
        currentWordID: model.currentWordID,
        scrollTarget: model.scrollTargetWordID,
        followMode: model.followMode,
        reveal: model.reveal
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    HStack(spacing: 14) {
      Text(model.transcriptCaption)
        .font(.system(size: 11, weight: .semibold)).tracking(1.5)
        .foregroundStyle(Color(white: 0.44))
      Spacer()
      speedControl
      zoomControls
    }
  }

  private var speedControl: some View {
    Menu {
      ForEach(model.speedMenuOptions) { option in
        Button {
          model.speedSelected(option.rate)
        } label: {
          if option.isCurrent {
            Label(option.label, systemImage: "checkmark")
          } else {
            Text(option.label)
          }
        }
      }
    } label: {
      Label(model.speedLabel, systemImage: "speedometer")
        .monospacedDigit()
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
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

}

#Preview("Clip containers") {
  let sentence =
    "When we tour on the bus they have a playlist compiled over the years but it is "
    + "always so fun because it is all cool whatever they play a big one for me when I "
    + "was young was Jimmy Buffett and he sang about a romantic life of sailing"
  let words = sentence.split(separator: " ").enumerated().map { index, text in
    Word(id: index + 1, text: String(text), start: 0, end: nil, startSample: nil, endSample: nil)
  }
  let model = TranscriptPageModel(planURL: nil)
  model.document = TranscriptDocument(words: words)
  model.clipBands = [
    // A green clip that wraps across a line, and an amber suggestion further down.
    TranscriptClipBand(id: UUID(), wordIDs: Array(1...14), kind: .approved),
    TranscriptClipBand(id: UUID(), wordIDs: Array(41...49), kind: .suggested),
  ]
  return TranscriptTextView(
    model: model,
    text: model.plainTranscriptText,
    fontSize: 17,
    paragraphSpacing: 12,
    lineSpacing: 12,
    // A red selection overlapping the green clip, to eyeball that it draws ON TOP of the fill.
    selected: Set([10, 11, 12]),
    clipContainers: model.clipContainers,
    removedWordIDs: [],
    // A "current word" highlight (light band) on word 30 to eyeball it against the fills.
    currentWordID: 30,
    scrollTarget: nil,
    followMode: .following,
    reveal: nil
  )
  .frame(width: 480, height: 340)
  .background(Color.black)
}
