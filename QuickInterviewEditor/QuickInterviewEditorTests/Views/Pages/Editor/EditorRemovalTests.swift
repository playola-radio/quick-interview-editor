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

  // MARK: - validatedRemovals

  @Test func validatedRemovalsDropsOutOfBoundsRemoval() {
    let duration = Fixtures.editPlan().source.durationSamples
    let raw: IdentifiedArrayOf<TimelineRemoval> = [
      TimelineRemoval(
        id: Fixtures.uuid(1), removedRange: (duration - 10)..<(duration + 100),
        crossfade: Crossfade(lengthSamples: 48, curve: .equalPower))
    ]
    let validated = EditorModel.validatedRemovals(raw, sourceDurationSamples: duration)
    expectNoDifference(validated, [])
  }

  @Test func validatedRemovalsReducesOverlappingPairToNonOverlappingSubset() {
    let duration = Fixtures.editPlan().source.durationSamples
    let first = TimelineRemoval(
      id: Fixtures.uuid(1), removedRange: 100..<300,
      crossfade: Crossfade(lengthSamples: 48, curve: .equalPower))
    let overlapping = TimelineRemoval(
      id: Fixtures.uuid(2), removedRange: 200..<400,
      crossfade: Crossfade(lengthSamples: 48, curve: .equalPower))
    let validated = EditorModel.validatedRemovals(
      [first, overlapping], sourceDurationSamples: duration)
    expectNoDifference(validated, [first])
  }

  @Test func validatedRemovalsDropsEmptyRange() {
    let duration = Fixtures.editPlan().source.durationSamples
    let raw: IdentifiedArrayOf<TimelineRemoval> = [
      TimelineRemoval(
        id: Fixtures.uuid(1), removedRange: 500..<500,
        crossfade: Crossfade(lengthSamples: 48, curve: .equalPower))
    ]
    let validated = EditorModel.validatedRemovals(raw, sourceDurationSamples: duration)
    expectNoDifference(validated, [])
  }

  @Test func validatedRemovalsLeavesValidSetUnchanged() {
    let duration = Fixtures.editPlan().source.durationSamples
    let first = TimelineRemoval(
      id: Fixtures.uuid(1), removedRange: 300..<400,
      crossfade: Crossfade(lengthSamples: 48, curve: .equalPower))
    let second = TimelineRemoval(
      id: Fixtures.uuid(2), removedRange: 1000..<2000,
      crossfade: Crossfade(lengthSamples: 48, curve: .equalPower))
    let validated = EditorModel.validatedRemovals(
      [second, first], sourceDurationSamples: duration)
    expectNoDifference(validated, [first, second])
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

  /// Regression: a sidecar written by a foreign/older/hand-edited process (or the same source
  /// re-analyzed to a shorter duration) can carry an out-of-bounds or overlapping removal.
  /// Seeding from it must not crash, and the seeded `timelineRemovals` must stay consistent with
  /// `editedTimeline` — no split-brain (strike-through/export-gate on with no waveform collapse).
  @Test func seedingFromCorruptSidecarDoesNotCrashAndStaysConsistent() throws {
    let fingerprint = "fp-seed-corrupt"
    let url = ProjectState.sidecarURL(fingerprint: fingerprint)
    let duration = Fixtures.editPlan().source.durationSamples
    let valid = TimelineRemoval(
      id: Fixtures.uuid(1), removedRange: 300..<400,
      crossfade: Crossfade(lengthSamples: 48, curve: .equalPower))
    let outOfBounds = TimelineRemoval(
      id: Fixtures.uuid(2), removedRange: (duration - 10)..<(duration + 1000),
      crossfade: Crossfade(lengthSamples: 48, curve: .equalPower))
    let overlapping = TimelineRemoval(
      id: Fixtures.uuid(3), removedRange: 350..<500,
      crossfade: Crossfade(lengthSamples: 48, curve: .equalPower))
    let seeded = ProjectState(timelineRemovals: [valid, outOfBounds, overlapping])
    let seededData = try JSONEncoder().encode(seeded)
    let fileSystem = LockIsolated<[URL: Data]>([url: seededData])
    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let model = editor(fingerprint: fingerprint)

      // Out-of-bounds dropped; overlapping loses to the earlier `valid` removal.
      expectNoDifference(model.timelineRemovals, [valid])
      // `editedTimeline` agrees with the stored removals: no split-brain.
      expectNoDifference(model.editedTimeline.removals.map(\.id), Array(model.timelineRemovals.ids))
      #expect(model.editedTimeline.isValid)
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

  /// Reverse of the export-gate race: an in-flight export is rendering the un-cut canonical
  /// audio, so adding a removal mid-export would leave the finished AIFF stale relative to
  /// what the editor now shows/persists. Both the enablement and the action must block.
  @Test func removeSelectedSectionBlockedWhileExporting() async {
    let fileSystem = LockIsolated<[URL: Data]>([:])
    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let model = editor(fingerprint: "fp-remove-during-export")
      model.transcript.selectWords(
        anchorID: model.editPlan.words[1].id, focusID: model.editPlan.words[2].id)
      model.exportPhase = .exporting(current: 1, total: 1)

      expectNoDifference(model.canRemoveSelectedSection, false)

      await model.removeSelectedSectionTapped()

      expectNoDifference(model.timelineRemovals, [])
    }
  }

  /// Sanity check alongside the export-gate test above: the same selection with an idle
  /// export phase is NOT over-blocked by the new guard.
  @Test func removeSelectedSectionAllowedWhenNotExporting() {
    let fileSystem = LockIsolated<[URL: Data]>([:])
    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let model = editor(fingerprint: "fp-remove-not-exporting")
      model.transcript.selectWords(
        anchorID: model.editPlan.words[1].id, focusID: model.editPlan.words[2].id)
      model.exportPhase = .idle

      expectNoDifference(model.canRemoveSelectedSection, true)
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

  /// Word 3's midpoint (77704 + (98916-77704)/2 = 88310) falls inside the removal below;
  /// words 1, 2, and 4's midpoints do not.
  @Test func removedWordIDsTracksMidpointMembershipAndClearsOnUndo() async {
    let fileSystem = LockIsolated<[URL: Data]>([:])
    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let model = editor(fingerprint: "fp-removed-words")
      let word3 = model.editPlan.words[2].id
      expectNoDifference(model.removedWordIDs, [])

      model.mutateDocument { doc in
        doc.timelineRemovals.append(
          TimelineRemoval(
            id: Fixtures.uuid(5), removedRange: 80_000..<100_000,
            crossfade: Crossfade(lengthSamples: 48, curve: .equalPower)))
      }
      expectNoDifference(model.removedWordIDs, [word3])

      await model.undoTapped()
      expectNoDifference(model.removedWordIDs, [])
    }
  }

  @Test func pendingRemovalGatesExportAndSurfacesNote() {
    let fileSystem = LockIsolated<[URL: Data]>([:])
    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let model = editor(fingerprint: "fp-export-gate")
      model.slices.append(
        Slice(
          id: Fixtures.uuid(20), name: "A", startSample: 0, endSample: 100, wordIDs: [],
          snippet: "x", warnings: []))
      expectNoDifference(model.canExportAll, true)
      expectNoDifference(model.canExportSlice, true)
      expectNoDifference(model.exportBlockedByRemovalsNote, nil)

      model.mutateDocument { doc in
        doc.timelineRemovals.append(
          TimelineRemoval(
            id: Fixtures.uuid(6), removedRange: 1000..<2000,
            crossfade: Crossfade(lengthSamples: 48, curve: .equalPower)))
      }

      expectNoDifference(model.canExportAll, false)
      expectNoDifference(model.canExportSlice, false)
      #expect(model.exportBlockedByRemovalsNote != nil)
    }
  }

  @Test func undoingRemovalRestoresExportGate() async {
    let fileSystem = LockIsolated<[URL: Data]>([:])
    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let model = editor(fingerprint: "fp-export-gate-undo")
      model.slices.append(
        Slice(
          id: Fixtures.uuid(21), name: "A", startSample: 0, endSample: 100, wordIDs: [],
          snippet: "x", warnings: []))
      model.mutateDocument { doc in
        doc.timelineRemovals.append(
          TimelineRemoval(
            id: Fixtures.uuid(8), removedRange: 1000..<2000,
            crossfade: Crossfade(lengthSamples: 48, curve: .equalPower)))
      }
      expectNoDifference(model.canExportAll, false)
      expectNoDifference(model.canExportSlice, false)

      await model.undoTapped()

      expectNoDifference(model.canExportAll, true)
      expectNoDifference(model.canExportSlice, true)
      expectNoDifference(model.exportBlockedByRemovalsNote, nil)
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
