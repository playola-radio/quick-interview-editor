import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
import Testing

@testable import PlayolaInterviewEditor

/// The editor side of the cut-suggestion boundary (PR 2): the child panel emits intents and
/// `EditorModel` funnels them through `mutateDocument`, so accept/reject are undoable and every
/// change dirties, while a background analysis pass stores candidates without touching undo.
@MainActor
struct EditorSuggestionFlowTests {

  @Test func replacementClearsBeforePreparationAndCannotReturnThroughUndo() async throws {
    try await withMainSerialExecutor {
      let fixture = SuggestionRunFixture()
      try await withDependencies {
        fixture.install(&$0)
      } operation: {
        let model = editor()
        fixture.wireEditor(model)
        let (candidate, batch) = try numberedSuggestion(plan: model.editPlan)
        let saved = Fixtures.slice(id: Fixtures.uuid(99))
        let reservation = try #require(candidate.naming?.reservation)
        model.mutateDocument(recordUndo: false) {
          $0.cutSuggestions = [candidate]
          $0.suggestionBatch = batch
          $0.slices = [saved]
          $0.suggestionStarts.types["spotlight"] = .init(number: 8, isExplicit: true)
          $0.issuedSuggestionNumbers = [reservation]
        }
        model.mutateDocument { $0.slices[id: saved.id]?.name = "Edited clip" }
        let before = model.documentState
        var changes: [EditorDocumentState] = []
        model.onDocumentStateChanged = { changes.append($0) }
        let prepare = model.cutSuggestions.run.prepare
        model.cutSuggestions.run.prepare = { preparation in
          expectNoDifference(model.documentCutSuggestions.elements, [])
          expectNoDifference(model.suggestionBatch, nil)
          expectNoDifference(changes.first?.cutSuggestions.elements, [])
          return try await prepare(preparation)
        }
        await model.cutSuggestions.run.suggestTapped()
        expectNoDifference(model.documentState, before)
        let task = Task { await model.cutSuggestions.run.replaceConfirmed() }
        await fixture.waitForRequests()
        expectNoDifference(model.documentCutSuggestions.elements, [])
        expectNoDifference(model.documentState.slices, before.slices)
        expectNoDifference(model.suggestionStarts, before.suggestionStarts)
        expectNoDifference(model.issuedSuggestionNumbers, before.issuedSuggestionNumbers)
        fixture.state.value.continuations[0].finish(
          throwing: CutSuggestClientError.decodeFailed("Search failed"))
        await task.value
        await model.undoTapped()
        expectNoDifference(model.slices.elements, [saved])
        expectNoDifference(model.documentCutSuggestions.elements, [])
        expectNoDifference(model.suggestionBatch, nil)
        expectNoDifference(model.issuedSuggestionNumbers, before.issuedSuggestionNumbers)
      }
    }
  }

  @Test func numbersAreIssuedInAcceptanceOrderWithoutRejectedSuggestionGaps() async throws {
    try await withMainSerialExecutor {
      let fixture = SuggestionRunFixture()
      try await withDependencies {
        fixture.install(&$0)
      } operation: {
        let model = EditorModel(
          sourceURL: URL(fileURLWithPath: "/clip.m4a"),
          canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: Fixtures.editPlan(),
          sourceFingerprint: fixture.owner.sourceFingerprint)
        fixture.wireEditor(model)
        model.suggestionStarts.types["spotlight"] = .init(number: 7, isExplicit: true)
        let task = Task { await model.cutSuggestions.suggestCutsTapped() }
        await fixture.waitForRequests()
        fixture.finish((1...4).map { fixture.candidate($0) })
        await task.value
        expectNoDifference(
          model.documentCutSuggestions.map(\.title), Array(repeating: "Story", count: 4))
        expectNoDifference(model.documentCutSuggestions.compactMap { $0.naming?.reservation }, [])
        model.cutSuggestions.rejectTapped(Fixtures.uuid(1))
        model.cutSuggestions.acceptTapped(Fixtures.uuid(3))
        model.cutSuggestions.acceptTapped(Fixtures.uuid(2))
        expectNoDifference(model.slices.map(\.name), ["Spotlight 7", "Spotlight 8"])
        expectNoDifference(model.issuedSuggestionNumbers.map(\.number), [7, 8])
        await model.undoTapped()
        model.cutSuggestions.acceptTapped(Fixtures.uuid(2))
        expectNoDifference(model.slices.map(\.name), ["Spotlight 7", "Spotlight 8"])
        expectNoDifference(model.issuedSuggestionNumbers.map(\.number), [7, 8])
        await model.deleteSlice(Fixtures.uuid(3))
        model.cutSuggestions.acceptTapped(Fixtures.uuid(4))
        expectNoDifference(model.slices.map(\.name), ["Spotlight 8", "Spotlight 9"])
        expectNoDifference(model.issuedSuggestionNumbers.map(\.number), [7, 8, 9])
      }
    }
  }

