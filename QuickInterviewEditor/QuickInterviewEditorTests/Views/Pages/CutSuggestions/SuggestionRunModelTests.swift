import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
import IdentifiedCollections
import Testing

@testable import PlayolaInterviewEditor

final class SuggestionRunFixture: Sendable {
  struct State {
    var checkpoint: SuggestionRunCheckpoint?
    var pythonPhase: SuggestionRunCheckpoint.Phase = .discovering
    var requests: [CutSuggestRequest] = []
    var keys: [String?] = []
    var prepared: [SuggestionRecoveryPreparation] = []
    var controls: [SuggestionRecoveryControl] = []
    var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    var continuations: [AsyncThrowingStream<CutSuggestEvent, Error>.Continuation] = []
  }
  let state = LockIsolated(State())
  let document = LockIsolated(EditorDocumentState())
  let owner = SuggestionRecoveryOwner(
    id: Fixtures.uuid(800), documentURL: nil, sourceFingerprint: "run-fixture",
    transcriptHash: Fixtures.editPlan().transcriptHash)
  let directory = URL(fileURLWithPath: "/validated/test-journal")
  var client: CutSuggestClient {
    CutSuggestClient { [self] request, key in
      AsyncThrowingStream { continuation in
        state.withValue {
          $0.requests.append(request)
          $0.keys.append(key)
          $0.continuations.append(continuation)
          let count = $0.requests.count
          let ready = $0.waiters.filter { $0.0 <= count }
          $0.waiters.removeAll { $0.0 <= count }
          for waiter in ready { waiter.1.resume() }

        }
      }
    }
  }
  func waitForRequests(_ count: Int = 1) async {
    await withCheckedContinuation { continuation in
      state.withValue {
        if $0.requests.count >= count {
          continuation.resume()
        } else {
          $0.waiters.append((count, continuation))
        }
      }
    }
  }

  var recovery: SuggestionRecoveryClient {
    var client = SuggestionRecoveryClient.testValue
    client.prepare = { [self] _, preparation in
      state.withValue {
        $0.prepared.append(preparation)
        $0.pythonPhase = .discovering
        $0.checkpoint = .init(
          pythonRevision: 0, controlRevision: preparation.control.revision,
          originalBatchFingerprint: preparation.control.originalBatchFingerprint,
          snapshot: preparation.snapshot, phase: .discovering, candidates: [],
          completedRequestKeys: [], failedRequestKeys: [],
          proposedStarts: preparation.control.proposedStarts)
      }
      return directory
    }
    client.capture = { [self] _, runID, revision in
      guard let checkpoint = state.value.checkpoint, checkpoint.snapshot.runID == runID,
        checkpoint.pythonRevision >= (revision ?? 0)
      else { throw SuggestionRecoveryError.missingRun }
      return .init(checkpoint: checkpoint, archive: Data(), journalDirectory: directory)
    }
    client.load = { [self] _ in state.value.checkpoint }
    client.updateControl = { [self] _, runID, control, expected in
      try state.withValue {
        guard $0.checkpoint?.snapshot.runID == runID, $0.checkpoint?.controlRevision == expected
        else {
          throw SuggestionRecoveryError.staleControl
        }
        $0.controls.append(control)
        $0.checkpoint?.controlRevision = control.revision
        $0.checkpoint?.proposedStarts = control.proposedStarts
        $0.checkpoint?.originalBatchFingerprint = control.originalBatchFingerprint
        $0.checkpoint?.phase = control.isPaused ? .paused : $0.pythonPhase
      }
    }
    client.discard = { [self] _, _ in state.withValue { $0.checkpoint = nil } }
    return client
  }

  @MainActor func install(_ dependencies: inout DependencyValues) {
    dependencies.suggestionConfiguration = .inMemory()
    dependencies.suggestionRecovery = recovery
    dependencies.cutSuggest = client
    dependencies.keychain = .inMemory("ephemeral-test-key")
    dependencies.environment = .constant([:])
    dependencies.uuid = .incrementing
  }

