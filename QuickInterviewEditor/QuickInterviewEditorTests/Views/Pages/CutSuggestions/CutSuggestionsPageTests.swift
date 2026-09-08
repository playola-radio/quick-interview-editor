import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
import IdentifiedCollections
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct CutSuggestionsPageTests {

  @Test func replacementRequiresConfirmationBeforePreparingOrCallingProvider() async {
    let calls = LockIsolated(0)
    let preparations = LockIsolated(0)
    let existing = Fixtures.cutSuggestion(id: Fixtures.uuid(1), wordIDs: [10, 11, 12])
    let store = LockIsolated<IdentifiedArrayOf<CutSuggestion>>([existing])
    await withDependencies {
      $0.uuid = .incrementing
      $0.keychain = .inMemory("test-key")
      $0.suggestionConfiguration = .inMemory()
      $0.suggestionRecovery.prepare = { _, _ in
        preparations.withValue { $0 += 1 }
        return URL(fileURLWithPath: "/unused")
      }
      $0.cutSuggest = CutSuggestClient { _, _ in
        calls.withValue { $0 += 1 }
        return AsyncThrowingStream { $0.finish() }
      }
    } operation: {
      let model = CutSuggestionsPageModel(
        editPlan: Fixtures.editPlan(), sourceFingerprint: "confirmation")
      wire(model, to: store)
      await model.suggestCutsTapped()
      expectNoDifference(calls.value, 0)
      expectNoDifference(preparations.value, 0)
      expectNoDifference(store.value, [existing])
    }
  }

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
  /// `currentSuggestions` and its intents (`onAccept`/`onReject`)
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
  }

  private func stamped(
    _ suggestion: CutSuggestion, transcriptHash: String, fingerprint: String
  ) -> CutSuggestion {
    var copy = suggestion
    copy.provenance = .init(
      model: "claude-sonnet-5", promptVersion: "v2", productSpecVersion: "v1",
      transcriptHash: transcriptHash, sourceFingerprint: fingerprint, diarizationHash: nil)
    return copy
  }

  @Test func pageUsesConfiguredDurableRunAndKeychainBeforeEnvironment() async throws {
    try await withMainSerialExecutor {
      let fixture = SuggestionRunFixture()
      try await withDependencies {
        fixture.install(&$0)
        $0.keychain = .inMemory("keychain-value")
        $0.environment = .constant([anthropicAPIKeyEnvVar: "env-value"])
      } operation: {
        let model = CutSuggestionsPageModel(
          editPlan: Fixtures.editPlan(), sourceFingerprint: fixture.owner.sourceFingerprint)
        fixture.wirePage(model)
        let task = Task { await model.suggestCutsTapped() }
        await fixture.waitForRequests()
        let request = try #require(fixture.state.value.requests.first)
        expectNoDifference(request.snapshot?.configuration, SuggestionDefaults.configuration)
        expectNoDifference(request.transcriptUnits, Fixtures.editPlan().transcriptUnits)
        expectNoDifference(request.mode, .fresh)
        expectNoDifference(fixture.state.value.keys.first!, "keychain-value")
        fixture.finish([fixture.candidate()])
        await task.value
        expectNoDifference(model.phase, .idle)
        expectNoDifference(model.suggestions.first?.title, "Spotlight 1")
        expectNoDifference(
          model.suggestions.first?.provenance.sourceFingerprint, fixture.owner.sourceFingerprint)
        #expect(model.suggestions.first?.naming != nil)
      }
    }
  }

  @Test func emptyReadyRendersDiagnosticAfterReplacementConfirmation() async throws {
    try await withMainSerialExecutor {
      let fixture = SuggestionRunFixture()
      fixture.document.withValue { $0.cutSuggestions = [fixture.candidate()] }
      try await withDependencies {
        fixture.install(&$0)
      } operation: {
        let model = CutSuggestionsPageModel(
          editPlan: Fixtures.editPlan(), sourceFingerprint: fixture.owner.sourceFingerprint)
        fixture.wirePage(model)
        await model.suggestCutsTapped()
        expectNoDifference(model.run.phase, .confirmingReplacement)
        let task = Task { await model.run.replaceConfirmed() }
        await fixture.waitForRequests()
        let stream = try #require(fixture.state.value.continuations.first)
        stream.yield(.diagnostic("0 raw clips."))
        fixture.finish()
        await task.value
        expectNoDifference(model.lastRunDiagnostic, "0 raw clips.")
        expectNoDifference(model.suggestions, [])
        expectNoDifference(model.phase, .idle)
      }
    }
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

      model.run.phase = .running(runID: Fixtures.uuid(1), message: "Working…")
      expectNoDifference(model.isSuggesting, true)
      expectNoDifference(model.progressMessage, "Working…")
      expectNoDifference(model.showsProgress, true)
      expectNoDifference(model.showsEmptyState, false)

      model.run.phase = .failed(message: "boom")
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

  @Test func autoSuggestRunsAndEmitsWhenEmptyWithAKey() async throws {
    try await withMainSerialExecutor {
      let fixture = SuggestionRunFixture()
      try await withDependencies {
        fixture.install(&$0)
      } operation: {
        let model = CutSuggestionsPageModel(
          editPlan: Fixtures.editPlan(), sourceFingerprint: fixture.owner.sourceFingerprint)
        fixture.wirePage(model)
        let task = Task { await model.autoSuggestCutsIfNeeded() }
        await fixture.waitForRequests()
        expectNoDifference(fixture.state.value.requests.first?.mode, .automatic)
        _ = try #require(fixture.state.value.continuations.first)
        fixture.finish([fixture.candidate()])
        await task.value
        expectNoDifference(model.suggestions.count, 1)
      }
    }
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
