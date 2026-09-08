import SwiftUI

struct SuggestionSettingsView: View {
  @Bindable var model: SuggestionSettingsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(model.title).font(.title2)
      Text(model.helpText).foregroundStyle(.secondary)
      HSplitView {
        sidebar.frame(minWidth: 165, idealWidth: 190, maxWidth: 230)
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            if model.showsTypeEditor {
              typeEditor
            } else if model.showsFieldEditor {
              fieldEditor
            } else {
              Text(model.selectionPrompt).foregroundStyle(.secondary)
            }
          }
          .padding(.leading, 12)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 390)
      }
      .disabled(!model.canEdit)
      if model.isBusy { ProgressView() }
      if let notice = model.savedRevisionStatus { Text(notice).foregroundStyle(.orange) }
      if let status = model.statusMessage { Text(status).textSelection(.enabled) }
      ForEach(model.validationMessages, id: \.self) { message in
        Text(message).foregroundStyle(.orange)
      }
      HStack {
        Button(model.reloadLabel) { Task { await model.reloadTapped() } }
          .disabled(!model.canReload)
        Spacer()
        Button(model.cancelLabel) { model.cancelTapped() }
          .disabled(!model.canCancel)
          .keyboardShortcut(.cancelAction)
        Button(model.saveLabel) { Task { await model.saveTapped() } }
          .disabled(!model.canSave)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(minWidth: 700, idealWidth: 780, minHeight: 570, idealHeight: 680)
    .task { await model.viewAppeared() }
    .interactiveDismissDisabled(model.isBusy)
  }

  private var sidebar: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        Text(model.typesTitle).font(.headline)
        ForEach(model.typeRows) { row in
          Button(row.title) { model.typeSelected(row.id) }
            .buttonStyle(.plain)
            .fontWeight(row.isSelected ? .semibold : .regular)
            .foregroundStyle(row.isSelected ? Color.accentColor : Color.primary)
        }
        Button(model.addTypeLabel, systemImage: "plus") { model.addTypeTapped() }
        if model.showsRestore {
          Menu(model.restoreLabel) {
            ForEach(model.missingPresets) { row in
              Button(row.title) { model.restoreBuiltInTapped(row.id) }
            }
          }
        }
        Divider()
        Text(model.fieldsTitle).font(.headline)
        ForEach(model.fieldRows) { row in
          Button(row.title) { model.fieldSelected(row.id) }
            .buttonStyle(.plain)
            .fontWeight(row.isSelected ? .semibold : .regular)
            .foregroundStyle(row.isSelected ? Color.accentColor : Color.primary)
        }
        Button(model.addFieldLabel, systemImage: "plus") { model.addFieldTapped() }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.trailing, 8)
    }
  }

  private var typeEditor: some View {
    VStack(alignment: .leading, spacing: 12) {
      TextField(model.nameLabel, text: $model.typeName)
      Picker(model.groupLabel, selection: $model.typeGroup) {
        ForEach(model.groupOptions) { option in Text(option.title).tag(option.id) }
      }
      if model.isBuiltInType { Text(model.builtInHelp).foregroundStyle(.secondary) }
      Text(model.guidelinesLabel).font(.headline)
      Text(model.guidelinesHelp).foregroundStyle(.secondary)
      TextEditor(text: $model.typeGuidelines)
        .frame(minHeight: 70)
        .accessibilityLabel(model.guidelinesLabel)
      if let builder = model.namingTemplate { NamingTemplateView(model: builder) }
      Button(model.removeTypeLabel, role: .destructive) { model.removeSelectedTypeTapped() }
        .disabled(!model.canRemoveType)
    }
  }

  private var fieldEditor: some View {
    VStack(alignment: .leading, spacing: 12) {
      TextField(model.nameLabel, text: $model.fieldName)
      Text(model.fieldInstructionsLabel).font(.headline)
      Text(model.instructionsHelp).foregroundStyle(.secondary)
      TextEditor(text: $model.fieldInstructions)
        .frame(minHeight: 160)
        .accessibilityLabel(model.fieldInstructionsLabel)
      Button(model.removeFieldLabel, role: .destructive) { model.removeSelectedFieldTapped() }
    }
  }
}