  @Test func reopeningOldPendingNumbersPreservesIssuedClipsAndUndoUsesDescriptiveLabels()
    async throws
  {
    let plan = Fixtures.editPlan()
    var (accepted, batch) = try numberedSuggestion(plan: plan)
    accepted.accept()
    var pending = try numberedSuggestion(plan: plan, id: Fixtures.uuid(2)).candidate
    pending.naming?.reservation?.number = 4
    pending.title = "Spotlight 4"
    let issued = try #require(accepted.naming?.reservation)
    var saved = Fixtures.slice(id: accepted.id)
    saved.name = "Previously saved name"
    saved.suggestionNaming = accepted.naming
    let persisted = EditorDocumentState(
      slices: [saved], cutSuggestions: [accepted, pending], suggestionBatch: batch,
      issuedSuggestionNumbers: [issued])
    let reopened = try JSONDecoder().decode(
      EditorDocumentState.self, from: JSONEncoder().encode(persisted))
    let model = EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: plan,
      sourceFingerprint: fingerprint, initialDocument: reopened)
    expectNoDifference(model.slices.elements, [saved])
    expectNoDifference(model.documentCutSuggestions[0], accepted)
    expectNoDifference(model.documentCutSuggestions[1].title, "Writing on the road")
    expectNoDifference(model.documentCutSuggestions[1].naming?.reservation, nil)
    model.cutSuggestions.acceptTapped(pending.id)
    expectNoDifference(model.slices[id: pending.id]?.name, "Spotlight 4")
    let newlyIssued = model.issuedSuggestionNumbers
    await model.undoTapped()
    expectNoDifference(model.documentCutSuggestions[1].title, "Writing on the road")
    expectNoDifference(model.issuedSuggestionNumbers, newlyIssued)
    model.cutSuggestions.acceptTapped(pending.id)
    expectNoDifference(model.slices[id: pending.id]?.name, "Spotlight 4")
    expectNoDifference(model.issuedSuggestionNumbers, newlyIssued)
  }

  private let fingerprint = "fp-flow"

  private func editor(_ plan: EditPlan = Fixtures.editPlan()) -> EditorModel {
    EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: plan,
      sourceFingerprint: fingerprint)
  }

  /// A suggestion stamped so the accept-time staleness gate treats it as fresh for this editor.
  private func freshSuggestion(_ id: UUID, plan: EditPlan) -> CutSuggestion {
    var suggestion = Fixtures.cutSuggestion(id: id, wordIDs: [10, 11, 12, 13, 14, 15, 16])
    suggestion.provenance = CutSuggestion.Provenance(
      model: "claude-sonnet-5", promptVersion: "v2", productSpecVersion: "v1",
      transcriptHash: plan.transcriptHash, sourceFingerprint: fingerprint, diarizationHash: nil)
    return suggestion
  }

  private func numberedSuggestion(
    plan: EditPlan, id: UUID = Fixtures.uuid(1), typeID: String = "spotlight",
    values: [String: String] = [:]
  ) throws -> (candidate: CutSuggestion, batch: SuggestionBatch) {
    var candidate = freshSuggestion(id, plan: plan)
    let type = try #require(SuggestionDefaults.types.first { $0.id == typeID })
    candidate.productType = ProductType(rawValue: typeID)!
    candidate.title = "Spotlight 3"
    let reservation = SequenceReservation(
      candidateID: candidate.id,
      key: suggestionSequenceKey(type: type, values: values, candidateID: candidate.id),
      number: 3, canonicalValues: values)
    candidate.naming = SuggestionNamingRecord(
      runID: Fixtures.uuid(2), typeID: type.id, typeName: type.name, typeGroup: type.group,
      discoveryLabel: "Writing on the road", extractedValues: values, missingFieldIDs: [],
      correctedValues: [:], reservation: reservation)
    let snapshot = SuggestionRunSnapshot(
      runID: Fixtures.uuid(2), configuration: SuggestionDefaults.configuration,
      configurationHash: "fixture",
      model: "fixture-model", discoveryPromptVersion: "configured-v1",
      extractionPromptVersion: "fields-v1", productSpecVersion: "configured-v1",
      transcriptHash: plan.transcriptHash, sourceFingerprint: fingerprint,
      sampleRate: plan.source.sampleRate)
    return (
      candidate,
      SuggestionBatch(snapshot: snapshot, actualStarts: SuggestionStarts(), canonicalGroups: [])
    )
  }

  @Test func undoAcceptanceKeepsItsIssuedNumber() async throws {
    let plan = Fixtures.editPlan()
    let model = editor(plan)
    let (candidate, batch) = try numberedSuggestion(plan: plan)
    model.mutateDocument(recordUndo: false) {
      $0.cutSuggestions = [candidate]
      $0.suggestionBatch = batch
    }
    var changes: [EditorDocumentState] = []
    model.onDocumentStateChanged = { changes.append($0) }

    model.cutSuggestions.acceptTapped(candidate.id)
    let reservation = try #require(model.slices.first?.suggestionNaming?.reservation)
    expectNoDifference(changes.count, 1)
    expectNoDifference(reservation.number, 1)
    await model.undoTapped()
    expectNoDifference(model.slices.count, 0)
    expectNoDifference(model.documentState.issuedSuggestionNumbers, [reservation])
    expectNoDifference(model.documentCutSuggestions[id: candidate.id]?.status, .pending)
    await model.redoTapped()
    expectNoDifference(model.documentCutSuggestions[id: candidate.id]?.status, .accepted)
    expectNoDifference(model.documentState.issuedSuggestionNumbers, [reservation])
    await model.undoTapped()
    model.cutSuggestions.acceptTapped(candidate.id)
    model.cutSuggestions.acceptTapped(candidate.id)
    expectNoDifference(model.slices.count, 1)
    expectNoDifference(model.documentState.issuedSuggestionNumbers, [reservation])
  }

  @Test func acceptedRecordMissingNumberCannotBeAppliedAndShowsActionableMessage() throws {
    let model = editor()
    var (candidate, batch) = try numberedSuggestion(plan: model.editPlan)
    candidate.naming?.reservation = nil
    candidate.accept()
    let empty = model.documentState
    #expect(throws: SuggestionRunValidationError.invalidNaming(candidateID: candidate.id)) {
      try model.replaceSuggestionBatch(candidates: [candidate], batch: batch)
    }
    expectNoDifference(model.documentState, empty)
    model.mutateDocument(recordUndo: false) {
      $0.cutSuggestions = [candidate]
      $0.suggestionBatch = batch
    }
    var changes: [EditorDocumentState] = []
    model.onDocumentStateChanged = { changes.append($0) }
    let before = model.documentState
    model.cutSuggestions.acceptTapped(candidate.id)
    expectNoDifference(model.documentState, before)
    expectNoDifference(changes, [])
    #expect(!model.canUndo)
    #expect(!model.canRedo)
    expectNoDifference(
      model.cutSuggestions.actionMessage,
      "This suggestion's saved naming details are invalid. Review its fields or suggest cuts again."
    )
  }

  @Test func sequenceFreeNamedCandidateCanBeAppliedAndAcceptedWithoutReservation() throws {
    let model = editor()
    var (candidate, batch) = try numberedSuggestion(plan: model.editPlan)
    let typeIndex = try #require(
      batch.snapshot.configuration.types.firstIndex { $0.id == "spotlight" })
    batch.snapshot.configuration.types[typeIndex].template = [
      .init(kind: .literal, value: "A story")
    ]
    candidate.naming?.reservation = nil
    candidate.title = "A story"
    try model.replaceSuggestionBatch(candidates: [candidate], batch: batch)
    model.cutSuggestions.acceptTapped(candidate.id)
    expectNoDifference(model.slices.first?.name, "A story")
    expectNoDifference(model.documentCutSuggestions[id: candidate.id]?.status, .accepted)
    expectNoDifference(model.documentState.issuedSuggestionNumbers, [])
    expectNoDifference(model.cutSuggestions.actionMessage, nil)
  }

  @Test func missingOwningSnapshotShowsActionableMessageAtAcceptance() throws {
    let model = editor()
    let (candidate, _) = try numberedSuggestion(plan: model.editPlan)
    model.mutateDocument(recordUndo: false) { $0.cutSuggestions = [candidate] }
    let before = model.documentState
    model.cutSuggestions.acceptTapped(candidate.id)
    expectNoDifference(model.documentState, before)
    expectNoDifference(
      model.cutSuggestions.actionMessage,
      "This suggestion's saved naming rules are missing. Suggest cuts again before accepting.")
  }

  @Test func unissuedPendingReservationDoesNotConflictWithPermanentNumbers() throws {
    let model = editor()
    let (candidate, batch) = try numberedSuggestion(plan: model.editPlan)
    var taken = try #require(candidate.naming?.reservation)
    taken.candidateID = Fixtures.uuid(9)
    model.mutateDocument(recordUndo: false) {
      $0.cutSuggestions = [candidate]
      $0.suggestionBatch = batch
      $0.issuedSuggestionNumbers = [taken]
    }
    model.cutSuggestions.acceptTapped(candidate.id)
    expectNoDifference(model.slices.first?.name, "Spotlight 4")
    expectNoDifference(model.issuedSuggestionNumbers.map(\.number), [3, 4])
    expectNoDifference(model.cutSuggestions.actionMessage, nil)
  }

  @Test func finalAcceptanceIgnoresUntrustedChildSliceAndChecksCurrentProvenance() throws {
    let model = editor()
    var (candidate, batch) = try numberedSuggestion(plan: model.editPlan)
    try model.replaceSuggestionBatch(candidates: [candidate], batch: batch)
    let forged = Fixtures.slice(id: Fixtures.uuid(8))
    model.acceptCutSuggestion(forged, id: candidate.id)
    expectNoDifference(model.slices.first?.id, candidate.id)
    expectNoDifference(model.slices.first?.wordIDs, candidate.wordIDs)
    candidate.provenance.transcriptHash = "stale"
    model.mutateDocument(recordUndo: false) { $0.cutSuggestions[id: candidate.id] = candidate }
    let before = model.documentState
    model.acceptCutSuggestion(forged, id: candidate.id)
    expectNoDifference(model.documentState, before)
    expectNoDifference(
      model.cutSuggestions.actionMessage, cutSuggestionStaleMessage(.transcriptChanged))
  }

  @Test func deletedAndReopenedAcceptedNumberIsNotReusedByFreshRun() throws {
    let model = editor()
    let (candidate, batch) = try numberedSuggestion(plan: model.editPlan)
    try model.replaceSuggestionBatch(candidates: [candidate], batch: batch)
    model.cutSuggestions.acceptTapped(candidate.id)
    let issued = model.issuedSuggestionNumbers
    model.mutateSlices { $0[id: candidate.id]?.name = "Manually renamed" }
    model.mutateSlices { $0.remove(id: candidate.id) }
    let saved = try JSONEncoder().encode(model.documentState)
    let reopened = try JSONDecoder().decode(EditorDocumentState.self, from: saved)
    let fresh = try numberedSuggestion(plan: model.editPlan, id: Fixtures.uuid(7)).candidate
    let result = try numberSuggestions(
      [fresh], snapshot: batch.snapshot, starts: reopened.suggestionStarts,
      issued: reopened.issuedSuggestionNumbers, retained: [])
    expectNoDifference(result.candidates.first?.naming?.reservation?.number, 2)
    expectNoDifference(
      reopened.issuedSuggestionNumbers, issued)
  }

  @Test func correctedGroupAfterUndoKeepsOldIssuedIdentityAndAllocatesOnlyOnAcceptance()
    async throws
  {
    let model = editor()
    let (candidate, batch) = try numberedSuggestion(
      plan: model.editPlan, typeID: "intro", values: ["song-title": "Café", "artist-name": "Björk"])
    try model.replaceSuggestionBatch(candidates: [candidate], batch: batch)
    model.cutSuggestions.acceptTapped(candidate.id)
    let first = try #require(model.issuedSuggestionNumbers.first)
    await model.undoTapped()
    try model.applySuggestionReviewIntent(
      .fields(
        candidateID: candidate.id, runID: batch.snapshot.runID,
        values: ["song-title": "Another Song"]))
    expectNoDifference(model.issuedSuggestionNumbers, [first])
    expectNoDifference(model.documentCutSuggestions[0].naming?.reservation, nil)
    model.cutSuggestions.acceptTapped(candidate.id)
    expectNoDifference(model.slices.first?.name, "Another Song 1, Björk")
    expectNoDifference(model.issuedSuggestionNumbers.map(\.number), [1, 1])
    #expect(model.issuedSuggestionNumbers[0].key != model.issuedSuggestionNumbers[1].key)
    await model.undoTapped()
    try model.applySuggestionReviewIntent(
      .fields(
        candidateID: candidate.id, runID: batch.snapshot.runID,
        values: ["song-title": "Café"]))
    model.cutSuggestions.acceptTapped(candidate.id)
    expectNoDifference(model.slices.first?.suggestionNaming?.reservation?.identity, first.identity)
    expectNoDifference(model.issuedSuggestionNumbers.count, 2)
  }

  @Test func replacingBatchRebasesCandidatesAndMetadataTogetherAndFutureStartsUndoSeparately()
    async throws
  {
    let model = editor()
    model.mutateDocument { $0.speakerCountOverride = 2 }
    let (candidate, batch) = try numberedSuggestion(plan: model.editPlan)
    try model.replaceSuggestionBatch(candidates: [candidate], batch: batch)
    await model.undoTapped()
    expectNoDifference(model.documentState.suggestionBatch, batch)
    var pending = candidate
    pending.title = "Writing on the road"
    pending.naming?.reservation = nil
    expectNoDifference(model.documentCutSuggestions.elements, [pending])
    model.mutateDocument {
      $0.suggestionStarts.types["spotlight"] = .init(number: 20, isExplicit: true)
    }
    await model.undoTapped()
    expectNoDifference(model.documentState.suggestionStarts, SuggestionStarts())
    expectNoDifference(model.documentState.suggestionBatch, batch)
  }

  @Test func backgroundPassStoresSuggestionsAndDirtiesButLeavesCanUndoFalse() {
    let plan = Fixtures.editPlan()
    let model = editor(plan)
    var seen: [EditorDocumentState] = []
    model.onDocumentStateChanged = { seen.append($0) }

    let first = freshSuggestion(Fixtures.uuid(1), plan: plan)
    let second = freshSuggestion(Fixtures.uuid(2), plan: plan)
    model.mutateDocument(recordUndo: false) { $0.cutSuggestions = [first, second] }

    expectNoDifference(model.documentCutSuggestions.count, 2)
    expectNoDifference(seen.count, 1)
    #expect(!model.canUndo)
  }

  @Test func acceptingASuggestionLandsASliceFlipsStatusIsUndoableAndFires() async {
    let plan = Fixtures.editPlan()
    let model = editor(plan)
    let suggestion = freshSuggestion(Fixtures.uuid(1), plan: plan)
    model.mutateDocument(recordUndo: false) { $0.cutSuggestions = [suggestion] }
    #expect(!model.canUndo)

    var seen: [EditorDocumentState] = []
    model.onDocumentStateChanged = { seen.append($0) }

    model.cutSuggestions.acceptTapped(suggestion.id)

    expectNoDifference(model.slices[id: suggestion.id]?.wordIDs, [10, 11, 12, 13, 14, 15, 16])
    expectNoDifference(model.documentCutSuggestions[id: suggestion.id]?.status, .accepted)
    #expect(model.canUndo)
    // Accept lands the slice AND the status flip in ONE transaction — one callback, one entry.
    expectNoDifference(seen.count, 1)

    // A single undo reverts the WHOLE acceptance: the slice goes and the status returns to
    // pending together, so the transcript is never left with a half-accepted suggestion.
    await model.undoTapped()
    expectNoDifference(model.documentCutSuggestions[id: suggestion.id]?.status, .pending)
    #expect(model.slices[id: suggestion.id] == nil)
  }

  @Test func suggestionsProducedAfterAnEditSurviveUndoAndRedoOfThatEdit() async {
    let plan = Fixtures.editPlan()
    let model = editor(plan)
    // An undoable edit lands FIRST, while no suggestions exist — so its undo snapshot predates
    // them. This is the ordering the old sidecar could never break, since suggestions lived
    // outside undo entirely.
    model.mutateDocument { $0.slices.append(Fixtures.slice(id: Fixtures.uuid(9))) }

    // Then a background pass stores suggestions non-undoably.
    let suggestion = freshSuggestion(Fixtures.uuid(1), plan: plan)
    model.mutateDocument(recordUndo: false) { $0.cutSuggestions = [suggestion] }
    expectNoDifference(model.documentCutSuggestions.count, 1)

    // Undoing the slice must NOT rewind to the pre-suggestion snapshot and erase them.
    await model.undoTapped()
    expectNoDifference(model.slices.count, 0)
    expectNoDifference(model.documentCutSuggestions[id: suggestion.id]?.id, suggestion.id)

    // Redo restores the slice and still keeps the suggestions.
    await model.redoTapped()
    expectNoDifference(model.slices.count, 1)
    expectNoDifference(model.documentCutSuggestions[id: suggestion.id]?.id, suggestion.id)
  }

  @Test func rejectingASuggestionFlipsStatusAndIsUndoable() async {
    let plan = Fixtures.editPlan()
    let model = editor(plan)
    let suggestion = freshSuggestion(Fixtures.uuid(1), plan: plan)
    model.mutateDocument(recordUndo: false) { $0.cutSuggestions = [suggestion] }

    model.cutSuggestions.rejectTapped(suggestion.id)

    expectNoDifference(model.documentCutSuggestions[id: suggestion.id]?.status, .rejected)
    #expect(model.canUndo)

    await model.undoTapped()
    expectNoDifference(model.documentCutSuggestions[id: suggestion.id]?.status, .pending)
  }

  @Test func configuredAndLockedSuggestionsDoNotAllowInlineTitleEditing() throws {
    let model = editor()
    let (candidate, batch) = try numberedSuggestion(plan: model.editPlan)
    model.mutateDocument(recordUndo: false) {
      $0.cutSuggestions = [candidate]
      $0.suggestionBatch = batch
    }
    let row = suggestionRow(candidate, currentTranscriptHash: "t", currentFingerprint: "f")
    expectNoDifference(row.showsEditableTitle, false)
    expectNoDifference(row.showsRevealableTitle, true)
    expectNoDifference(row.showsReviewButton, true)
    let before = model.documentState
    model.cutSuggestions.titleChanged(candidate.id, to: "Ignored")
    model.cutSuggestions.onTitleChanged?(candidate.id, "Also ignored")
    expectNoDifference(model.documentState, before)
    let legacy = freshSuggestion(Fixtures.uuid(9), plan: model.editPlan)
    model.mutateDocument(recordUndo: false) { $0.cutSuggestions = [legacy] }
    model.cutSuggestions.run.ownershipBlocked = true
    let locked = model.documentState
    model.cutSuggestions.titleFocusChanged(legacy.id, isFocused: true)
    model.cutSuggestions.titleChanged(legacy.id, to: "Ignored")
    model.cutSuggestions.onTitleChanged?(legacy.id, "Also ignored")
    expectNoDifference(model.documentState, locked)
  }

  @Test func editingASuggestionTitleCoalescesTypingIntoOneUndoableAction() async {
    let plan = Fixtures.editPlan()
    let model = editor(plan)
    let suggestion = freshSuggestion(Fixtures.uuid(1), plan: plan)
    model.mutateDocument(recordUndo: false) { $0.cutSuggestions = [suggestion] }

    var seen: [EditorDocumentState] = []
    model.onDocumentStateChanged = { seen.append($0) }

    model.cutSuggestions.titleFocusChanged(suggestion.id, isFocused: true)
    model.cutSuggestions.titleChanged(suggestion.id, to: "R")
    model.cutSuggestions.titleChanged(suggestion.id, to: "Renamed")
    model.cutSuggestions.titleChanged(suggestion.id, to: "Renamed cut")

    expectNoDifference(model.documentCutSuggestions[id: suggestion.id]?.title, "Renamed cut")
    expectNoDifference(seen.count, 3)
    expectNoDifference(model.history.undo.count, 0)
    #expect(!model.canUndo)

    model.cutSuggestions.titleFocusChanged(suggestion.id, isFocused: false)

    expectNoDifference(model.history.undo.count, 1)
    #expect(model.canUndo)

    await model.undoTapped()
    expectNoDifference(
      model.documentCutSuggestions[id: suggestion.id]?.title, suggestion.title)
  }

  @Test func acceptingAfterEditingTheTitleNamesTheSliceFromTheEditedTitle() {
    let plan = Fixtures.editPlan()
    let model = editor(plan)
    let suggestion = freshSuggestion(Fixtures.uuid(1), plan: plan)
    model.mutateDocument(recordUndo: false) { $0.cutSuggestions = [suggestion] }

    model.cutSuggestions.titleFocusChanged(suggestion.id, isFocused: true)
    model.cutSuggestions.titleChanged(suggestion.id, to: "My custom")
    model.cutSuggestions.titleChanged(suggestion.id, to: "My custom clip name")
    model.cutSuggestions.acceptTapped(suggestion.id)

    expectNoDifference(model.slices[id: suggestion.id]?.name, "My custom clip name")
    expectNoDifference(model.history.undo.count, 2)
  }

  @Test func speakerOverridesFlowThroughTheDocumentAndAreUndoable() async {
    let model = editor()
    var seen: [EditorDocumentState] = []
    model.onDocumentStateChanged = { seen.append($0) }

    model.cutSuggestions.onSpeakerOverridesChanged?(2, ["0": "Host"])

    expectNoDifference(model.documentState.speakerCountOverride, 2)
    expectNoDifference(model.documentState.speakerDisplayNames, ["0": "Host"])
    expectNoDifference(seen.count, 1)
    #expect(model.canUndo)

    await model.undoTapped()
    expectNoDifference(model.documentState.speakerCountOverride, nil)
    expectNoDifference(model.documentState.speakerDisplayNames, [:])
  }

  @Test func pendingSuggestionsSurfaceAsTranscriptClipBands() {
    let plan = Fixtures.editPlan()
    let model = editor(plan)
    let suggestion = freshSuggestion(Fixtures.uuid(1), plan: plan)
    model.mutateDocument(recordUndo: false) { $0.cutSuggestions = [suggestion] }

    let suggestedBands = model.clipBands.filter { $0.kind == .suggested }
    expectNoDifference(suggestedBands.map(\.id), [suggestion.id])
  }
  @Test func runningAndNumberingLockDirectCandidateActionsButAllowSavedClipEdits() async {
    await withMainSerialExecutor {
      let fixture = SuggestionRunFixture()
      await withDependencies {
        fixture.install(&$0)
      } operation: {
        let model = EditorModel(
          sourceURL: URL(fileURLWithPath: "/clip.m4a"),
          canonicalAudioURL: Fixtures.canonicalAudioURL,
          editPlan: Fixtures.editPlan(), sourceFingerprint: fixture.owner.sourceFingerprint)
        fixture.wireEditor(model)
        var old = fixture.candidate()
        old.provenance.sourceFingerprint = fixture.owner.sourceFingerprint
        old.provenance.transcriptHash = model.editPlan.transcriptHash
        model.mutateDocument(recordUndo: false) { $0.cutSuggestions = [old] }
        await model.cutSuggestions.suggestCutsTapped()
        let task = Task { await model.cutSuggestions.run.replaceConfirmed() }
        await fixture.waitForRequests()
        expectNoDifference(model.documentCutSuggestions.elements, [])
        model.mutateDocument(recordUndo: false) { $0.cutSuggestions = [old] }
        let before = model.documentCutSuggestions
        model.cutSuggestions.acceptTapped(old.id)
        model.acceptCutSuggestion(Fixtures.slice(), id: old.id)
        model.cutSuggestions.rejectTapped(old.id)
        model.cutSuggestions.onReject?(old.id)
        expectNoDifference(model.documentCutSuggestions, before)
        expectNoDifference(model.slices.count, 0)
        model.mutateDocument { $0.slices.append(Fixtures.slice(id: Fixtures.uuid(90))) }
        expectNoDifference(model.slices.count, 1)
        model.cutSuggestions.run.cancelSearchTapped()
        await model.cutSuggestions.run.waitUntilStopped()
        await task.value
        model.cutSuggestions.rejectTapped(old.id)
        expectNoDifference(model.documentCutSuggestions.first?.status, .rejected)
        let paused = model.cutSuggestions.run.phase
        model.cutSuggestions.run.phase = .needsNumbering(
          runID: Fixtures.uuid(500), message: "Choose a number")
        model.cutSuggestions.acceptTapped(old.id)
        model.acceptCutSuggestion(Fixtures.slice(), id: old.id)
        expectNoDifference(model.slices.count, 1)
        model.mutateDocument { $0.slices[id: Fixtures.uuid(90)]?.name = "Renamed while numbering" }
        expectNoDifference(model.slices.first?.name, "Renamed while numbering")
        model.cutSuggestions.run.phase = paused
      }
    }
  }

  @Test func readyApplicationRebasesAtomicBatchAndRunMetadataWithoutChangingClipsOrFutureStarts()
    async throws
  {
    try await withMainSerialExecutor {
      let fixture = SuggestionRunFixture()
      try await withDependencies {
        fixture.install(&$0)
      } operation: {
        let model = EditorModel(
          sourceURL: URL(fileURLWithPath: "/clip.m4a"),
          canonicalAudioURL: Fixtures.canonicalAudioURL,
          editPlan: Fixtures.editPlan(), sourceFingerprint: fixture.owner.sourceFingerprint)
        fixture.wireEditor(model)
        model.mutateDocument { $0.slices.append(Fixtures.slice(id: Fixtures.uuid(90))) }
        let task = Task { await model.cutSuggestions.suggestCutsTapped() }
        await fixture.waitForRequests()
        var changes: [EditorDocumentState] = []
        model.onDocumentStateChanged = { changes.append($0) }
        fixture.finish([fixture.candidate()])
        await task.value
        let applied = try #require(model.suggestionBatch)
        expectNoDifference(model.lastAppliedSuggestionRunID, applied.snapshot.runID)
        expectNoDifference(model.unfinishedSuggestionRun, nil)
        expectNoDifference(changes.last?.suggestionBatch, applied)
        expectNoDifference(changes.last?.unfinishedSuggestionRun, nil)
        expectNoDifference(model.suggestionStarts, SuggestionStarts())
        expectNoDifference(model.slices.count, 1)
        await model.undoTapped()
        expectNoDifference(model.slices.count, 0)
        expectNoDifference(model.suggestionBatch, applied)
        expectNoDifference(model.lastAppliedSuggestionRunID, applied.snapshot.runID)
        expectNoDifference(model.unfinishedSuggestionRun, nil)
        await model.redoTapped()
        expectNoDifference(model.slices.count, 1)
        expectNoDifference(model.suggestionBatch, applied)
      }
    }
  }

  @Test func finalEditorApplyDefersConflictingStartUntilAcceptanceAgainstLatestLedger() async throws
  {
    try await withMainSerialExecutor {
      let fixture = SuggestionRunFixture()
      try await withDependencies {
        fixture.install(&$0)
      } operation: {
        let model = EditorModel(
          sourceURL: URL(fileURLWithPath: "/clip.m4a"),
          canonicalAudioURL: Fixtures.canonicalAudioURL,
          editPlan: Fixtures.editPlan(), sourceFingerprint: fixture.owner.sourceFingerprint)
        fixture.wireEditor(model)
        model.mutateDocument(recordUndo: false) {
          $0.suggestionStarts.types["spotlight"] = .init(number: 1, isExplicit: true)
        }
        let type = try #require(SuggestionDefaults.types.first { $0.id == "spotlight" })
        model.cutSuggestions.run.onApply = { candidates, batch in
          model.mutateDocument(recordUndo: false) {
            $0.issuedSuggestionNumbers.append(
              .init(
                candidateID: Fixtures.uuid(90),
                key: suggestionSequenceKey(type: type, values: [:], candidateID: Fixtures.uuid(90)),
                number: 5, canonicalValues: [:]))
          }
          try model.applySuggestionRun(candidates: candidates, batch: batch)
        }
        let task = Task { await model.cutSuggestions.suggestCutsTapped() }
        await fixture.waitForRequests()
        fixture.finish([fixture.candidate()])
        await task.value
        expectNoDifference(model.documentCutSuggestions.first?.title, "Story")
        expectNoDifference(model.documentCutSuggestions.first?.naming?.reservation, nil)
        expectNoDifference(model.cutSuggestions.run.phase, .idle)
        model.cutSuggestions.acceptTapped(Fixtures.uuid(1))
        expectNoDifference(model.slices.first?.name, "Spotlight 6")
      }
    }
  }

  @Test func readyCheckpointWithoutBaselineCanApplyWhenCurrentCandidatesAreEmpty() async {
    let fixture = SuggestionRunFixture()
    await withDependencies {
      fixture.install(&$0)
    } operation: {
      let model = EditorModel(
        sourceURL: URL(fileURLWithPath: "/clip.m4a"), canonicalAudioURL: Fixtures.canonicalAudioURL,
        editPlan: Fixtures.editPlan(), sourceFingerprint: fixture.owner.sourceFingerprint)
      fixture.wireEditor(model)
      let prepare = model.cutSuggestions.run.prepare
      model.cutSuggestions.run.prepare = { preparation in
        var original = preparation
        original.control.originalBatchFingerprint = nil
        return try await prepare(original)
      }
      let task = Task { await model.cutSuggestions.suggestCutsTapped() }
      await fixture.waitForRequests()
      fixture.finish([fixture.candidate()])
      await task.value
      expectNoDifference(model.documentCutSuggestions.count, 1)
      expectNoDifference(model.cutSuggestions.run.phase, .idle)
      expectNoDifference(model.unfinishedSuggestionRun, nil)
    }
  }

  @Test func acceptanceSevenDeletionRerunUndoAndExactExportRemainProjectLocal() async throws {
    try await withMainSerialExecutor {
      let fixture = SuggestionRunFixture()
      let destination = FileManager.default.temporaryDirectory.appending(
        component: UUID().uuidString)
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: destination) }
      try await withDependencies {
        fixture.install(&$0)
        $0.exportRender.renderSlice = { try writeStubAIFF($0) }
        $0.engine.injectMarkers = { _ in }
        $0.workspace.reveal = { _ in }
      } operation: {
        let model = EditorModel(
          sourceURL: URL(fileURLWithPath: "/Tape Two.m4a"),
          canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: Fixtures.editPlan(),
          sourceFingerprint: fixture.owner.sourceFingerprint)
        fixture.wireEditor(model)
        model.cutSuggestions[futureStart: "spotlight"] = "7"
        model.cutSuggestions.applyTypeStartTapped("spotlight")
        let future = model.suggestionStarts
        let firstTask = Task { await model.cutSuggestions.suggestCutsTapped() }
        await fixture.waitForRequests()
        expectNoDifference(fixture.state.value.requests[0].options.promptVersion, "configured-v5")
        fixture.finish([fixture.candidate(1)])
        await firstTask.value
        let first = try #require(model.documentCutSuggestions.first)
        expectNoDifference(first.title, "Story")
        model.cutSuggestions.acceptTapped(first.id)
        let originalClip = try #require(model.slices.first)
        let issuedSeven = model.documentState.issuedSuggestionNumbers
        expectNoDifference(issuedSeven.count, 1)
        await model.deleteSlice(first.id)
        expectNoDifference(model.slices.count, 0)
        expectNoDifference(model.documentState.issuedSuggestionNumbers, issuedSeven)

        try await applySecondRunWithoutPendingNumberConflicts(model, fixture: fixture)
        expectNoDifference(model.suggestionStarts, future)
        await model.undoTapped()
        expectNoDifference(model.slices.elements, [originalClip])
        expectNoDifference(model.documentState.issuedSuggestionNumbers, issuedSeven)
        expectNoDifference(model.documentCutSuggestions.first?.title, "Story")
        model.cutSuggestions.acceptTapped(Fixtures.uuid(2))
        expectNoDifference(model.documentState.issuedSuggestionNumbers.map(\.number), [7, 8])
        try await assertExactExportRequiresReview(
          model, slice: originalClip, destination: destination)

        try await assertIndependentProjectStartsAtOne(destination: destination)
      }
    }
  }

  @Test(arguments: ["empty", "provider", "extraction", "cancel", "invalidCandidate", "prepare"])
  func replacementOutcomesPreserveAcceptedClipsAndIssuedNumbers(outcome: String) async throws {
    try await withMainSerialExecutor {
      let fixture = SuggestionRunFixture()
      try await withDependencies {
        fixture.install(&$0)
      } operation: {
        let model = EditorModel(
          sourceURL: URL(fileURLWithPath: "/clip.m4a"),
          canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: Fixtures.editPlan(),
          sourceFingerprint: fixture.owner.sourceFingerprint)
        fixture.wireEditor(model)
        let initial = Task { await model.cutSuggestions.suggestCutsTapped() }
        await fixture.waitForRequests()
        fixture.finish([fixture.candidate()])
        await initial.value
        model.cutSuggestions.acceptTapped(Fixtures.uuid(1))
        let savedClips = model.slices
        let ledger = model.documentState.issuedSuggestionNumbers
        let previous = model.documentCutSuggestions
        await model.cutSuggestions.suggestCutsTapped()
        model.cutSuggestions.run.cancelReplacementTapped()
        expectNoDifference(model.slices, savedClips)
        expectNoDifference(model.documentCutSuggestions, previous)
        await model.cutSuggestions.suggestCutsTapped()
        if outcome == "prepare" {
          model.cutSuggestions.run.prepare = { _ in throw CocoaError(.fileWriteUnknown) }
          await model.cutSuggestions.run.replaceConfirmed()
        } else {
          let task = Task { await model.cutSuggestions.run.replaceConfirmed() }
          await fixture.waitForRequests(2)
          try await finishReplacement(outcome, fixture: fixture, model: model)
          await task.value
        }
        expectNoDifference(model.slices, savedClips)
        expectNoDifference(model.documentState.issuedSuggestionNumbers, ledger)
        expectNoDifference(model.documentCutSuggestions.elements, [])
        if outcome == "empty" {
          expectNoDifference(
            model.cutSuggestions.emptyStateMessage, "No matching suggestions found.")
        }
      }
    }
  }

  private func assertIndependentProjectStartsAtOne(destination: URL) async throws {
    let independentFixture = SuggestionRunFixture()
    try await withDependencies {
      independentFixture.install(&$0)
    } operation: {
      let independent = EditorModel(
        sourceURL: URL(fileURLWithPath: "/Another Tape.m4a"),
        canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: Fixtures.editPlan(),
        sourceFingerprint: independentFixture.owner.sourceFingerprint)
      independentFixture.wireEditor(independent)
      independent.cutSuggestions[futureStart: "spotlight"] = "1"
      independent.cutSuggestions.applyTypeStartTapped("spotlight")
      let task = Task { await independent.cutSuggestions.suggestCutsTapped() }
      await independentFixture.waitForRequests()
      independentFixture.finish([independentFixture.candidate(3)])
      await task.value
      independent.cutSuggestions.acceptTapped(Fixtures.uuid(3))
      expectNoDifference(independent.slices.first?.name, "Spotlight 1")
      expectNoDifference(independent.documentState.issuedSuggestionNumbers.map(\.number), [1])
      let existing = destination.appending(component: "Spotlight 1.aiff")
      try Data("Another project's export".utf8).write(to: existing)
      independent.destinationURL = destination
      independent.exportAllTapped()
      await independent.exportTask?.value
      let collision = try #require(independent.exportReview)
      expectNoDifference(collision.mappings.map(\.proposedName), ["Spotlight 1 2.aiff"])
      expectNoDifference(independent.slices.first?.name, "Spotlight 1")
      expectNoDifference(independent.documentState.issuedSuggestionNumbers.map(\.number), [1])
      collision.reviewNamesTapped()
      await independent.awaitExportTeardown()
    }
  }

  private func assertExactExportRequiresReview(
    _ model: EditorModel, slice: Slice, destination: URL
  ) async throws {
    model.destinationURL = destination
    model.exportSliceTapped(slice.id)
    await model.exportTask?.value
    expectNoDifference(model.exportPhase, .done(count: 1))
    expectNoDifference(
      try FileManager.default.contentsOfDirectory(atPath: destination.path),
      ["Spotlight 7.aiff"])
    let originalBytes = try Data(
      contentsOf: destination.appending(component: "Spotlight 7.aiff"))
    model.exportSliceTapped(slice.id)
    await model.exportTask?.value
    let review = try #require(model.exportReview)
    expectNoDifference(review.mappings.map(\.requestedName), ["Spotlight 7.aiff"])
    expectNoDifference(review.mappings.map(\.proposedName), ["Spotlight 7 2.aiff"])
    review.reviewNamesTapped()
    await model.awaitExportTeardown()
    expectNoDifference(
      try Data(contentsOf: destination.appending(component: "Spotlight 7.aiff")), originalBytes)
    expectNoDifference(model.slices[id: slice.id], slice)
    expectNoDifference(model.documentState.issuedSuggestionNumbers.map(\.number), [7, 8])
  }

  private func finishReplacement(
    _ outcome: String, fixture: SuggestionRunFixture, model: EditorModel
  ) async throws {
    switch outcome {
    case "empty": fixture.finish([], attempt: 1)
    case "provider":
      fixture.state.value.continuations[1].finish(
        throwing: CutSuggestClientError.suggestFailed("Provider failed"))
    case "extraction":
      fixture.checkpoint(
        phase: .needsRetry, candidates: [fixture.candidate(2)], failed: ["naming"],
        message: "Naming failed")
      let runID = try #require(fixture.state.value.checkpoint?.snapshot.runID)
      fixture.state.value.continuations[1].yield(
        .recoverableFailure(
          runID: runID, failedRequestKeys: ["naming"], message: "Naming failed"))
      fixture.state.value.continuations[1].finish()
    case "cancel":
      model.cutSuggestions.run.cancelSearchTapped()
      await model.cutSuggestions.run.waitUntilStopped()
    default:
      var invalid = fixture.candidate(2)
      invalid.productType = ProductType(rawValue: "unrequested-type")!
      fixture.finish([invalid], attempt: 1)
    }
  }

  private func applySecondRunWithoutPendingNumberConflicts(
    _ model: EditorModel, fixture: SuggestionRunFixture
  ) async throws {
    await model.cutSuggestions.suggestCutsTapped()
    let replacement = Task { await model.cutSuggestions.run.replaceConfirmed() }
    await fixture.waitForRequests(2)
    fixture.finish([fixture.candidate(2)], attempt: 1)
    await replacement.value
    expectNoDifference(model.cutSuggestions.run.phase, .idle)
    expectNoDifference(model.documentCutSuggestions.first?.id, Fixtures.uuid(2))
    expectNoDifference(fixture.state.value.requests.count, 2)
    expectNoDifference(model.documentCutSuggestions.first?.title, "Story")
    expectNoDifference(model.documentCutSuggestions.first?.naming?.reservation, nil)
  }

}
