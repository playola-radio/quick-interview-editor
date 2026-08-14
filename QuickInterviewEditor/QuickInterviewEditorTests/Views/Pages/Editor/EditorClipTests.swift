import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
@_spi(Internals) import Sharing
import Testing

@testable import QuickInterviewEditor

@MainActor
struct EditorClipTests {

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

  // MARK: - Derived clip list

  @Test func clipsMapSuggestionStatusesInRankedOrder() {
    let fingerprint = "fp-map"
    let plan = Fixtures.editPlan()
    let pending = validSuggestion(
      id: Fixtures.uuid(1), plan: plan, fingerprint: fingerprint, wordIDs: [10, 11, 12],
      status: .pending, rank: 1)
    let accepted = validSuggestion(
      id: Fixtures.uuid(2), plan: plan, fingerprint: fingerprint, wordIDs: [13, 14, 15],
      status: .accepted, rank: 2)
    let rejected = validSuggestion(
      id: Fixtures.uuid(3), plan: plan, fingerprint: fingerprint, wordIDs: [16, 17, 18],
      status: .rejected, rank: 3)

    withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState(
        cutSuggestions: [rejected, accepted, pending])
      let model = editor(plan, fingerprint: fingerprint)

      expectNoDifference(model.clips.map(\.id), [pending.id, accepted.id, rejected.id])
      expectNoDifference(model.clips.map(\.state), [.suggested, .approved, .rejected])
      expectNoDifference(model.clips.map(\.order), [0, 1, 2])
      expectNoDifference(
        model.clips.map(\.source),
        [
          .suggestion(pending.id), .suggestion(accepted.id), .suggestion(rejected.id),
        ])
    }
  }

  @Test func acceptedSuggestionWithMatchingSliceDedupesAndPrefersSlice() {
    let fingerprint = "fp-dedupe"
    let plan = Fixtures.editPlan()
    let accepted = validSuggestion(
      id: Fixtures.uuid(1), plan: plan, fingerprint: fingerprint, wordIDs: [10, 11, 12],
      status: .accepted, title: "Suggestion title")

    withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState(
        cutSuggestions: [accepted])
      let model = editor(plan, fingerprint: fingerprint)
      let slice = Slice(
        id: accepted.id, name: "Slice name", startSample: 1000, endSample: 2000,
        wordIDs: [10, 11], snippet: "sliced", warnings: [])
      model.acceptCutSuggestionSlice(slice)

      expectNoDifference(model.clips.count, 1)
      let clip = model.clips[0]
      expectNoDifference(clip.source, .suggestion(accepted.id))
      expectNoDifference(clip.state, .approved)
      expectNoDifference(clip.title, "Slice name")
      expectNoDifference(clip.range, 1000..<2000)
      expectNoDifference(clip.wordIDs, [10, 11])
      expectNoDifference(clip.snippet, "sliced")
    }
  }

  @Test func manualSliceAppearsApprovedAndRejectsWhenMarked() {
    let fingerprint = "fp-manual"
    withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let model = editor(fingerprint: fingerprint)
      let slice = manualSlice(id: Fixtures.uuid(9))
      model.mutateSlices { $0.append(slice) }

      expectNoDifference(model.clips.map(\.state), [.approved])
      expectNoDifference(model.clips.map(\.source), [.manualSlice(slice.id)])

      model.rejectedManualSliceIDs.insert(slice.id)
      expectNoDifference(model.clips.map(\.state), [.rejected])
    }
  }

  // MARK: - Selection

  @Test func selectClipSelectsWordsAndLeavesActiveSliceUnchanged() {
    let fingerprint = "fp-select"
    let plan = Fixtures.editPlan()
    let suggestion = validSuggestion(
      id: Fixtures.uuid(1), plan: plan, fingerprint: fingerprint, wordIDs: [10, 11, 12])

    withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState(
        cutSuggestions: [suggestion])
      let model = editor(plan, fingerprint: fingerprint)

      model.selectClip(suggestion.id)

      expectNoDifference(model.currentClipID, suggestion.id)
      expectNoDifference(model.transcript.selectedWordIDSet, Set([10, 11, 12]))
      #expect(model.activeSliceID == nil)
    }
  }

  @Test func selectClipWithUnknownIDIsANoOp() {
    let fingerprint = "fp-select-unknown"
    withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let model = editor(fingerprint: fingerprint)

      model.selectClip(Fixtures.uuid(42))

      #expect(model.currentClipID == nil)
    }
  }

  // MARK: - Navigation

  @Test func nextAndPreviousClipWrapOverClips() {
    let fingerprint = "fp-nav"
    let plan = Fixtures.editPlan()
    let first = validSuggestion(
      id: Fixtures.uuid(1), plan: plan, fingerprint: fingerprint, wordIDs: [10, 11], rank: 1)
    let second = validSuggestion(
      id: Fixtures.uuid(2), plan: plan, fingerprint: fingerprint, wordIDs: [12, 13], rank: 2)

    withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState(
        cutSuggestions: [first, second])
      let model = editor(plan, fingerprint: fingerprint)

      model.nextClip()
      expectNoDifference(model.currentClipID, first.id)
      model.nextClip()
      expectNoDifference(model.currentClipID, second.id)
      model.nextClip()
      expectNoDifference(model.currentClipID, first.id)
      model.previousClip()
      expectNoDifference(model.currentClipID, second.id)
    }
  }

  @Test func navigationIsANoOpWhenThereAreNoClips() {
    let fingerprint = "fp-nav-empty"
    withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let model = editor(fingerprint: fingerprint)

      model.nextClip()
      #expect(model.currentClipID == nil)
      model.previousClip()
      #expect(model.currentClipID == nil)
    }
  }

  // MARK: - Approve

  @Test func approveCurrentClipAcceptsASuggestedClip() async {
    let fingerprint = "fp-approve"
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

      expectNoDifference(state.cutSuggestions[id: suggestion.id]?.status, .accepted)
      #expect(model.slices[id: suggestion.id] != nil)
    }
  }

  @Test func approveCurrentClipTogglesAnApprovedClipBackToPendingAndRemovesItsSlice() async {
    let fingerprint = "fp-approve-toggle"
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

      await model.approveCurrentClip()

      expectNoDifference(state.cutSuggestions[id: suggestion.id]?.status, .pending)
      #expect(model.slices[id: suggestion.id] == nil)
    }
  }

  @Test func approveCurrentClipOnAStaleSuggestionSurfacesAMessageAndAppendsNoSlice() async {
    let fingerprint = "fp-approve-stale"
    let plan = Fixtures.editPlan()
    var suggestion = Fixtures.cutSuggestion(id: Fixtures.uuid(1), wordIDs: [10, 11, 12])
    suggestion.provenance = CutSuggestion.Provenance(
      model: "m", promptVersion: "v", productSpecVersion: "v",
      transcriptHash: "different-hash", sourceFingerprint: fingerprint, diarizationHash: nil)

    await withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState(
        cutSuggestions: [suggestion])
      let model = editor(plan, fingerprint: fingerprint)
      model.selectClip(suggestion.id)

      await model.approveCurrentClip()

      expectNoDifference(state.cutSuggestions[id: suggestion.id]?.status, .pending)
      #expect(model.slices[id: suggestion.id] == nil)
      expectNoDifference(
        model.cutSuggestions.actionMessage, cutSuggestionStaleMessage(.transcriptChanged))
    }
  }

  @Test func approveCurrentClipOnAManualClipIsANoOp() async {
    let fingerprint = "fp-approve-manual"
    await withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let model = editor(fingerprint: fingerprint)
      let slice = manualSlice(id: Fixtures.uuid(9))
      model.mutateSlices { $0.append(slice) }
      model.selectClip(slice.id)

      await model.approveCurrentClip()

      expectNoDifference(model.clips.map(\.state), [.approved])
      #expect(model.slices[id: slice.id] != nil)
    }
  }

  // MARK: - Reject

  @Test func rejectCurrentClipRejectsASuggestionAndRemovesItsAcceptedSlice() async {
    let fingerprint = "fp-reject"
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

      expectNoDifference(state.cutSuggestions[id: suggestion.id]?.status, .rejected)
      #expect(model.slices[id: suggestion.id] == nil)
    }
  }

  @Test func rejectCurrentClipOnAManualClipMarksItRejectedWithoutDeletingTheSlice() async {
    let fingerprint = "fp-reject-manual"
    await withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let model = editor(fingerprint: fingerprint)
      let slice = manualSlice(id: Fixtures.uuid(9))
      model.mutateSlices { $0.append(slice) }
      model.selectClip(slice.id)

      await model.rejectCurrentClip()

      #expect(model.rejectedManualSliceIDs.contains(slice.id))
      #expect(model.slices[id: slice.id] != nil)
      expectNoDifference(model.clips.map(\.state), [.rejected])
    }
  }

  // MARK: - Reconciliation on removal

  @Test func approveTogglingOffAnActiveClipReconcilesTheFineTuneSession() async {
    let fingerprint = "fp-toggle-reconcile"
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
      model.focusCurrentClip()
      #expect(model.activeSliceID == suggestion.id)

      await model.approveCurrentClip()

      #expect(model.activeSliceID == nil)
      #expect(model.fineTune.target == nil)
    }
  }

  @Test func focusCurrentClipRespectsAnUnsavedEditOnAnotherTarget() async {
    let fingerprint = "fp-focus-guard"
    let plan = Fixtures.editPlan()
    let accepted = validSuggestion(
      id: Fixtures.uuid(1), plan: plan, fingerprint: fingerprint,
      wordIDs: [10, 11, 12, 13, 14, 15, 16], rank: 1)
    var pending = validSuggestion(
      id: Fixtures.uuid(2), plan: plan, fingerprint: fingerprint, wordIDs: [17, 18], rank: 2)
    pending.startSample = 500
    pending.endSample = 1500

    await withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState(
        cutSuggestions: [accepted, pending])
      let model = editor(plan, fingerprint: fingerprint)
      model.selectClip(accepted.id)
      await model.approveCurrentClip()
      model.focusCurrentClip()
      model.fineTune.nudgeCutOut(byMs: 10)
      #expect(model.fineTune.hasUnsavedChange)

      model.selectClip(pending.id)
      model.focusCurrentClip()

      #expect(model.activeSliceID == accepted.id)
      #expect(model.fineTune.hasUnsavedChange)
    }
  }

  // MARK: - Export exclusion

  @Test func exportExcludesRejectedManualSlices() {
    let fingerprint = "fp-export"
    withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let model = editor(fingerprint: fingerprint)
      let kept = manualSlice(id: Fixtures.uuid(1), name: "Kept")
      let rejected = manualSlice(id: Fixtures.uuid(2), name: "Rejected", start: 3000, end: 4000)
      model.mutateSlices {
        $0.append(kept)
        $0.append(rejected)
      }
      model.rejectedManualSliceIDs.insert(rejected.id)

      expectNoDifference(model.exportableSlices.map(\.id), [kept.id])
      #expect(model.canExportAll)
    }
  }

  @Test func canExportAllIsFalseWhenEveryManualSliceIsRejected() {
    let fingerprint = "fp-export-none"
    withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let model = editor(fingerprint: fingerprint)
      let slice = manualSlice(id: Fixtures.uuid(1))
      model.mutateSlices { $0.append(slice) }
      model.rejectedManualSliceIDs.insert(slice.id)

      #expect(!model.canExportAll)
      #expect(model.exportableSlices.isEmpty)
    }
  }

  @Test func exportSliceTappedIgnoresARejectedManualSlice() {
    let fingerprint = "fp-export-single"
    withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let model = editor(fingerprint: fingerprint)
      let slice = manualSlice(id: Fixtures.uuid(1))
      model.mutateSlices { $0.append(slice) }
      model.rejectedManualSliceIDs.insert(slice.id)

      model.exportSliceTapped(slice.id)

      expectNoDifference(model.exportPhase, .idle)
    }
  }

  // MARK: - Play + Space routing

  @Test func playCurrentClipPlaysTheClipRange() async {
    let fingerprint = "fp-play"
    let recorded = LockIsolated<Range<Int>?>(nil)

    await withDependencies {
      $0.defaultFileStorage = inMemory
      $0.audioPlayer.play = { _, range, _, _ in
        recorded.setValue(range)
        return .finished
      }
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let model = editor(fingerprint: fingerprint)
      let slice = manualSlice(id: Fixtures.uuid(9))
      model.mutateSlices { $0.append(slice) }
      model.selectClip(slice.id)

      await model.playCurrentClip()

      expectNoDifference(recorded.value, 1000..<2000)
    }
  }

  @Test func spaceRoutesToClipPlaybackWhenAClipIsCurrent() async {
    let fingerprint = "fp-space-clip"
    let recorded = LockIsolated<Range<Int>?>(nil)

    await withDependencies {
      $0.defaultFileStorage = inMemory
      $0.audioPlayer.play = { _, range, _, _ in
        recorded.setValue(range)
        return .finished
      }
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let model = editor(fingerprint: fingerprint)
      let slice = manualSlice(id: Fixtures.uuid(9))
      model.mutateSlices { $0.append(slice) }
      model.selectClip(slice.id)

      await model.auditionKeyPressed(.space)

      expectNoDifference(recorded.value, 1000..<2000)
    }
  }

  @Test func spaceRoutesToTheTransportToggleWhenNoClipIsCurrent() async {
    let fingerprint = "fp-space-transport"
    let recorded = LockIsolated<Range<Int>?>(nil)

    await withDependencies {
      $0.defaultFileStorage = inMemory
      $0.audioPlayer.play = { _, range, _, _ in
        recorded.setValue(range)
        return .finished
      }
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let model = editor(fingerprint: fingerprint)
      model.playheadSample = 1000

      await model.auditionKeyPressed(.space)

      #expect(model.currentClipID == nil)
      expectNoDifference(recorded.value?.lowerBound, 1000)
    }
  }

  @Test func spaceStopsPlaybackEvenWhenAClipIsCurrent() async {
    let fingerprint = "fp-space-stop"
    let plan = Fixtures.editPlan()
    let suggestion = validSuggestion(
      id: Fixtures.uuid(1), plan: plan, fingerprint: fingerprint, wordIDs: [10, 11, 12])
    let played = LockIsolated(false)

    await withDependencies {
      $0.defaultFileStorage = inMemory
      $0.audioPlayer.play = { _, _, _, _ in
        played.setValue(true)
        return .finished
      }
      $0.audioPlayer.stop = { _ in }
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState(
        cutSuggestions: [suggestion])
      let model = editor(plan, fingerprint: fingerprint)
      model.selectClip(suggestion.id)
      model.transportPhase = .playing(PlaybackSessionID())

      await model.auditionKeyPressed(.space)

      #expect(!played.value)
      expectNoDifference(model.transportPhase, .stopped)
    }
  }
}
