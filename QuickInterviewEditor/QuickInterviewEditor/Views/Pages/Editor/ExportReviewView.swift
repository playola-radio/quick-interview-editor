import SwiftUI

struct ExportReviewView: View {
  @Bindable var model: ExportReviewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(model.title).font(.title2)
      Text(model.warning).foregroundStyle(.orange)
      Text(model.helpText).foregroundStyle(.secondary)
      Text(model.progressLabel).font(.caption)
      if model.isCopying { ProgressView() }
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(model.mappings) { mapping in
            VStack(alignment: .leading) {
              LabeledContent(model.requestedLabel, value: mapping.requestedName)
              LabeledContent(model.proposedLabel, value: mapping.proposedName)
            }
          }
          if model.showsCopied {
            Text(model.copiedTitle).font(.headline)
            ForEach(model.copiedRows) { row in Text(row.title) }
          }
        }
        .textSelection(.enabled)
      }
      HStack {
        Button(model.reviewNamesLabel) { model.reviewNamesTapped() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button(model.exportWithSuffixesLabel) { model.exportWithSuffixesTapped() }
          .disabled(!model.canApprove)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(minWidth: 620, idealWidth: 720, minHeight: 350, idealHeight: 520)
    .interactiveDismissDisabled(model.isCopying)
  }
}
