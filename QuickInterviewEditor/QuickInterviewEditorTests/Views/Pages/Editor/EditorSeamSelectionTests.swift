import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
import IdentifiedCollections
@_spi(Internals) import Sharing
import Testing

@testable import QuickInterviewEditor

/// Minimal `playEdited` gate: suspends free-play until `stop` releases it, and reports when a play
/// started. Mirrors `EditorTransportTests`' `TransportGate` (kept private there).
private final class SeamPlayGate: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [CheckedContinuation<Void, Never>] = []
  private let startedContinuation: AsyncStream<Void>.Continuation
  let started: AsyncStream<Void>
  init() {
    var continuation: AsyncStream<Void>.Continuation!
    started = AsyncStream { continuation = $0 }
    startedContinuation = continuation
  }
  func play() async -> PlaybackEnd {
    startedContinuation.yield(())
    await withCheckedContinuation { cont in
      lock.lock()
      continuations.append(cont)
      lock.unlock()
    }
    return .finished
  }
  func release() {
    lock.lock()
    let conts = continuations
    continuations = []
    lock.unlock()
    for cont in conts { cont.resume() }
  }
  func awaitStarted() async {
    var it = started.makeAsyncIterator()
    _ = await it.next()
  }
}

@MainActor
struct EditorSeamSelectionTests {
  private func editor(fingerprint: String) -> EditorModel {
    EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL,
      editPlan: Fixtures.editPlan(), sourceFingerprint: fingerprint)
  }

  @discardableResult
  private func addRemoval(
    _ model: EditorModel, id: UUID = Fixtures.uuid(1),
    range: Range<Int> = 100_000..<300_000, length: Int = 96
  ) -> UUID {
    model.mutateDocument { doc in
      doc.timelineRemovals.append(
        TimelineRemoval(
          id: id, removedRange: range,
          crossfade: Crossfade(lengthSamples: length, curve: .equalPower)))
    }
    return id
  }

  /// Installs a loaded source pyramid + matching geometry so `editedWaveform.hasUsableGeometry` is
  /// true (its gate requires a loaded source waveform), mirroring `EditorAreaSelectTests.geometry`.
  private func primeGeometry(
    _ model: EditorModel, samplesPerPixel: Double = 300, start: Int = 0,
    viewportWidth: CGFloat = 1000
  ) {
    let duration = model.editPlan.source.durationSamples
    model.waveform.totalSamples = duration
    model.waveform.waveform = Waveform.pyramid(
      baseMins: [0], baseMaxs: [0], sampleRate: model.editPlan.source.sampleRate,
      totalSamples: duration, baseBucketSize: 4)
    model.waveform.viewportWidth = viewportWidth
    model.waveform.samplesPerPixel = samplesPerPixel
    model.waveform.visibleStartSample = start
    model.editedWaveform.viewportWidth = viewportWidth
    model.editedWaveform.samplesPerPixel = samplesPerPixel
    model.editedWaveform.visibleStartSample = start
  }

  /// Runs `body` with an in-memory sidecar so `mutateDocument`'s persistence has somewhere to write.
  private func withStorage(
    _ fileSystem: LockIsolated<[URL: Data]> = LockIsolated([:]), _ body: () -> Void
  ) {
    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      body()
    }
  }

  // MARK: - Selection state + mutual exclusion

  @Test func seamClickedSelectsSeamAndClearsRangeSelection() {
    withStorage {
      let model = editor(fingerprint: "fp-seam-select")
      let id = addRemoval(model)
      model.selectSourceRange(400_000..<500_000, snapPlayhead: false)
      #expect(model.audioSelection != nil)

      model.seamClicked(id)

      expectNoDifference(model.selectedSeamID, id)
      expectNoDifference(model.audioSelection, nil)
    }
  }

  @Test func selectingRangeClearsSeamSelection() {
    withStorage {
      let model = editor(fingerprint: "fp-range-clears-seam")
      let id = addRemoval(model)
      model.selectSeam(id)
      #expect(model.selectedSeamID == id)

      model.selectSourceRange(400_000..<500_000, snapPlayhead: false)

      expectNoDifference(model.selectedSeamID, nil)
      #expect(model.audioSelection != nil)
    }
  }

  @Test func marqueeBeginClearsSeamSelection() {
    withStorage {
      let model = editor(fingerprint: "fp-marquee-clears-seam")
      primeGeometry(model)
      let id = addRemoval(model)
      model.selectSeam(id)
      #expect(model.selectedSeamID == id)

      model.waveformAreaSelectBegan(atX: 500, extending: false)

      expectNoDifference(model.selectedSeamID, nil)
    }
  }

  @Test func selectSeamIgnoresUnknownID() {
    withStorage {
      let model = editor(fingerprint: "fp-seam-unknown")
      addRemoval(model)
      model.selectSeam(Fixtures.uuid(999))
      expectNoDifference(model.selectedSeamID, nil)
    }
  }

  @Test func deselectSeamClearsSelection() {
    withStorage {
      let model = editor(fingerprint: "fp-seam-deselect")
      let id = addRemoval(model)
      model.selectSeam(id)
      model.deselectSeam()
      expectNoDifference(model.selectedSeamID, nil)
    }
  }

  @Test func selectionSummaryReportsCrossfadeWhenSeamSelected() {
    withStorage {
      let model = editor(fingerprint: "fp-seam-summary")
      let id = addRemoval(model)
      model.selectSeam(id)
      expectNoDifference(model.selectionSummary, model.crossfadeSelectedSummary)
    }
  }

  // MARK: - Stale-selection reconciliation

  @Test func undoingTheRemovalClearsStaleSeamSelection() async {
    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
    } operation: {
      let model = editor(fingerprint: "fp-seam-undo")
      let id = addRemoval(model)
      model.selectSeam(id)
      #expect(model.selectedSeamID == id)

      await model.undoTapped()

      expectNoDifference(model.timelineRemovals.count, 0)
      expectNoDifference(model.selectedSeamID, nil)
    }
  }

  // MARK: - Restore

  @Test func restoreRemovalDropsRemovalUndoably() {
    withStorage {
      let model = editor(fingerprint: "fp-restore-undoable")
      let id = addRemoval(model)
      expectNoDifference(model.timelineRemovals.count, 1)

      model.restoreRemoval(id: id)

      expectNoDifference(model.timelineRemovals.count, 0)
      #expect(model.canUndo)
    }
  }

  @Test func restoreRemovalTappedRestoresSelectedSeamAndClearsSelection() {
    withStorage {
      let model = editor(fingerprint: "fp-restore-tapped")
      let id = addRemoval(model)
      model.selectSeam(id)

      model.restoreRemovalTapped()

      expectNoDifference(model.timelineRemovals.count, 0)
      expectNoDifference(model.selectedSeamID, nil)
    }
  }

  @Test func restoreRemovalIgnoresUnknownID() async {
    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
    } operation: {
      let model = editor(fingerprint: "fp-restore-unknown")
      addRemoval(model)
      model.restoreRemoval(id: Fixtures.uuid(999))
      expectNoDifference(model.timelineRemovals.count, 1)
      // Restoring an unknown id must not push an undo entry: a single undo returns the ONE real
      // mutation (the setup's add) to empty.
      await model.undoTapped()
      expectNoDifference(model.timelineRemovals.count, 0)
    }
  }

  @Test func restoreRemovalPersistsSidecar() throws {
    let fingerprint = "fp-restore-persist"
    let url = ProjectState.sidecarURL(fingerprint: fingerprint)
    let fileSystem = LockIsolated<[URL: Data]>([:])
    try withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let model = editor(fingerprint: fingerprint)
      let id = addRemoval(model)
      model.restoreRemoval(id: id)
      let onDisk = try JSONDecoder().decode(ProjectState.self, from: fileSystem.value[url]!)
      expectNoDifference(onDisk.timelineRemovals.count, 0)
    }
  }

  @Test func restoreControlGatingFollowsSeamSelection() {
    withStorage {
      let model = editor(fingerprint: "fp-restore-gating")
      let id = addRemoval(model)
      #expect(!model.shouldShowRestoreControl)
      #expect(!model.canRestoreSelectedRemoval)

      model.selectSeam(id)

      #expect(model.shouldShowRestoreControl)
      #expect(model.canRestoreSelectedRemoval)
    }
  }

  // MARK: - updateCrossfade

  @Test func updateCrossfadeChangesCrossfadeUndoably() async {
    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
    } operation: {
      let model = editor(fingerprint: "fp-update-xfade")
      let id = addRemoval(model, length: 96)

      model.updateCrossfade(
        id: id, Crossfade(lengthSamples: 480, curve: .linear, curveAmount: 0.5))

      expectNoDifference(model.timelineRemovals[id: id]?.crossfade.lengthSamples, 480)
      expectNoDifference(model.timelineRemovals[id: id]?.crossfade.curve, .linear)

      await model.undoTapped()

      expectNoDifference(model.timelineRemovals[id: id]?.crossfade.lengthSamples, 96)
      expectNoDifference(model.timelineRemovals[id: id]?.crossfade.curve, .equalPower)
    }
  }

  @Test func updateCrossfadeIgnoresUnknownID() {
    withStorage {
      let model = editor(fingerprint: "fp-update-unknown")
      addRemoval(model, length: 96)
      model.updateCrossfade(id: Fixtures.uuid(999), Crossfade(lengthSamples: 999))
      expectNoDifference(model.timelineRemovals[id: Fixtures.uuid(1)]?.crossfade.lengthSamples, 96)
    }
  }

  // MARK: - Hit-testing

  /// Installs a fixed zoom (spp 200, well under the fit ceiling) so `timelineChanged` never re-fits,
  /// keeping the seam's view-x stable for hit-testing.
  private func hitTestEditor(_ fingerprint: String) -> (model: EditorModel, id: UUID) {
    let model = editor(fingerprint: fingerprint)
    model.editedWaveform.viewportWidth = 1000
    model.editedWaveform.samplesPerPixel = 200
    model.editedWaveform.visibleStartSample = 0
    let id = addRemoval(model, range: 30_000..<90_000, length: 600)
    return (model, id)
  }

  @Test func seamIDAtXHitsBowtieAndMissesElsewhere() {
    withStorage {
      let (model, id) = hitTestEditor("fp-hittest")
      #expect(!model.seamOverlays.isEmpty)
      let span = model.seamOverlays[0].span
      let mid = span.positionX + span.width / 2

      expectNoDifference(model.seamID(atX: mid), id)
      expectNoDifference(model.seamID(atX: span.positionX + span.width + 60), nil)
    }
  }

  @Test func seamIDResolvesToNearestWhenTargetsOverlap() {
    withStorage {
      let model = editor(fingerprint: "fp-nearest-seam")
      model.editedWaveform.viewportWidth = 1000
      model.editedWaveform.samplesPerPixel = 200
      model.editedWaveform.visibleStartSample = 0
      // Two removals with a short kept gap between them: their bowties end up a couple points apart,
      // close enough that each one's widened hit target covers the other's center. This is the case
      // where a first-match hit-test would always return the earlier seam and shadow the later one.
      let idA = addRemoval(model, id: Fixtures.uuid(1), range: 40_000..<80_000, length: 400)
      let idB = addRemoval(model, id: Fixtures.uuid(2), range: 80_600..<120_000, length: 400)

      let overlayA = model.seamOverlays.first { $0.id == idA }!
      let overlayB = model.seamOverlays.first { $0.id == idB }!
      let centerA = overlayA.span.positionX + overlayA.span.width / 2
      let centerB = overlayB.span.positionX + overlayB.span.width / 2
      #expect(centerB > centerA)
      #expect(centerB - centerA < 4)

      expectNoDifference(model.seamID(atX: centerA), idA)
      expectNoDifference(model.seamID(atX: centerB), idB)
    }
  }

  @Test func hardCutSeamIsSelectableAndRestorable() {
    withStorage {
      let model = editor(fingerprint: "fp-hardcut-restore")
      model.editedWaveform.viewportWidth = 1000
      model.editedWaveform.samplesPerPixel = 200
      model.editedWaveform.visibleStartSample = 1_500_000
      // Removal running to EOF: the trailing kept island is empty, so the crossfade clamps to 0 —
      // a hard cut with a zero-width bowtie. It must still be clickable (and therefore restorable);
      // otherwise a head/tail trim would be an un-restorable dead-end that permanently blocks export.
      let id = addRemoval(model, range: 1_600_000..<1_855_488, length: 600)
      let seam = model.editedWaveform.timeline.seams[0]
      expectNoDifference(seam.crossfadeLength, 0)

      let span = model.seamOverlays[0].span
      expectNoDifference(span.width, 0)
      expectNoDifference(model.seamID(atX: span.positionX), id)

      model.waveformClicked(atX: span.positionX, extending: false)
      expectNoDifference(model.selectedSeamID, id)

      model.restoreRemovalTapped()
      expectNoDifference(model.timelineRemovals[id: id], nil)
      expectNoDifference(model.selectedSeamID, nil)
    }
  }

  @Test func waveformClickOnSeamSelectsItWithoutMovingPlayhead() {
    withStorage {
      let (model, id) = hitTestEditor("fp-click-seam")
      model.playheadEditedSample = 12_345
      let span = model.seamOverlays[0].span
      let mid = span.positionX + span.width / 2

      model.waveformClicked(atX: mid, extending: false)

      expectNoDifference(model.selectedSeamID, id)
      expectNoDifference(model.playheadEditedSample, 12_345)
    }
  }

  @Test func shiftClickDoesNotSelectSeam() {
    withStorage {
      let (model, _) = hitTestEditor("fp-shiftclick-seam")
      let span = model.seamOverlays[0].span
      let mid = span.positionX + span.width / 2

      model.waveformClicked(atX: mid, extending: true)

      expectNoDifference(model.selectedSeamID, nil)
    }
  }

  @Test func gapClickDeselectsSeam() {
    withStorage {
      let (model, id) = hitTestEditor("fp-gap-deselect")
      model.selectSeam(id)
      #expect(model.selectedSeamID == id)

      // x 0 → source 0, before the first word (54,772) and clear of the bowtie: a gap click.
      model.waveformClicked(atX: 0, extending: false)

      expectNoDifference(model.selectedSeamID, nil)
    }
  }

  // MARK: - Context menu

  @Test func seamContextMenuSelectsSeamAndOffersRestore() {
    withStorage {
      let (model, id) = hitTestEditor("fp-context-menu")
      let span = model.seamOverlays[0].span
      let mid = span.positionX + span.width / 2

      let items = model.seamContextMenuItems(atX: mid)

      expectNoDifference(model.selectedSeamID, id)
      expectNoDifference(items.map(\.title), [model.restoreRemovedAudioLabel])

      items[0].action()
      expectNoDifference(model.timelineRemovals.count, 0)
    }
  }

  @Test func seamContextMenuIsEmptyOffSeam() {
    withStorage {
      let (model, _) = hitTestEditor("fp-context-empty")
      let span = model.seamOverlays[0].span

      let items = model.seamContextMenuItems(atX: span.positionX + span.width + 60)

      #expect(items.isEmpty)
    }
  }

  // MARK: - Delete-key + Escape arbitration

  @Test func deleteKeyWithSeamSelectedRestoresRemoval() {
    withStorage {
      let model = editor(fingerprint: "fp-delete-restores")
      let id = addRemoval(model)
      model.selectSeam(id)

      let consumed = model.editorKeyDown(.removeSection)

      #expect(consumed)
      expectNoDifference(model.timelineRemovals.count, 0)
      expectNoDifference(model.selectedSeamID, nil)
    }
  }

  @Test func deleteKeyWithNothingSelectedFallsThrough() {
    withStorage {
      let model = editor(fingerprint: "fp-delete-fallthrough")
      addRemoval(model)
      // No seam selected and no removable range selection: the key must fall through.
      expectNoDifference(model.editorKeyDown(.removeSection), false)
    }
  }

  @Test func escapeDeselectsSeamOnlyWhenOneIsSelected() {
    withStorage {
      let model = editor(fingerprint: "fp-escape")
      let id = addRemoval(model)

      // Nothing selected: Escape falls through.
      expectNoDifference(model.editorKeyDown(.escape), false)

      model.selectSeam(id)
      let consumed = model.editorKeyDown(.escape)

      #expect(consumed)
      expectNoDifference(model.selectedSeamID, nil)
    }
  }

  // MARK: - Playback reconciliation

  /// A restore mid free-playback must stop the stale playlist and leave the cursor on the SAME
  /// source moment (it rides `mutateDocument` → `syncEditedTimeline`, the PR 3 reconciliation path).
  @Test func restoreDuringFreePlayStopsPlaybackAndKeepsSourceMoment() async {
    let gate = SeamPlayGate()
    let fileSystem = LockIsolated<[URL: Data]>([:])
    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
      $0.audioPlayer.playEdited = { _, _, _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      let model = editor(fingerprint: "fp-restore-midplay")
      let id = addRemoval(model, range: 10_000..<210_000, length: 96)
      model.playheadEditedSample = 100_000  // past the seam, on the identity-mapped tail
      let sourceBefore = model.playheadSourceSample

      let task = Task { await model.transportPlayTapped() }
      await gate.awaitStarted()
      #expect(model.isTransportPlaying)

      model.restoreRemoval(id: id)
      await task.value

      expectNoDifference(model.transportPhase, .stopped)
      expectNoDifference(model.playheadSourceSample, sourceBefore)
      expectNoDifference(model.timelineRemovals.count, 0)
    }
  }
}
