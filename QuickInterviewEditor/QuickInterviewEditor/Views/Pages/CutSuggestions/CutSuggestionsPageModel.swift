import Dependencies
import Foundation
import IdentifiedCollections
import Observation
import Sharing

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
  @ObservationIgnored @Dependency(\.suggestionConfiguration) var configurationClient
  @ObservationIgnored @Shared(.suggestionConfiguration) var savedConfiguration

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
  @ObservationIgnored var onInterviewArtistChanged: (@MainActor (String?) -> Void)?
  /// Emits per-file speaker overrides for the editor to fold into the document. Wired now;
  /// the paragraph/speaker UI that drives it lands in a later PR.
  @ObservationIgnored var onSpeakerOverridesChanged: (@MainActor (Int?, [String: String]) -> Void)?
  /// Asks the editor to reveal a suggestion across both panes (select its words, scroll the
  /// transcript, zoom the waveform) when the user clicks a row. Wired by `EditorModel`.
  @ObservationIgnored var onSelectSuggestion: ((CutSuggestion) -> Void)?

  init(
    editPlan: EditPlan,
    sourceFingerprint: String,
    options: CutSuggestOptions = .freshConfigured,
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
  var suggestionReview: SuggestionReviewModel?
  @ObservationIgnored var onReviewApply: (SuggestionReviewIntent) throws -> Void = { _ in
    throw SuggestionReviewError.unavailable
  }
  var interviewArtistDraft: String?
  private var futureStartDrafts: [String: String] = [:]
  /// Whether pending suggestions are drawn as faint outline bands in the transcript. The ranked
  /// list in this panel is unaffected — this only mutes the transcript overlay so the user can
  /// hide the proposals while keeping the list. Session-local: defaults on and resets per load.
  var showsSuggestionBands = true
  private var editingTitleID: CutSuggestion.ID?
  var selectedTypeIDs: Set<String>?
  var catalog: SuggestionConfiguration?
  private var attemptedCatalogLoad = false
  var catalogMessage: String?

  // MARK: - Display Text
  let typesMenuTitle = "Types"
  let allTypesTitle = "All Types"
  let noMatchesMessage = "No suggestions match the selected types. Choose All Types to show them."
  let futureStartsTitle = "Starting Counts"
  let numberingScopeTitle = "Numbering — This project"
  let numberingHelp =
    "Numbers are assigned when you accept clips, so rejected suggestions do not use a number. "
    + "Save or reset each starting count below; accepted clips continue after previously assigned numbers. "
    + "These changes apply only to this project and can be undone in the editor."
  let futureStartLabel = "Start numbering at"
  let applyTypeStartLabel = "Save Type Start"
  let songStartsTitle = "Song and Group Counts"
  let songStartsHelp =
    "Song overrides stay with their original song, even when a correction moves a suggestion elsewhere."
  let reviewFieldsLabel = "Review Fields…"
  let reviewGroupLabel = "Review Group…"
  let resetSongStartLabel = "Reset to Type Start"
  let automaticTypeStartLabel = "Use Automatic"
  let orphanTitle = "Recover an unfinished search"
  let orphanMessage = "Choose a saved search for this transcript, then resume or discard it."
  let startingMessage = "Analyzing transcript…"
  var emptyStateMessage: String {
    run.currentDocument().suggestionBatch == nil
      ? "No suggestions yet. Tap \u{201c}Suggest Cuts\u{201d} to find product cuts."
      : "No matching suggestions found."
  }
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
  var suggestions: [CutSuggestion] {
    visibleSuggestions(currentSuggestions().ranked, selected: selectedTypeIDs)
  }

  /// The still-undecided candidates, in ranked order — the source of the amber clip
  /// containers the transcript draws. Accepted candidates are already slices (drawn green,
  /// so they aren't double-drawn here); rejected ones aren't drawn at all.
  var pendingSuggestions: [CutSuggestion] {
    visibleSuggestions(currentSuggestions().pending, selected: selectedTypeIDs)
  }

  var interviewArtist: String? { run.currentDocument().interviewArtist }

  func visibleTypeFilterRows(in group: SuggestionGroup) -> [SuggestionTypeFilterRow] {
    let rows = typeFilterRows.filter { $0.group == group }
    guard rows.count == 1, let row = rows.first,
      row.id == "intro" || row.id == "spotlight",
      let preset = SuggestionDefaults.types.first(where: { $0.id == row.id }),
      row.group == preset.group, row.title == preset.name
    else { return rows }
    return []
  }

  var typeFilterRows: [SuggestionTypeFilterRow] {
    var rows: [SuggestionTypeFilterRow] = []
    let configuration = savedConfiguration ?? catalog
    for type in configuration?.types ?? [] {
      rows.append(.init(id: type.id, title: type.name, group: type.group, state: .none))
    }
    for type in run.currentDocument().suggestionBatch?.snapshot.configuration.types ?? []
    where !rows.contains(where: { $0.id == type.id }) {
      rows.append(.init(id: type.id, title: type.name, group: type.group, state: .none))
    }
    for candidate in currentSuggestions()
    where !rows.contains(where: { $0.id == candidate.productType.rawValue }) {
      rows.append(
        .init(
          id: candidate.productType.rawValue,
          title: candidate.naming?.typeName ?? candidate.productType.displayLabel,
          group: candidate.naming?.typeGroup
            ?? (candidate.productType == .intro ? .songIntros : .spotlights),
          state: .none))
    }
    return rows.map { row in
      var row = row
      row.state = selectedTypeIDs?.contains(row.id) == false ? .none : .all
      return row
    }
  }
  var typeFilterGroups: [SuggestionFilterGroup] {
    [
      (SuggestionGroup.spotlights, "Spotlights"), (.songIntros, "Song Intros"),
      (.audioImages, "Audio Images"),
    ]
    .map { group, title in
      .init(id: group, title: title, types: typeFilterRows.filter { $0.group == group })
    }.filter { !$0.types.isEmpty }
  }
  var allTypesState: SuggestionFilterState {
    if selectedTypeIDs == nil { return .all }
    if typeFilterRows.allSatisfy({ $0.state == .none }) { return .none }
    return typeFilterRows.allSatisfy({ $0.state == .all }) ? .all : .some
  }
  var showsNoMatches: Bool { !currentSuggestions().isEmpty && suggestions.isEmpty }

  var futureStartRows: [SuggestionFutureStartRow] {
    let document = run.currentDocument()
    return typeFilterRows.map { type in
      let preference = document.suggestionStarts.types[type.id]
      let explicit = preference?.isExplicit == true
      return .init(
        id: type.id, title: type.title,
        preferenceLabel: explicit
          ? "Starting count: \(preference?.number ?? 1)"
          : "Automatic — starts at 1 or after previously issued numbers",
        hasOverride: preference != nil)
    }
  }
  var songStartRows: [SuggestionSongStartRow] {
    let document = run.currentDocument()
    var keys = document.suggestionStarts.groups.map(\.key)
    if let batch = document.suggestionBatch {
      for candidate in document.cutSuggestions {
        if let key = reviewSequenceKey(candidate, batch: batch), !keys.contains(key) {
          keys.append(key)
        }
      }
    }
    return keys.map { key in
      let display = groupDisplay(key)
      let values = key.fields.map { field in
        display.canonicalValues[field.fieldID] ?? field.value
      }.filter { !$0.isEmpty }
      let song = values.isEmpty ? "Unresolved group" : values.joined(separator: " · ")
      let override = document.suggestionStarts.groups.first { $0.key == key }
      let number =
        override?.start.number ?? document.suggestionStarts.types[key.typeID]?.number ?? 1
      let title =
        key.fields.isEmpty && key.provisionalCandidateID == nil
        ? display.typeName : display.typeName + " · " + song
      return .init(
        id: key, title: title,
        startLabel: "Starting count: \(number)", hasOverride: override != nil)
    }
  }
  subscript(futureStart id: String) -> String {
    get {
      futureStartDrafts[id] ?? String(run.currentDocument().suggestionStarts.types[id]?.number ?? 1)
    }
    set { futureStartDrafts[id] = newValue }
  }

  /// The show/hide toggle only makes sense when there are pending suggestions whose transcript
  /// outlines it can mute — hidden otherwise so it never dangles over an empty list.
  var showsSuggestionsToggle: Bool { !pendingSuggestions.isEmpty }

  /// Ranked candidates grouped/labeled by product type, with per-row display values and
  /// freshness derived against the current transcript/source.
  var sections: [SuggestionSection] {
    suggestionSections(
      from: suggestions, currentTranscriptHash: editPlan.transcriptHash,
      currentFingerprint: sourceFingerprint,
      fieldNames: Dictionary(
        uniqueKeysWithValues: (run.currentDocument().suggestionBatch?.snapshot.configuration.fields
          ?? []).map { ($0.id, $0.name) }))
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
  var showsOnboarding: Bool { !hasAPIKey && currentSuggestions().isEmpty && !isSuggesting }
  var showsEmptyState: Bool {
    hasAPIKey && currentSuggestions().isEmpty && !isSuggesting && errorMessage == nil
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

  func catalogAppeared() async {
    guard !attemptedCatalogLoad else { return }
    attemptedCatalogLoad = true
    do {
      catalog = try await configurationClient.load()
      catalogMessage = nil
    } catch {
      catalogMessage = "Could not load saved suggestion types. \(error.localizedDescription)"
    }
  }

  func allTypesTapped() { selectedTypeIDs = allTypesState == .all ? [] : nil }

  func typeFilterTapped(_ id: String) {
    var selected = selectedTypeIDs ?? Set(typeFilterRows.map(\.id))
    if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    selectedTypeIDs = selected
  }

  func groupFilterTapped(_ group: SuggestionGroup) {
    guard let row = typeFilterGroups.first(where: { $0.id == group }) else { return }
    var selected = selectedTypeIDs ?? Set(typeFilterRows.map(\.id))
    if row.state == .all {
      selected.subtract(row.types.map(\.id))
    } else {
      selected.formUnion(row.types.map(\.id))
    }
    selectedTypeIDs = selected
  }

  func applyTypeStartTapped(_ id: String) {
    do {
      let number = try parseSuggestionStartingNumber(self[futureStart: id])
      try applyReviewIntent(.futureType(typeID: id, start: number))
      futureStartDrafts[id] = nil
    } catch { actionMessage = reviewErrorMessage(error) }
  }

  func resetSongStartTapped(_ key: SuggestionSequenceKey) {
    do { try applyReviewIntent(.resetGroup(key)) } catch {
      actionMessage = reviewErrorMessage(error)
    }
  }

  func resetTypeStartTapped(_ id: String) {
    do {
      try applyReviewIntent(.resetType(id))
      futureStartDrafts[id] = nil
    } catch { actionMessage = reviewErrorMessage(error) }
  }

  func reviewFieldsTapped(_ id: UUID) {
    guard !candidateActionsDisabled,
      let candidate = currentSuggestions()[id: id], candidate.isPending, candidate.naming != nil
    else { return }
    presentReview(candidateID: id)
  }

  func reviewGroupTapped(
    _ key: SuggestionSequenceKey, settings: SuggestionSettingsModel? = nil
  ) {
    guard !candidateActionsDisabled else { return }
    presentReview(sequenceKey: key, settings: settings)
  }

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

  // MARK: - Private Helpers
  private func applyReviewIntent(_ intent: SuggestionReviewIntent) throws {
    guard !candidateActionsDisabled else { throw SuggestionReviewError.locked }
    try onReviewApply(intent)
    actionMessage = nil
  }

  private func presentReview(
    candidateID: UUID? = nil, sequenceKey: SuggestionSequenceKey? = nil,
    settings: SuggestionSettingsModel? = nil
  ) {
    let review = SuggestionReviewModel(
      candidateID: candidateID, sequenceKey: sequenceKey,
      currentDocument: { [weak self] in self?.run.currentDocument() ?? .init() },
      isLocked: { [weak self] in self?.candidateActionsDisabled ?? true },
      onApply: { [weak self] intent in
        guard let self else { throw SuggestionReviewError.unavailable }
        try applyReviewIntent(intent)
      },
      onCancelled: { [weak self, weak settings] in
        if let settings { settings.numberingReview = nil } else { self?.suggestionReview = nil }
      })
    if let settings { settings.numberingReview = review } else { suggestionReview = review }
  }

  private func groupDisplay(_ key: SuggestionSequenceKey) -> SuggestionStarts.GroupDisplay {
    let document = run.currentDocument()
    let snapshot = document.suggestionBatch?.snapshot.configuration
    let saved = document.suggestionStarts.groups.first { $0.key == key }?.display
    let type =
      snapshot?.types.first { $0.id == key.typeID }
      ?? (savedConfiguration ?? catalog)?.types.first { $0.id == key.typeID }
    let fields = snapshot?.fields ?? (savedConfiguration ?? catalog)?.fields ?? []
    let canonical =
      document.suggestionBatch?.canonicalGroups.first { $0.key == key }?.values
      ?? saved?.canonicalValues ?? document.issuedSuggestionNumbers.first { $0.key == key }?
      .canonicalValues
      ?? Dictionary(uniqueKeysWithValues: key.fields.map { ($0.fieldID, $0.value) })
    return .init(
      typeName: type?.name ?? saved?.typeName ?? key.typeID,
      fieldNames: saved?.fieldNames
        ?? Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0.name) }),
      canonicalValues: canonical)
  }

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

struct SuggestionFutureStartRow: Identifiable {
  var id: String
  var title: String
  var preferenceLabel: String
  var hasOverride: Bool
}

struct SuggestionSongStartRow: Identifiable {
  var id: SuggestionSequenceKey
  var title: String
  var startLabel: String
  var hasOverride: Bool
}
