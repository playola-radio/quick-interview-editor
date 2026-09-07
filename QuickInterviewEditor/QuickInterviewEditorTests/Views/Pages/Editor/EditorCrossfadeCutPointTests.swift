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
      frozenCommittedTimeline: EditedTimeline(sourceDurationSamples: 1_000_000, removals: []),
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

  @Test func updateRemovalRangeMovesBoundPreservingStoredLengthAndID() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-commit")
      let id = addRemoval(model, range: 48_000..<96_000, length: 600)

      model.updateRemovalRange(id: id, removedRange: 46_000..<96_000)

      expectNoDifference(model.timelineRemovals[id: id]?.removedRange, 46_000..<96_000)
      expectNoDifference(model.timelineRemovals[id: id]?.crossfade.lengthSamples, 600)  // untouched
      #expect(model.timelineRemovals[id: id]?.id == id)  // identity preserved
    }
  }

  @Test func updateRemovalRangeIsBlockedWhileExporting() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-export-guard")
      let id = addRemoval(model, range: 48_000..<96_000, length: 600)
      // isExporting is computed off exportPhase.
      model.exportPhase = .exporting(current: 0, total: 1)

      model.updateRemovalRange(id: id, removedRange: 46_000..<96_000)

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
      let clamped = model.clampedRemovalRange(id: id, proposed: 200_000..<200_000)

      expectNoDifference(clamped, 95_999..<96_000)
    }
  }

  @Test func clampUpperReachesTheNeighborRemovalBoundaryNotItsFade() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-clamp-upper-neighbor")
      let id = addRemoval(model, id: Fixtures.uuid(1), range: 48_000..<96_000, length: 600)
      // Neighbor removal to the right at 150_000: cR upper bound = 150_000, flush against the neighbor
      // (Option C: no fade reservation — a neighbor removal is just another edge, so both shared fades
      // render shorter rather than the cut being walled off short of it).
      addRemoval(model, id: Fixtures.uuid(2), range: 150_000..<200_000, length: 400)

      let clamped = model.clampedRemovalRange(id: id, proposed: 48_000..<300_000)

      expectNoDifference(clamped, 48_000..<150_000)
    }
  }

  @Test func clampLowerReachesTheNeighborRemovalBoundaryNotItsFade() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-clamp-lower-neighbor")
      addRemoval(model, id: Fixtures.uuid(1), range: 48_000..<96_000, length: 400)
      let id = addRemoval(model, id: Fixtures.uuid(2), range: 150_000..<200_000, length: 600)

      // Neighbor removal to the left ending at 96_000: cL lower bound = 96_000, flush against the
      // neighbor (Option C: no fade reservation — the cut reaches the neighbor boundary, both shared
      // fades render shorter rather than the cut being walled off short of it).
      let clamped = model.clampedRemovalRange(id: id, proposed: 0..<200_000)

      expectNoDifference(clamped, 96_000..<200_000)
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
      let clamped = model.clampedRemovalRange(id: id, proposed: 48_000..<48_000)

      expectNoDifference(clamped, 48_000..<48_001)
    }
  }

  // MARK: - Reach the edge (own-fade reservation removed)

  /// The moving cut may run all the way to the source START — the clamp reserves NO room for the
  /// removal's OWN fade, even one much longer than the material before it. With no previous neighbor
  /// the floor is `prevUpper(0) + prevF(0) = 0`; the old own-fade reservation would have walled cL off
  /// at `frozenLength`. `EditedTimeline` renders the fade shorter (down to a hard cut) instead.
  @Test func clampLowerCanReachTheSourceStartWithoutOwnFadeReservation() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-reach-start")
      let id = addRemoval(model, range: 48_000..<96_000, length: 2_000)

      let clamped = model.clampedRemovalRange(id: id, proposed: (-12_000)..<96_000)

      expectNoDifference(clamped, 0..<96_000)  // reaches source start, not walled off at the fade
    }
  }

  /// Symmetric to the lower edge: the last removal's cut-out may run all the way to the source END
  /// (`nextLower = source.durationSamples`, `nextF = 0`), no own-fade reservation. The bundled fixture
  /// source is 1_855_488 samples.
  @Test func clampUpperCanReachTheSourceEndWithoutOwnFadeReservation() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-reach-end")
      let id = addRemoval(model, range: 48_000..<96_000, length: 2_000)

      let clamped = model.clampedRemovalRange(id: id, proposed: 48_000..<3_000_000)

      expectNoDifference(clamped, 48_000..<1_855_488)  // reaches source end
    }
  }

  /// The clamp moves only ONE edge: when a (defensive) proposal changes BOTH bounds, the lower-edge
  /// branch (`proposed.lowerBound != cL`) wins and the committed upper bound is held. Documents that
  /// callers move a single cut per drag — the paired bound is never silently applied.
  @Test func clampReadsOnlyTheMovingLowerEdgeWhenBothBoundsDiffer() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-both-bounds")
      let id = addRemoval(model, range: 48_000..<96_000, length: 600)

      let clamped = model.clampedRemovalRange(id: id, proposed: 40_000..<200_000)

      expectNoDifference(clamped, 40_000..<96_000)  // upper (200_000) ignored; committed cR held
    }
  }

  /// Crowding an upper cut flush against a following removal renders BOTH shared fades shorter, never
  /// rewriting either STORED length (Option C, decision B: a neighbor removal is just another edge —
  /// the clamp reserves no fade room). `EditedTimeline` allocates seams left-to-right, so the left
  /// (moving) seam claims the shrunken island first and the right neighbor's rendered fade is starved
  /// to a hard cut. Encodes Codex's worked example: current fade 600, next fade 400, island 400 →
  /// current renders 400, next renders 0, both stored lengths untouched.
  @Test func crowdingUpperCutFlushToNeighborShortensBothSharedFadesPreservingStored() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-neighbor-crowd")
      let idA = addRemoval(model, id: Fixtures.uuid(1), range: 48_000..<80_000, length: 600)
      let idB = addRemoval(model, id: Fixtures.uuid(2), range: 100_000..<200_000, length: 400)

      // Move A's cut-out from 80_000 toward B, leaving a 400-sample island before B (100_000).
      // The clamp reaches toward the neighbor, not walled off at its fade.
      let clamped = model.clampedRemovalRange(id: idA, proposed: 48_000..<99_600)
      expectNoDifference(clamped, 48_000..<99_600)
      model.updateRemovalRange(id: idA, removedRange: clamped)

      // Stored fade lengths are untouched (non-destructive).
      expectNoDifference(model.timelineRemovals[id: idA]?.crossfade.lengthSamples, 600)
      expectNoDifference(model.timelineRemovals[id: idB]?.crossfade.lengthSamples, 400)

      // Both shared fades render shorter: A's own fade 600 → 400 (island), B starved 400 → 0.
      let seams = model.editedTimeline.seams
      expectNoDifference(seams.first(where: { $0.id == idA })?.crossfadeLength, 400)
      expectNoDifference(seams.first(where: { $0.id == idB })?.crossfadeLength, 0)
    }
  }

  // MARK: - Reach the edge (drag lifecycle)

  /// Dragging the left cut toward the source start past the stored fade length shortens the rendered
  /// (EFFECTIVE) fade to the shrinking left handle while the STORED length is preserved (Option C:
  /// non-destructive). cL 48_000 → 800 leaves only 800 kept samples before the cut, so the 2_000-sample
  /// stored fade renders as 800; the stored value survives for when the cut is pulled back out.
  @Test func draggingLeftCutTowardTheStartShortensEffectiveFadePreservingStored() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-reach-shortens")
      primeGeometry(model)  // spp 200, visibleStart 0
      let id = addRemoval(model, range: 48_000..<96_000, length: 2_000)
      let effective = {
        model.editedWaveform.timeline.seams.first(where: { $0.id == id })?.crossfadeLength
      }
      expectNoDifference(effective(), 2_000)  // full stored fade before the drag

      // dragStart edited = 20_000; +236px → delta +47_200 → cL 48_000 → 800.
      model.crossfadeCutPointDragBegan(id: id, edge: .lower, atX: 100)
      model.crossfadeCutPointDragged(toX: 336)
      expectNoDifference(model.crossfadeCutPointDraft?.draftedRange, 800..<96_000)
      model.crossfadeCutPointDragEnded()

      // Stored fade preserved; rendered fade shortened to the 800-sample left handle.
      expectNoDifference(model.timelineRemovals[id: id]?.crossfade.lengthSamples, 2_000)
      expectNoDifference(effective(), 800)
    }
  }

  /// The crossfade stays pinned to its start-of-drag screen position even as its EFFECTIVE length
  /// shrinks near the edge — the viewport re-anchors on the seam's actual edited position
  /// (`editedCrossfadeStart`), NOT on ΔcL. With visibleStart 100_000, dragging cL 48_000 → 800 moves
  /// the seam's edited start 46_000 → 0 (the fade clamps to the 800 handle), so the viewport shifts by
  /// −46_000 to 54_000. A naive ΔcL anchor would shift by −47_200 (to 52_800) and let the fade drift.
  @Test func draggingLeftCutTowardTheStartKeepsTheCrossfadePinnedWhileTheFadeShrinks() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-reach-pinned")
      model.editedWaveform.viewportWidth = 1000
      model.editedWaveform.samplesPerPixel = 200
      model.editedWaveform.visibleStartSample = 100_000
      let id = addRemoval(model, range: 48_000..<96_000, length: 2_000)
      let seamStart = { model.editedWaveform.timeline.seams.first?.editedCrossfadeStart ?? 0 }
      let offsetBefore = seamStart() - model.editedWaveform.visibleStartSample

      model.crossfadeCutPointDragBegan(id: id, edge: .lower, atX: 100)  // dragStart edited 120_000
      model.crossfadeCutPointDragged(toX: 336)  // +47_200 → cL 800

      expectNoDifference(model.crossfadeCutPointDraft?.draftedRange, 800..<96_000)
      expectNoDifference(model.editedWaveform.visibleStartSample, 54_000)
      let offsetAfter = seamStart() - model.editedWaveform.visibleStartSample
      expectNoDifference(offsetAfter, offsetBefore)  // crossfade held its screen position
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

  @Test func draggingLeftCutReanchorsViewportToPinTheCrossfade() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-reanchor-left")
      model.editedWaveform.viewportWidth = 1000
      model.editedWaveform.samplesPerPixel = 200
      model.editedWaveform.visibleStartSample = 40_000  // positive, so a shift is observable
      let id = addRemoval(model, range: 48_000..<96_000, length: 600)
      // Crossfade start (edited) = cL − L = 47_400; its screen offset from the viewport is fixed.
      let seamScreenOffsetBefore =
        (model.editedWaveform.timeline.seams.first?.editedCrossfadeStart ?? 0)
        - model.editedWaveform.visibleStartSample

      model.crossfadeCutPointDragBegan(id: id, edge: .lower, atX: 100)  // dragStart edited = 60_000
      model.crossfadeCutPointDragged(toX: 90)  // −10px → delta −2000 → cL 48_000 → 50_000

      expectNoDifference(model.crossfadeCutPointDraft?.draftedRange, 50_000..<96_000)
      // Viewport re-anchored by ΔcL (+2000) so the crossfade holds its screen position.
      expectNoDifference(model.editedWaveform.visibleStartSample, 42_000)
      let seamScreenOffsetAfter =
        (model.editedWaveform.timeline.seams.first?.editedCrossfadeStart ?? 0)
        - model.editedWaveform.visibleStartSample
      expectNoDifference(seamScreenOffsetAfter, seamScreenOffsetBefore)
    }
  }

  @Test func draggingRightCutLeavesTheViewportAnchored() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-reanchor-right")
      model.editedWaveform.viewportWidth = 1000
      model.editedWaveform.samplesPerPixel = 200
      model.editedWaveform.visibleStartSample = 40_000
      let id = addRemoval(model, range: 48_000..<96_000, length: 600)

      // dragStart edited = 100_000; −10px → cR 96_000 → 98_000.
      model.crossfadeCutPointDragBegan(id: id, edge: .upper, atX: 300)
      model.crossfadeCutPointDragged(toX: 290)

      expectNoDifference(model.crossfadeCutPointDraft?.draftedRange, 48_000..<98_000)
      // cL untouched → the crossfade (and everything left of it) stays put; only the right slides.
      expectNoDifference(model.editedWaveform.visibleStartSample, 40_000)
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

  // MARK: - Non-destructive move (stored length preserved)

  @Test func movingCutPreservesStoredLengthWhileRenderClampsEffective() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-preserve-stored")
      primeGeometry(model)
      // Left handle (1_000 samples) is smaller than the stored fade (2_000), so `EditedTimeline`
      // clamps the seam's EFFECTIVE `crossfadeLength` down to 1_000 — every other fixture in this
      // file uses a fade small enough that stored == effective, which would let a regression that
      // committed the EFFECTIVE length (1_000) instead of the stored one pass unnoticed.
      let id = addRemoval(model, range: 1_000..<5_000, length: 2_000)
      let effectiveLength = {
        model.editedWaveform.timeline.seams.first(where: { $0.id == id })?.crossfadeLength
      }
      expectNoDifference(effectiveLength(), 1_000)

      model.crossfadeCutPointDragBegan(id: id, edge: .upper, atX: 300)
      model.crossfadeCutPointDragged(toX: 290)  // -10px leftward → delta -2000 → cR + 2000
      model.crossfadeCutPointDragEnded()

      // Moving the cut is non-destructive: the STORED fade duration (2_000) survives, never rewritten
      // down to the geometry-clamped effective length (Option C).
      expectNoDifference(model.timelineRemovals[id: id]?.crossfade.lengthSamples, 2_000)
      // The rendered seam's crossfade still clamps to the 1_000-sample handle — the stored overhang
      // just renders shorter, and would return in full if the cut were pulled back out.
      expectNoDifference(effectiveLength(), 1_000)
    }
  }

  @Test func draggingLeftCutAwayFromEdgeGrowsPreviewFadeToMatchCommit() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-preview-matches-commit")
      primeGeometry(model)  // spp 200, visibleStart 0 → xToSample(x) = x * 200
      // Removal hard against the source start: the left handle (100) is far smaller than the stored
      // fade (2_000), so `EditedTimeline` clamps the seam's EFFECTIVE length down to 100 at begin.
      let id = addRemoval(model, range: 100..<40_000, length: 2_000)
      let effective = {
        model.editedWaveform.timeline.seams.first(where: { $0.id == id })?.crossfadeLength
      }
      expectNoDifference(effective(), 100)

      // Drag the LEFT cut inward (rightward, away from the start): dragStart edited = 60_000,
      // toX 275 → edited 55_000 → delta −5_000 → cL 100 → 5_100. The left handle grows to 5_100, so
      // the fade can now render its full stored 2_000.
      model.crossfadeCutPointDragBegan(id: id, edge: .lower, atX: 300)
      model.crossfadeCutPointDragged(toX: 275)
      expectNoDifference(model.crossfadeCutPointDraft?.draftedRange, 5_100..<40_000)
      // The LIVE PREVIEW already renders the grown fade (2_000), not the 100 frozen at begin — the
      // preview is built from the stored length, so it clamps to the live handle just like the commit.
      let previewEffective = effective()
      expectNoDifference(previewEffective, 2_000)

      model.crossfadeCutPointDragEnded()
      // The committed render matches the preview exactly — no fade-pop on release.
      expectNoDifference(effective(), previewEffective)
      expectNoDifference(effective(), 2_000)
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

  @Test func midDragNeighborMutationInvalidatesDraftAndBlocksStaleCommit() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-neighbor-stale")
      primeGeometry(model)
      let id = addRemoval(model, id: Fixtures.uuid(1), range: 48_000..<96_000, length: 600)
      model.selectSeam(id)

      // Begin dragging the LEFT cut inward; the draft's committed baseline is 48_000..<96_000.
      model.crossfadeCutPointDragBegan(id: id, edge: .lower, atX: 100)
      model.crossfadeCutPointDragged(toX: 110)  // draft → 46_000..<96_000
      expectNoDifference(model.crossfadeCutPointDraft?.draftedRange, 46_000..<96_000)

      // Mid-drag a DISTANT neighbor removal appears (an undo/redo of an unrelated cut is the same
      // class of document mutation). It leaves THIS seam's own range AND effective fade length
      // untouched — the earlier per-seam guard (own range OR own effective length changed) would keep
      // the stale draft alive — but the drafted range was clamped against the pre-mutation layout, so
      // the whole-timeline baseline guard must still drop it.
      addRemoval(model, id: Fixtures.uuid(2), range: 500_000..<600_000, length: 400)
      // Own range unchanged.
      expectNoDifference(model.timelineRemovals[id: id]?.removedRange, 48_000..<96_000)
      // Own effective fade length unchanged — only a neighbor moved.
      expectNoDifference(
        model.editedWaveform.timeline.seams.first(where: { $0.id == id })?.crossfadeLength, 600)
      // Draft invalidated by the neighbor change.
      expectNoDifference(model.crossfadeCutPointDraft, nil)

      // Mouse-up commits nothing: the drag is abandoned rather than committing the stale
      // 46_000..<96_000 against the reflowed layout.
      model.crossfadeCutPointDragEnded()
      expectNoDifference(model.timelineRemovals[id: id]?.removedRange, 48_000..<96_000)
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

  @Test func nudgePreservesStoredFadeLengthNotEffective() {
    withStorage {
      let model = editor(fingerprint: "fp-cut-nudge-preserve-stored")
      // Stored fade 2_000 but the left handle is only 1_000 → effective clamps to 1_000. A nudge that
      // committed the effective length would shrink the stored duration; it must pin the stored one.
      let id = addRemoval(model, range: 1_000..<5_000, length: 2_000)
      model.selectSeam(id)

      // cR + 441; the left handle (and so the effective length) is unchanged.
      _ = model.editorKeyDown(.nudgeRightCutLater)

      expectNoDifference(model.timelineRemovals[id: id]?.crossfade.lengthSamples, 2_000)
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