  @MainActor func wire(_ model: SuggestionRunModel) {
    model.currentDocument = { [self] in document.value }
    model.currentOwner = { [self] in owner }
    model.resolveAPIKey = { "ephemeral-test-key" }
    model.prepare = { [self, weak model] preparation in
      let directory = try await recovery.prepare(owner, preparation)
      let capture = try await recovery.capture(owner, preparation.snapshot.runID, nil)
      try model?.onCheckpoint(capture)
      return directory
    }
    model.onCheckpoint = { [self] capture in
      document.withValue {
        $0.suggestionRecoveryOwnerID = owner.id
        $0.unfinishedSuggestionRun = capture.checkpoint
      }
    }
    model.onApply = { [self] candidates, batch in
      document.withValue {
        $0.cutSuggestions = IdentifiedArray(uniqueElements: candidates)
        $0.suggestionBatch = batch
        $0.lastAppliedSuggestionRunID = batch.snapshot.runID
        $0.unfinishedSuggestionRun = nil
      }
    }
    model.onDiscard = { [self] in
      state.withValue { $0.checkpoint = nil }
      document.withValue { $0.unfinishedSuggestionRun = nil }
    }
  }

  @MainActor func wirePage(_ model: CutSuggestionsPageModel) {
    let resolveKey = model.run.resolveAPIKey
    wire(model.run)
    model.run.resolveAPIKey = resolveKey
    model.currentSuggestions = { [self] in document.value.cutSuggestions }
  }

  @MainActor func wireEditor(_ editor: EditorModel) {
    wire(editor.cutSuggestions.run)
    editor.cutSuggestions.run.currentDocument = { [weak editor] in editor?.documentState ?? .init()
    }
    editor.cutSuggestions.run.onCheckpoint = { [weak editor] capture in
      guard let editor else { throw CancellationError() }
      editor.mutateDocument(recordUndo: false) {
        $0.suggestionRecoveryOwnerID = self.owner.id
        $0.unfinishedSuggestionRun = capture.checkpoint
      }
    }
    editor.cutSuggestions.run.onApply = { [weak editor] candidates, batch in
      guard let editor else { throw CancellationError() }
      try editor.applySuggestionRun(candidates: candidates, batch: batch)
    }
  }

  @MainActor func model(options: CutSuggestOptions = .freshConfigured) -> SuggestionRunModel {
    let model = SuggestionRunModel(
      editPlan: Fixtures.editPlan(), sourceFingerprint: owner.sourceFingerprint, options: options)
    wire(model)
    return model
  }

  func checkpoint(
    phase: SuggestionRunCheckpoint.Phase, candidates: [CutSuggestion] = [],
    completed: [String] = [], failed: [String] = [], message: String? = nil
  ) {
    state.withValue {
      $0.pythonPhase = phase
      $0.checkpoint?.phase = phase
      $0.checkpoint?.pythonRevision += 1
      let snapshot = $0.checkpoint?.snapshot
      $0.checkpoint?.candidates = candidates.map { candidate in
        var candidate = candidate
        if let snapshot {
          candidate.provenance = .init(
            model: snapshot.model, promptVersion: snapshot.discoveryPromptVersion,
            productSpecVersion: snapshot.productSpecVersion,
            transcriptHash: snapshot.transcriptHash,
            sourceFingerprint: snapshot.sourceFingerprint, diarizationHash: nil)
        }
        return candidate
      }
      $0.checkpoint?.completedRequestKeys = completed
      $0.checkpoint?.failedRequestKeys = failed
      $0.checkpoint?.failureMessage = message
    }
  }

  func finish(_ candidates: [CutSuggestion] = [], attempt: Int = 0) {
    checkpoint(phase: .ready, candidates: candidates)
    state.value.continuations[attempt].yield(.completed(candidates))
    state.value.continuations[attempt].finish()
  }

