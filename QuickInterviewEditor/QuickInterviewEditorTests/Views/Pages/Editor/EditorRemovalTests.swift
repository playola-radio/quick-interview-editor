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
}
