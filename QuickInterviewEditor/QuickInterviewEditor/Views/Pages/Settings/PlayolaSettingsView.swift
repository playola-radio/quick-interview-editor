import SwiftUI

struct PlayolaSettingsView: View {
  let model: PlayolaSettingsModel

  var body: some View {
    Form {
      Section {
        LabeledContent(model.accountRowLabel) {
          VStack(alignment: .trailing, spacing: 2) {
            Text(model.accountValue)
            if let detail = model.accountDetail {
              Text(detail)
                .font(.callout)
                .foregroundStyle(model.accountDetailIsError ? Color.red : Color.secondary)
            }
          }
        }
        if model.showsAccountButton {
          Button(model.accountButtonTitle) { Task { await model.accountButtonTapped() } }
            .keyboardShortcut(model.accountButtonIsProminent ? .defaultAction : nil)
        }
      } header: {
        Text(model.accountHeader)
      }
      if model.showsServerPicker {
        Section {
          Picker(
            model.serverLabel,
            selection: Binding(
              get: { model.selectedEnvironment },
              set: { environment in Task { await model.environmentPicked(environment) } })
          ) {
            ForEach(model.environments, id: \.self) { environment in
              Text(environment.label).tag(environment)
            }
          }
          Text(model.serverHelp)
            .font(.callout)
            .foregroundStyle(.secondary)
        } header: {
          Text(model.serverHeader)
        }
      }
    }
    .padding()
    .frame(width: 460)
  }
}
