import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
import IdentifiedCollections
@_spi(Internals) import Sharing
import Testing

@testable import QuickInterviewEditor

@MainActor
struct EditorRemovalTests {
  private func editor(fingerprint: String) -> EditorModel {
    EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL,
      editPlan: Fixtures.editPlan(), sourceFingerprint: fingerprint)
  }

  @Test func removalWritesThroughToSidecar() {
    let fingerprint = "fp-writethrough"
    let fileSystem = LockIsolated<[URL: Data]>([:])
    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let model = editor(fingerprint: fingerprint)
      model.mutateDocument { doc in
        doc.timelineRemovals.append(
          TimelineRemoval(
            id: Fixtures.uuid(1), removedRange: 100..<200,
            crossfade: Crossfade(lengthSamples: 48, curve: .equalPower)))
      }
      @Shared(.projectState(fingerprint: fingerprint)) var persisted = ProjectState()
      expectNoDifference(persisted.timelineRemovals.count, 1)
    }
  }

  @Test func seedsTimelineRemovalsFromSidecar() throws {
    let fingerprint = "fp-seed"
    let url = ProjectState.sidecarURL(fingerprint: fingerprint)
    let seeded = ProjectState(
      timelineRemovals: [
        TimelineRemoval(
          id: Fixtures.uuid(2), removedRange: 300..<400,
          crossfade: Crossfade(lengthSamples: 48, curve: .equalPower))
      ])
    let seededData = try JSONEncoder().encode(seeded)
    let fileSystem = LockIsolated<[URL: Data]>([url: seededData])
    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let model = editor(fingerprint: fingerprint)
      expectNoDifference(model.timelineRemovals, seeded.timelineRemovals)
    }
  }

  @Test func removeSelectedSectionCreatesRemovalWithDefaultCrossfade() async {
    let fileSystem = LockIsolated<[URL: Data]>([:])
    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let model = editor(fingerprint: "fp-remove")
      model.transcript.selectWords(
        anchorID: model.editPlan.words[1].id, focusID: model.editPlan.words[2].id)
      #expect(model.canRemoveSelectedSection)

      await model.removeSelectedSectionTapped()

      expectNoDifference(model.timelineRemovals.count, 1)
      #expect(model.timelineRemovals.first?.crossfade.curve == .equalPower)
      #expect(model.transcript.hasSelection == false)
    }
  }

  @Test func canRemoveRejectsCrossSeamAndEmptySelections() {
    let fileSystem = LockIsolated<[URL: Data]>([:])
    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let model = editor(fingerprint: "fp-reject")
      model.mutateDocument { doc in
        doc.timelineRemovals.append(
          TimelineRemoval(
            id: Fixtures.uuid(9), removedRange: 500..<600,
            crossfade: Crossfade(lengthSamples: 48, curve: .equalPower)))
      }

      #expect(model.canRemove(sourceRange: 450..<550) == false)
      #expect(model.canRemove(sourceRange: 1000..<2000) == true)
      #expect(model.canRemove(sourceRange: 700..<700) == false)
    }
  }

  @Test func seamOverlaysDerivedFromTimeline() {
    let fileSystem = LockIsolated<[URL: Data]>([:])
    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let model = editor(fingerprint: "fp-seams")
      model.mutateDocument { doc in
        doc.timelineRemovals.append(
          TimelineRemoval(
            id: Fixtures.uuid(4), removedRange: 1000..<2000,
            crossfade: Crossfade(lengthSamples: 96, curve: .equalPower)))
      }
      expectNoDifference(model.seamOverlays.count, 1)
      expectNoDifference(model.seamOverlays.first?.crossfadeLength, 96)
      // EditedTimeline's editedCenter is the right kept-segment's editedStart, which already
      // nets out this seam's own crossfade overlap (see EditedTimelineTests.seamLookup):
      // 1000 (nothing removed before it) - 96 (this seam's crossfade) = 904.
      expectNoDifference(model.seamOverlays.first?.editedCenterSample, 904)
    }
  }

  /// Integration proof of the axis flip: with the lane's geometry installed, a removal must
  /// COLLAPSE the edited waveform (its edited duration shrinks by the removed span PLUS the
  /// crossfade overlap), draw a bowtie at the seam (`seamSpans` becomes non-empty), and re-place a
  /// post-removal cursor by its EDITED (leftward-shifted) position — all without the view touching
  /// any waveform math. A fixed zoom (spp 300, well under the fit ceiling) keeps `timelineChanged`
  /// from re-fitting, so the cursor's view-x moving left is purely the collapse.
  @Test func removalCollapsesEditedWaveformAndDrawsSeam() async {
    let fileSystem = LockIsolated<[URL: Data]>([:])
    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let model = editor(fingerprint: "fp-collapse")
      let duration = model.editPlan.source.durationSamples
      model.editedWaveform.viewportWidth = 1000
      model.editedWaveform.samplesPerPixel = 300  // shows edited [0, 300_000)
      model.editedWaveform.visibleStartSample = 0
      model.playheadSample = 220_000  // a source sample just past the removal
      let beforePlayheadX = model.playheadX  // identity axis: 220_000 / 300 = 733.3…

      // Remove [10_000, 210_000) (200_000 samples) with a 96-sample crossfade.
      model.mutateDocument { doc in
        doc.timelineRemovals.append(
          TimelineRemoval(
            id: Fixtures.uuid(7), removedRange: 10_000..<210_000,
            crossfade: Crossfade(lengthSamples: 96, curve: .equalPower)))
      }

      // Edited duration = source − removed − crossfade overlap.
      expectNoDifference(
        model.editedWaveform.editedDurationSamples, duration - 200_000 - 96)
      // A bowtie is now drawn at the single seam.
      expectNoDifference(model.seamSpans.count, 1)
      // Source 220_000 now sits at edited 220_000 − 200_000 − 96 = 19_904 → x 66.3…: the cursor
      // reads the EDITED axis and moved left with the collapse.
      #expect(beforePlayheadX != nil)
      #expect(model.playheadX != nil)
      #expect(model.playheadX! < beforePlayheadX!)
    }
  }
}
