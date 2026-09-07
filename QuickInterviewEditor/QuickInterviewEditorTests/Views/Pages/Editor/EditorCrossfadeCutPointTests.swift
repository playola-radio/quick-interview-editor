import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
import IdentifiedCollections
@_spi(Internals) import Sharing
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct EditorCrossfadeCutPointTests {

  // MARK: - Draft value type

  @Test func draftIsEquatableByValue() {
    let a = CrossfadeCutPointDraft(
      id: Fixtures.uuid(1), edge: .lower, committedRange: 48_000..<96_000,
      draftedRange: 46_000..<96_000, frozenCrossfadeLength: 600,
      dragStartEditedSample: 20_000, frozenVisibleStart: 0, frozenSamplesPerPixel: 200)
    var b = a
    b.draftedRange = 46_000..<96_000
    expectNoDifference(a, b)
    b.edge = .upper
    #expect(a != b)
  }

  // MARK: - Helpers

  private func editor(fingerprint: String) -> EditorModel {
    EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL,
      editPlan: Fixtures.editPlan(), sourceFingerprint: fingerprint)
  }

  @discardableResult
  private func addRemoval(
    _ model: EditorModel, id: UUID = Fixtures.uuid(1),
    range: Range<Int> = 48_000..<96_000, length: Int = 600
  ) -> UUID {
    model.mutateDocument { doc in
      doc.timelineRemovals.append(
        TimelineRemoval(
          id: id, removedRange: range,
          crossfade: Crossfade(lengthSamples: length, curve: .equalPower)))
    }
    return id
  }

  private func primeGeometry(_ model: EditorModel) {
    model.editedWaveform.viewportWidth = 1000
    model.editedWaveform.samplesPerPixel = 200
    model.editedWaveform.visibleStartSample = 0
  }

  private func withStorage(_ body: () -> Void) {
    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
    } operation: {
      body()
    }
  }

  // MARK: - Commit funnel

  @Test func updateRemovalRangeMovesBoundAndFreezesLengthPreservingID() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-commit")
      let id = addRemoval(model, range: 48_000..<96_000, length: 600)

      model.updateRemovalRange(id: id, removedRange: 46_000..<96_000, freezingCrossfadeLength: 600)

      expectNoDifference(model.timelineRemovals[id: id]?.removedRange, 46_000..<96_000)
      expectNoDifference(model.timelineRemovals[id: id]?.crossfade.lengthSamples, 600)
      #expect(model.timelineRemovals[id: id]?.id == id)  // identity preserved
    }
  }

  @Test func updateRemovalRangeIsBlockedWhileExporting() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-export-guard")
      let id = addRemoval(model, range: 48_000..<96_000, length: 600)
      // isExporting is computed off exportPhase.
      model.exportPhase = .exporting(current: 0, total: 1)

      model.updateRemovalRange(id: id, removedRange: 46_000..<96_000, freezingCrossfadeLength: 600)

      expectNoDifference(model.timelineRemovals[id: id]?.removedRange, 48_000..<96_000)
    }
  }

  // MARK: - Clamp

  @Test func clampLowerCannotCrossTheRightCut() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-clamp-lower-cross")
      let id = addRemoval(model, range: 48_000..<96_000, length: 600)

      // Propose cL past cR: pinned to cR - 1. `200_000..<200_000` (not `200_000..<96_000`) because Swift's
      // `Range` enforces lowerBound <= upperBound even via `uncheckedBounds`; the moving-lower-edge branch
      // of clampedRemovalRange only reads `proposed.lowerBound`, so the paired upperBound is irrelevant here.
      let clamped = model.clampedRemovalRange(
        id: id, proposed: 200_000..<200_000, frozenLength: 600)

      expectNoDifference(clamped, 95_999..<96_000)
    }
  }

  @Test func clampUpperRespectsNeighborRemovalAndItsFade() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-clamp-upper-neighbor")
      let id = addRemoval(model, id: Fixtures.uuid(1), range: 48_000..<96_000, length: 600)
      // Neighbor removal to the right, fade 400: cR upper bound = 150_000 - 600 - 400 = 149_000.
      addRemoval(model, id: Fixtures.uuid(2), range: 150_000..<200_000, length: 400)

      let clamped = model.clampedRemovalRange(
        id: id, proposed: 48_000..<300_000, frozenLength: 600)

      expectNoDifference(clamped, 48_000..<149_000)
    }
  }
}
