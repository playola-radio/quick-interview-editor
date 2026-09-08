import SwiftUI

struct NamingTemplateView: View {
  @Bindable var model: NamingTemplateModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(model.title).font(.headline)
      Text(model.helpText).foregroundStyle(.secondary)
      ForEach(model.rows) { row in
        HStack {
          if row.isLiteral {
            TextField(model.literalLabel, text: $model[literalAt: row.index])
          } else {
            Text(row.label)
            Spacer()
          }
          Button(model.moveUpLabel, systemImage: "arrow.up") { model.moveUpTapped(at: row.index) }
            .labelStyle(.iconOnly)
            .disabled(!row.canMoveUp)
          Button(model.moveDownLabel, systemImage: "arrow.down") {
            model.moveDownTapped(at: row.index)
          }
          .labelStyle(.iconOnly)
          .disabled(!row.canMoveDown)
          Button(model.removeLabel, systemImage: "minus.circle") {
            model.removeTapped(at: row.index)
          }
          .labelStyle(.iconOnly)
        }
      }
      HStack {
        Button(model.addLiteralLabel) { model.addLiteralTapped() }
        Menu(model.addFieldLabel) {
          ForEach(model.availableFields) { field in
            Button(field.name) { model.addFieldTapped(field.id) }
          }
        }
        Button(model.addSequenceLabel) { model.addSequenceTapped() }
      }
      Text(model.sequenceHelp).font(.caption).foregroundStyle(.secondary)
      LabeledContent(model.previewLabel) {
        Text(model.previewName).textSelection(.enabled)
      }
      ForEach(model.validationMessages, id: \.self) { message in
        Text(message).foregroundStyle(.orange)
      }
      Divider()
      Text(model.groupingTitle).font(.headline)
      Text(model.groupingHelp).foregroundStyle(.secondary)
      ForEach(model.groupingRows) { row in
        Button(row.label, systemImage: row.selectionImage) { model.groupingFieldTapped(row.id) }
          .buttonStyle(.plain)
      }
    }
  }
}
