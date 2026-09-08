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
            if model.showsInterview {
              interviewEditor
            } else if model.showsNumbering, let page = model.numberingPage {
              SuggestionNumberingView(model: page)
            } else if model.showsTypeEditor {
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
      .disabled(model.isBusy)
      if model.isBusy { ProgressView() }
      if let notice = model.savedRevisionStatus { Text(notice).foregroundStyle(.orange) }
      if let status = model.statusMessage { Text(status).textSelection(.enabled) }
      ForEach(model.validationMessages, id: \.self) { message in
        Text(message).foregroundStyle(.orange)
      }
      HStack {
        if model.showsRuleActions {
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
        if model.showsDone {
          Spacer()
          Button(model.doneLabel) { model.cancelTapped() }
            .disabled(!model.canCancel)
            .keyboardShortcut(.cancelAction)
        }
      }
    }
    .padding(20)
    .frame(minWidth: 700, idealWidth: 780, minHeight: 570, idealHeight: 680)
    .task { await model.viewAppeared() }
    .interactiveDismissDisabled(model.isBusy)
    .sheet(item: $model.numberingReview) { review in
      SuggestionReviewView(model: review)
    }
  }

  private var sidebar: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        Group {
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
        .disabled(!model.canEdit)
        if model.showsNumberingOption {
          Divider()
          Text(model.projectScopeTitle).font(.headline)
          Button(model.interviewTitle) { model.interviewSelected() }
            .buttonStyle(.plain)
            .fontWeight(model.isInterviewSelected ? .semibold : .regular)
            .foregroundStyle(model.isInterviewSelected ? Color.accentColor : Color.primary)
          Button(model.numberingTitle) { model.numberingSelected() }
            .buttonStyle(.plain)
            .fontWeight(model.isNumberingSelected ? .semibold : .regular)
            .foregroundStyle(model.isNumberingSelected ? Color.accentColor : Color.primary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.trailing, 8)
    }
  }

  private var interviewEditor: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(model.interviewTitle).font(.title3)
      TextField(model.interviewArtistLabel, text: $model.interviewArtistText)
      Text(model.interviewArtistHelp).foregroundStyle(.secondary)
      Button(model.saveInterviewLabel) { model.saveInterviewTapped() }
        .disabled(!model.canSaveInterview)
    }
  }

  private var typeEditor: some View {
    VStack(alignment: .leading, spacing: 12) {
      TextField(model.nameLabel, text: $model.typeName)
      Picker(model.groupLabel, selection: $model.typeGroup) {
        ForEach(model.groupOptions) { option in Text(option.title).tag(option.id) }
      }
      if model.showsTunedDiscoveryHelp { Text(model.builtInHelp).foregroundStyle(.secondary) }
      Text(model.guidelinesLabel).font(.headline)
      Text(model.guidelinesHelp).foregroundStyle(.secondary)
      TextEditor(text: $model.typeGuidelines)
        .frame(minHeight: 70)
        .accessibilityLabel(model.guidelinesLabel)
      if let builder = model.namingTemplate { NamingTemplateView(model: builder) }
      Button(model.removeTypeLabel, role: .destructive) { model.removeSelectedTypeTapped() }
        .disabled(!model.canRemoveType)
    }
    .disabled(!model.canEdit)
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
    .disabled(!model.canEdit)
  }
}

private struct SuggestionNumberingView: View {
  @Bindable var model: CutSuggestionsPageModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(model.numberingScopeTitle).font(.title3)
      Text(model.numberingHelp).foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 12) {
        Text(model.futureStartsTitle).font(.headline)
        ForEach(model.futureStartRows) { row in
          VStack(alignment: .leading, spacing: 6) {
            Text(row.title).font(.headline)
            Text(row.preferenceLabel).font(.caption).foregroundStyle(.secondary)
            TextField(model.futureStartLabel, text: $model[futureStart: row.id])
              .accessibilityLabel(row.title + " — " + model.futureStartLabel)
            HStack {
              Button(model.applyTypeStartLabel) { model.applyTypeStartTapped(row.id) }
              if row.hasOverride {
                Button(model.automaticTypeStartLabel) { model.resetTypeStartTapped(row.id) }
              }
            }
          }
          Divider()
        }
        Text(model.songStartsTitle).font(.headline)
        Text(model.songStartsHelp).font(.caption).foregroundStyle(.secondary)
        ForEach(model.songStartRows) { row in
          VStack(alignment: .leading, spacing: 6) {
            Text(row.title).font(.headline)
            Text(row.startLabel).font(.caption)
            HStack {
              Button(model.reviewGroupLabel) { model.reviewGroupTapped(row.id) }
              if row.hasOverride {
                Button(model.resetSongStartLabel) { model.resetSongStartTapped(row.id) }
              }
            }
          }
        }
      }
      .disabled(model.candidateActionsDisabled)
      if let message = model.actionMessage {
        Text(message).foregroundStyle(.orange).textSelection(.enabled)
      }
    }
  }
}
