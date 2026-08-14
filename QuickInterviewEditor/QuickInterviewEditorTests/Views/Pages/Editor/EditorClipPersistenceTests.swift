import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
import IdentifiedCollections
@_spi(Internals) import Sharing
import Testing

@testable import QuickInterviewEditor

@MainActor
struct EditorClipPersistenceTests {

  // MARK: - Helpers

  private func editor(_ plan: EditPlan = Fixtures.editPlan(), fingerprint: String) -> EditorModel {
    EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: plan,
      sourceFingerprint: fingerprint)
  }

  private func validSuggestion(
    id: UUID, plan: EditPlan, fingerprint: String, wordIDs: [Word.ID],
    status: CutSuggestion.Status = .pending, rank: Int = 0, title: String = "A story"
  ) -> CutSuggestion {
    var suggestion = Fixtures.cutSuggestion(
      id: id, title: title, wordIDs: wordIDs, rank: rank, status: status)
    suggestion.provenance = CutSuggestion.Provenance(
      model: "claude-sonnet-5", promptVersion: "v1", productSpecVersion: "v1",
      transcriptHash: plan.transcriptHash, sourceFingerprint: fingerprint, diarizationHash: nil)
    return suggestion
  }

  private func manualSlice(
    id: UUID, name: String = "Manual", start: Int = 1000, end: Int = 2000
  ) -> Slice {
    Slice(
      id: id, name: name, startSample: start, endSample: end, wordIDs: [10, 11],
      snippet: "hi", warnings: [])
  }

  private var inMemory: FileStorage { FileStorage.inMemory(fileSystem: LockIsolated([:])) }

  // MARK: - Decoding tolerance

  @Test func oldSidecarWithNoClipSectionsDecodesEmptyWithoutWipingSuggestions() throws {
    let decoded = try JSONDecoder().decode(ProjectState.self, from: Fixtures.projectStateData())

    expectNoDifference(decoded.cutSuggestions.count, 2)
    expectNoDifference(decoded.slices, [])
    expectNoDifference(decoded.rejectedManualSliceIDs, [])
  }

  @Test func emptyObjectDecodesToDefaultProjectState() throws {
    let decoded = try JSONDecoder().decode(ProjectState.self, from: Data("{}".utf8))

    expectNoDifference(decoded, ProjectState())
  }

  @Test func malformedClipSectionDecodesEmptyWithoutWipingSuggestions() throws {
    var object = try #require(
      JSONSerialization.jsonObject(with: Fixtures.projectStateData()) as? [String: Any])
    object["slices"] = "not-an-array"

    let data = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(ProjectState.self, from: data)

    expectNoDifference(decoded.cutSuggestions.count, 2)
    expectNoDifference(decoded.slices, [])
  }

  // MARK: - Round-trip persistence

  @Test func manualSliceHydratesIntoAFreshModel() {
    let fingerprint = "fp-hydrate-manual"
    withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      let slice = manualSlice(id: Fixtures.uuid(9), name: "Kept")
      let first = editor(fingerprint: fingerprint)
      first.mutateSlices { $0.append(slice) }

      let reopened = editor(fingerprint: fingerprint)

      expectNoDifference(reopened.slices, [slice])
      expectNoDifference(reopened.clips.map(\.source), [.manualSlice(slice.id)])
    }
  }

  @Test func renameMoveAndBoundaryEditsSurviveAFreshModel() {
    let fingerprint = "fp-edits"
    withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      let one = manualSlice(id: Fixtures.uuid(1), name: "One", start: 1000, end: 2000)
      let two = manualSlice(id: Fixtures.uuid(2), name: "Two", start: 3000, end: 4000)
      let first = editor(fingerprint: fingerprint)
      first.mutateSlices {
        $0.append(one)
        $0.append(two)
      }
      first.renameSlice(one.id, to: "Renamed")
      first.mutateSlices { $0[id: one.id]?.endSample = 2500 }
      first.moveSlices(fromOffsets: IndexSet(integer: 0), toOffset: 2)

      let reopened = editor(fingerprint: fingerprint)

      expectNoDifference(reopened.slices.map(\.id), [two.id, one.id])
      expectNoDifference(reopened.slices[id: one.id]?.name, "Renamed")
      expectNoDifference(reopened.slices[id: one.id]?.endSample, 2500)
    }
  }

  @Test func manualRejectSurvivesAFreshModelAndIsExcludedFromExport() async {
    let fingerprint = "fp-reject-persist"
    await withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      let slice = manualSlice(id: Fixtures.uuid(9))
      let first = editor(fingerprint: fingerprint)
      first.mutateSlices { $0.append(slice) }
      first.selectClip(slice.id)
      await first.rejectCurrentClip()

      let reopened = editor(fingerprint: fingerprint)

      #expect(reopened.rejectedManualSliceIDs.contains(slice.id))
      expectNoDifference(reopened.clips.map(\.state), [.rejected])
      #expect(reopened.exportableSlices.isEmpty)
    }
  }

  @Test func undoRestoredBundlePersistsToAFreshModel() {
    let fingerprint = "fp-undo-persist"
    withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      let kept = manualSlice(id: Fixtures.uuid(1), name: "Kept")
      let removed = manualSlice(id: Fixtures.uuid(2), name: "Removed", start: 3000, end: 4000)
      let first = editor(fingerprint: fingerprint)
      first.mutateSlices { $0.append(kept) }
      first.mutateSlices { $0.append(removed) }
      first.mutateSlices { $0.remove(id: removed.id) }

      let reopened = editor(fingerprint: fingerprint)
      expectNoDifference(reopened.slices.map(\.id), [kept.id])
    }
  }

  @Test func undoOnAFreshModelSeesTheUndoneStatePersisted() async {
    let fingerprint = "fp-undo-fresh"
    await withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      let removed = manualSlice(id: Fixtures.uuid(2), name: "Removed", start: 3000, end: 4000)
      let first = editor(fingerprint: fingerprint)
      first.mutateSlices { $0.append(removed) }
      first.mutateSlices { $0.remove(id: removed.id) }

      await first.undoTapped()

      let reopened = editor(fingerprint: fingerprint)
      expectNoDifference(reopened.slices.map(\.id), [removed.id])
    }
  }

  // MARK: - Suggestion accept persistence

  @Test func acceptedSuggestionPersistsStatusAndSliceAndDedupesInAFreshModel() async {
    let fingerprint = "fp-accept-persist"
    let plan = Fixtures.editPlan()
    let suggestion = validSuggestion(
      id: Fixtures.uuid(1), plan: plan, fingerprint: fingerprint,
      wordIDs: [10, 11, 12, 13, 14, 15, 16])

    await withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState(
        cutSuggestions: [suggestion])
      let first = editor(plan, fingerprint: fingerprint)
      first.selectClip(suggestion.id)
      await first.approveCurrentClip()

      let reopened = editor(plan, fingerprint: fingerprint)

      expectNoDifference(reopened.clips.count, 1)
      expectNoDifference(reopened.clips.map(\.state), [.approved])
      #expect(reopened.slices[id: suggestion.id] != nil)
      expectNoDifference(reopened.exportableSlices.map(\.id), [suggestion.id])
    }
  }

  @Test func rejectingAnAcceptedSuggestionExcludesItFromExportEvenAfterUndo() async {
    let fingerprint = "fp-reject-accepted"
    let plan = Fixtures.editPlan()
    let suggestion = validSuggestion(
      id: Fixtures.uuid(1), plan: plan, fingerprint: fingerprint,
      wordIDs: [10, 11, 12, 13, 14, 15, 16])

    await withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState(
        cutSuggestions: [suggestion])
      let first = editor(plan, fingerprint: fingerprint)
      first.selectClip(suggestion.id)
      await first.approveCurrentClip()
      await first.rejectCurrentClip()

      let reopened = editor(plan, fingerprint: fingerprint)
      expectNoDifference(reopened.clips.map(\.state), [.rejected])
      #expect(reopened.exportableSlices.isEmpty)

      await first.undoTapped()
      #expect(first.slices[id: suggestion.id] != nil)
      #expect(first.exportableSlices.isEmpty)
    }
  }

  @Test func singleRowExportRespectsTheAcceptedGateAfterRejectUndo() async {
    let fingerprint = "fp-single-export-gate"
    let plan = Fixtures.editPlan()
    let suggestion = validSuggestion(
      id: Fixtures.uuid(1), plan: plan, fingerprint: fingerprint,
      wordIDs: [10, 11, 12, 13, 14, 15, 16])

    await withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState(
        cutSuggestions: [suggestion])
      let model = editor(plan, fingerprint: fingerprint)
      model.selectClip(suggestion.id)
      await model.approveCurrentClip()
      await model.rejectCurrentClip()
      await model.undoTapped()  // re-adds the slice while its suggestion stays rejected

      #expect(model.slices[id: suggestion.id] != nil)
      model.exportSliceTapped(suggestion.id)

      expectNoDifference(model.exportPhase, .idle)
    }
  }

  // MARK: - Sidecar co-tenancy

  @Test func persistingSlicesPreservesSuggestionsAndReservedSpeakerFields() {
    let fingerprint = "fp-cotenant"
    let plan = Fixtures.editPlan()
    let suggestion = validSuggestion(
      id: Fixtures.uuid(1), plan: plan, fingerprint: fingerprint, wordIDs: [10, 11, 12])

    withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState(
        cutSuggestions: [suggestion], speakerCountOverride: 3,
        speakerDisplayNames: ["SPEAKER_00": "Host"])
      let model = editor(plan, fingerprint: fingerprint)
      let slice = manualSlice(id: Fixtures.uuid(9))
      model.mutateSlices { $0.append(slice) }

      expectNoDifference(state.slices, [slice])
      expectNoDifference(state.cutSuggestions[id: suggestion.id]?.id, suggestion.id)
      expectNoDifference(state.speakerCountOverride, 3)
      expectNoDifference(state.speakerDisplayNames, ["SPEAKER_00": "Host"])
    }
  }
}
