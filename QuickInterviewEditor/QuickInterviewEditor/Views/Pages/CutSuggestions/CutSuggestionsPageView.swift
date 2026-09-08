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

      if model.showsSuggestionsToggle {
        Toggle(model.showSuggestionsToggleLabel, isOn: $model.showsSuggestionBands)
      }

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
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          ForEach(model.sections) { section in
            VStack(alignment: .leading, spacing: 8) {
              Text(section.title).font(.headline)
              ForEach(section.rows) { row in
                SuggestionCard(model: model, row: row).id(row.id)
              }
            }
          }
        }
      }
      .onChange(of: model.sidebarReveal) { _, reveal in
        if case .suggestion(let id) = reveal?.objectID { proxy.scrollTo(id, anchor: .center) }
      }
      .onAppear {
        if case .suggestion(let id) = model.sidebarReveal?.objectID {
          proxy.scrollTo(id, anchor: .center)
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
      .simultaneousGesture(TapGesture(count: 2).onEnded { model.rowOpened(row.id) })
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
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(
          Color.accentColor, lineWidth: model.selectedObjectID == .suggestion(row.id) ? 1.5 : 0))
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
