import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
import IdentifiedCollections
@_spi(Internals) import Sharing
import Testing

@testable import PlayolaInterviewEditor

/// Suspends a play call until released, reporting when it started. A minimal local mirror of
/// `EditorTransportTests`' `TransportGate`, scoped to the one playback-interruption test below.
private final class PlaybackGate: @unchecked Sendable {
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
struct EditorCrossfadeCutPointTests {

  // MARK: - Draft value type

  @Test func draftIsEquatableByValue() {
    let original = CrossfadeCutPointDraft(
      id: Fixtures.uuid(1), edge: .lower, committedRange: 48_000..<96_000,
      draftedRange: 46_000..<96_000, frozenCrossfadeLength: 600,
      dragStartEditedSample: 20_000, frozenVisibleStart: 0, frozenSamplesPerPixel: 200)
    var copy = original
    copy.draftedRange = 46_000..<96_000
    expectNoDifference(original, copy)
    copy.edge = .upper
    #expect(original != copy)
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

  @Test func clampLowerRespectsNeighborRemovalAndItsFade() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-clamp-lower-neighbor")
      addRemoval(model, id: Fixtures.uuid(1), range: 48_000..<96_000, length: 400)
      let id = addRemoval(model, id: Fixtures.uuid(2), range: 150_000..<200_000, length: 600)

      // Neighbor removal to the left, fade 400: cL lower bound = 96_000 + 400 + 600 = 97_000.
      let clamped = model.clampedRemovalRange(
        id: id, proposed: 0..<200_000, frozenLength: 600)

      expectNoDifference(clamped, 97_000..<200_000)
    }
  }

  @Test func clampUpperCannotCrossTheLeftCut() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-clamp-upper-cross")
      let id = addRemoval(model, range: 48_000..<96_000, length: 600)

      // Propose cR before cL: pinned to cL + 1 (removal stays non-empty). `48_000..<48_000` (not
      // `0..<48_000`) because Swift's `Range` enforces lowerBound <= upperBound, and the
      // moving-upper-edge branch of clampedRemovalRange is selected by `proposed.lowerBound == cL` —
      // it then only reads `proposed.upperBound`, so the paired lowerBound must equal cL to route here.
      let clamped = model.clampedRemovalRange(
        id: id, proposed: 48_000..<48_000, frozenLength: 600)

