import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
// `FileStorage.inMemory(fileSystem:)` is `@_spi(Internals)`, matching how the sidecar's
// own persistence tests inject an isolated in-memory file system.
@_spi(Internals) import Sharing
import Testing

@testable import QuickInterviewEditor

@MainActor
struct CutSuggestionsPageTests {

  // MARK: - Helpers

  /// A fixture cutter: optionally captures the request it was handed, emits progress ticks,
  /// then completes with the given candidates — synchronously, no sleeps, no network.
  private func fixtureClient(
    progress: [String] = ["Analyzing transcript…"],
    completed: [CutSuggestion],
    capture: LockIsolated<CutSuggestRequest?>? = nil
  ) -> CutSuggestClient {
    CutSuggestClient { request in
      capture?.setValue(request)
      return AsyncThrowingStream { continuation in
        for message in progress { continuation.yield(.progress(message)) }
        continuation.yield(.completed(completed))
        continuation.finish()
      }
    }
  }

  private func stampedProvenance(
    transcriptHash: String, fingerprint: String
  ) -> CutSuggestion.Provenance {
    CutSuggestion.Provenance(
      model: "claude-sonnet-5", promptVersion: "v1", productSpecVersion: "v1",
      transcriptHash: transcriptHash, sourceFingerprint: fingerprint, diarizationHash: nil)
  }

  // MARK: - Request building

  @Test func buildsRequestFromTheTranscriptAndSendsItToTheClient() async {
    let fingerprint = "fp-request"
    let plan = Fixtures.editPlan()
    let capture = LockIsolated<CutSuggestRequest?>(nil)

    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
      $0.cutSuggest = fixtureClient(completed: [], capture: capture)
    } operation: {
      let model = CutSuggestionsPageModel(editPlan: plan, sourceFingerprint: fingerprint)
      await model.suggestCutsTapped()
    }

    let request = capture.value
    expectNoDifference(request?.transcriptUnits, plan.transcriptUnits)
    expectNoDifference(request?.transcriptHash, plan.transcriptHash)
    expectNoDifference(request?.sourceFingerprint, fingerprint)
    expectNoDifference(request?.productSpecs, ProductSpec.defaults)
    expectNoDifference(request?.options, CutSuggestOptions())
    #expect(request?.diarization == nil)
  }

  // MARK: - Completion → sidecar

  @Test func completedRunStampsProvenanceAndWritesSuggestionsToTheSidecar() async {
    let fingerprint = "fp-complete"
    let plan = Fixtures.editPlan()
    // Deliberately-wrong provenance proves the model re-stamps from the current run.
    var raw = Fixtures.cutSuggestion(id: Fixtures.uuid(1), wordIDs: [10, 11, 12])
    raw.provenance.transcriptHash = "stale-hash"
    raw.provenance.sourceFingerprint = "some-other-file"

    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
      $0.cutSuggest = fixtureClient(completed: [raw])
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let model = CutSuggestionsPageModel(editPlan: plan, sourceFingerprint: fingerprint)
      await model.suggestCutsTapped()

      var expected = raw
      expected.provenance = stampedProvenance(
        transcriptHash: plan.transcriptHash, fingerprint: fingerprint)
      expectNoDifference(state.cutSuggestions.elements, [expected])
      expectNoDifference(model.phase, .idle)
      #expect(!model.isSuggesting)
      expectNoDifference(model.errorMessage, nil)
    }
  }

  @Test func aProducedSuggestionPassesTheAcceptTranscriptHashGate() async {
    // End-to-end: a suggestion the model persisted is stamped with the current transcript
    // hash, so accepting it against that same hash is not stale.
    let fingerprint = "fp-accept"
    let plan = Fixtures.editPlan()
    let raw = Fixtures.cutSuggestion(
      id: Fixtures.uuid(1), wordIDs: [10, 11, 12, 13, 14, 15, 16])

    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
      $0.cutSuggest = fixtureClient(completed: [raw])
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let model = CutSuggestionsPageModel(editPlan: plan, sourceFingerprint: fingerprint)
      await model.suggestCutsTapped()

      let result = acceptCutSuggestion(
        raw.id, in: state, plan: plan, sourceFingerprint: fingerprint,
        transcriptHash: plan.transcriptHash)
      guard case .accepted = result else {
        Issue.record("expected .accepted, got \(result)")
        return
      }
    }
  }

  @Test func completedWithDuplicateSuggestionIDsDoesNotCrashAndKeepsTheFirst() async {
    // A malformed response repeating an ID must not trap `IdentifiedArray(uniqueElements:)`.
    let fingerprint = "fp-dup"
    let plan = Fixtures.editPlan()
    let first = Fixtures.cutSuggestion(id: Fixtures.uuid(1), title: "first", wordIDs: [10, 11, 12])
    let second = Fixtures.cutSuggestion(
      id: Fixtures.uuid(1), title: "second", wordIDs: [13, 14, 15])

    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
      $0.cutSuggest = fixtureClient(completed: [first, second])
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let model = CutSuggestionsPageModel(editPlan: plan, sourceFingerprint: fingerprint)
      await model.suggestCutsTapped()

      expectNoDifference(state.cutSuggestions.count, 1)
      expectNoDifference(state.cutSuggestions[id: Fixtures.uuid(1)]?.title, "first")
      expectNoDifference(model.phase, .idle)
    }
  }

  @Test func streamFinishingWithoutCompletionReturnsToIdle() async {
    // A degenerate run that never emits `.completed` must not leave the spinner stuck.
    let fingerprint = "fp-nocomplete"
    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
      $0.cutSuggest = CutSuggestClient { _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.progress("Analyzing transcript…"))
          continuation.finish()
        }
      }
    } operation: {
      let model = CutSuggestionsPageModel(
        editPlan: Fixtures.editPlan(), sourceFingerprint: fingerprint)
      await model.suggestCutsTapped()

      expectNoDifference(model.phase, .idle)
      #expect(!model.isSuggesting)
    }
  }

  // MARK: - Error handling

  @Test func streamErrorSurfacesTheMessageAndLeavesTheSidecarEmpty() async {
    let fingerprint = "fp-error"
    let error = CutSuggestClientError.unimplemented("suggestCuts")

    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
      $0.cutSuggest = CutSuggestClient { _ in
        AsyncThrowingStream { $0.finish(throwing: error) }
      }
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let model = CutSuggestionsPageModel(
        editPlan: Fixtures.editPlan(), sourceFingerprint: fingerprint)
      await model.suggestCutsTapped()

      expectNoDifference(model.errorMessage, error.errorDescription)
      expectNoDifference(model.phase, .failed(error.errorDescription ?? ""))
      #expect(state.cutSuggestions.isEmpty)
    }
  }

  // MARK: - View-facing state

  @Test func viewFacingStateMapsFromPhase() {
    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
    } operation: {
      let model = CutSuggestionsPageModel(
        editPlan: Fixtures.editPlan(), sourceFingerprint: "fp-phase")

      expectNoDifference(model.isSuggesting, false)
      expectNoDifference(model.progressMessage, "")
      expectNoDifference(model.errorMessage, nil)
      expectNoDifference(model.showsEmptyState, true)

      model.phase = .suggesting("Working…")
      expectNoDifference(model.isSuggesting, true)
      expectNoDifference(model.progressMessage, "Working…")
      expectNoDifference(model.showsProgress, true)
      expectNoDifference(model.showsEmptyState, false)

      model.phase = .failed("boom")
      expectNoDifference(model.errorMessage, "boom")
      expectNoDifference(model.isSuggesting, false)
    }
  }
}
