import SwiftUI

/// The "Editing" settings tab: two sliders nudging where a NEW clip's cut points land.
/// All copy, bounds, and enablement come from the model; the view only lays out and binds.
struct ClipBoundarySettingsView: View {
  @Bindable var model: ClipBoundarySettingsModel

  var body: some View {
    Form {
      Section {
        Text(model.helpText)
          .font(.callout)
          .foregroundStyle(.secondary)
        LabeledContent(model.startSliderLabel) {
          HStack {
            Slider(
              value: Binding(get: { model.startOffsetMs }, set: { model.startOffsetChanged($0) }),
              in: model.minMs...model.maxMs, step: 1
            )
            Text(model.startOffsetLabel)
              .monospacedDigit()
              .frame(width: 64, alignment: .trailing)
          }
        }
        LabeledContent(model.endSliderLabel) {
          HStack {
            Slider(
              value: Binding(get: { model.endOffsetMs }, set: { model.endOffsetChanged($0) }),
              in: model.minMs...model.maxMs, step: 1
            )
            Text(model.endOffsetLabel)
              .monospacedDigit()
              .frame(width: 64, alignment: .trailing)
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
  }
}
