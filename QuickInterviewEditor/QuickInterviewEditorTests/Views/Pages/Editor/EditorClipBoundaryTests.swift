import CustomDump
import Dependencies
import Foundation
@_spi(Internals) import Sharing
import Testing

@testable import QuickInterviewEditor

@MainActor
struct EditorClipBoundaryTests {

  // MARK: - FineTuneModel sample setter

  private func fineTune(
    sampleRate: Int = 44100, duration: Int = 2_000_000, silences: [EditPlan.Silence] = []
  ) -> FineTuneModel {
    FineTuneModel(sampleRate: sampleRate, durationSamples: duration, silences: silences)
  }

  @Test func setStartBypassesTheInsetWindowClamp() {
    let model = fineTune()
    model.begin(target: .pendingSelection, range: 1_000_000..<1_100_000)

    // 100_000 is far outside the ±0.5s inset window centered on the committed start; the
    // sample setter (unlike the cut-line drag) must let a whole-word edge move there.
    model.setStart(toSample: 100_000, snap: .word)

    expectNoDifference(model.draftRange, 100_000..<1_100_000)
  }

  @Test func setEndSilenceSnapPullsToNearbySilenceButWordSnapDoesNot() {
    let silences = [EditPlan.Silence(startSample: 500_000, endSample: 520_000)]

    let silenceModel = fineTune(silences: silences)
    silenceModel.begin(target: .pendingSelection, range: 100_000..<505_000)
    silenceModel.setEnd(toSample: 519_500, snap: .silence)
    expectNoDifference(silenceModel.draftRange, 100_000..<520_000)

    let wordModel = fineTune(silences: silences)
    wordModel.begin(target: .pendingSelection, range: 100_000..<505_000)
    wordModel.setEnd(toSample: 519_500, snap: .word)
    expectNoDifference(wordModel.draftRange, 100_000..<519_500)
  }

  @Test func setBoundaryIsANoOpWithoutASession() {
    let model = fineTune()
    model.setStart(toSample: 100_000, snap: .word)
    #expect(model.draftRange == nil)
  }

  // MARK: - Boundary edit funnel (EditorModel)

