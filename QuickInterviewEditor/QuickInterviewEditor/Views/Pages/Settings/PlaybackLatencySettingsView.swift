import SwiftUI

/// The "Playback Latency" settings tab. Device name + auto estimate are read-only; the slider
/// nudges this device's manual offset. No logic here — all copy/bounds/enablement come from the model.
struct PlaybackLatencySettingsView: View {
  @Bindable var model: PlaybackLatencySettingsModel

  var body: some View {
    Form {
      Section {
        Text(model.helpText)
          .font(.callout)
          .foregroundStyle(.secondary)
        Text(model.deviceLabel)
        Text(model.autoEstimateLabel)
          .foregroundStyle(.secondary)
        LabeledContent(model.offsetSliderLabel) {
          HStack {
            Slider(
              value: Binding(get: { model.offsetMs }, set: { model.offsetChanged($0) }),
              in: model.minMs...model.maxMs, step: 1)
            Text(model.offsetLabel)
              .monospacedDigit()
              .frame(width: 96, alignment: .trailing)
          }
        }
        Button(model.resetLabel) { model.resetTapped() }
          .disabled(!model.canReset)
      } header: {
        Text(model.sectionHeader)
      }
    }
    .padding()
    .frame(width: 460)
    .onAppear { model.viewAppeared() }
  }
}
