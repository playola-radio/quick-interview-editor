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

  // MARK: - Block edge drag (absolute word) — view-only preview, commit on release

  @Test func blockEdgeDragMakesNoModelChangeUntilReleaseThenOneUndoEntry() async {
    let fingerprint = "fp-block-drag"
    let plan = Fixtures.editPlan()

    await withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let model = editor(plan, fingerprint: fingerprint)
      let slice = wordSlice(id: Fixtures.uuid(9))  // words 11–14, end 243_653
      model.mutateSlices { $0.append(slice) }
      model.selectClip(slice.id)

      // The drag is a pure view-only band preview: it makes NO model call, so as the pointer
      // crosses words 15 and 16 the model — slice range and fine-tune draft alike — is untouched.
      let preDrag = model.slices[id: slice.id]
      #expect(!model.fineTune.hasUnsavedChange)
      expectNoDifference(model.slices[id: slice.id], preDrag)

      // Release commits ONCE, to the word the edge landed on ("is," end 263_938).
      model.commitClipBoundary(slice.id, side: .end, toWordID: 16)
      expectNoDifference(model.slices[id: slice.id]?.endSample, 263_938)
      expectNoDifference(model.slices[id: slice.id]?.wordIDs, [11, 12, 13, 14, 15, 16])

      // The whole drag is ONE undo entry: undoing once restores the pre-drag range (the slice
      // itself survives — a second undo would remove it).
      await model.undoTapped()
      expectNoDifference(model.slices[id: slice.id]?.endSample, 243_653)
      expectNoDifference(model.slices[id: slice.id]?.wordIDs, [11, 12, 13, 14])
    }
  }

  @Test func escCancelledDragRecordsNoUndoEntry() async {
    let fingerprint = "fp-block-esc"
    let plan = Fixtures.editPlan()

    await withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let model = editor(plan, fingerprint: fingerprint)
      let slice = wordSlice(id: Fixtures.uuid(9))
      model.mutateSlices { $0.append(slice) }  // the slice's creation is the sole undo entry
      model.selectClip(slice.id)

      // Esc drops the view preview WITHOUT calling `commitClipBoundary`, so the model never
      // changes and no undo entry is recorded. The only entry on the stack is the slice's
      // creation, so one undo removes the slice entirely (it does not just restore a boundary).
      #expect(!model.fineTune.hasUnsavedChange)
      expectNoDifference(model.slices[id: slice.id]?.endSample, 243_653)
      #expect(model.canUndo)
      await model.undoTapped()
      #expect(model.slices[id: slice.id] == nil)
    }
  }

  @Test func commitClipBoundaryIsRefusedWhenAnUnsavedEditIsHeldElsewhere() {
    let fingerprint = "fp-block-refuse"
    let plan = Fixtures.editPlan()

    withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let model = editor(plan, fingerprint: fingerprint)
      let slice = wordSlice(id: Fixtures.uuid(9))  // words 11–14, end 243_653
      model.mutateSlices { $0.append(slice) }

      // A clip with a range would accept a drag…
      #expect(model.canBeginBoundaryEdit(on: slice.id))

      // …but with an unsaved edit held on a DIFFERENT target the query refuses, and a commit is a
      // no-op that leaves selection + the other draft untouched (atomic — it never retargets).
      let other = Slice(
        id: Fixtures.uuid(8), name: "Other", startSample: 300_000, endSample: 340_000,
        wordIDs: [16, 17], snippet: "x", warnings: [])
      model.mutateSlices { $0.append(other) }
      model.selectClip(other.id)
      model.focusCurrentClip()
      model.cutOutNudged(byMs: 10)  // dirties the other clip's draft
      #expect(model.fineTune.hasUnsavedChange)
      #expect(model.canBeginBoundaryEdit(on: slice.id) == false)

      model.commitClipBoundary(slice.id, side: .end, toWordID: 18)
      expectNoDifference(model.slices[id: slice.id]?.endSample, 243_653)
      expectNoDifference(model.currentClipID, other.id)
      #expect(model.fineTune.hasUnsavedChange)
    }
  }

  @Test func commitClipBoundaryResizesTheExplicitClipWithoutMovingSelection() async {
    let fingerprint = "fp-block-explicit"
    let plan = Fixtures.editPlan()

    await withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let sliceA = wordSlice(id: Fixtures.uuid(9))  // words 11–14, end 243_653
      let sliceB = Slice(
        id: Fixtures.uuid(8), name: "B", startSample: 260_410, endSample: 280_696,
        wordIDs: [16, 17, 18], snippet: "x", warnings: [])
      let model = editor(plan, fingerprint: fingerprint)
      model.mutateSlices {
        $0.append(sliceA)
        $0.append(sliceB)
      }
      model.selectClip(sliceB.id)

      // The drag captures sliceA's id at drag-begin and commits it explicitly, so it resizes sliceA
      // even though sliceB is the current clip. The commit is SILENT: it never selects the dragged
      // clip, so the current clip stays sliceB — the screen keeps its place.
      model.commitClipBoundary(sliceA.id, side: .end, toWordID: 15)  // Wiley, end 258_646

      expectNoDifference(model.currentClipID, sliceB.id)
      expectNoDifference(model.slices[id: sliceA.id]?.endSample, 258_646)
      expectNoDifference(model.slices[id: sliceA.id]?.wordIDs, [11, 12, 13, 14, 15])
      // sliceB is untouched, and the whole drag is ONE undo entry.
      expectNoDifference(model.slices[id: sliceB.id]?.endSample, 280_696)
      await model.undoTapped()
      expectNoDifference(model.slices[id: sliceA.id]?.endSample, 243_653)
    }
  }

  @Test func commitClipBoundaryResizesSilentlyWithoutSelectingOrOpeningTheFineTunePane() async {
    let fingerprint = "fp-block-silent"
    let plan = Fixtures.editPlan()

    await withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let model = editor(plan, fingerprint: fingerprint)
      let slice = wordSlice(id: Fixtures.uuid(9))  // words 11–14, end 243_653
      model.mutateSlices { $0.append(slice) }

      // Drag-commit an unselected clip: it resizes in place and leaves the screen exactly as the
      // drag preview left it — nothing selected, no words highlighted, no fine-tune pane.
      #expect(model.currentClipID == nil)
      model.commitClipBoundary(slice.id, side: .end, toWordID: 16)  // "is," end 263_938

      expectNoDifference(model.slices[id: slice.id]?.endSample, 263_938)
      expectNoDifference(model.slices[id: slice.id]?.wordIDs, [11, 12, 13, 14, 15, 16])
      #expect(model.currentClipID == nil)
      #expect(model.activeSliceID == nil)
      #expect(!model.fineTune.hasUnsavedChange)
      #expect(model.transcript.selectedSampleRange == nil)

      // Still exactly one undo entry for the whole drag.
      await model.undoTapped()
      expectNoDifference(model.slices[id: slice.id]?.endSample, 243_653)
    }
  }

  @Test func commitClipBoundaryReanchorsAnOpenFineTunePaneOnTheSameClip() {
    let fingerprint = "fp-block-pane-sync"
    let plan = Fixtures.editPlan()

    withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let model = editor(plan, fingerprint: fingerprint)
      let slice = wordSlice(id: Fixtures.uuid(9))  // words 11–14, end 243_653
      model.mutateSlices { $0.append(slice) }
      model.selectClip(slice.id)
      model.focusCurrentClip()  // opens the fine-tune pane on this slice (clean)
      expectNoDifference(model.activeSliceID, slice.id)
      expectNoDifference(model.fineTune.committedRange?.upperBound, 243_653)

      model.commitClipBoundary(slice.id, side: .end, toWordID: 16)  // "is," end 263_938

      // The slice resized, and the still-clean pane re-anchored to the new range so the two
      // surfaces can't drift (no stale cut lines) — without dirtying the session, moving the
      // current clip, or closing/retargeting the pane.
      expectNoDifference(model.slices[id: slice.id]?.endSample, 263_938)
      expectNoDifference(model.fineTune.committedRange?.upperBound, 263_938)
      #expect(!model.fineTune.hasUnsavedChange)
      expectNoDifference(model.currentClipID, slice.id)
      expectNoDifference(model.activeSliceID, slice.id)
    }
  }

  @Test func commitClipBoundaryDroppedOnTheClipsOwnBoundaryWordIsANoOp() async {
    let fingerprint = "fp-block-noop"
    let plan = Fixtures.editPlan()

    await withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let model = editor(plan, fingerprint: fingerprint)
      let slice = wordSlice(id: Fixtures.uuid(9))  // words 11–14, start 195_098 (word 11's start)
      model.mutateSlices { $0.append(slice) }  // the slice's creation is the sole undo entry

      // Releasing the start edge back on word 11 (already the clip's start word) doesn't move the
      // boundary, so nothing is written and no undo entry is added.
      model.commitClipBoundary(slice.id, side: .start, toWordID: 11)
      expectNoDifference(model.slices[id: slice.id]?.startSample, 195_098)
      expectNoDifference(model.slices[id: slice.id]?.wordIDs, [11, 12, 13, 14])

      // The only entry on the stack is the creation, so one undo removes the slice entirely.
      #expect(model.canUndo)
      await model.undoTapped()
      #expect(model.slices[id: slice.id] == nil)
    }
  }

  @Test func keyboardAndNavKeysAreRefusedDuringABlockEdgeDrag() {
    let fingerprint = "fp-block-drag-vs-keys"
    let plan = Fixtures.editPlan()

    withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let sliceA = wordSlice(id: Fixtures.uuid(9))  // words 11–14, end 243_653
      let sliceB = Slice(
        id: Fixtures.uuid(8), name: "B", startSample: 260_410, endSample: 280_696,
        wordIDs: [16, 17, 18], snippet: "x", warnings: [])
      let model = editor(plan, fingerprint: fingerprint)
      model.mutateSlices {
        $0.append(sliceA)
        $0.append(sliceB)
      }
      model.selectClip(sliceA.id)

      // The view enters a block edge-drag preview (view-only). While it's active a ⌥-arrow and a
      // J-nav are both refused, so neither mutates the model out from under the drag — the release
      // stays exactly one undo entry.
      model.blockEdgeDragBegan()
      model.moveCurrentClipBoundary(.endLater)
      #expect(!model.fineTune.hasUnsavedChange)
      expectNoDifference(model.slices[id: sliceA.id]?.endSample, 243_653)
      #expect(model.clipKeyDown(.next) == false)
      expectNoDifference(model.currentClipID, sliceA.id)

      // Once the drag ends the keyboard path works again.
      model.blockEdgeDragEnded()
      model.moveCurrentClipBoundary(.endLater)
      #expect(model.slices[id: sliceA.id]?.endSample != 243_653)
    }
  }

  @Test func commitClipBoundaryResizesASuggestionInPlaceKeepingItPending() {
    let fingerprint = "fp-block-suggestion"
    let plan = Fixtures.editPlan()
    var suggestion = Fixtures.cutSuggestion(id: Fixtures.uuid(1), wordIDs: [11, 12, 13, 14])
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

      model.commitClipBoundary(suggestion.id, side: .end, toWordID: 15)  // "Wiley," end 258_646

      // A suggestion resizes in place in the sidecar: it keeps its pending status, mints no slice,
      // and opens no fine-tune draft — the card follows the suggestion's new range, not a draft.
      #expect(model.slices.isEmpty)
      expectNoDifference(state.cutSuggestions[id: suggestion.id]?.status, .pending)
      expectNoDifference(state.cutSuggestions[id: suggestion.id]?.endSample, 258_646)
      expectNoDifference(state.cutSuggestions[id: suggestion.id]?.wordIDs, [11, 12, 13, 14, 15])
      #expect(model.boundaryDraftClipID == nil)
      #expect(!model.fineTune.hasUnsavedChange)
      let clip = model.clips.first { $0.id == suggestion.id }
      expectNoDifference(clip?.range, 195_098..<258_646)
    }
  }

  // MARK: - Click inside a clip

  @Test func interiorClickFocusesAClipThenPullsTheNearerBoundary() {
    let fingerprint = "fp-inside"
    let plan = Fixtures.editPlan()

    withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let model = editor(plan, fingerprint: fingerprint)
      let slice = wordSlice(id: Fixtures.uuid(9))  // words 11–14
      model.mutateSlices { $0.append(slice) }

      // First click on a non-current clip only focuses it — no trim.
      model.clipInteriorClicked(slice.id, wordID: 12)
      expectNoDifference(model.currentClipID, slice.id)
      expectNoDifference(model.slices[id: slice.id]?.startSample, 195_098)
      expectNoDifference(model.slices[id: slice.id]?.wordIDs, [11, 12, 13, 14])

      // A second click, now that it's current, pulls the nearer boundary (word 12 is closer to
      // the start) to word 12's start edge, trimming word 11.
      model.clipInteriorClicked(slice.id, wordID: 12)
      expectNoDifference(model.slices[id: slice.id]?.startSample, 208_328)
      expectNoDifference(model.slices[id: slice.id]?.wordIDs, [12, 13, 14])
    }
  }

  @Test func pullClipBoundaryTrimsTheNearerEndToTheClickedWord() {
    let fingerprint = "fp-pull"
    let plan = Fixtures.editPlan()

    withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let model = editor(plan, fingerprint: fingerprint)
      let slice = wordSlice(id: Fixtures.uuid(9))  // words 11–14
      model.mutateSlices { $0.append(slice) }
      model.selectClip(slice.id)

      // Word 13 is nearer the end boundary, so the end pulls to word 13's end edge.
      model.pullClipBoundary(slice.id, toWordID: 13)
      expectNoDifference(model.slices[id: slice.id]?.endSample, 235_714)
      expectNoDifference(model.slices[id: slice.id]?.wordIDs, [11, 12, 13])
    }
  }

  // MARK: - §7 model fixes

  @Test func approvingAnEditedSuggestionCarriesTheDraftIntoTheMintedSlice() async {
    let fingerprint = "fp-approve-edited"
    let plan = Fixtures.editPlan()
    var suggestion = Fixtures.cutSuggestion(id: Fixtures.uuid(1), wordIDs: [11, 12, 13, 14])
    suggestion.startSample = 195_098
    suggestion.endSample = 243_653
    suggestion.provenance = CutSuggestion.Provenance(
      model: "m", promptVersion: "v", productSpecVersion: "v",
      transcriptHash: plan.transcriptHash, sourceFingerprint: fingerprint, diarizationHash: nil)

    await withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState(
        cutSuggestions: [suggestion])
      let model = editor(plan, fingerprint: fingerprint)
      model.selectClip(suggestion.id)

      // Move the start one word later (live draft only — no slice yet), then approve.
      model.moveCurrentClipBoundary(.startLater)
      await model.approveCurrentClip()

      // The minted slice carries the edited start (208_328), not the suggestion's original.
      expectNoDifference(state.cutSuggestions[id: suggestion.id]?.status, .accepted)
      expectNoDifference(model.slices[id: suggestion.id]?.startSample, 208_328)
      expectNoDifference(model.slices[id: suggestion.id]?.wordIDs, [12, 13, 14])
    }
  }

  @Test func approvingARejectedManualClipUnRejectsIt() async {
    let fingerprint = "fp-unreject"
    let plan = Fixtures.editPlan()

    await withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let model = editor(plan, fingerprint: fingerprint)
      let slice = wordSlice(id: Fixtures.uuid(9))
      model.mutateSlices { $0.append(slice) }
      model.selectClip(slice.id)

      await model.rejectCurrentClip()
      expectNoDifference(model.currentClip?.state, .rejected)
      #expect(state.rejectedManualSliceIDs.contains(slice.id))

      await model.approveCurrentClip()
      expectNoDifference(model.currentClip?.state, .approved)
      #expect(state.rejectedManualSliceIDs.isEmpty)
    }
  }

  @Test func nextSliceNumberSeedsPastTheHighestExistingSliceName() {
    let fingerprint = "fp-seed"
    let plan = Fixtures.editPlan()
    let hydrated = Slice(
      id: Fixtures.uuid(5), name: "Slice 5", startSample: 195_098, endSample: 243_653,
      wordIDs: [11, 12, 13, 14], snippet: "hi", warnings: [])

    withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState(slices: [hydrated])
      let model = editor(plan, fingerprint: fingerprint)

      // A fresh slice is named past the highest existing "Slice N", not `count + 1`.
      model.transcript.selectWords(anchorID: 16, focusID: 18)
      model.addSliceTapped()

      expectNoDifference(model.slices.map(\.name), ["Slice 5", "Slice 6"])
    }
  }

  // MARK: - Block render data

  @Test func visibleBlocksAndFooterTrackTheCurrentClip() {
    let fingerprint = "fp-blocks"
    let plan = Fixtures.editPlan()

    withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let model = editor(plan, fingerprint: fingerprint)
      let slice = wordSlice(id: Fixtures.uuid(9))  // words 11–14
      model.mutateSlices { $0.append(slice) }
      model.selectClip(slice.id)

      expectNoDifference(model.visibleClipBlocks.map(\.id), [slice.id])
      expectNoDifference(model.visibleClipBlocks.map(\.isCurrent), [true])
      expectNoDifference(model.visibleClipBlocks.map(\.wordIDs), [[11, 12, 13, 14]])

      let footer = model.currentClipFooter
      expectNoDifference(footer?.state, .approved)
      expectNoDifference(footer?.wordCountLabel, "4 words")
      expectNoDifference(footer?.title, "Manual")
    }
  }
}
