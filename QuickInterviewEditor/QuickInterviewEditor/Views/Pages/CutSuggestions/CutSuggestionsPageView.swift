import SwiftUI

/// Placeholder panel for the cut-suggester. The polished ranked-candidate UI (accept /
/// reject / preview / refresh / stale indicator) is PR 7; this view just exercises the
/// model's states so the streaming path is runnable. All content comes from the model.
struct CutSuggestionsPageView: View {
  @Bindable var model: CutSuggestionsPageModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Button(model.suggestButtonLabel) {
        Task { await model.suggestCutsTapped() }
      }
      .disabled(model.isSuggesting)

      if model.showsProgress {
        HStack(spacing: 8) {
          ProgressView()
          Text(model.progressMessage)
        }
      }

      if let errorMessage = model.errorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
          .textSelection(.enabled)
      }

      if model.showsEmptyState {
        Text(model.emptyStateMessage)
          .foregroundStyle(.secondary)
      }

      ForEach(model.suggestions) { suggestion in
        VStack(alignment: .leading, spacing: 2) {
          Text(suggestion.title)
          Text("\(suggestion.productTypeLabel) · \(suggestion.timeRangeDisplay)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding()
  }
}
