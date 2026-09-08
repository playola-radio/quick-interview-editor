import CustomDump
import Dependencies
import Foundation
import IdentifiedCollections
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct EditorDocumentMutationTests {

  @Test func automaticTypeStartIsVisibleAndRestorableWithSeparateUndo() async throws {
    let model = try SuggestionReviewTests().fixture()
    let before = model.documentState
    expectNoDifference(
      model.cutSuggestions.futureStartRows.first { $0.id == "intro" }?.preferenceLabel,
      "Automatic — starts at 1 or after previously issued numbers")
    model.cutSuggestions[futureStart: "intro"] = "7"
    model.cutSuggestions.applyTypeStartTapped("intro")
    expectNoDifference(
      model.cutSuggestions.futureStartRows.first { $0.id == "intro" }?.preferenceLabel,
      "Starting count: 7")
    model.cutSuggestions.resetTypeStartTapped("intro")
    expectNoDifference(model.suggestionStarts.types["intro"], nil)
    await model.undoTapped()
    expectNoDifference(model.suggestionStarts.types["intro"]?.number, 7)
    expectNoDifference(model.documentCutSuggestions, before.cutSuggestions)
    expectNoDifference(model.suggestionBatch, before.suggestionBatch)
  }

  @Test func futureStartsResetUndoAndReopenNeverRenumberCurrentBatch() async throws {
    let model = try SuggestionReviewTests().fixture()
    let before = model.documentState
    let batch = try #require(model.suggestionBatch)
    let key = try #require(reviewSequenceKey(model.documentCutSuggestions[0], batch: batch))
    expectNoDifference(model.documentCutSuggestions[0].naming?.reservation, nil)
    model.cutSuggestions[futureStart: "intro"] = "7"
    model.cutSuggestions.applyTypeStartTapped("intro")
    expectNoDifference(model.documentCutSuggestions, before.cutSuggestions)
    expectNoDifference(model.suggestionStarts.types["intro"]?.number, 7)
    let reopened = try JSONDecoder().decode(
      EditorDocumentState.self, from: JSONEncoder().encode(model.documentState))
    expectNoDifference(reopened.suggestionStarts, model.suggestionStarts)
    try model.applySuggestionReviewIntent(.futureGroup(key: key, start: 10, display: nil))
    model.cutSuggestions.resetSongStartTapped(key)
    expectNoDifference(model.suggestionStarts.groups, [])
    await model.undoTapped()
    expectNoDifference(model.suggestionStarts.groups.first?.start.number, 10)
    expectNoDifference(model.documentCutSuggestions, before.cutSuggestions)
    model.cutSuggestions.recoveryBlocksSuggestions = true
    let locked = model.documentState
    model.cutSuggestions[futureStart: "intro"] = "20"
    model.cutSuggestions.applyTypeStartTapped("intro")
    model.cutSuggestions.resetSongStartTapped(key)
    expectNoDifference(model.documentState, locked)
  }

  @Test func groupStartOldJSONRemainsDecodableWithoutDisplayMetadata() throws {
    let start = SuggestionStarts.GroupStart(
      key: .init(typeID: "intro", fields: [], provisionalCandidateID: nil),
      start: .init(number: 3, isExplicit: true))
    let decoded = try JSONDecoder().decode(
      SuggestionStarts.GroupStart.self, from: JSONEncoder().encode(start))
    expectNoDifference(decoded, start)
    expectNoDifference(decoded.display, nil)
  }

  private func editor() -> EditorModel {
    EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL,
      editPlan: Fixtures.editPlan(), sourceFingerprint: "fp-mutation")
  }

  @Test func recoveryOwnerIsAllocatedOnlyWhenRecoveryWorkStartsAndSurvivesUndo() async {
    await withDependencies {
      $0.uuid = .constant(Fixtures.uuid(77))
    } operation: {
      let model = editor()
      expectNoDifference(model.documentState.suggestionRecoveryOwnerID, nil)
      model.mutateDocument { $0.speakerCountOverride = 2 }
      expectNoDifference(model.ensureSuggestionRecoveryOwner(), Fixtures.uuid(77))
      expectNoDifference(model.ensureSuggestionRecoveryOwner(), Fixtures.uuid(77))
      await model.undoTapped()
      expectNoDifference(model.documentState.suggestionRecoveryOwnerID, Fixtures.uuid(77))
      expectNoDifference(model.documentState.speakerCountOverride, nil)
    }
  }

  @Test func initializationMutationAndRestorePreserveAllSuggestionRecoveryFields() async {
    let plan = Fixtures.editPlan()
    let snapshot = SuggestionRunSnapshot(
      runID: Fixtures.uuid(1), configuration: SuggestionDefaults.configuration,
      configurationHash: "fixture",
      model: "fixture", discoveryPromptVersion: "configured-v1",
      extractionPromptVersion: "fields-v1",
      productSpecVersion: "configured-v1", transcriptHash: plan.transcriptHash,
      sourceFingerprint: "fixture", sampleRate: plan.source.sampleRate)
    let checkpoint = SuggestionRunCheckpoint(
      pythonRevision: 4, controlRevision: 3, originalBatchFingerprint: "old", snapshot: snapshot,
      phase: .needsRetry, candidates: [], completedRequestKeys: ["done"],
      failedRequestKeys: ["failed"],
      proposedStarts: SuggestionStarts(), failureMessage: "Retry field extraction")
    let seed = EditorDocumentState(
      suggestionBatch: .init(
        snapshot: snapshot, actualStarts: SuggestionStarts(), canonicalGroups: []),
      unfinishedSuggestionRun: checkpoint, lastAppliedSuggestionRunID: Fixtures.uuid(2),
      suggestionRecoveryOwnerID: Fixtures.uuid(3))
    let model = EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"), canonicalAudioURL: Fixtures.canonicalAudioURL,
      editPlan: plan, initialDocument: seed)
    expectNoDifference(model.documentState, seed)
    await MainActor.run {
      expectDifference(model.documentState) {
        model.mutateDocument {
          $0.unfinishedSuggestionRun?.failureMessage = "Updated"
          $0.lastAppliedSuggestionRunID = Fixtures.uuid(4)
        }
      } changes: {
        $0.unfinishedSuggestionRun?.failureMessage = "Updated"
        $0.lastAppliedSuggestionRunID = Fixtures.uuid(4)
      }
    }
    await model.undoTapped()
    expectNoDifference(model.documentState, seed)
    await model.redoTapped()
    expectNoDifference(model.documentState.unfinishedSuggestionRun?.failureMessage, "Updated")
    expectNoDifference(model.documentState.lastAppliedSuggestionRunID, Fixtures.uuid(4))
    expectNoDifference(
      model.documentState.suggestionRecoveryOwnerID, seed.suggestionRecoveryOwnerID)
  }

  @Test func mutateDocumentEmitsChangeOnceWithTheNewState() {
    let model = editor()
    var seen: [EditorDocumentState] = []
    model.onDocumentStateChanged = { seen.append($0) }

    let slice = Fixtures.slice(id: Fixtures.uuid(1))
    model.mutateDocument { $0.slices.append(slice) }

    expectNoDifference(seen.count, 1)
    expectNoDifference(seen.last?.slices.last, slice)
    #expect(model.canUndo)
  }

  @Test func noOpMutateDocumentNeitherFiresTheCallbackNorRecordsUndo() {
    let model = editor()
    var seen: [EditorDocumentState] = []
    model.onDocumentStateChanged = { seen.append($0) }

    model.mutateDocument { _ in }

    expectNoDifference(seen.count, 0)
    #expect(!model.canUndo)
  }

  @Test func recordUndoFalseDirtiesButLeavesCanUndoUnchanged() {
    let model = editor()
    var seen: [EditorDocumentState] = []
    model.onDocumentStateChanged = { seen.append($0) }

    model.mutateDocument(recordUndo: false) {
      $0.slices.append(Fixtures.slice(id: Fixtures.uuid(1)))
    }

    expectNoDifference(seen.count, 1)
    expectNoDifference(seen.last?.slices.count, 1)
    #expect(!model.canUndo)
  }

  @Test func undoAndRedoFireTheCallbackAfterRestoring() async {
    let model = editor()
    let slice = Fixtures.slice(id: Fixtures.uuid(1))
    model.mutateDocument { $0.slices.append(slice) }

    var seen: [EditorDocumentState] = []
    model.onDocumentStateChanged = { seen.append($0) }

    await model.undoTapped()
    expectNoDifference(seen.count, 1)
    expectNoDifference(seen.last?.slices.count, 0)

    await model.redoTapped()
    expectNoDifference(seen.count, 2)
    expectNoDifference(seen.last?.slices.last, slice)
  }

  @Test func documentStateCarriesTheNewFields() {
    let model = editor()
    let suggestion = Fixtures.cutSuggestion(id: Fixtures.uuid(5))
    model.mutateDocument { doc in
      doc.cutSuggestions.append(suggestion)
      doc.speakerCountOverride = 3
      doc.speakerDisplayNames = ["0": "Host"]
    }

    expectNoDifference(model.documentState.cutSuggestions.elements, [suggestion])
    expectNoDifference(model.documentState.speakerCountOverride, 3)
    expectNoDifference(model.documentState.speakerDisplayNames, ["0": "Host"])
  }
}
