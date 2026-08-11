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

  /// A fixture cutter: optionally captures the request + key it was handed, emits progress
  /// ticks, then completes with the given candidates — synchronously, no sleeps, no network.
  private func fixtureClient(
    progress: [String] = ["Analyzing transcript…"],
    completed: [CutSuggestion],
    capture: LockIsolated<CutSuggestRequest?>? = nil,
    captureKey: LockIsolated<String?>? = nil
  ) -> CutSuggestClient {
    CutSuggestClient { request, apiKey in
      capture?.setValue(request)
      captureKey?.setValue(apiKey)
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

  @Test func buildsRequestAndThreadsTheResolvedKeyToTheClient() async {
    let fingerprint = "fp-request"
    let plan = Fixtures.editPlan()
    let capture = LockIsolated<CutSuggestRequest?>(nil)
    let capturedKey = LockIsolated<String?>(nil)

    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
      $0.keychain = .inMemory("sk-keychain")
      $0.cutSuggest = fixtureClient(completed: [], capture: capture, captureKey: capturedKey)
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
    // The Keychain key is threaded in memory to the client (never inside the request).
    expectNoDifference(capturedKey.value, "sk-keychain")
  }

  // MARK: - Completion → sidecar

  @Test func completedRunStampsProvenanceAndWritesSuggestionsToTheSidecar() async {
    let fingerprint = "fp-complete"
    let plan = Fixtures.editPlan()
    var raw = Fixtures.cutSuggestion(id: Fixtures.uuid(1), wordIDs: [10, 11, 12])
    raw.provenance.transcriptHash = "stale-hash"
    raw.provenance.sourceFingerprint = "some-other-file"

    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
      $0.keychain = .inMemory("sk-keychain")
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

  @Test func completedWithDuplicateSuggestionIDsDoesNotCrashAndKeepsTheFirst() async {
    let fingerprint = "fp-dup"
    let plan = Fixtures.editPlan()
    let first = Fixtures.cutSuggestion(id: Fixtures.uuid(1), title: "first", wordIDs: [10, 11, 12])
    let second = Fixtures.cutSuggestion(
      id: Fixtures.uuid(1), title: "second", wordIDs: [13, 14, 15])

    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
      $0.keychain = .inMemory("sk-keychain")
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

  @Test func emptyCompletionSurfacesFailureAndLeavesExistingSuggestions() async {
    let fingerprint = "fp-empty"
    let existing = Fixtures.cutSuggestion(id: Fixtures.uuid(1), wordIDs: [10, 11, 12])

    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
      $0.keychain = .inMemory("sk-keychain")
      $0.cutSuggest = fixtureClient(completed: [])
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState(
        cutSuggestions: [existing])
      let model = CutSuggestionsPageModel(
        editPlan: Fixtures.editPlan(), sourceFingerprint: fingerprint)
      await model.suggestCutsTapped()

      guard case .failed(let message) = model.phase else {
        Issue.record("expected .failed, got \(model.phase)")
        return
      }
      #expect(message.contains("produced no usable suggestions"))
      expectNoDifference(state.cutSuggestions.elements, [existing])
    }
  }

  @Test func streamFinishingWithoutCompletionSurfacesFailure() async {
    let fingerprint = "fp-nocomplete"
    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
      $0.keychain = .inMemory("sk-keychain")
      $0.cutSuggest = CutSuggestClient { _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.progress("Analyzing transcript…"))
          continuation.finish()
        }
      }
    } operation: {
      let model = CutSuggestionsPageModel(
        editPlan: Fixtures.editPlan(), sourceFingerprint: fingerprint)
      await model.suggestCutsTapped()

      expectNoDifference(model.phase, .failed("The cut-suggester stopped before returning results."))
      #expect(!model.isSuggesting)
    }
  }

  // MARK: - Error handling

  @Test func streamErrorSurfacesTheMessageAndLeavesTheSidecarEmpty() async {
    let fingerprint = "fp-error"
    let error = CutSuggestClientError.unimplemented("suggestCuts")

    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
      $0.keychain = .inMemory("sk-keychain")
      $0.cutSuggest = CutSuggestClient { _, _ in
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

  // MARK: - Key resolution & onboarding

  @Test func noKeyShowsOnboardingAndSuggestPresentsKeyEntryWithoutCallingTheClient() async {
    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
      $0.keychain = .inMemory(nil)
      $0.environment = .constant([:])
      // A cutter that would fail loudly if it were ever called with no key.
      $0.cutSuggest = CutSuggestClient { _, _ in
        AsyncThrowingStream { $0.finish(throwing: CutSuggestClientError.unimplemented("x")) }
      }
    } operation: {
      let model = CutSuggestionsPageModel(
        editPlan: Fixtures.editPlan(), sourceFingerprint: "fp-none")
      model.viewAppeared()
      expectNoDifference(model.showsOnboarding, true)
      expectNoDifference(model.suggestButtonLabel, model.addKeyButtonLabel)

      await model.suggestCutsTapped()
      // No call happened (no error surfaced); the key-entry sheet is presented instead.
      expectNoDifference(model.phase, .idle)
      #expect(model.keyEntry != nil)
    }
  }

  @Test func keychainKeyEnablesSuggest() {
    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
      $0.keychain = .inMemory("sk-keychain")
      $0.environment = .constant([:])
    } operation: {
      let model = CutSuggestionsPageModel(
        editPlan: Fixtures.editPlan(), sourceFingerprint: "fp-kc")
      model.viewAppeared()
      expectNoDifference(model.showsOnboarding, false)
      expectNoDifference(model.suggestButtonLabel, "Suggest Cuts")
    }
  }

  @Test func envVarKeyResolvesWhenNoKeychainValue() {
    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
      $0.keychain = .inMemory(nil)
      $0.environment = .constant([anthropicAPIKeyEnvVar: "env-key"])
    } operation: {
      let model = CutSuggestionsPageModel(
        editPlan: Fixtures.editPlan(), sourceFingerprint: "fp-env")
      model.viewAppeared()
      expectNoDifference(model.showsOnboarding, false)
    }
  }

  @Test func savingAKeyInTheEntrySheetRefreshesStateAndDismisses() {
    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
      $0.keychain = .inMemory(nil)
      $0.environment = .constant([:])
    } operation: {
      let model = CutSuggestionsPageModel(
        editPlan: Fixtures.editPlan(), sourceFingerprint: "fp-save")
      model.viewAppeared()
      expectNoDifference(model.showsOnboarding, true)

      model.addAPIKeyTapped()
      let entry = model.keyEntry
      #expect(entry != nil)
      entry?.apiKeyDraft = "sk-new"
      entry?.saveTapped()

      // The onSaved hook refreshed key state and dismissed the sheet.
      #expect(model.keyEntry == nil)
      expectNoDifference(model.showsOnboarding, false)
    }
  }

  // MARK: - Accept / reject

  @Test func acceptTappedAddsSliceFlipsStatusAndPersists() {
    let fingerprint = "fp-accept"
    let plan = Fixtures.editPlan()
    var suggestion = Fixtures.cutSuggestion(
      id: Fixtures.uuid(1), wordIDs: [10, 11, 12, 13, 14, 15, 16])
    suggestion.provenance = stampedProvenance(
      transcriptHash: plan.transcriptHash, fingerprint: fingerprint)
    let acceptedSlice = LockIsolated<Slice?>(nil)

    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
      $0.keychain = .inMemory("sk-keychain")
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState(
        cutSuggestions: [suggestion])
      let model = CutSuggestionsPageModel(editPlan: plan, sourceFingerprint: fingerprint)
      model.onAcceptSlice = { acceptedSlice.setValue($0) }

      model.acceptTapped(suggestion.id)

      expectNoDifference(acceptedSlice.value?.id, suggestion.id)
      expectNoDifference(state.cutSuggestions[id: suggestion.id]?.status, .accepted)
      expectNoDifference(model.actionMessage, nil)
    }
  }

  @Test func acceptTappedOnAStaleSuggestionSurfacesAMessageAndDoesNotAccept() {
    let fingerprint = "fp-stale"
    let plan = Fixtures.editPlan()
    var suggestion = Fixtures.cutSuggestion(id: Fixtures.uuid(1), wordIDs: [10, 11, 12])
    // Same file, different transcript hash → transcript drifted under it.
    suggestion.provenance = stampedProvenance(
      transcriptHash: "different-hash", fingerprint: fingerprint)
    let acceptedSlice = LockIsolated<Slice?>(nil)

    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState(
        cutSuggestions: [suggestion])
      let model = CutSuggestionsPageModel(editPlan: plan, sourceFingerprint: fingerprint)
      model.onAcceptSlice = { acceptedSlice.setValue($0) }

      model.acceptTapped(suggestion.id)

      #expect(acceptedSlice.value == nil)
      expectNoDifference(state.cutSuggestions[id: suggestion.id]?.status, .pending)
      expectNoDifference(model.actionMessage, cutSuggestionStaleMessage(.transcriptChanged))
    }
  }

  @Test func acceptTappedOnAnInvalidSuggestionSurfacesAMessage() {
    let fingerprint = "fp-invalid"
    let plan = Fixtures.editPlan()
    var suggestion = Fixtures.cutSuggestion(id: Fixtures.uuid(1), wordIDs: [])
    suggestion.provenance = stampedProvenance(
      transcriptHash: plan.transcriptHash, fingerprint: fingerprint)

    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState(
        cutSuggestions: [suggestion])
      let model = CutSuggestionsPageModel(editPlan: plan, sourceFingerprint: fingerprint)

      model.acceptTapped(suggestion.id)

      expectNoDifference(state.cutSuggestions[id: suggestion.id]?.status, .pending)
      expectNoDifference(model.actionMessage, cutSuggestionInvalidMessage(.noWords))
    }
  }

  @Test func rejectTappedMarksTheSuggestionRejected() {
    let fingerprint = "fp-reject"
    let plan = Fixtures.editPlan()
    let suggestion = Fixtures.cutSuggestion(id: Fixtures.uuid(1), wordIDs: [10, 11, 12])

    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState(
        cutSuggestions: [suggestion])
      let model = CutSuggestionsPageModel(editPlan: plan, sourceFingerprint: fingerprint)

      model.rejectTapped(suggestion.id)

      expectNoDifference(state.cutSuggestions[id: suggestion.id]?.status, .rejected)
    }
  }

  // MARK: - Ranked, grouped presentation + freshness

  @Test func sectionsGroupByProductTypeInRankedOrderWithFreshnessFlags() {
    let fingerprint = "fp-sections"
    let plan = Fixtures.editPlan()
    let hash = plan.transcriptHash
    func provenance(transcriptHash: String) -> CutSuggestion.Provenance {
      stampedProvenance(transcriptHash: transcriptHash, fingerprint: fingerprint)
    }
    var spotlight = Fixtures.cutSuggestion(
      id: Fixtures.uuid(1), productType: .spotlight, title: "Story",
      wordIDs: [10, 11, 12], rank: 1)
    spotlight.provenance = provenance(transcriptHash: hash)
    var intro = Fixtures.cutSuggestion(
      id: Fixtures.uuid(2), productType: .intro, title: "Setup", song: "Hit",
      wordIDs: [13, 14], rank: 2)
    intro.provenance = provenance(transcriptHash: "stale")  // transcript drifted under the intro

    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState(
        cutSuggestions: [intro, spotlight])
      let model = CutSuggestionsPageModel(editPlan: plan, sourceFingerprint: fingerprint)

      let sections = model.sections
      // Spotlight ranks first (rank 1), so its section leads.
      expectNoDifference(sections.map(\.title), ["Artist Spotlight", "Intro"])
      expectNoDifference(sections[0].rows.map(\.id), [spotlight.id])
      expectNoDifference(sections[0].rows[0].isStale, false)
      expectNoDifference(sections[0].rows[0].canAccept, true)

      let introRow = sections[1].rows[0]
      expectNoDifference(introRow.isStale, true)
      expectNoDifference(introRow.canAccept, false)
      expectNoDifference(introRow.showsFreshnessWarning, true)
      expectNoDifference(introRow.songLine, "Song: Hit (unverified)")
    }
  }

  // MARK: - View-facing state

  @Test func viewFacingStateMapsFromPhase() {
    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
      $0.keychain = .inMemory("sk-keychain")
    } operation: {
      let model = CutSuggestionsPageModel(
        editPlan: Fixtures.editPlan(), sourceFingerprint: "fp-phase")
      model.viewAppeared()

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