  func candidate(_ id: Int = 1) -> CutSuggestion {
    var candidate = Fixtures.cutSuggestion(id: Fixtures.uuid(id), wordIDs: [10, 11, 12])
    candidate.productType = ProductType(rawValue: "spotlight")!
    candidate.title = "Story"
    return candidate
  }
}

@MainActor
@Suite(.serialized)
struct SuggestionRunModelTests {
  @Test func resumedRequestKeepsCapturedVersionsInsteadOfFreshConfiguredDefaults() {
    let model = SuggestionRunModel(editPlan: Fixtures.editPlan(), sourceFingerprint: "fresh")
    var captured = suggestionResultSnapshot()
    captured.model = "captured-model"
    captured.discoveryPromptVersion = "configured-v1"
    captured.extractionPromptVersion = "captured-fields"
    captured.stage1Window = 70
    captured.stage1Step = 60
    let request = model.makeRequest(captured, .resume, nil)
    expectNoDifference(request.snapshot, captured)
    expectNoDifference(
      request.options,
      CutSuggestOptions(
        model: "captured-model", promptVersion: "configured-v1",
        productSpecVersion: captured.productSpecVersion, stage1Window: 70, stage1Step: 60))
  }

  @Test func freshRunUsesConfiguredDiscoveryVersion() {
    let model = SuggestionRunModel(editPlan: Fixtures.editPlan(), sourceFingerprint: "fresh")
    expectNoDifference(model.options.promptVersion, "configured-v5")
  }

  @Test(arguments: [
    ("configured-v5", "fields-v3"), ("configured-v4", "fields-v2"), ("configured-v3", "fields-v1"),
  ])
  func freshSearchCapturesInterviewArtistAndResumeKeepsItAfterProjectEdit(
    discoveryVersion: String, extractionVersion: String
  ) async throws {
    try await withMainSerialExecutor {
      let fixture = SuggestionRunFixture()
      fixture.document.withValue { $0.interviewArtist = "River Vale" }
      try await withDependencies {
        fixture.install(&$0)
      } operation: {
        let model = fixture.model(options: CutSuggestOptions(promptVersion: discoveryVersion))
        let task = Task { await model.suggestTapped() }
        await fixture.waitForRequests()
        let first = try #require(fixture.state.value.requests.first)
        expectNoDifference(first.snapshot?.interviewArtist, "River Vale")
        expectNoDifference(first.snapshot?.extractionPromptVersion, extractionVersion)
        fixture.checkpoint(phase: .needsRetry, completed: ["saved"], failed: ["retry"])
        fixture.state.value.continuations[0].yield(
          .recoverableFailure(
            runID: try #require(first.snapshot?.runID),
            failedRequestKeys: ["retry"], message: "retry"))
        fixture.state.value.continuations[0].finish()
        await task.value
        fixture.document.withValue { $0.interviewArtist = "Changed Project Artist" }
        let reopened = fixture.model()
        let retry = Task { await reopened.resumeTapped() }
        await fixture.waitForRequests(2)
        expectNoDifference(fixture.state.value.requests.last?.snapshot, first.snapshot)
        fixture.finish([], attempt: 1)
        await retry.value
        expectNoDifference(fixture.document.value.interviewArtist, "Changed Project Artist")
      }
    }
  }

  @Test func confirmationCancelPreservesTheExactDocumentWithoutPreparing() async {
    let fixture = SuggestionRunFixture()
    fixture.document.withValue {
      $0.cutSuggestions = [fixture.candidate()]
      $0.slices = [Fixtures.slice(id: Fixtures.uuid(99))]
      $0.suggestionStarts = .init(types: ["spotlight": .init(number: 8, isExplicit: true)])
    }
    let before = fixture.document.value
    await withDependencies {
      fixture.install(&$0)
    } operation: {
      let model = fixture.model()
      await model.suggestTapped()
      expectNoDifference(model.phase, .confirmingReplacement)
      expectNoDifference(fixture.state.value.prepared.count, 0)
      expectNoDifference(fixture.state.value.requests.count, 0)
      expectNoDifference(model.replaceTitle, "Replace existing suggestions?")
      expectNoDifference(
        model.replaceMessage,
        "This will run a new search and replace the current suggestions. Your saved clips will not be changed."
      )
      expectNoDifference(model.replaceButtonTitle, "Replace Suggestions")
      expectNoDifference(model.cancelButtonTitle, "Cancel")
      model.cancelReplacementTapped()
      expectNoDifference(model.phase, .idle)
      expectNoDifference(fixture.document.value, before)
    }
  }

