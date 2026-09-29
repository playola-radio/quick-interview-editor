import SwiftUI
import UniformTypeIdentifiers

// swiftlint:disable inclusive_language

struct MasteringPageView: View {
  @Bindable var model: MasteringPageModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(model.title).font(.title2)
      if model.showsEligibilitySummary {
        Text(model.eligibilitySummary).foregroundStyle(.secondary)
      }
      if model.showsStaleNotice { Text(model.staleMessage).foregroundStyle(.orange) }
      if let message = model.message { Text(message).textSelection(.enabled) }
      ForEach(model.warningMessages, id: \.self) { warning in
        Text(warning).foregroundStyle(.orange)
      }
      if model.showsActivity {
        HStack {
          ProgressView()
          Text(model.activityLabel)
        }
      }
      if !model.hasRun { Text(model.noRunMessage).foregroundStyle(.secondary) }
      HStack {
        Button(model.prepareLabel) { Task { await model.prepareTapped() } }
          .disabled(model.isBusy)
        Button(model.cancelLabel) { Task { await model.cancelTapped() } }
          .disabled(!model.isBusy)
        Button(model.openSiteLabel) { model.openMasterchannelTapped() }
      }
      ForEach(model.rows) { row in
        HStack {
          VStack(alignment: .leading) {
            Text(row.title).font(.headline)
            Text(row.status).foregroundStyle(.secondary)
          }
          Spacer()
          if row.canDrag {
            Text(model.dragLabel).onDrag {
              NSItemProvider(contentsOf: model.dragURLSync(for: row.id)) ?? NSItemProvider()
            }
          }
          if row.canReplace { Button(model.replaceLabel) { model.replacePartTapped(row.id) } }
        }
      }
      Text(model.dropHelp).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 80)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary))
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
          model.providersDropped(providers)
          return true
        }
      HStack {
        Button(model.saveLabel) { model.saveFinalsTapped() }.disabled(!model.canSave)
        if !model.savedFiles.isEmpty {
          Button(model.showInFinderLabel) { model.showInFinderTapped() }
        }
      }
    }
    .padding(20)
    .frame(minWidth: 650, minHeight: 420)
    .task(id: model.run?.id) { await model.preloadDragSources() }
    .confirmationDialog(model.confirmAgainMessage, isPresented: $model.confirmingPrepareAgain) {
      Button(model.prepareAgainLabel) { Task { await model.prepareAgainConfirmed() } }
      Button(model.cancelLabel, role: .cancel) { model.prepareAgainCancelled() }
    }
    .confirmationDialog(model.destinationMessage, isPresented: $model.isDestinationPresented) {
      Button(model.saveLabel) { model.destinationSaveSelected() }
      Button(model.chooseOtherLabel) { model.destinationChooseOtherSelected() }
      Button(model.cancelLabel, role: .cancel) { model.destinationCancelTapped() }
    }
    .sheet(item: $model.exportReview) { ExportReviewView(model: $0) }
    .interactiveDismissDisabled(model.isBusy)
    .confirmationDialog(model.ambiguityMessage, isPresented: $model.isAmbiguityPresented) {
      ForEach(model.ambiguityChoices) { choice in
        Button(choice.title) { model.ambiguousChoiceTapped(choice.id) }
      }
      Button(model.cancelLabel, role: .cancel) { model.ambiguousReturnCancelled() }
    }
  }
}

// swiftlint:enable inclusive_language
