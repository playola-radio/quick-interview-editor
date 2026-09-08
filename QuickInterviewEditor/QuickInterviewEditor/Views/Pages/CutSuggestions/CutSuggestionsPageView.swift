import SwiftUI

/// The cut-suggester panel: run suggestions, browse the ranked candidates grouped by
/// product type, and accept/reject each. Onboarding (no API key) and accept failures are
/// model-driven states. Contains no logic — every string and flag comes from the model.
struct CutSuggestionsPageView: View {
  @Bindable var model: CutSuggestionsPageModel

  var body: some View {
    @Bindable var run = model.run
    VStack(alignment: .leading, spacing: 12) {
      Button(model.suggestButtonLabel) {
        Task { await model.suggestCutsTapped() }
      }
      .disabled(model.suggestDisabled)

      if model.showsSuggestionsToggle {
        Toggle(model.showSuggestionsToggleLabel, isOn: $model.showsSuggestionBands)
      }

      if model.showsProgress {
        HStack(spacing: 8) {
          ProgressView()
          Text(model.progressMessage)
          Button(model.run.cancelButtonTitle) { model.run.cancelSearchTapped() }
        }
      }

      if model.showsOrphanChoices {
        Text(model.orphanTitle).font(.headline)
        Text(model.orphanMessage)
        ForEach(model.orphanRows) { row in
          Button(row.title) { Task { await model.orphanSelected(row.id) } }
        }
        Button(model.run.cancelButtonTitle) { model.orphanCancelled() }
      }
      if let recoveryMessage = model.recoveryMessage { Text(recoveryMessage) }
      if model.showsRecoveryActions {
        HStack {
          if model.run.canResume {
            Button(model.run.resumeButtonTitle) { Task { await model.run.resumeTapped() } }
          }
          if model.run.canDiscard {
            Button(model.run.discardButtonTitle) { Task { await model.run.discardSearchTapped() } }
          }
        }
      }
      if model.run.showsNumbering {
        Text(model.run.numberingTitle).font(.headline)
        ForEach($run.numberingEntries) { $entry in
          TextField(entry.title, value: $entry.number, format: .number)
        }
        Button(model.run.applyNumberingTitle) { Task { await model.run.numberingApplyTapped() } }
      }
      if let diagnostic = model.lastRunDiagnostic {
        Text(diagnostic).foregroundStyle(.secondary).textSelection(.enabled)
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
    .confirmationDialog(model.run.replaceTitle, isPresented: $run.isConfirmingReplacement) {
      Button(model.run.replaceButtonTitle, role: .destructive) {
        model.run.replacementButtonTapped()
      }
      Button(model.run.cancelButtonTitle, role: .cancel) { model.run.cancelReplacementTapped() }
    } message: {
      Text(model.run.replaceMessage)
    }
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
              SuggestionCard(model: model, row: row)
            }
          }
        }
      }
    }
  }

}

/// One ranked candidate. The title is an inline rename field while the suggestion is pending
/// (mirroring the clip-name field in the slices sidebar); the accepted clip inherits it. Kept a
/// dedicated view so each row owns its own focus/hover state.
private struct SuggestionCard: View {
  @Bindable var model: CutSuggestionsPageModel
  let row: SuggestionRow
  @FocusState private var titleFocused: Bool
  @State private var titleHovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if row.showsEditableTitle {
        header { editableTitle }
      }
      // The descriptive lines are a plain-style button so the reveal is keyboard- and
      // VoiceOver-accessible. The title field and Accept/Reject buttons stay outside it so a
      // tap on them never doubles as a reveal.
      Button {
        model.rowTapped(row.id)
      } label: {
        VStack(alignment: .leading, spacing: 4) {
          if row.showsRevealableTitle {
            header { Text(row.title) }
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
            .disabled(!row.canAccept || model.candidateActionsDisabled)
        }
        if row.showsRejectButton {
          Button(model.rejectLabel) { model.rejectTapped(row.id) }
            .disabled(!row.canReject || model.candidateActionsDisabled)
        }
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(white: 0.1))
    .clipShape(RoundedRectangle(cornerRadius: 6))
  }

  private func header<Title: View>(@ViewBuilder title: () -> Title) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(row.rankLabel)
        .font(.caption)
        .foregroundStyle(.secondary)
      title()
      Spacer()
      Text(row.statusLabel)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var editableTitle: some View {
    TextField(
      row.titlePlaceholder,
      text: $model[dynamicMember: \.[editableTitle: row.id]]
    )
    .textFieldStyle(.plain)
    .focused($titleFocused)
    .padding(.horizontal, 6).padding(.vertical, 3)
    .background(
      RoundedRectangle(cornerRadius: 5)
        .fill(Color.white.opacity(titleFocused ? 0.14 : (titleHovering ? 0.07 : 0)))
    )
    .onChange(of: titleFocused) { _, isFocused in
      model.titleFocusChanged(row.id, isFocused: isFocused)
    }
    .onHover { titleHovering = $0 }
    .help(model.suggestionTitleHelp)
    .accessibilityLabel(model.suggestionTitleLabel)
  }
}
