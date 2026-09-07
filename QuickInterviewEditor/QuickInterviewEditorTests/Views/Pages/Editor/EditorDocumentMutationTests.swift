import CustomDump
import Dependencies
import Foundation
import IdentifiedCollections
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct EditorDocumentMutationTests {

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
    await expectDifference(model.documentState) {
      model.mutateDocument {
        $0.unfinishedSuggestionRun?.failureMessage = "Updated"
        $0.lastAppliedSuggestionRunID = Fixtures.uuid(4)
      }
    } changes: {
      $0.unfinishedSuggestionRun?.failureMessage = "Updated"
      $0.lastAppliedSuggestionRunID = Fixtures.uuid(4)
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
