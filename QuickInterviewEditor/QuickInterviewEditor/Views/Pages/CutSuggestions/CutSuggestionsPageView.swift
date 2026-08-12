import SwiftUI

/// The cut-suggester panel: run suggestions, browse the ranked candidates grouped by
/// product type, and accept/reject each. Onboarding (no API key) and accept failures are
/// model-driven states. Contains no logic — every string and flag comes from the model.
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

      if let actionMessage = model.actionMessage {
        Text(actionMessage)
          .foregroundStyle(.orange)
          .textSelection(.enabled)
      }

      if model.showsOnboarding {
        onboarding
      } else if model.showsEmptyState {
        Text(model.emptyStateMessage)
          .foregroundStyle(.secondary)
      } else {
        suggestionList
      }

      Spacer(minLength: 0)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onAppear { model.viewAppeared() }
    .sheet(item: $model.keyEntry) { entry in
      SettingsView(model: entry)
    }
  }

  private var onboarding: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(model.onboardingTitle).font(.headline)
      Text(model.onboardingBody).foregroundStyle(.secondary)
      Button(model.addKeyButtonLabel) { model.addAPIKeyTapped() }
    }
  }

  private var suggestionList: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        ForEach(model.sections) { section in
          VStack(alignment: .leading, spacing: 8) {
            Text(section.title).font(.headline)
            ForEach(section.rows) { row in
              rowView(row)
            }
          }
        }
      }
    }
  }

  private func rowView(_ row: SuggestionRow) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      // The descriptive lines are a plain-style button so the reveal is keyboard- and
      // VoiceOver-accessible; the Accept/Reject buttons stay outside it so a tap on them never
      // doubles as a reveal.
      Button {
        model.rowTapped(row.id)
      } label: {
        VStack(alignment: .leading, spacing: 4) {
          HStack(alignment: .firstTextBaseline) {
            Text(row.rankLabel)
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(row.title)
            Spacer()
            Text(row.statusLabel)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if let songLine = row.songLine {
            Text(songLine)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Text("\(row.timeRange) · \(row.duration)")
            .font(.caption)
            .foregroundStyle(.secondary)
          if row.showsFreshnessWarning {
            Text(row.freshnessLabel)
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(model.revealSuggestionLabel)
      HStack {
        if row.showsAcceptButton {
          Button(model.acceptLabel) { model.acceptTapped(row.id) }
            .disabled(!row.canAccept)
        }
        if row.showsRejectButton {
          Button(model.rejectLabel) { model.rejectTapped(row.id) }
            .disabled(!row.canReject)
        }
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(white: 0.1))
    .clipShape(RoundedRectangle(cornerRadius: 6))
  }
}