  @Test func emptyReadyClearsOnlyTheBatchAndCapturesOriginalRequestBeforeProvider() async throws {
    try await withMainSerialExecutor {
      let fixture = SuggestionRunFixture()
      fixture.document.withValue {
        $0.cutSuggestions = [fixture.candidate()]
        $0.slices = [Fixtures.slice(id: Fixtures.uuid(99))]
        $0.suggestionStarts = .init(types: ["spotlight": .init(number: 7, isExplicit: true)])
      }
      let before = fixture.document.value
      try await withDependencies {
        fixture.install(&$0)
      } operation: {
        let model = fixture.model()
        await model.suggestTapped()
        let task = Task { await model.replaceConfirmed() }
        await fixture.waitForRequests()
        let request = try #require(fixture.state.value.requests.first)
        let preparation = try #require(fixture.state.value.prepared.first)
        #expect(fixture.document.value.unfinishedSuggestionRun != nil)
        expectNoDifference(request.journalDirectory, fixture.directory)
        let json = try #require(
          JSONSerialization.jsonObject(with: preparation.originalRequest) as? [String: Any])
        #expect(json["journal_directory"] == nil)
        expectNoDifference(request.snapshot?.stage1Window, 130)
        expectNoDifference(request.snapshot?.stage1Step, 110)
        fixture.finish()
        await task.value
        expectNoDifference(model.phase, .idle)
        expectNoDifference(model.activeAttemptID, nil)
        expectNoDifference(fixture.document.value.cutSuggestions.elements, [])
        expectNoDifference(fixture.document.value.slices, before.slices)
        expectNoDifference(fixture.document.value.suggestionStarts, before.suggestionStarts)
        expectNoDifference(
          fixture.document.value.lastAppliedSuggestionRunID, request.snapshot?.runID)
        expectNoDifference(fixture.document.value.unfinishedSuggestionRun, nil)
      }
    }
  }

  @Test func bareCompletionAndProviderFailurePreserveOldBatchAndFutureStarts() async throws {
    for failure in [true, false] {
      try await withMainSerialExecutor {
        let fixture = SuggestionRunFixture()
        fixture.document.withValue {
          $0.cutSuggestions = [fixture.candidate()]
          $0.slices = [Fixtures.slice(id: Fixtures.uuid(99))]
          $0.suggestionStarts.types["spotlight"] = .init(number: 3, isExplicit: true)
        }
        let before = fixture.document.value
        try await withDependencies {
          fixture.install(&$0)
        } operation: {
          let model = fixture.model()
          await model.suggestTapped()
          let task = Task { await model.replaceConfirmed() }
          await fixture.waitForRequests()
          let stream = try #require(fixture.state.value.continuations.first)
          if failure {
            stream.finish(throwing: CutSuggestClientError.decodeFailed("Malformed result"))
          } else {
            stream.yield(.completed([]))
            stream.finish()
          }
          await task.value
          #expect(!model.isRunning)
          #expect(model.message != nil)
          expectNoDifference(fixture.document.value.cutSuggestions, before.cutSuggestions)
          expectNoDifference(fixture.document.value.slices, before.slices)
          expectNoDifference(fixture.document.value.suggestionStarts, before.suggestionStarts)
          #expect(model.canResume)
          #expect(!model.candidatesLocked)
        }
      }
    }
  }

  @Test func partialExtractionResumeUsesSameRunAndOnlyMissingWork() async throws {
    try await withMainSerialExecutor {
      let fixture = SuggestionRunFixture()
      try await withDependencies {
        fixture.install(&$0)
      } operation: {
        let model = SuggestionRunModel(
          editPlan: Fixtures.editPlan(), sourceFingerprint: fixture.owner.sourceFingerprint,
          options: .init(model: "captured-model", promptVersion: "configured-v1"))
        fixture.wire(model)
        let task = Task { await model.suggestTapped() }
        await fixture.waitForRequests()
        let runID = try #require(model.activeRunID)
        let firstAttempt = model.activeAttemptID
        fixture.checkpoint(
          phase: .needsRetry, completed: ["one", "two", "three", "four"],
          failed: ["five"], message: "One field request failed.")
        fixture.state.value.continuations[0].yield(
          .recoverableFailure(
            runID: runID, failedRequestKeys: ["five"], message: "retry"))
        fixture.state.value.continuations[0].finish()
        await task.value
        expectNoDifference(model.message, "One field request failed.")
        let reopened = fixture.model()
        expectNoDifference(reopened.options.promptVersion, "configured-v5")
        let retry = Task { await reopened.resumeTapped() }
        await fixture.waitForRequests(2)
        expectNoDifference(fixture.state.value.prepared.count, 1)
        expectNoDifference(fixture.state.value.requests.count, 2)
        expectNoDifference(fixture.state.value.requests.last?.mode, .resume)
        expectNoDifference(
          fixture.state.value.requests.last?.options.promptVersion, "configured-v1")
        expectNoDifference(fixture.state.value.requests.last?.options.model, "captured-model")
        expectNoDifference(fixture.state.value.requests.last?.snapshot?.runID, runID)
        expectNoDifference(fixture.state.value.requests.last?.journalDirectory, fixture.directory)
        expectNoDifference(
          fixture.document.value.unfinishedSuggestionRun?.completedRequestKeys,
          ["one", "two", "three", "four"])
        #expect(reopened.activeAttemptID != firstAttempt)
        fixture.finish([fixture.candidate()], attempt: 1)
        await retry.value
        expectNoDifference(fixture.document.value.cutSuggestions.count, 1)
      }
    }
  }

  @Test func cancelAndDiscardIgnoreLateCompletionAndUnlockOldBatch() async throws {
    try await withMainSerialExecutor {
      let fixture = SuggestionRunFixture()
      fixture.document.withValue { $0.cutSuggestions = [fixture.candidate()] }
      try await withDependencies {
        fixture.install(&$0)
      } operation: {
        let model = fixture.model()
        await model.suggestTapped()
        let task = Task { await model.replaceConfirmed() }
        await fixture.waitForRequests()
        let stream = try #require(fixture.state.value.continuations.first)
        model.cancelSearchTapped()
        expectNoDifference(model.activeAttemptID, nil)
        stream.yield(.completed([]))
        await model.waitUntilStopped()
        await task.value
        expectNoDifference(fixture.document.value.cutSuggestions.count, 1)
        expectNoDifference(fixture.document.value.unfinishedSuggestionRun?.phase, .paused)
        #expect(!model.candidatesLocked)
        await model.discardSearchTapped()
        stream.yield(.progress("Late old event"))
        expectNoDifference(model.phase, .idle)
        expectNoDifference(fixture.document.value.unfinishedSuggestionRun, nil)
        expectNoDifference(fixture.document.value.cutSuggestions.count, 1)
      }
    }
  }

  @Test func changedBaselineResumeConfirmsAndCancelRestoresPausedState() async throws {
    try await withMainSerialExecutor {
      let fixture = SuggestionRunFixture()
      fixture.document.withValue { $0.cutSuggestions = [fixture.candidate()] }
      try await withDependencies {
        fixture.install(&$0)
      } operation: {
        let model = fixture.model()
        await model.suggestTapped()
        let task = Task { await model.replaceConfirmed() }
        await fixture.waitForRequests()
        model.cancelSearchTapped()
        await model.waitUntilStopped()
        await task.value
        fixture.document.withValue { $0.cutSuggestions[id: Fixtures.uuid(1)]?.reject() }
        let before = fixture.document.value
        let previous = model.phase
        await model.resumeTapped()
        expectNoDifference(model.phase, .confirmingReplacement)
        model.cancelReplacementTapped()
        expectNoDifference(model.phase, previous)
        expectNoDifference(fixture.document.value, before)
        await model.resumeTapped()
        let retry = Task { await model.replaceConfirmed() }
        await fixture.waitForRequests(2)
        expectNoDifference(
          fixture.state.value.controls.last?.originalBatchFingerprint,
          try suggestionBatchFingerprint(fixture.document.value))
        fixture.finish([], attempt: 1)
        await retry.value
        expectNoDifference(fixture.document.value.cutSuggestions.elements, [])
      }
    }
  }

  @Test func searchCompletesWithoutReservingNumbersOrConflictingWithIssuedFloor() async throws {
    let fixture = SuggestionRunFixture()
    fixture.document.withValue {
      $0.suggestionStarts.types["spotlight"] = .init(number: 1, isExplicit: true)
      $0.issuedSuggestionNumbers = [
        .init(
          candidateID: Fixtures.uuid(99),
          key: .init(typeID: "spotlight", fields: [], provisionalCandidateID: nil),
          number: Int.max, canonicalValues: [:])
      ]
    }
    await withDependencies {
      fixture.install(&$0)
    } operation: {
      let model = fixture.model()
      let before = fixture.document.value
      let task = Task { await model.suggestTapped() }
      await fixture.waitForRequests()
      fixture.finish([fixture.candidate()])
      await task.value
      expectNoDifference(model.phase, .idle)
      expectNoDifference(fixture.document.value.cutSuggestions.first?.title, "Story")
      expectNoDifference(fixture.document.value.cutSuggestions.first?.naming?.reservation, nil)
      expectNoDifference(
        fixture.document.value.issuedSuggestionNumbers, before.issuedSuggestionNumbers)
      expectNoDifference(fixture.document.value.suggestionStarts, before.suggestionStarts)
      expectNoDifference(fixture.state.value.requests.count, 1)
    }
  }

  @Test func oldCompletedNumberingCheckpointAppliesOfflineAsDescriptiveUnissuedSuggestions()
    async throws
  {
    let fixture = SuggestionRunFixture()
    try await withDependencies {
      fixture.install(&$0)
    } operation: {
      let model = fixture.model()
      let task = Task { await model.suggestTapped() }
      await fixture.waitForRequests()
      fixture.checkpoint(phase: .needsNumbering, candidates: [fixture.candidate()])
      fixture.state.value.continuations[0].finish(throwing: CancellationError())
      await task.value
      let captured = try #require(fixture.state.value.checkpoint)
      fixture.document.withValue { $0.unfinishedSuggestionRun = captured }
      let reopened = fixture.model()
      reopened.synchronizeDocument()
      #expect(!reopened.showsNumbering)
      #expect(reopened.canResume)
      await reopened.resumeTapped()
      expectNoDifference(reopened.phase, .idle)
      expectNoDifference(fixture.state.value.requests.count, 1)
      expectNoDifference(fixture.document.value.cutSuggestions.first?.title, "Story")
      expectNoDifference(fixture.document.value.cutSuggestions.first?.naming?.reservation, nil)
      expectNoDifference(fixture.document.value.unfinishedSuggestionRun, nil)
      expectNoDifference(fixture.document.value.suggestionBatch?.snapshot, captured.snapshot)
    }
  }

  @Test func readyReopenIsOfflineAndIgnoresChangedGlobalConfiguration() async throws {
    try await withMainSerialExecutor {
      let fixture = SuggestionRunFixture()
      try await withDependencies {
        fixture.install(&$0)
      } operation: {
        let model = fixture.model()
        let task = Task { await model.suggestTapped() }
        await fixture.waitForRequests()
        model.cancelSearchTapped()
        await model.waitUntilStopped()
        await task.value
        fixture.checkpoint(phase: .ready, candidates: [fixture.candidate()])
        fixture.state.withValue { $0.checkpoint?.phase = .paused }
        let capture = try await fixture.recovery.capture(
          fixture.owner, try #require(model.activeRunID), nil)
        fixture.document.withValue { $0.unfinishedSuggestionRun = capture.checkpoint }
        await withDependencies {
          $0.suggestionConfiguration.load = {
            throw SuggestionRecoveryError.invalid("Changed configuration")
          }
        } operation: {
          let reopened = fixture.model()
          reopened.resolveAPIKey = { nil }
          reopened.synchronizeDocument()
          await reopened.resumeTapped()
          expectNoDifference(reopened.phase, .idle)
          expectNoDifference(fixture.document.value.cutSuggestions.count, 1)
          expectNoDifference(fixture.state.value.requests.count, 1)
          expectNoDifference(
            fixture.document.value.suggestionBatch?.snapshot.configuration,
            SuggestionDefaults.configuration)
        }
      }
    }
  }

  @Test func automaticRaceCannotOverwriteNewCandidatesAndSecondSearchCannotStart() async {
    await withMainSerialExecutor {
      let fixture = SuggestionRunFixture()
      await withDependencies {
        fixture.install(&$0)
      } operation: {
        let model = fixture.model()
        let task = Task { await model.automaticSearchIfNeeded() }
        await fixture.waitForRequests()
        await model.suggestTapped()
        fixture.document.withValue { $0.cutSuggestions = [fixture.candidate(9)] }
        fixture.finish([])
        await task.value
        expectNoDifference(fixture.document.value.cutSuggestions.map(\.id), [Fixtures.uuid(9)])
        expectNoDifference(fixture.state.value.requests.count, 1)
        await model.suggestTapped()
        expectNoDifference(fixture.state.value.requests.count, 1)
        #expect(model.canResume)
      }
    }
  }

  @Test func streamEndingWithoutCompletionIsVisibleAndDiagnosticSurvives() async throws {
    try await withMainSerialExecutor {
      let fixture = SuggestionRunFixture()
      try await withDependencies {
        fixture.install(&$0)
      } operation: {
        let model = fixture.model()
        let task = Task { await model.suggestTapped() }
        await fixture.waitForRequests()
        let stream = try #require(fixture.state.value.continuations.first)
        stream.yield(.progress("completed"))
        stream.yield(.diagnostic("Malformed candidates were dropped."))
        stream.finish()
        await task.value
        #expect(!model.isRunning)
        #expect(model.message?.contains("stopped before returning results") == true)
        let failure = model.message
        model.synchronizeDocument()
        expectNoDifference(model.message, failure)
        expectNoDifference(model.diagnostic, "Malformed candidates were dropped.")
        expectNoDifference(fixture.document.value.lastAppliedSuggestionRunID, nil)
      }
    }
  }
  @Test func oldAttemptEventsCannotAlterResumedAttemptOfTheSameRun() async throws {
    try await withMainSerialExecutor {
      let fixture = SuggestionRunFixture()
      try await withDependencies {
        fixture.install(&$0)
      } operation: {
        let model = fixture.model()
        let first = Task { await model.suggestTapped() }
        await fixture.waitForRequests()
        let runID = try #require(model.activeRunID)
        let oldStream = try #require(fixture.state.value.continuations.first)
        model.cancelSearchTapped()
        await model.waitUntilStopped()
        await first.value
        let second = Task { await model.resumeTapped() }
        await fixture.waitForRequests(2)
        let currentAttempt = model.activeAttemptID
        let before = fixture.document.value
        oldStream.yield(.progress("Old attempt"))
        oldStream.yield(.checkpoint(runID: runID, revision: 900))
        oldStream.yield(
          .recoverableFailure(runID: runID, failedRequestKeys: [], message: "Old error"))
        oldStream.yield(.completed([]))
        expectNoDifference(model.activeAttemptID, currentAttempt)
        expectNoDifference(fixture.document.value, before)
        fixture.finish([fixture.candidate()], attempt: 1)
        await second.value
        expectNoDifference(fixture.document.value.lastAppliedSuggestionRunID, runID)
        expectNoDifference(fixture.document.value.cutSuggestions.count, 1)
      }
    }
  }

  @Test func globalConfigurationEditDuringSearchDoesNotChangeItsSnapshot() async throws {
    try await withMainSerialExecutor {
      let fixture = SuggestionRunFixture()
      let configuration = SuggestionConfigurationClient.inMemory()
      try await withDependencies {
        fixture.install(&$0)
        $0.suggestionConfiguration = configuration
      } operation: {
        let model = fixture.model()
        let task = Task { await model.suggestTapped() }
        await fixture.waitForRequests()
        let original = try #require(fixture.state.value.requests.first?.snapshot)
        var edited = original.configuration
        edited.types[0].name = "Changed after launch"
        _ = try await configuration.save(edited, edited.revision)
        fixture.finish([fixture.candidate()])
        await task.value
        expectNoDifference(fixture.document.value.suggestionBatch?.snapshot, original)
        expectNoDifference(
          fixture.document.value.cutSuggestions.first?.naming?.typeName, "Spotlight")
      }
    }
  }

  @Test func refusedCheckpointCannotLaunchResumeOrApply() async {
    await withMainSerialExecutor {
      let fixture = SuggestionRunFixture()
      await withDependencies {
        fixture.install(&$0)
      } operation: {
        let model = fixture.model()
        let task = Task { await model.suggestTapped() }
        await fixture.waitForRequests()
        model.cancelSearchTapped()
        await model.waitUntilStopped()
        await task.value
        let before = fixture.document.value
        model.onCheckpoint = { _ in throw CancellationError() }
        await model.resumeTapped()
        expectNoDifference(fixture.state.value.requests.count, 1)
        expectNoDifference(fixture.document.value, before)
        #expect(!model.isRunning)
      }
    }
  }

  @Test func sourceChangeRefusesResumeWithoutProviderOrApplication() async {
    await withMainSerialExecutor {
      let fixture = SuggestionRunFixture()
      await withDependencies {
        fixture.install(&$0)
      } operation: {
        let model = fixture.model()
        let task = Task { await model.suggestTapped() }
        await fixture.waitForRequests()
        model.cancelSearchTapped()
        await model.waitUntilStopped()
        await task.value
        fixture.state.withValue { $0.checkpoint?.snapshot.transcriptHash = "different-transcript" }
        let before = fixture.document.value
        await model.resumeTapped()
        expectNoDifference(fixture.state.value.requests.count, 1)
        expectNoDifference(fixture.document.value, before)
        #expect(model.message?.contains("source or transcript changed") == true)
      }
    }
  }

  @Test func cancelDuringPreparationWaitsForDurabilityAndPausesBeforeAnyProviderCall() async throws
  {
    let fixture = SuggestionRunFixture()
    let entered = AsyncStream.makeStream(of: Void.self)
    let release = AsyncStream.makeStream(of: Void.self)
    await withDependencies {
      fixture.install(&$0)
    } operation: {
      let model = fixture.model()
      model.currentOwner = {
        fixture.document.value.suggestionRecoveryOwnerID == nil ? nil : fixture.owner
      }
      let prepare = model.prepare
      model.prepare = { preparation in
        entered.continuation.yield(())
        var iterator = release.stream.makeAsyncIterator()
        _ = await iterator.next()
        return try await prepare(preparation)
      }
      let task = Task { await model.suggestTapped() }
      var iterator = entered.stream.makeAsyncIterator()
      _ = await iterator.next()
      model.cancelSearchTapped()
      release.continuation.yield(())
      await task.value
      await model.waitUntilStopped()
      expectNoDifference(model.activeAttemptID, nil)
      expectNoDifference(fixture.state.value.requests.count, 0)
      expectNoDifference(fixture.document.value.unfinishedSuggestionRun?.phase, .paused)
      #expect(!model.candidatesLocked)
      #expect(model.canResume)
    }
  }

}
