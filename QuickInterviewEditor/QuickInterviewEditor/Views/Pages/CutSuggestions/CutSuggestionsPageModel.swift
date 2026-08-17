import Dependencies
import Foundation
import IdentifiedCollections
import Observation
import Sharing

/// Drives the cut-suggester surface: resolves the Anthropic key (onboarding when none),
/// runs the "Suggest cuts" action, and lets the editor accept/reject the ranked candidates.
/// All display text and derived state live here; the view only renders (CLAUDE.md's "no
/// logic in views"). Accepted candidates flow to the editor through `onAcceptSlice`.
@MainActor
@Observable
final class CutSuggestionsPageModel: ViewModel {

  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.cutSuggest) var cutSuggest
  @ObservationIgnored @Dependency(\.keychain) var keychain
  @ObservationIgnored @Dependency(\.environment) var environment

  // MARK: - Shared State
  @ObservationIgnored @Shared var projectState: ProjectState

  // MARK: - Initialization
  let editPlan: EditPlan
  let sourceFingerprint: String
  let options: CutSuggestOptions
  let productSpecs: [ProductSpec]
  /// Hands an accepted suggestion's `Slice` to the editor (wired by `EditorModel`), which
  /// appends it to its slices/render list. Kept a closure so this model stays editor-agnostic.
  @ObservationIgnored var onAcceptSlice: ((Slice) -> Void)?
  /// Asks the editor to reveal a suggestion across both panes (select its words, scroll the
  /// transcript, zoom the waveform) when the user clicks a row. Wired by `EditorModel`.
  @ObservationIgnored var onSelectSuggestion: ((CutSuggestion) -> Void)?

  init(
    editPlan: EditPlan,
    sourceFingerprint: String,
    options: CutSuggestOptions = CutSuggestOptions(),
    productSpecs: [ProductSpec] = ProductSpec.defaults,
    onAcceptSlice: ((Slice) -> Void)? = nil,
    onSelectSuggestion: ((CutSuggestion) -> Void)? = nil
  ) {
    self.editPlan = editPlan
    self.sourceFingerprint = sourceFingerprint
    self.options = options
    self.productSpecs = productSpecs
    self.onAcceptSlice = onAcceptSlice
    self.onSelectSuggestion = onSelectSuggestion
    _projectState = Shared(.projectState(fingerprint: sourceFingerprint))
    super.init()
  }

  // MARK: - Phase
  enum Phase: Equatable {
    case idle
    case suggesting(String)
    case failed(String)
  }

  // MARK: - Properties
  var phase: Phase = .idle
  /// Whether a usable Anthropic key resolved (Keychain or env). Refreshed on appear and
  /// after key entry; drives onboarding vs the live suggest flow.
  private(set) var hasAPIKey = false
  /// The message shown when accepting a suggestion failed (stale / invalid). Cleared on a
  /// successful accept or a new run.
  var actionMessage: String?
  /// The API-key entry sheet, presented when onboarding or when the user taps to add a key.
  var keyEntry: SettingsModel?
  /// Whether pending suggestions are drawn as faint outline bands in the transcript. The ranked
  /// list in this panel is unaffected — this only mutes the transcript overlay so the user can
  /// hide the proposals while keeping the list. Session-local: defaults on and resets per load.
  var showsSuggestionBands = true

  // MARK: - Display Text
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

  var suggestButtonLabel: String {
    hasAPIKey ? "Suggest Cuts" : addKeyButtonLabel
  }

  // MARK: - View Helpers
  /// The candidates to show, in ranked order, read straight from the sidecar.
  var suggestions: [CutSuggestion] { projectState.rankedSuggestions }

  /// The still-undecided candidates, in ranked order — the source of the amber clip
  /// containers the transcript draws. Accepted candidates are already slices (drawn green,
  /// so they aren't double-drawn here); rejected ones aren't drawn at all.
  var pendingSuggestions: [CutSuggestion] { projectState.pendingSuggestions }

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
  func viewAppeared() { refreshKeyState() }

  /// Clicking a row asks the editor to reveal it (select its words, scroll the transcript, zoom
  /// the waveform) so the user can review — and, with the fine-tune pane open, audition — the
  /// candidate before accepting or rejecting it. A no-op for an unknown ID.
  func rowTapped(_ id: CutSuggestion.ID) {
    guard let suggestion = suggestions.first(where: { $0.id == id }) else { return }
    onSelectSuggestion?(suggestion)
  }

  func suggestCutsTapped() async {
    guard !isSuggesting else { return }
    // No key resolved → don't call the LLM; take the user to key entry instead.
    guard let apiKey = resolvedAPIKey() else {
      addAPIKeyTapped()
      return
    }
    await runSuggest(apiKey: apiKey)
  }

  /// Fired once when the editor loads a file, so the user lands on suggestions already in
  /// flight instead of having to press a button. It's deliberately quiet: it does nothing when
  /// suggestions already exist (so it never clobbers prior results or accept/reject decisions),
  /// and, unlike the manual button, it does NOT open the key-entry sheet when no key resolves —
  /// a background pass must never nag. The button remains the way to add a key and run by hand.
  func autoSuggestCutsIfNeeded() async {
    guard !isSuggesting, suggestions.isEmpty else { return }
    guard let apiKey = resolvedAPIKey() else { return }
    await runSuggest(apiKey: apiKey, isBackgroundPass: true)
  }

  /// The shared run: stream the cutter and fold its events into `phase`/the sidecar. Both the
  /// manual button and the background auto-pass funnel through here so they behave identically
  /// once a key is in hand. `isBackgroundPass` is the one difference: a background pass refuses
  /// to overwrite suggestions that appeared while it was in flight (see the completion handler).
  private func runSuggest(apiKey: String, isBackgroundPass: Bool = false) async {
    actionMessage = nil
    phase = .suggesting(startingMessage)
    let request = buildRequest()
    do {
      for try await event in cutSuggest.suggestCuts(request, apiKey) {
        switch event {
        case .progress(let message):
          phase = .suggesting(message)
        case .completed(let candidates):
          guard !candidates.isEmpty else {
            phase = .failed(
              "The cut-suggester completed but produced no usable suggestions. "
                + "Existing suggestions were left unchanged.")
            return
          }
          // A background pass guards emptiness at start, but suggestions can land while it's in
          // flight (a manual run, or the same file open elsewhere sharing this fingerprint's
          // sidecar). Committing now would replace them — silently wiping the user's
          // accept/reject decisions. So a background pass only writes if the sidecar is still
          // empty; a manual run always commits (an explicit re-run is meant to replace).
          if isBackgroundPass, !suggestions.isEmpty {
            phase = .idle
            return
          }
          let stamped = candidates.map { stampProvenance(on: $0, from: request) }
          // De-dupe defensively: a malformed response repeating a suggestion ID would trap
          // `IdentifiedArray(uniqueElements:)`. Regenerating replaces the prior candidates
          // (a merge policy that preserves accept/reject decisions is future work).
          $projectState.withLock {
            $0.cutSuggestions = IdentifiedArray(stamped, uniquingIDsWith: { first, _ in first })
          }
          phase = .idle
          return
        }
      }
      // The stream finished without ever completing (a degenerate run): don't hang on the
      // spinner, but fail visibly so the user sees the missing subprocess result.
      if isSuggesting {
        phase = .failed("The cut-suggester stopped before returning results.")
      }
    } catch is CancellationError {
      phase = .idle
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  /// Accepts a suggestion: converts it to a `Slice` against the current plan (PR 3's
  /// `acceptCutSuggestion`), flips it accepted in the sidecar, and hands the slice to the
  /// editor. Stale/invalid inputs surface a message instead of a slice — never a crash.
  func acceptTapped(_ id: CutSuggestion.ID) {
    switch acceptCutSuggestion(
      id, in: projectState, plan: editPlan, sourceFingerprint: sourceFingerprint,
      transcriptHash: editPlan.transcriptHash)
    {
    case .accepted(let slice, _):
      $projectState.withLock { $0.acceptSuggestion(id) }
      onAcceptSlice?(slice)
      actionMessage = nil
    case .stale(let reason):
      actionMessage = cutSuggestionStaleMessage(reason)
    case .invalid(let reason):
      actionMessage = cutSuggestionInvalidMessage(reason)
    }
  }

  func rejectTapped(_ id: CutSuggestion.ID) {
    $projectState.withLock { $0.rejectSuggestion(id) }
    actionMessage = nil
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
  private func refreshKeyState() { hasAPIKey = resolvedAPIKey() != nil }

  /// Resolves the key by the fixed order (Keychain, then `ANTHROPIC_API_KEY`). A Keychain
  /// read failure degrades to "no Keychain value" rather than throwing into the UI.
  private func resolvedAPIKey() -> String? {
    resolveAnthropicAPIKey(
      keychain: (try? keychain.load()) ?? nil,
      env: environment.value(anthropicAPIKeyEnvVar))
  }

  private func buildRequest() -> CutSuggestRequest {
    CutSuggestRequest(
      transcriptUnits: editPlan.transcriptUnits,
      diarization: nil,
      productSpecs: productSpecs,
      options: options,
      transcriptHash: editPlan.transcriptHash,
      sourceFingerprint: sourceFingerprint,
      sampleRate: editPlan.source.sampleRate)
  }

  /// Provenance is bookkeeping the model owns authoritatively: it knows the current
  /// transcript hash, source fingerprint, and pinned versions this run used. Stamping it
  /// here (rather than trusting the client) guarantees every persisted suggestion carries
  /// the hash the accept-time staleness gate compares against.
  private func stampProvenance(on suggestion: CutSuggestion, from request: CutSuggestRequest)
    -> CutSuggestion
  {
    var stamped = suggestion
    stamped.provenance = CutSuggestion.Provenance(
      model: request.options.model,
      promptVersion: request.options.promptVersion,
      productSpecVersion: request.options.productSpecVersion,
      transcriptHash: request.transcriptHash,
      sourceFingerprint: request.sourceFingerprint,
      diarizationHash: request.diarization?.diarizationHash)
    return stamped
  }
}
