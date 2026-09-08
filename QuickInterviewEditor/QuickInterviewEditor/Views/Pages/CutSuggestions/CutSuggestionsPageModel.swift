import Dependencies
import Foundation
import IdentifiedCollections
import Observation

/// Drives the cut-suggester surface: resolves the Anthropic key (onboarding when none),
/// runs the "Suggest cuts" action, and lets the editor accept/reject the ranked candidates.
/// All display text and derived state live here; the view only renders (CLAUDE.md's "no
/// logic in views").
///
/// Owns no persisted state: the candidates it displays are read through
/// `currentSuggestions` (the editor's document is the source of truth), and every edit is
/// emitted as an intent (`onAccept`/`onReject`/`onTitleChanged`/
/// `onSpeakerOverridesChanged`) that the editor funnels through `mutateDocument`.
@MainActor
@Observable
final class CutSuggestionsPageModel: ViewModel {

  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.keychain) var keychain
  @ObservationIgnored @Dependency(\.environment) var environment

  // MARK: - Initialization
  let editPlan: EditPlan
  let sourceFingerprint: String
  let options: CutSuggestOptions
  let productSpecs: [ProductSpec]
  /// Reads the document's current cut candidates (the editor's `documentCutSuggestions`).
  /// A closure so this model stays editor-agnostic; reading the editor's `@Observable`
  /// property here keeps the panel in sync with document changes.
  @ObservationIgnored var currentSuggestions: @MainActor () -> IdentifiedArrayOf<CutSuggestion> =
    { [] }
  /// Asks the editor to accept a suggestion (wired by `EditorModel`): land its derived `Slice`
  /// and flip the suggestion to `.accepted` in ONE undoable document transaction, so a single
  /// undo reverts both. Kept a closure so this model stays editor-agnostic.
  @ObservationIgnored var onAccept: (@MainActor (Slice, CutSuggestion.ID) -> Void)?
  /// Asks the editor to flip a suggestion to `.rejected` in the document (undoably).
  @ObservationIgnored var onReject: (@MainActor (CutSuggestion.ID) -> Void)?
  /// Asks the editor to rename a suggestion in the document. Focus callbacks bracket the live
  /// changes so the editor can coalesce one typing session into one undoable action.
  @ObservationIgnored var onTitleChanged: (@MainActor (CutSuggestion.ID, String) -> Void)?
  @ObservationIgnored var onTitleEditingBegan: (@MainActor (CutSuggestion.ID) -> Void)?
  @ObservationIgnored var onTitleEditingEnded: (@MainActor (CutSuggestion.ID) -> Void)?
  /// Emits per-file speaker overrides for the editor to fold into the document. Wired now;
  /// the paragraph/speaker UI that drives it lands in a later PR.
  @ObservationIgnored var onSpeakerOverridesChanged: (@MainActor (Int?, [String: String]) -> Void)?
  /// Asks the editor to reveal a suggestion across both panes (select its words, scroll the
  /// transcript, zoom the waveform) when the user clicks a row. Wired by `EditorModel`.
  @ObservationIgnored var onSelectSuggestion: ((CutSuggestion) -> Void)?

  init(
    editPlan: EditPlan,
    sourceFingerprint: String,
    options: CutSuggestOptions = CutSuggestOptions(),
    productSpecs: [ProductSpec] = ProductSpec.defaults,
    onSelectSuggestion: ((CutSuggestion) -> Void)? = nil
  ) {
    self.run = SuggestionRunModel(
      editPlan: editPlan, sourceFingerprint: sourceFingerprint, options: options)
    self.editPlan = editPlan
    self.sourceFingerprint = sourceFingerprint
    self.options = options
    self.productSpecs = productSpecs
    self.onSelectSuggestion = onSelectSuggestion
    super.init()
    run.currentDocument = { [weak self] in
      EditorDocumentState(cutSuggestions: self?.currentSuggestions() ?? [])
    }
    run.resolveAPIKey = { [weak self] in self?.resolvedAPIKey() }
    run.onMissingAPIKey = { [weak self] in self?.addAPIKeyTapped() }
    run.onExplicitStart = { [weak self] in self?.onExplicitSuggest?() }
  }

  // MARK: - Phase
  enum Phase: Equatable {
    case idle
    case suggesting(String)
    case failed(String)
  }

  // MARK: - Properties
  var orphanChoices: [SuggestionRecoveryOwner] = []
  var onOrphanSelected: @MainActor (SuggestionRecoveryOwner) async -> Void = { _ in }
  var onOrphanCancelled: @MainActor () -> Void = {}
  let run: SuggestionRunModel
  var phase: Phase {
    switch run.phase {
    case .running(_, let message): .suggesting(message)
    case .failed(let message), .needsRetry(_, let message): .failed(message)
    default: .idle
    }
  }
  /// Whether a usable Anthropic key resolved (Keychain or env). Refreshed on appear and
  /// after key entry; drives onboarding vs the live suggest flow.
  private(set) var hasAPIKey = false
  var automaticSuggestionsEnabled: Bool {
    get { run.automaticEnabled }
    set { run.automaticEnabled = newValue }
  }
  var onExplicitSuggest: (() -> Void)?
  /// The message shown when accepting a suggestion failed (stale / invalid). Cleared on a
  /// successful accept or a new run.
  var actionMessage: String?
  var lastRunDiagnostic: String? {
    get { run.diagnostic }
    set { run.diagnostic = newValue }
  }
  /// The API-key entry sheet, presented when onboarding or when the user taps to add a key.
  var keyEntry: SettingsModel?
  var suggestionSettings: SuggestionSettingsModel?
  /// Whether pending suggestions are drawn as faint outline bands in the transcript. The ranked
  /// list in this panel is unaffected — this only mutes the transcript overlay so the user can
  /// hide the proposals while keeping the list. Session-local: defaults on and resets per load.
  var showsSuggestionBands = true
  private var editingTitleID: CutSuggestion.ID?

  // MARK: - Display Text
  let configureSuggestionsLabel = "Configure Suggestions…"
  let orphanTitle = "Recover an unfinished search"
  let orphanMessage = "Choose a saved search for this transcript, then resume or discard it."
  let startingMessage = "Analyzing transcript…"
  let emptyStateMessage =
    "No suggestions yet. Tap \u{201c}Suggest Cuts\u{201d} to find product cuts."
  let onboardingTitle = "Add your Anthropic API key to enable cut suggestions"
  let onboardingBody =
    "Cut suggestions use a hosted Claude model. Add your Anthropic API key (stored in your "
    + "Keychain, billed to your own key) to get started."
  let addKeyButtonLabel = "Add API Key…"
  let acceptLabel = "Accept"
  let rejectLabel = "Reject"
  let revealSuggestionLabel = "Reveal suggestion in transcript and waveform"
  let showSuggestionsToggleLabel = "Show suggestions in transcript"
  let suggestionTitleLabel = "Suggestion title"
  let suggestionTitleHelp = "Click to rename — the accepted clip keeps this title"

  var suggestButtonLabel: String {
    hasAPIKey ? "Suggest Cuts" : addKeyButtonLabel
  }

  // MARK: - View Helpers
  var orphanRows: [SuggestionOrphanRow] {
    orphanChoices.map {
      .init(
        id: $0.id,
        title: ($0.documentURL?.lastPathComponent ?? "Untitled project") + " · "
          + $0.id.uuidString.prefix(8))
    }
  }
  var showsOrphanChoices: Bool { !orphanChoices.isEmpty }
  /// The candidates to show, in ranked order, read from the editor's document.
  var suggestions: [CutSuggestion] { currentSuggestions().ranked }

  /// The still-undecided candidates, in ranked order — the source of the amber clip
  /// containers the transcript draws. Accepted candidates are already slices (drawn green,
  /// so they aren't double-drawn here); rejected ones aren't drawn at all.
  var pendingSuggestions: [CutSuggestion] { currentSuggestions().pending }

  /// The show/hide toggle only makes sense when there are pending suggestions whose transcript
  /// outlines it can mute — hidden otherwise so it never dangles over an empty list.
  var showsSuggestionsToggle: Bool { !pendingSuggestions.isEmpty }

  /// Ranked candidates grouped/labeled by product type, with per-row display values and
  /// freshness derived against the current transcript/source.
  var sections: [SuggestionSection] {
    suggestionSections(
      from: suggestions, currentTranscriptHash: editPlan.transcriptHash,
      currentFingerprint: sourceFingerprint)
  }

  /// The current (untrimmed) title of a suggestion, read live from the document so a rename
  /// `TextField` round-trips through `titleChanged` on every keystroke rather than editing a
  /// stale row snapshot. Empty string for an unknown ID.
  func editableTitle(for id: CutSuggestion.ID) -> String {
    currentSuggestions()[id: id]?.title ?? ""
  }

  subscript(editableTitle id: CutSuggestion.ID) -> String {
    get { editableTitle(for: id) }
    set { titleChanged(id, to: newValue) }
  }

  var isSuggesting: Bool {
    if case .suggesting = phase { return true }
    return false
  }

  /// The line shown while a run is in flight (empty otherwise).
  var progressMessage: String {
    if case .suggesting(let message) = phase { return message }
    return ""
  }

  /// The last run's failure, or `nil` when the last run succeeded / none has run.
  var errorMessage: String? {
    if case .failed(let message) = phase { return message }
    return nil
  }

  var showsProgress: Bool { isSuggesting }
  /// The onboarding panel replaces the empty state when no key resolved and there's nothing
  /// to act on yet.
  var showsOnboarding: Bool { !hasAPIKey && suggestions.isEmpty && !isSuggesting }
  var showsEmptyState: Bool {
    hasAPIKey && suggestions.isEmpty && !isSuggesting && errorMessage == nil
  }

  // MARK: - User Actions
  var recoveryBlocksSuggestions: Bool {
    get { run.ownershipBlocked }
    set { run.ownershipBlocked = newValue }
  }
  var candidateActionsDisabled: Bool { run.candidatesLocked }
  var suggestDisabled: Bool { !run.canStart || showsOrphanChoices }
  var showsRecoveryActions: Bool { run.canResume || run.canDiscard }
  var recoveryMessage: String? {
    switch run.phase {
    case .paused, .needsNumbering: run.message
    default: nil
    }
  }

  func viewAppeared() { refreshKeyState() }

  func orphanSelected(_ id: UUID) async {
    guard let owner = orphanChoices.first(where: { $0.id == id }) else { return }
    await onOrphanSelected(owner)
  }
  func orphanCancelled() { onOrphanCancelled() }

  /// Clicking a row asks the editor to reveal it (select its words, scroll the transcript, zoom
  /// the waveform) so the user can review — and, with the fine-tune pane open, audition — the
  /// candidate before accepting or rejecting it. A no-op for an unknown ID.
  func rowTapped(_ id: CutSuggestion.ID) {
    guard let suggestion = suggestions.first(where: { $0.id == id }) else { return }
    onSelectSuggestion?(suggestion)
  }

  func suggestCutsTapped() async {
    actionMessage = nil
    guard !showsOrphanChoices else { return }
    await run.suggestTapped()
  }

  func autoSuggestCutsIfNeeded() async {
    guard !showsOrphanChoices else { return }
    await run.automaticSearchIfNeeded()
  }

  /// Accepts a suggestion: validates it against the current plan, then — on success —
  /// asks the editor to land the derived `Slice` and flip the suggestion accepted in one
  /// undoable document transaction (`onAccept`). Stale/invalid inputs surface a message
  /// instead of a slice — never a crash. Validating here (the model owns the plan,
  /// fingerprint, and `actionMessage`) keeps the outcome message local; the editor owns
  /// the undoable document write.
  func acceptTapped(_ id: CutSuggestion.ID) {
    guard !candidateActionsDisabled else { return }
    finishTitleEditing(id)
    switch acceptCutSuggestion(
      id, in: ProjectState(cutSuggestions: currentSuggestions()), plan: editPlan,
      sourceFingerprint: sourceFingerprint, transcriptHash: editPlan.transcriptHash)
    {
    case .accepted(let slice, _):
      actionMessage = nil
      onAccept?(slice, id)
    case .stale(let reason):
      actionMessage = cutSuggestionStaleMessage(reason)
    case .invalid(let reason):
      actionMessage = cutSuggestionInvalidMessage(reason)
    }
  }

  func rejectTapped(_ id: CutSuggestion.ID) {
    guard !candidateActionsDisabled else { return }
    finishTitleEditing(id)
    actionMessage = nil
    onReject?(id)
  }

  /// Renames a suggestion as the user types in its title field. Routed to the editor so the
  /// document and accepted-slice name stay live while the surrounding focus session is coalesced.
  func titleChanged(_ id: CutSuggestion.ID, to newTitle: String) {
    onTitleChanged?(id, newTitle)
  }

  func titleFocusChanged(_ id: CutSuggestion.ID, isFocused: Bool) {
    if isFocused {
      guard editingTitleID != id else { return }
      if let editingTitleID { finishTitleEditing(editingTitleID) }
      editingTitleID = id
      onTitleEditingBegan?(id)
    } else {
      finishTitleEditing(id)
    }
  }

  /// Presents the key-entry sheet; on save/clear it refreshes the resolved-key state and
  /// dismisses.
  func addAPIKeyTapped() {
    keyEntry = withDependencies(from: self) {
      SettingsModel(onSaved: { [weak self] in
        self?.refreshKeyState()
        self?.keyEntry = nil
      })
    }
  }

  func configureSuggestionsTapped() {
    suggestionSettings = withDependencies(from: self) {
      SuggestionSettingsModel(
        onSaved: { [weak self] in self?.suggestionSettings = nil },
        onCancelled: { [weak self] in self?.suggestionSettings = nil })
    }
  }

  // MARK: - Private Helpers
  private func refreshKeyState() { hasAPIKey = resolvedAPIKey() != nil }

  private func finishTitleEditing(_ id: CutSuggestion.ID) {
    guard editingTitleID == id else { return }
    editingTitleID = nil
    onTitleEditingEnded?(id)
  }

  /// Resolves the key by the fixed order (Keychain, then `ANTHROPIC_API_KEY`). A Keychain
  /// read failure degrades to "no Keychain value" rather than throwing into the UI.
  private func resolvedAPIKey() -> String? {
    resolveAnthropicAPIKey(
      keychain: (try? keychain.load()) ?? nil,
      env: environment.value(anthropicAPIKeyEnvVar))
  }

}

struct SuggestionOrphanRow: Identifiable {
  var id: UUID
  var title: String
}