  private func editor(_ plan: EditPlan, fingerprint: String) -> EditorModel {
    EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: plan,
      sourceFingerprint: fingerprint)
  }

  private var inMemory: FileStorage { FileStorage.inMemory(fileSystem: LockIsolated([:])) }

  /// A manual slice on the fixture word edges: words 11–14 (Hubbard…Ray).
  private func wordSlice(id: UUID) -> Slice {
    Slice(
      id: id, name: "Manual", startSample: 195_098, endSample: 243_653,
      wordIDs: [11, 12, 13, 14], snippet: "hi", warnings: [])
  }

  @Test func movingStartLaterOnASliceDropsAWordAndUndoRestoresIt() async {
    let fingerprint = "fp-bound-start"
    let plan = Fixtures.editPlan()

    await withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let model = editor(plan, fingerprint: fingerprint)
      let slice = wordSlice(id: Fixtures.uuid(9))
      model.mutateSlices { $0.append(slice) }
      model.selectClip(slice.id)

      model.moveCurrentClipBoundary(.startLater)

      // Start snaps forward to word 12's start edge; word 11 drops by midpoint membership.
      expectNoDifference(model.slices[id: slice.id]?.startSample, 208_328)
      expectNoDifference(model.slices[id: slice.id]?.wordIDs, [12, 13, 14])
      #expect(model.canUndo)

      // A single boundary step is one undo entry: undoing it restores the original range.
      await model.undoTapped()
      expectNoDifference(model.slices[id: slice.id]?.startSample, 195_098)
      expectNoDifference(model.slices[id: slice.id]?.wordIDs, [11, 12, 13, 14])
    }
  }

  @Test func movingStartEarlierAtTheClipHeadIsANoOp() {
    let fingerprint = "fp-bound-noop"
    let plan = Fixtures.editPlan()

    withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let model = editor(plan, fingerprint: fingerprint)
      // Slice starting on the very first word: no earlier word to pull in.
      let firstStart = plan.words.compactMap(\.startSample).min()!
      let slice = Slice(
        id: Fixtures.uuid(9), name: "Head", startSample: firstStart, endSample: 243_653,
        wordIDs: [], snippet: "hi", warnings: [])
      model.mutateSlices { $0.append(slice) }
      model.selectClip(slice.id)

      model.moveCurrentClipBoundary(.startEarlier)

      expectNoDifference(model.slices[id: slice.id]?.startSample, firstStart)
    }
  }

  @Test func boundaryEditOnASuggestionUpdatesTheLiveCardButMintsNoSlice() {
    let fingerprint = "fp-bound-suggestion"
    let plan = Fixtures.editPlan()
    var suggestion = Fixtures.cutSuggestion(
      id: Fixtures.uuid(1), wordIDs: [11, 12, 13, 14])
    suggestion.startSample = 195_098
    suggestion.endSample = 243_653
    suggestion.provenance = CutSuggestion.Provenance(
      model: "m", promptVersion: "v", productSpecVersion: "v",
      transcriptHash: plan.transcriptHash, sourceFingerprint: fingerprint, diarizationHash: nil)

    withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState(
        cutSuggestions: [suggestion])
      let model = editor(plan, fingerprint: fingerprint)
      model.selectClip(suggestion.id)

      model.moveCurrentClipBoundary(.startLater)

      // No slice minted (a suggestion stays a suggestion until approved)…
      #expect(model.slices.isEmpty)
      // …but the live card mirrors the fine-tune draft (the two-way sync spine).
      expectNoDifference(model.boundaryDraftClipID, suggestion.id)
      let card = model.clipCards.first { $0.id == suggestion.id }
      expectNoDifference(card?.range, model.fineTune.draftRange)
    }
  }

  // MARK: - Point-and-add

  @Test func pointAndAddPickingAnEarlierWordExtendsTheStartAndDisarms() {
    let fingerprint = "fp-pna-extend"
    let plan = Fixtures.editPlan()

    withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let model = editor(plan, fingerprint: fingerprint)
      let slice = wordSlice(id: Fixtures.uuid(9))  // words 11–14, start 195_098
      model.mutateSlices { $0.append(slice) }

      model.armAddTapped(slice.id, side: .start)
      #expect(model.transcript.armedAddSide == .start)
      model.pointAndAddPicked(10)  // Wiley, start_sample 179_222

      expectNoDifference(model.slices[id: slice.id]?.startSample, 179_222)
      #expect(model.slices[id: slice.id]?.wordIDs.contains(10) == true)
      #expect(model.transcript.armedAddSide == nil)
    }
  }

  @Test func pointAndAddPickingAWordInsideTheClipShrinksTheStart() {
    let fingerprint = "fp-pna-shrink"
    let plan = Fixtures.editPlan()

    withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let model = editor(plan, fingerprint: fingerprint)
      let slice = wordSlice(id: Fixtures.uuid(9))  // words 11–14, start 195_098
      model.mutateSlices { $0.append(slice) }

      model.armAddTapped(slice.id, side: .start)
      model.pointAndAddPicked(13)  // "and", start_sample 232_186 — inside the clip

      expectNoDifference(model.slices[id: slice.id]?.startSample, 232_186)
      #expect(model.slices[id: slice.id]?.wordIDs.contains(11) == false)
    }
  }

  @Test func fineTuneCutLineDragMovesTheCurrentCardsWordRange() {
    let fingerprint = "fp-reverse-sync"
    let plan = Fixtures.editPlan()

    withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let model = editor(plan, fingerprint: fingerprint)
      let slice = wordSlice(id: Fixtures.uuid(9))
      model.mutateSlices { $0.append(slice) }
      model.selectClip(slice.id)
      model.focusCurrentClip()
      let committed = model.fineTune.committedRange

      // A fine-tune nudge (the cut-line path) moves the draft end; the card must follow it.
      model.cutOutNudged(byMs: 10)

      #expect(model.fineTune.draftRange != committed)
      let card = model.clipCards.first { $0.id == slice.id }
      expectNoDifference(card?.range, model.fineTune.draftRange)
    }
  }

  @Test func gripDragCoalescesManyStepsIntoOneUndoEntry() async {
    let fingerprint = "fp-bound-grip"
    let plan = Fixtures.editPlan()

    await withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let model = editor(plan, fingerprint: fingerprint)
      let slice = wordSlice(id: Fixtures.uuid(9))
      model.mutateSlices { $0.append(slice) }
      model.selectClip(slice.id)

      model.clipGripDragBegan()
      model.clipGripDragged(.endLater)
      model.clipGripDragged(.endLater)
      // Mid-drag nothing is committed to the slice yet.
      expectNoDifference(model.slices[id: slice.id]?.endSample, 243_653)
      model.clipGripDragEnded()

      let draggedEnd = model.slices[id: slice.id]?.endSample
      #expect(draggedEnd != 243_653)

      // The whole drag is ONE undo entry: undoing once restores the pre-drag end (not just one
      // of the two steps). A second undo would remove the slice entirely.
      await model.undoTapped()
      expectNoDifference(model.slices[id: slice.id]?.endSample, 243_653)
    }
  }
}