      expectNoDifference(clamped, 48_000..<48_001)
    }
  }

  // MARK: - Drag lifecycle

  @Test func draggingLeftCutInwardMovesLowerBoundWithoutTouchingDocument() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-drag-left-preview")
      primeGeometry(model)  // spp 200 → 10px = 2000 samples
      let id = addRemoval(model, range: 48_000..<96_000, length: 600)

      model.crossfadeCutPointDragBegan(id: id, edge: .lower, atX: 100)
      model.crossfadeCutPointDragged(toX: 110)  // +10px rightward → delta +2000

      // Draft reflects cL - delta = 46_000; document still committed.
      expectNoDifference(model.crossfadeCutPointDraft?.draftedRange, 46_000..<96_000)
      expectNoDifference(model.timelineRemovals[id: id]?.removedRange, 48_000..<96_000)
    }
  }

  @Test func endingLeftDragCommitsMovedCutUndoably() async {
    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
    } operation: {
      let model = editor(fingerprint: "fp-cut-drag-left-commit")
      model.editedWaveform.viewportWidth = 1000
      model.editedWaveform.samplesPerPixel = 200
      model.editedWaveform.visibleStartSample = 0
      model.mutateDocument { doc in
        doc.timelineRemovals.append(
          TimelineRemoval(
            id: Fixtures.uuid(1), removedRange: 48_000..<96_000,
            crossfade: Crossfade(lengthSamples: 600, curve: .equalPower)))
      }

      model.crossfadeCutPointDragBegan(id: Fixtures.uuid(1), edge: .lower, atX: 100)
      model.crossfadeCutPointDragged(toX: 110)
      model.crossfadeCutPointDragEnded()

      expectNoDifference(model.crossfadeCutPointDraft, nil)
      expectNoDifference(
        model.timelineRemovals[id: Fixtures.uuid(1)]?.removedRange, 46_000..<96_000)
      expectNoDifference(
        model.timelineRemovals[id: Fixtures.uuid(1)]?.crossfade.lengthSamples, 600)  // length fixed
      #expect(model.canUndo)

      await model.undoTapped()
      expectNoDifference(
        model.timelineRemovals[id: Fixtures.uuid(1)]?.removedRange, 48_000..<96_000)
      expectNoDifference(model.selectedSeamID, Fixtures.uuid(1))  // seam stays selected across undo
    }
  }

  @Test func draggingRightCutInwardMovesUpperBound() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-drag-right")
      primeGeometry(model)
      let id = addRemoval(model, range: 48_000..<96_000, length: 600)

      model.crossfadeCutPointDragBegan(id: id, edge: .upper, atX: 300)
      model.crossfadeCutPointDragged(toX: 290)  // -10px leftward → delta -2000 → cR + 2000

      expectNoDifference(model.crossfadeCutPointDraft?.draftedRange, 48_000..<98_000)
    }
  }

  @Test func cancellingDragRestoresCommittedTimelineAndDropsDraft() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-drag-cancel")
      primeGeometry(model)
      let id = addRemoval(model, range: 48_000..<96_000, length: 600)

      model.crossfadeCutPointDragBegan(id: id, edge: .lower, atX: 100)
      model.crossfadeCutPointDragged(toX: 110)
      model.crossfadeCutPointDragCancelled()

      expectNoDifference(model.crossfadeCutPointDraft, nil)
      expectNoDifference(model.timelineRemovals[id: id]?.removedRange, 48_000..<96_000)
    }
  }

  @Test func draggingSelectsTheSeam() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-drag-selects")
      primeGeometry(model)
      let id = addRemoval(model, range: 48_000..<96_000, length: 600)

      model.crossfadeCutPointDragBegan(id: id, edge: .lower, atX: 100)

      expectNoDifference(model.selectedSeamID, id)
    }
  }

  // MARK: - Effective length freeze

  @Test func movingCutFreezesEffectiveLengthNotStoredLength() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-freeze-effective")
      primeGeometry(model)
      // Left handle (1_000 samples) is smaller than the stored fade (2_000), so `EditedTimeline`
      // clamps the seam's EFFECTIVE `crossfadeLength` down to 1_000 — every other fixture in this
      // file uses a fade small enough that stored == effective, which would let a regression that
      // freezes the STORED length (2_000) instead of the effective one pass unnoticed.
      let id = addRemoval(model, range: 1_000..<5_000, length: 2_000)
      let effectiveLength = {
        model.editedWaveform.timeline.seams.first(where: { $0.id == id })?.crossfadeLength
      }
      expectNoDifference(effectiveLength(), 1_000)

      model.crossfadeCutPointDragBegan(id: id, edge: .upper, atX: 300)
      model.crossfadeCutPointDragged(toX: 290)  // -10px leftward → delta -2000 → cR + 2000
      model.crossfadeCutPointDragEnded()

      // Committed fade is pinned to the EFFECTIVE length (1_000) that was frozen at drag begin, not
      // the original stored length (2_000).
      expectNoDifference(model.timelineRemovals[id: id]?.crossfade.lengthSamples, 1_000)
      // The rendered seam's crossfade length is unchanged by the move.
      expectNoDifference(effectiveLength(), 1_000)
    }
  }

  // MARK: - Stale-draft invalidation (mid-drag document mutation)

  @Test func midDragDocumentMutationInvalidatesDraftAndBlocksStaleCommit() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-stale-draft")
      primeGeometry(model)
      let id = addRemoval(model, range: 48_000..<96_000, length: 600)
      model.selectSeam(id)

      // Begin dragging the LEFT cut inward; the draft's committed baseline is 48_000..<96_000.
      model.crossfadeCutPointDragBegan(id: id, edge: .lower, atX: 100)
      model.crossfadeCutPointDragged(toX: 110)  // draft → 46_000..<96_000
      expectNoDifference(model.crossfadeCutPointDraft?.draftedRange, 46_000..<96_000)

      // Mid-drag the document changes under the drag (here a right-cut nudge; undo/redo is the same
      // class — all mutations funnel through `syncEditedTimeline`). Its guard must drop the now-stale
      // cut-point draft: the committed baseline (…96_000) no longer matches the document (…96_441).
      _ = model.editorKeyDown(.nudgeRightCutLater)  // cR + 441
      expectNoDifference(model.timelineRemovals[id: id]?.removedRange, 48_000..<96_441)
      expectNoDifference(model.crossfadeCutPointDraft, nil)  // draft invalidated

      // Mouse-up now commits nothing: the newer (nudged) state survives instead of being clobbered
      // by the stale drafted 46_000..<96_000.
      model.crossfadeCutPointDragEnded()
      expectNoDifference(model.timelineRemovals[id: id]?.removedRange, 48_000..<96_441)
    }
  }

  // MARK: - Keyboard nudge

  @Test func nudgeMovesLeftCutBy10msWhenSeamSelected() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-nudge-left")
      let id = addRemoval(model, range: 48_000..<96_000, length: 600)
      model.selectSeam(id)

      _ = model.editorKeyDown(.nudgeLeftCutEarlier)  // 10ms @ 44100 = 441 samples earlier

      expectNoDifference(model.timelineRemovals[id: id]?.removedRange, 47_559..<96_000)
    }
  }

  @Test func nudgeMovesRightCutBy10msWhenSeamSelected() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-nudge-right")
      let id = addRemoval(model, range: 48_000..<96_000, length: 600)
      model.selectSeam(id)

      _ = model.editorKeyDown(.nudgeRightCutLater)  // cR + 441

      expectNoDifference(model.timelineRemovals[id: id]?.removedRange, 48_000..<96_441)
    }
  }

  @Test func nudgeIsANoOpWithNoSeamSelected() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-nudge-noseam")
      let id = addRemoval(model, range: 48_000..<96_000, length: 600)

      let consumed = model.editorKeyDown(.nudgeLeftCutEarlier)

      #expect(consumed == false)
      expectNoDifference(model.timelineRemovals[id: id]?.removedRange, 48_000..<96_000)
    }
  }

  // MARK: - Playback interruption

  @Test func nudgeStopsActiveTransportPlayback() async {
    let gate = PlaybackGate()
    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
      $0.audioPlayer.playEdited = { _, _, _, _, _ in
        EditedPlaybackEnd(end: await gate.play(), finishedEditedSample: nil)
      }
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      let model = editor(fingerprint: "fp-cut-nudge-playback-stop")
      let id = addRemoval(model, range: 48_000..<96_000, length: 600)
      model.selectSeam(id)
      let task = Task { await model.transportPlayTapped() }
      await gate.awaitStarted()
      #expect(model.isTransportPlaying)

      _ = model.editorKeyDown(.nudgeLeftCutEarlier)

      // Synchronous: a committing nudge stops transport before returning, the same as a cut-point
      // drag — without waiting on the fire-and-forget audio-node stop below.
      #expect(!model.isTransportPlaying)

      await task.value
    }
  }
}
