import CustomDump
import Dependencies
import Foundation
@_spi(Internals) import Sharing
import Testing

@testable import QuickInterviewEditor

@MainActor
struct EditorClipCardTests {

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

  private var inMemory: FileStorage { FileStorage.inMemory(fileSystem: LockIsolated([:])) }

  // MARK: - Card view models

  @Test func clipCardsCarryStateNumberAndCurrentness() {
    let fingerprint = "fp-cards"
    let plan = Fixtures.editPlan()
    let pending = validSuggestion(
      id: Fixtures.uuid(1), plan: plan, fingerprint: fingerprint, wordIDs: [10, 11, 12],
      status: .pending, rank: 1)
    let rejected = validSuggestion(
      id: Fixtures.uuid(2), plan: plan, fingerprint: fingerprint, wordIDs: [13, 14, 15],
      status: .rejected, rank: 2)

    withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState(
        cutSuggestions: [pending, rejected])
      let model = editor(plan, fingerprint: fingerprint)
      model.selectClip(pending.id)

      let cards = model.clipCards
      expectNoDifference(cards.map(\.number), [1, 2])
      expectNoDifference(cards.map(\.state), [.suggested, .rejected])
      expectNoDifference(cards.map(\.isCurrent), [true, false])
      expectNoDifference(cards.map(\.stateLabel), ["Suggested", "Rejected"])
      expectNoDifference(cards[0].title, "A story")
      expectNoDifference(cards[0].body, sliceSnippet(for: [10, 11, 12], words: plan.words))
      let expectedDuration = sampleDurationLabel(
        pending.endSample - pending.startSample, sampleRate: plan.source.sampleRate)
      expectNoDifference(cards[0].durationLabel, expectedDuration)
    }
  }

  @Test func visibleClipCardsFilterByStateButKeepStableNumbers() {
    let fingerprint = "fp-filter"
    let plan = Fixtures.editPlan()
    let pending = validSuggestion(
      id: Fixtures.uuid(1), plan: plan, fingerprint: fingerprint, wordIDs: [10, 11], rank: 1)
    let rejected = validSuggestion(
      id: Fixtures.uuid(2), plan: plan, fingerprint: fingerprint, wordIDs: [12, 13],
      status: .rejected, rank: 2)

    withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState(
        cutSuggestions: [pending, rejected])
      let model = editor(plan, fingerprint: fingerprint)

      model.transcript.clipFilterChanged(.rejected)
      expectNoDifference(model.visibleClipCards.map(\.id), [rejected.id])
      expectNoDifference(model.visibleClipCards.map(\.number), [2])

      model.transcript.clipFilterChanged(.all)
      expectNoDifference(model.visibleClipCards.map(\.id), [pending.id, rejected.id])
    }
  }

  @Test func clipMapSegmentsPositionByAudioRange() {
    let fingerprint = "fp-rail"
    let plan = Fixtures.editPlan()
    let total = Double(plan.source.durationSamples)

    withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let model = editor(plan, fingerprint: fingerprint)
      let slice = Slice(
        id: Fixtures.uuid(9), name: "Manual", startSample: 100_000, endSample: 400_000,
        wordIDs: [10, 11], snippet: "hi", warnings: [])
      model.mutateSlices { $0.append(slice) }
      model.selectClip(slice.id)

      let segments = model.clipMapSegments
      expectNoDifference(segments.count, 1)
      expectNoDifference(segments[0].id, slice.id)
      expectNoDifference(segments[0].isCurrent, true)
      expectNoDifference(segments[0].startFraction, 100_000 / total)
      expectNoDifference(segments[0].widthFraction, 300_000 / total)
    }
  }

  @Test func clipMapSegmentClampsAVanishinglyShortRangeToAHairline() {
    let fingerprint = "fp-rail-hairline"
    let plan = Fixtures.editPlan()

    withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      let model = editor(plan, fingerprint: fingerprint)
      let slice = Slice(
        id: Fixtures.uuid(9), name: "Tiny", startSample: 1000, endSample: 1200,
        wordIDs: [10], snippet: "hi", warnings: [])
      model.mutateSlices { $0.append(slice) }

      expectNoDifference(model.clipMapSegments[0].widthFraction, 0.004)
    }
  }

  @Test func clipCountsSummaryNamesAllThreeStates() {
    let fingerprint = "fp-counts"
    let plan = Fixtures.editPlan()
    let approved = validSuggestion(
      id: Fixtures.uuid(1), plan: plan, fingerprint: fingerprint, wordIDs: [10, 11],
      status: .accepted, rank: 1)
    let pending = validSuggestion(
      id: Fixtures.uuid(2), plan: plan, fingerprint: fingerprint, wordIDs: [12, 13], rank: 2)

    withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState(
        cutSuggestions: [approved, pending])
      let model = editor(plan, fingerprint: fingerprint)

      expectNoDifference(model.clipCountsSummary, "1 approved · 1 suggested · 0 rejected")
    }
  }

  // MARK: - Id-addressed card actions

  @Test func clipCardTappedMakesItCurrent() {
    let fingerprint = "fp-tap"
    let plan = Fixtures.editPlan()
    let suggestion = validSuggestion(
      id: Fixtures.uuid(1), plan: plan, fingerprint: fingerprint, wordIDs: [10, 11, 12])

    withDependencies {
      $0.defaultFileStorage = inMemory
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState(
        cutSuggestions: [suggestion])
      let model = editor(plan, fingerprint: fingerprint)

      model.clipCardTapped(suggestion.id)

      expectNoDifference(model.currentClipID, suggestion.id)
      expectNoDifference(model.transcript.selectedWordIDSet, Set([10, 11, 12]))
    }
  }

  @Test func approveClipTappedSelectsThenApproves() async {
    let fingerprint = "fp-approve-id"
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

      await model.approveClipTapped(suggestion.id)

      expectNoDifference(model.currentClipID, suggestion.id)
      expectNoDifference(state.cutSuggestions[id: suggestion.id]?.status, .accepted)
    }
  }
}
