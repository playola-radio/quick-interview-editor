import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
import IdentifiedCollections
import Testing

@testable import PlayolaInterviewEditor

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

  /// Stands in for the editor's document: the model reads its candidates through
  /// `currentSuggestions` and its intents (`onAccept`/`onReject`/`onSuggestionsProduced`)
  /// mutate it, exactly as `EditorModel.mutateDocument` would. `LockIsolated` so the fixture
  /// cutter (a `@Sendable` closure) can also land suggestions mid-flight.
  private func wire(
    _ model: CutSuggestionsPageModel,
    to store: LockIsolated<IdentifiedArrayOf<CutSuggestion>>
  ) {
    model.currentSuggestions = { store.value }
    model.onAccept = { _, id in store.withValue { $0[id: id]?.accept() } }
    model.onReject = { id in store.withValue { $0[id: id]?.reject() } }
    model.onTitleChanged = { id, title in store.withValue { $0[id: id]?.title = title } }
    model.onSuggestionsProduced = { produced in
      store.withValue { $0 = IdentifiedArray(produced, uniquingIDsWith: { first, _ in first }) }
    }
  }

  private func stampedProvenance(
    transcriptHash: String, fingerprint: String
  ) -> CutSuggestion.Provenance {
    CutSuggestion.Provenance(
      model: "claude-sonnet-5", promptVersion: "v2", productSpecVersion: "v1",
      transcriptHash: transcriptHash, sourceFingerprint: fingerprint, diarizationHash: nil)
  }

  /// Returns a copy of `suggestion` with provenance stamped — kept a pure `let`-producing
  /// helper so callers avoid a mutable `var` that a `@Sendable` `LockIsolated` autoclosure
  /// would refuse to capture.
  private func stamped(
    _ suggestion: CutSuggestion, transcriptHash: String, fingerprint: String
  ) -> CutSuggestion {
    var copy = suggestion
    copy.provenance = stampedProvenance(transcriptHash: transcriptHash, fingerprint: fingerprint)
    return copy
  }

  // MARK: - Request building

  @Test func buildsRequestAndThreadsTheResolvedKeyToTheClient() async {
    let fingerprint = "fp-request"
    let plan = Fixtures.editPlan()
    let capture = LockIsolated<CutSuggestRequest?>(nil)
    let capturedKey = LockIsolated<String?>(nil)

    await withDependencies {
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

  // MARK: - Completion → document

  @Test func completedRunStampsProvenanceAndEmitsSuggestionsToTheDocument() async {
    let fingerprint = "fp-complete"
    let plan = Fixtures.editPlan()
    var raw = Fixtures.cutSuggestion(id: Fixtures.uuid(1), wordIDs: [10, 11, 12])
    raw.provenance.transcriptHash = "stale-hash"
    raw.provenance.sourceFingerprint = "some-other-file"
    let store = LockIsolated<IdentifiedArrayOf<CutSuggestion>>([])

    await withDependencies {
      $0.keychain = .inMemory("sk-keychain")
      $0.cutSuggest = fixtureClient(completed: [raw])
    } operation: {
      let model = CutSuggestionsPageModel(editPlan: plan, sourceFingerprint: fingerprint)
      wire(model, to: store)
      await model.suggestCutsTapped()
    }

    var expected = raw
    expected.provenance = stampedProvenance(
      transcriptHash: plan.transcriptHash, fingerprint: fingerprint)
    expectNoDifference(store.value.elements, [expected])
  }

  @Test func completedWithDuplicateSuggestionIDsDoesNotCrashAndKeepsTheFirst() async {
    let fingerprint = "fp-dup"
    let plan = Fixtures.editPlan()
    let first = Fixtures.cutSuggestion(id: Fixtures.uuid(1), title: "first", wordIDs: [10, 11, 12])
    let second = Fixtures.cutSuggestion(
      id: Fixtures.uuid(1), title: "second", wordIDs: [13, 14, 15])
    let store = LockIsolated<IdentifiedArrayOf<CutSuggestion>>([])

    await withDependencies {
      $0.keychain = .inMemory("sk-keychain")
      $0.cutSuggest = fixtureClient(completed: [first, second])
    } operation: {
      let model = CutSuggestionsPageModel(editPlan: plan, sourceFingerprint: fingerprint)
      wire(model, to: store)
      await model.suggestCutsTapped()
    }

    expectNoDifference(store.value.count, 1)
    expectNoDifference(store.value[id: Fixtures.uuid(1)]?.title, "first")
  }

  @Test func emptyCompletionSucceedsAndReplacesExistingSuggestions() async {
    let fingerprint = "fp-empty"
    let existing = Fixtures.cutSuggestion(id: Fixtures.uuid(1), wordIDs: [10, 11, 12])
    let store = LockIsolated<IdentifiedArrayOf<CutSuggestion>>([existing])

    await withDependencies {
      $0.keychain = .inMemory("sk-keychain")
      $0.cutSuggest = CutSuggestClient { _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.diagnostic("0 raw clips."))
          continuation.yield(.completed([]))
          continuation.finish()
        }
      }
    } operation: {
      let model = CutSuggestionsPageModel(
        editPlan: Fixtures.editPlan(), sourceFingerprint: fingerprint)
      wire(model, to: store)
      await model.suggestCutsTapped()

      expectNoDifference(model.phase, .idle)
      expectNoDifference(model.lastRunDiagnostic, "0 raw clips.")
      await withDependencies {
        $0.cutSuggest = fixtureClient(completed: [])
      } operation: {
        let freshModel = CutSuggestionsPageModel(
          editPlan: Fixtures.editPlan(), sourceFingerprint: fingerprint)
        freshModel.lastRunDiagnostic = "Previous diagnostic"
        await freshModel.suggestCutsTapped()
        expectNoDifference(freshModel.lastRunDiagnostic, nil)
      }
    }

    expectNoDifference(store.value.elements, [])
  }

  @Test func streamFinishingWithoutCompletionSurfacesFailure() async {
    let fingerprint = "fp-nocomplete"
    await withDependencies {
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

      expectNoDifference(
        model.phase,
        .failed("The cut-suggester stopped before returning results."))
      #expect(!model.isSuggesting)
    }
  }

  // MARK: - Error handling

  @Test func streamErrorSurfacesTheMessageAndLeavesTheDocumentEmpty() async {
    let fingerprint = "fp-error"
    let error = CutSuggestClientError.unimplemented("suggestCuts")
    let store = LockIsolated<IdentifiedArrayOf<CutSuggestion>>([])

    await withDependencies {
      $0.keychain = .inMemory("sk-keychain")
      $0.cutSuggest = CutSuggestClient { _, _ in
        AsyncThrowingStream { $0.finish(throwing: error) }
      }
    } operation: {
      let model = CutSuggestionsPageModel(
        editPlan: Fixtures.editPlan(), sourceFingerprint: fingerprint)
      wire(model, to: store)
      await model.suggestCutsTapped()

      expectNoDifference(model.errorMessage, error.errorDescription)
      expectNoDifference(model.phase, .failed(error.errorDescription ?? ""))
    }

    #expect(store.value.isEmpty)
  }

  // MARK: - Key resolution & onboarding

  @Test func noKeyShowsOnboardingAndSuggestPresentsKeyEntryWithoutCallingTheClient() async {
    await withDependencies {
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

  @Test func acceptTappedHandsOffTheSliceAndFlipsTheStatus() {
    let fingerprint = "fp-accept"
    let plan = Fixtures.editPlan()
    let suggestion = stamped(
      Fixtures.cutSuggestion(id: Fixtures.uuid(1), wordIDs: [10, 11, 12, 13, 14, 15, 16]),
      transcriptHash: plan.transcriptHash, fingerprint: fingerprint)
    let store = LockIsolated<IdentifiedArrayOf<CutSuggestion>>([suggestion])
    let acceptedSlice = LockIsolated<Slice?>(nil)

    withDependencies {
      $0.keychain = .inMemory("sk-keychain")
    } operation: {
      let model = CutSuggestionsPageModel(editPlan: plan, sourceFingerprint: fingerprint)
      wire(model, to: store)
      model.onAccept = { slice, id in
        acceptedSlice.setValue(slice)
        store.withValue { $0[id: id]?.accept() }
      }

      model.acceptTapped(suggestion.id)

      expectNoDifference(model.actionMessage, nil)
    }

    expectNoDifference(acceptedSlice.value?.id, suggestion.id)
    expectNoDifference(store.value[id: suggestion.id]?.status, .accepted)
  }

  @Test func acceptTappedOnAStaleSuggestionSurfacesAMessageAndDoesNotAccept() {
    let fingerprint = "fp-stale"
    let plan = Fixtures.editPlan()
    // Same file, different transcript hash → transcript drifted under it.
    let suggestion = stamped(
      Fixtures.cutSuggestion(id: Fixtures.uuid(1), wordIDs: [10, 11, 12]),
      transcriptHash: "different-hash", fingerprint: fingerprint)
    let store = LockIsolated<IdentifiedArrayOf<CutSuggestion>>([suggestion])
    let acceptedSlice = LockIsolated<Slice?>(nil)

    withDependencies { _ in
    } operation: {
      let model = CutSuggestionsPageModel(editPlan: plan, sourceFingerprint: fingerprint)
      wire(model, to: store)
      model.onAccept = { slice, id in
        acceptedSlice.setValue(slice)
        store.withValue { $0[id: id]?.accept() }
      }

      model.acceptTapped(suggestion.id)

      expectNoDifference(model.actionMessage, cutSuggestionStaleMessage(.transcriptChanged))
    }

    #expect(acceptedSlice.value == nil)
    expectNoDifference(store.value[id: suggestion.id]?.status, .pending)
  }

  @Test func acceptTappedOnAnInvalidSuggestionSurfacesAMessage() {
    let fingerprint = "fp-invalid"
    let plan = Fixtures.editPlan()
    let suggestion = stamped(
      Fixtures.cutSuggestion(id: Fixtures.uuid(1), wordIDs: []),
      transcriptHash: plan.transcriptHash, fingerprint: fingerprint)
    let store = LockIsolated<IdentifiedArrayOf<CutSuggestion>>([suggestion])

    withDependencies { _ in
    } operation: {
      let model = CutSuggestionsPageModel(editPlan: plan, sourceFingerprint: fingerprint)
      wire(model, to: store)

      model.acceptTapped(suggestion.id)

      expectNoDifference(model.actionMessage, cutSuggestionInvalidMessage(.noWords))
    }

    expectNoDifference(store.value[id: suggestion.id]?.status, .pending)
  }

  @Test func rejectTappedMarksTheSuggestionRejected() {
    let fingerprint = "fp-reject"
    let plan = Fixtures.editPlan()
    let suggestion = Fixtures.cutSuggestion(id: Fixtures.uuid(1), wordIDs: [10, 11, 12])
    let store = LockIsolated<IdentifiedArrayOf<CutSuggestion>>([suggestion])

    withDependencies { _ in
    } operation: {
      let model = CutSuggestionsPageModel(editPlan: plan, sourceFingerprint: fingerprint)
      wire(model, to: store)

      model.rejectTapped(suggestion.id)
    }

    expectNoDifference(store.value[id: suggestion.id]?.status, .rejected)
  }

  // MARK: - Title editing

  @Test func editableTitleReadsTheCurrentSuggestionTitle() {
    let suggestion = Fixtures.cutSuggestion(id: Fixtures.uuid(1), title: "Original")
    let store = LockIsolated<IdentifiedArrayOf<CutSuggestion>>([suggestion])

    withDependencies { _ in
    } operation: {
      let model = CutSuggestionsPageModel(
        editPlan: Fixtures.editPlan(), sourceFingerprint: "fp-title-read")
      wire(model, to: store)

      expectNoDifference(model.editableTitle(for: suggestion.id), "Original")
      // An unknown ID reads as empty rather than trapping.
      expectNoDifference(model.editableTitle(for: Fixtures.uuid(99)), "")
    }
  }

  @Test func titleChangedUpdatesTheSuggestionTitle() {
    let suggestion = Fixtures.cutSuggestion(id: Fixtures.uuid(1), title: "Original")
    let store = LockIsolated<IdentifiedArrayOf<CutSuggestion>>([suggestion])

    withDependencies { _ in
    } operation: {
      let model = CutSuggestionsPageModel(
        editPlan: Fixtures.editPlan(), sourceFingerprint: "fp-title-edit")
      wire(model, to: store)

      model.titleChanged(suggestion.id, to: "Renamed")
      expectNoDifference(model.editableTitle(for: suggestion.id), "Renamed")
    }

    expectNoDifference(store.value[id: suggestion.id]?.title, "Renamed")
  }

  // MARK: - Ranked, grouped presentation + freshness

  @Test func sectionsGroupByProductTypeInRankedOrderWithFreshnessFlags() {
    let fingerprint = "fp-sections"
    let plan = Fixtures.editPlan()
    let hash = plan.transcriptHash
    let spotlight = stamped(
      Fixtures.cutSuggestion(
        id: Fixtures.uuid(1), productType: .spotlight, title: "Story",
        wordIDs: [10, 11, 12], rank: 1),
      transcriptHash: hash, fingerprint: fingerprint)
    // transcript drifted under the intro
    let intro = stamped(
      Fixtures.cutSuggestion(
        id: Fixtures.uuid(2), productType: .intro, title: "Setup", song: "Hit",
        wordIDs: [13, 14], rank: 2),
      transcriptHash: "stale", fingerprint: fingerprint)
    let store = LockIsolated<IdentifiedArrayOf<CutSuggestion>>([intro, spotlight])

    withDependencies { _ in
    } operation: {
      let model = CutSuggestionsPageModel(editPlan: plan, sourceFingerprint: fingerprint)
      wire(model, to: store)

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

  // MARK: - Row tap → reveal

  @Test func rowTappedHandsTheSuggestionToTheEditor() {
    let fingerprint = "fp-tap"
    let suggestion = Fixtures.cutSuggestion(id: Fixtures.uuid(1), wordIDs: [10, 11, 12])
    let store = LockIsolated<IdentifiedArrayOf<CutSuggestion>>([suggestion])
    let selected = LockIsolated<CutSuggestion?>(nil)

    withDependencies { _ in
    } operation: {
      let model = CutSuggestionsPageModel(
        editPlan: Fixtures.editPlan(), sourceFingerprint: fingerprint)
      wire(model, to: store)
      model.onSelectSuggestion = { selected.setValue($0) }

      model.rowTapped(suggestion.id)
    }

    expectNoDifference(selected.value?.id, suggestion.id)
  }

  @Test func rowTappedWithAnUnknownIDIsANoOp() {
    let selected = LockIsolated<CutSuggestion?>(nil)

    withDependencies { _ in
    } operation: {
      let model = CutSuggestionsPageModel(
        editPlan: Fixtures.editPlan(), sourceFingerprint: "fp-tap-unknown")
      model.onSelectSuggestion = { selected.setValue($0) }

      model.rowTapped(Fixtures.uuid(42))
    }

    #expect(selected.value == nil)
  }

  // MARK: - Auto-suggest on load

  @Test func autoSuggestRunsAndEmitsWhenEmptyWithAKey() async {
    let fingerprint = "fp-auto-empty"
    let plan = Fixtures.editPlan()
    let raw = Fixtures.cutSuggestion(id: Fixtures.uuid(1), wordIDs: [10, 11, 12])
    let store = LockIsolated<IdentifiedArrayOf<CutSuggestion>>([])

    await withDependencies {
      $0.keychain = .inMemory("sk-keychain")
      $0.cutSuggest = fixtureClient(completed: [raw])
    } operation: {
      let model = CutSuggestionsPageModel(editPlan: plan, sourceFingerprint: fingerprint)
      wire(model, to: store)
      await model.autoSuggestCutsIfNeeded()

      expectNoDifference(model.phase, .idle)
    }

    expectNoDifference(store.value[id: raw.id]?.id, raw.id)
  }

  @Test func autoSuggestSkipsWhenSuggestionsAlreadyExist() async {
    let fingerprint = "fp-auto-exists"
    let existing = Fixtures.cutSuggestion(id: Fixtures.uuid(1), wordIDs: [10, 11, 12])
    let store = LockIsolated<IdentifiedArrayOf<CutSuggestion>>([existing])
    let capture = LockIsolated<CutSuggestRequest?>(nil)

    await withDependencies {
      $0.keychain = .inMemory("sk-keychain")
      $0.cutSuggest = fixtureClient(completed: [], capture: capture)
    } operation: {
      let model = CutSuggestionsPageModel(
        editPlan: Fixtures.editPlan(), sourceFingerprint: fingerprint)
      wire(model, to: store)
      await model.autoSuggestCutsIfNeeded()

      expectNoDifference(model.phase, .idle)
    }

    // The cutter was never called (guarded off) and the existing suggestions are untouched.
    #expect(capture.value == nil)
    expectNoDifference(store.value.elements, [existing])
  }

  @Test func autoSuggestIsSilentWithNoKeyAndDoesNotPresentKeyEntry() async {
    let fingerprint = "fp-auto-nokey"
    let store = LockIsolated<IdentifiedArrayOf<CutSuggestion>>([])
    let capture = LockIsolated<CutSuggestRequest?>(nil)

    await withDependencies {
      $0.keychain = .inMemory(nil)
      $0.environment = .constant([:])
      $0.cutSuggest = fixtureClient(completed: [], capture: capture)
    } operation: {
      let model = CutSuggestionsPageModel(
        editPlan: Fixtures.editPlan(), sourceFingerprint: fingerprint)
      wire(model, to: store)
      await model.autoSuggestCutsIfNeeded()

      // No cutter call, no onboarding sheet, nothing written — a background pass never nags.
      #expect(model.keyEntry == nil)
      expectNoDifference(model.phase, .idle)
    }

    #expect(capture.value == nil)
    #expect(store.value.isEmpty)
  }

  @Test func autoSuggestDoesNotClobberSuggestionsThatLandMidFlight() async {
    let fingerprint = "fp-auto-race"
    let plan = Fixtures.editPlan()
    // A suggestion the user has already accepted, landing while the background pass runs.
    let decided = Fixtures.cutSuggestion(id: Fixtures.uuid(7), wordIDs: [1, 2], status: .accepted)
    let autoCandidate = Fixtures.cutSuggestion(id: Fixtures.uuid(9), wordIDs: [3, 4])
    let store = LockIsolated<IdentifiedArrayOf<CutSuggestion>>([])

    await withDependencies {
      $0.keychain = .inMemory("sk-keychain")
      $0.cutSuggest = CutSuggestClient { _, _ in
        AsyncThrowingStream { continuation in
          // Simulate suggestions (with a user decision) landing in the document while the
          // background pass is in flight, before it completes.
          store.withValue { $0 = [decided] }
          continuation.yield(.completed([autoCandidate]))
          continuation.finish()
        }
      }
    } operation: {
      let model = CutSuggestionsPageModel(editPlan: plan, sourceFingerprint: fingerprint)
      wire(model, to: store)
      await model.autoSuggestCutsIfNeeded()

      expectNoDifference(model.phase, .idle)
    }

    // The mid-flight suggestion and its accepted status survive; the auto candidate is dropped.
    expectNoDifference(store.value.elements, [decided])
  }

  // MARK: - Show/hide suggestions toggle

  @Test func showsSuggestionBandsDefaultsOnAndTheToggleTracksPendingSuggestions() {
    let pending = Fixtures.cutSuggestion(id: Fixtures.uuid(1), wordIDs: [10, 11, 12])

    let emptyModel = CutSuggestionsPageModel(
      editPlan: Fixtures.editPlan(), sourceFingerprint: "fp-toggle")
    expectNoDifference(emptyModel.showsSuggestionBands, true)
    // No pending suggestions → the toggle has nothing to mute, so it stays hidden.
    expectNoDifference(emptyModel.showsSuggestionsToggle, false)

    let store = LockIsolated<IdentifiedArrayOf<CutSuggestion>>([pending])
    let model = CutSuggestionsPageModel(
      editPlan: Fixtures.editPlan(), sourceFingerprint: "fp-toggle-pending")
    wire(model, to: store)
    expectNoDifference(model.showsSuggestionsToggle, true)
  }
}
