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
    let reservation = try #require(candidate.naming?.reservation)
    model.mutateDocument(recordUndo: false) {
      $0.cutSuggestions = [candidate]
      $0.suggestionBatch = batch
    }
    var changes: [EditorDocumentState] = []
    model.onDocumentStateChanged = { changes.append($0) }

    model.cutSuggestions.acceptTapped(candidate.id)
    expectNoDifference(changes.count, 1)
    expectNoDifference(model.slices.first?.suggestionNaming, candidate.naming)
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

  @Test func missingNumberCannotBeAcceptedOrAppliedAndShowsActionableMessage() throws {
    let model = editor()
    var (candidate, batch) = try numberedSuggestion(plan: model.editPlan)
    candidate.naming?.reservation = nil
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
      "This suggestion's saved name or number is invalid. Renumber it or suggest cuts again.")
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

  @Test func reservationConflictIsVisibleThroughThePageAndDoesNotMutateDocument() throws {
    let model = editor()
    let (candidate, batch) = try numberedSuggestion(plan: model.editPlan)
    var taken = try #require(candidate.naming?.reservation)
    taken.candidateID = Fixtures.uuid(9)
    model.mutateDocument(recordUndo: false) {
      $0.cutSuggestions = [candidate]
      $0.suggestionBatch = batch
      $0.issuedSuggestionNumbers = [taken]
    }
    let before = model.documentState
    model.cutSuggestions.acceptTapped(candidate.id)
    expectNoDifference(model.documentState, before)
    #expect(model.cutSuggestions.actionMessage?.contains("another suggestion") == true)
    #expect(!model.canUndo)
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
    model.mutateSlices { $0[id: candidate.id]?.name = "Manually renamed" }
    model.mutateSlices { $0.remove(id: candidate.id) }
    let saved = try JSONEncoder().encode(model.documentState)
    let reopened = try JSONDecoder().decode(EditorDocumentState.self, from: saved)
    let fresh = try numberedSuggestion(plan: model.editPlan, id: Fixtures.uuid(7)).candidate
    let result = try numberSuggestions(
      [fresh], snapshot: batch.snapshot, starts: reopened.suggestionStarts,
      issued: reopened.issuedSuggestionNumbers, retained: [])
    expectNoDifference(result.candidates.first?.naming?.reservation?.number, 4)
    expectNoDifference(
      reopened.issuedSuggestionNumbers, [try #require(candidate.naming?.reservation)])
  }

  @Test func correctedGroupSpellingAndChangedNumberKeepOriginalIssuedIdentity() async throws {
    let model = editor()
    let (candidate, batch) = try numberedSuggestion(
      plan: model.editPlan, typeID: "intro", values: ["song-title": "Café", "artist-name": "Björk"])
    try model.replaceSuggestionBatch(candidates: [candidate], batch: batch)
    model.cutSuggestions.acceptTapped(candidate.id)
    let original = try #require(candidate.naming?.reservation)
    await model.undoTapped()
    model.mutateDocument {
      $0.cutSuggestions[id: candidate.id]?.naming?.correctedValues = [
        "song-title": "CAFÉ", "artist-name": "Björk",
      ]
      $0.cutSuggestions[id: candidate.id]?.naming?.reservation?.canonicalValues = [
        "song-title": "CAFÉ", "artist-name": "Björk",
      ]
    }
    model.cutSuggestions.acceptTapped(candidate.id)
    expectNoDifference(model.documentState.issuedSuggestionNumbers, [original])
    await model.undoTapped()
    model.mutateDocument {
      $0.cutSuggestions[id: candidate.id]?.naming?.reservation?.number = 8
    }
    model.cutSuggestions.acceptTapped(candidate.id)
    var changed = original
    changed.number = 8
    changed.canonicalValues = ["song-title": "CAFÉ", "artist-name": "Björk"]
    expectNoDifference(model.documentState.issuedSuggestionNumbers, [original, changed])
    await model.undoTapped()
    expectNoDifference(model.documentState.issuedSuggestionNumbers, [original, changed])
    let type = try #require(batch.snapshot.configuration.types.first { $0.id == "intro" })
    let values = ["song-title": "Another Song", "artist-name": "Björk"]
    let moved = SequenceReservation(
      candidateID: candidate.id,
      key: suggestionSequenceKey(type: type, values: values, candidateID: candidate.id),
      number: 1, canonicalValues: values)
    model.mutateDocument {
      $0.cutSuggestions[id: candidate.id]?.naming?.correctedValues = values
      $0.cutSuggestions[id: candidate.id]?.naming?.reservation = moved
    }
    model.cutSuggestions.acceptTapped(candidate.id)
    expectNoDifference(model.documentState.issuedSuggestionNumbers, [original, changed, moved])
    await model.undoTapped()
    expectNoDifference(model.documentState.issuedSuggestionNumbers, [original, changed, moved])
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
    expectNoDifference(model.documentCutSuggestions.elements, [candidate])
    model.mutateDocument {
      $0.suggestionStarts.types["spotlight"] = .init(number: 20, isExplicit: true)
    }
    await model.undoTapped()
    expectNoDifference(model.documentState.suggestionStarts, SuggestionStarts())
    expectNoDifference(model.documentState.suggestionBatch, batch)
  }

  @Test func explicitPendingRenumberIsUndoableWithoutChangingRejectedOrIssued() async throws {
    let model = editor()
    let (candidate, batch) = try numberedSuggestion(plan: model.editPlan)
    var rejected = try numberedSuggestion(plan: model.editPlan, id: Fixtures.uuid(6)).candidate
    rejected.reject()
    rejected.naming?.reservation?.number = 4
    try model.replaceSuggestionBatch(candidates: [candidate, rejected], batch: batch)
    model.cutSuggestions.acceptTapped(candidate.id)
    await model.undoTapped()
    let ledger = model.documentState.issuedSuggestionNumbers
    let before = model.documentState
    let result = try numberSuggestions(
      model.documentCutSuggestions.elements, snapshot: batch.snapshot,
      starts: SuggestionStarts(types: ["spotlight": .init(number: 10, isExplicit: true)]),
      issued: ledger, retained: model.documentCutSuggestions.compactMap { $0.naming?.reservation },
      mode: .pendingRenumber(selectedCandidateIDs: [candidate.id]), existingBatch: batch)
    try model.replaceSuggestionBatch(
      candidates: result.candidates, batch: result.batch, recordUndo: true)
    expectNoDifference(
      model.documentCutSuggestions[id: candidate.id]?.naming?.reservation?.number, 10)
    expectNoDifference(model.documentCutSuggestions[id: rejected.id], rejected)
    expectNoDifference(model.documentState.issuedSuggestionNumbers, ledger)
    await model.undoTapped()
    expectNoDifference(model.documentState, before)
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

  @Test func editingASuggestionTitleCoalescesTypingIntoOneUndoableAction() async {
    let plan = Fixtures.editPlan()
    let model = editor(plan)
    let suggestion = freshSuggestion(Fixtures.uuid(1), plan: plan)
    model.cutSuggestions.onSuggestionsProduced?([suggestion])

    var seen: [EditorDocumentState] = []
    model.onDocumentStateChanged = { seen.append($0) }

    model.cutSuggestions.titleFocusChanged(suggestion.id, isFocused: true)
    model.cutSuggestions.titleChanged(suggestion.id, to: "R")
    model.cutSuggestions.titleChanged(suggestion.id, to: "Renamed")
    model.cutSuggestions.titleChanged(suggestion.id, to: "Renamed cut")

    expectNoDifference(model.documentCutSuggestions[id: suggestion.id]?.title, "Renamed cut")
    expectNoDifference(seen.count, 3)
    expectNoDifference(model.documentUndo.undo.count, 0)
    #expect(!model.canUndo)

    model.cutSuggestions.titleFocusChanged(suggestion.id, isFocused: false)

    expectNoDifference(model.documentUndo.undo.count, 1)
    #expect(model.canUndo)

    await model.undoTapped()
    expectNoDifference(
      model.documentCutSuggestions[id: suggestion.id]?.title, suggestion.title)
  }

  @Test func acceptingAfterEditingTheTitleNamesTheSliceFromTheEditedTitle() {
    let plan = Fixtures.editPlan()
    let model = editor(plan)
    let suggestion = freshSuggestion(Fixtures.uuid(1), plan: plan)
    model.cutSuggestions.onSuggestionsProduced?([suggestion])

    model.cutSuggestions.titleFocusChanged(suggestion.id, isFocused: true)
    model.cutSuggestions.titleChanged(suggestion.id, to: "My custom")
    model.cutSuggestions.titleChanged(suggestion.id, to: "My custom clip name")
    model.cutSuggestions.acceptTapped(suggestion.id)

    expectNoDifference(model.slices[id: suggestion.id]?.name, "My custom clip name")
    expectNoDifference(model.documentUndo.undo.count, 2)
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

  @Test func finalEditorApplyRevalidatesAnExplicitStartAgainstTheLatestIssuedLedger() async throws {
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
        expectNoDifference(model.documentCutSuggestions.elements, [])
        expectNoDifference(model.suggestionBatch, nil)
        expectNoDifference(model.lastAppliedSuggestionRunID, nil)
        expectNoDifference(
          model.cutSuggestions.run.message, "Choose a starting number of at least 6.")
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

}
