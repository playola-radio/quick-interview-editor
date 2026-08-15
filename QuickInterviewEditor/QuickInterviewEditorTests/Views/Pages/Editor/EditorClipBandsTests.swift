import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
import IdentifiedCollections
@_spi(Internals) import Sharing
import Testing

@testable import QuickInterviewEditor

@MainActor
struct EditorClipBandsTests {

  private func slice(_ id: UUID, wordIDs: [Word.ID]) -> Slice {
    Slice(
      id: id, name: "A story", startSample: 0, endSample: 100,
      wordIDs: wordIDs, snippet: "a story", warnings: [])
  }

  /// Builds an editor whose sidecar is pre-seeded with the given suggestions, backed by an
  /// isolated in-memory file system (no disk, no network).
  private func withEditor(
    suggestions: [CutSuggestion], _ body: (EditorModel) -> Void
  ) {
    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
    } operation: {
      let fingerprint = "fp-clip-bands"
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState(
        cutSuggestions: IdentifiedArray(uniqueElements: suggestions))
      let model = EditorModel(
        sourceURL: URL(fileURLWithPath: "/clip.m4a"),
        canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: Fixtures.editPlan(),
        sourceFingerprint: fingerprint)
      body(model)
    }
  }

  @Test func noSlicesOrSuggestionsProducesNoBands() {
    withEditor(suggestions: []) { model in
      expectNoDifference(model.clipBands, [])
    }
  }

  @Test func slicesBecomeApprovedBands() {
    withEditor(suggestions: []) { model in
      model.slices = [slice(Fixtures.uuid(1), wordIDs: [10, 11, 12])]
      expectNoDifference(
        model.clipBands,
        [TranscriptClipBand(id: Fixtures.uuid(1), wordIDs: [10, 11, 12], kind: .approved)])
    }
  }

  @Test func onlyPendingSuggestionsBecomeAmberBands() {
    let pending = Fixtures.cutSuggestion(id: Fixtures.uuid(1), wordIDs: [1, 2], status: .pending)
    let accepted = Fixtures.cutSuggestion(id: Fixtures.uuid(2), wordIDs: [3, 4], status: .accepted)
    let rejected = Fixtures.cutSuggestion(id: Fixtures.uuid(3), wordIDs: [5, 6], status: .rejected)
    withEditor(suggestions: [pending, accepted, rejected]) { model in
      // Accepted and rejected suggestions are not drawn as amber — only the pending one.
      expectNoDifference(
        model.clipBands,
        [TranscriptClipBand(id: Fixtures.uuid(1), wordIDs: [1, 2], kind: .suggested)])
    }
  }

  @Test func approvedComesBeforeSuggested() {
    let pending = Fixtures.cutSuggestion(id: Fixtures.uuid(9), wordIDs: [7, 8], status: .pending)
    withEditor(suggestions: [pending]) { model in
      model.slices = [slice(Fixtures.uuid(1), wordIDs: [1, 2])]
      expectNoDifference(
        model.clipBands,
        [
          TranscriptClipBand(id: Fixtures.uuid(1), wordIDs: [1, 2], kind: .approved),
          TranscriptClipBand(id: Fixtures.uuid(9), wordIDs: [7, 8], kind: .suggested),
        ])
    }
  }

  /// Green wins: a pending suggestion is drawn only over the words no slice already claims.
  @Test func sliceClaimsWinOverOverlappingSuggestion() {
    let pending = Fixtures.cutSuggestion(
      id: Fixtures.uuid(9), wordIDs: [2, 3, 4], status: .pending)
    withEditor(suggestions: [pending]) { model in
      model.slices = [slice(Fixtures.uuid(1), wordIDs: [1, 2, 3])]
      expectNoDifference(
        model.clipBands,
        [
          TranscriptClipBand(id: Fixtures.uuid(1), wordIDs: [1, 2, 3], kind: .approved),
          // words 2 and 3 are claimed green, so amber keeps only word 4.
          TranscriptClipBand(id: Fixtures.uuid(9), wordIDs: [4], kind: .suggested),
        ])
    }
  }

  @Test func suggestionFullyCoveredBySlicesProducesNoBand() {
    let pending = Fixtures.cutSuggestion(id: Fixtures.uuid(9), wordIDs: [1, 2], status: .pending)
    withEditor(suggestions: [pending]) { model in
      model.slices = [slice(Fixtures.uuid(1), wordIDs: [1, 2, 3])]
      expectNoDifference(
        model.clipBands,
        [TranscriptClipBand(id: Fixtures.uuid(1), wordIDs: [1, 2, 3], kind: .approved)])
    }
  }
}
