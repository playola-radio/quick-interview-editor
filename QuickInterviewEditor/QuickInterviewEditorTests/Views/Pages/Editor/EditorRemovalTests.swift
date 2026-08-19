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
}
