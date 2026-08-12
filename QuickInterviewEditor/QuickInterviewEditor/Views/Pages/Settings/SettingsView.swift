import SwiftUI

/// API-key entry, shared by the Settings scene and the cut-suggester onboarding sheet.
/// All copy and enablement come from the model; the view only lays out and binds.
struct SettingsView: View {
  @Bindable var model: SettingsModel

  var body: some View {
    Form {
      Section {
        Text(model.helpText)
          .font(.callout)
          .foregroundStyle(.secondary)
        Link(model.getKeyLinkLabel, destination: model.getKeyURL)
        SecureField(
          model.fieldLabel, text: $model.apiKeyDraft, prompt: Text(model.fieldPrompt)
        )
        .textFieldStyle(.roundedBorder)
        Text(model.storedKeyStatus)
          .font(.caption)
          .foregroundStyle(.secondary)
        if let statusMessage = model.statusMessage {
          Text(statusMessage)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        HStack {
          Button(model.saveLabel) { model.saveTapped() }
            .disabled(!model.canSave)
          Button(model.clearLabel, role: .destructive) { model.clearTapped() }
            .disabled(!model.canClear)
        }
      } header: {
        Text(model.title)
      }

      Section {
        Text(model.cacheStatus)
          .font(.caption)
          .foregroundStyle(.secondary)
        Button(model.clearCacheLabel, role: .destructive) { model.clearCacheTapped() }
          .disabled(!model.canClearCache)
      } header: {
        Text(model.cacheSectionTitle)
      }
    }
    .padding()
    .frame(width: 460)
    .onAppear { model.onAppear() }
  }
}
