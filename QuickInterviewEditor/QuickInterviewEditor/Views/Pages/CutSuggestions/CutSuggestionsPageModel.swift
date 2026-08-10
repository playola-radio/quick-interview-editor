import Dependencies
import Foundation
import IdentifiedCollections
import Observation
import Sharing

/// Drives the "Suggest cuts" action: builds a `CutSuggestRequest` from the current
/// transcript, streams the cutter's progress, and writes the ranked candidates into the
/// per-file project sidecar. All display text and derived state live here; the view only
/// renders (CLAUDE.md's "no logic in views"). The polished suggestion UI is PR 7 — this
/// model + its states is the deliverable, with a placeholder view.
@MainActor
@Observable
final class CutSuggestionsPageModel: ViewModel {

  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.cutSuggest) var cutSuggest

  // MARK: - Shared State
  @ObservationIgnored @Shared var projectState: ProjectState

  // MARK: - Initialization
  let editPlan: EditPlan
  let sourceFingerprint: String
  let options: CutSuggestOptions
  let productSpecs: [ProductSpec]

  init(
    editPlan: EditPlan,
    sourceFingerprint: String,
    options: CutSuggestOptions = CutSuggestOptions(),
    productSpecs: [ProductSpec] = ProductSpec.defaults
  ) {
    self.editPlan = editPlan
    self.sourceFingerprint = sourceFingerprint
    self.options = options
    self.productSpecs = productSpecs
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

  // MARK: - Display Text
  let suggestButtonLabel = "Suggest Cuts"
  let startingMessage = "Analyzing transcript…"
  let emptyStateMessage =
    "No suggestions yet. Tap \u{201c}Suggest Cuts\u{201d} to find product cuts."

  // MARK: - View Helpers
  /// The candidates to show, in ranked order, read straight from the sidecar.
  var suggestions: [CutSuggestion] { projectState.rankedSuggestions }

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
  var showsEmptyState: Bool { suggestions.isEmpty && !isSuggesting && errorMessage == nil }

  // MARK: - User Actions
  func suggestCutsTapped() async {
    guard !isSuggesting else { return }
    phase = .suggesting(startingMessage)
    let request = buildRequest()
    do {
      for try await event in cutSuggest.suggestCuts(request) {
        switch event {
        case .progress(let message):
          phase = .suggesting(message)
        case .completed(let candidates):
          let stamped = candidates.map { stampProvenance(on: $0, from: request) }
          // De-dupe defensively: a malformed response repeating a suggestion ID would trap
          // `IdentifiedArray(uniqueElements:)`. Regenerating replaces the prior candidates
          // (a merge policy that preserves accept/reject decisions is PR 7's concern).
          $projectState.withLock {
            $0.cutSuggestions = IdentifiedArray(stamped, uniquingIDsWith: { first, _ in first })
          }
          phase = .idle
          return
        }
      }
      // The stream finished without ever completing (a degenerate run): don't hang on the
      // spinner — drop back to idle with whatever the sidecar already held.
      if isSuggesting { phase = .idle }
    } catch is CancellationError {
      phase = .idle
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  // MARK: - Private Helpers
  private func buildRequest() -> CutSuggestRequest {
    CutSuggestRequest(
      transcriptUnits: editPlan.transcriptUnits,
      diarization: nil,
      productSpecs: productSpecs,
      options: options,
      transcriptHash: editPlan.transcriptHash,
      sourceFingerprint: sourceFingerprint)
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
