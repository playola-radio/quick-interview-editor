import SwiftUI

struct SuggestionReviewView: View {
  @Bindable var model: SuggestionReviewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(model.title).font(.title2)
      Text(model.contextTitle).foregroundStyle(.secondary)
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if model.showsFields { fieldsEditor }
          if model.showsGroup { groupEditor }
        }
        .disabled(!model.canEdit)
      }
      if let message = model.errorMessage { Text(message).foregroundStyle(.orange) }
      if let message = model.statusMessage { Text(message).foregroundStyle(.secondary) }
      HStack {
        Spacer()
        Button(model.cancelLabel) { model.cancelTapped() }.keyboardShortcut(.cancelAction)
      }
    }
    .padding(20)
    .frame(minWidth: 560, idealWidth: 650, minHeight: 400, idealHeight: 620)
  }

  private var fieldsEditor: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(model.fieldsTitle).font(.headline)
      ForEach(model.fields) { field in
        Text(field.title).font(.headline)
        TextField(field.title, text: $model[field: field.id])
        Text(field.evidence).font(.caption).foregroundStyle(.secondary)
      }
      if let message = model.missingFieldsMessage { Text(message).foregroundStyle(.orange) }
      namePreviews(model.previewNames)
      if let message = model.fieldsError { Text(message).foregroundStyle(.orange) }
      Button(model.applyFieldsLabel) { model.applyFieldsTapped() }.disabled(!model.canApplyFields)
    }
  }

  private var groupEditor: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(model.thisSearchStart).foregroundStyle(.secondary)
      Text(model.startLabel).font(.headline)
      TextField(model.startLabel, text: $model.startText)
      Text(model.futureHelp).foregroundStyle(.secondary)
      Button(model.applyFutureStartLabel) { model.applyFutureStartTapped() }.disabled(
        !model.canApplyFutureStart)
      Divider()
      Text(model.renumberPreviewTitle).font(.headline)
      namePreviews(model.renumberPreviewNames)
      if let message = model.numberingError { Text(message).foregroundStyle(.orange) }
      Button(model.renumberLabel) { model.renumberTapped() }.disabled(!model.canRenumber)
      Divider()
      Text(model.spellingTitle).font(.headline)
      Text(model.spellingHelp).foregroundStyle(.secondary)
      ForEach(model.groupingFields) { field in
        Text(field.title).font(.headline)
        TextField(field.title, text: $model[canonical: field.id])
      }
      Text(model.spellingPreviewTitle).font(.headline)
      namePreviews(model.spellingPreviewNames)
      if let message = model.spellingError { Text(message).foregroundStyle(.orange) }
      Button(model.applySpellingLabel) { model.applyGroupSpellingTapped() }.disabled(
        !model.canApplyGroupSpelling)
    }
  }

  private func namePreviews(_ rows: [SuggestionNamePreview]) -> some View {
    ForEach(rows) { row in
      VStack(alignment: .leading) {
        LabeledContent(model.beforeLabel, value: row.before)
        LabeledContent(model.afterLabel, value: row.after)
      }
    }
  }
}
