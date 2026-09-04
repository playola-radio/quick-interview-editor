import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
import IdentifiedCollections
@_spi(Internals) import Sharing
import Testing

@testable import QuickInterviewEditor

@MainActor
struct EditorCrossfadeStretchTests {
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

  /// Fixed zoom so a seam's view-x/width stays stable for bowtie-width assertions.
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

  private func withStorageThrowing(_ body: () throws -> Void) rethrows {
    try withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
    } operation: {
      try body()
    }
  }

  // MARK: - Draft clamping

  @Test func stretchClampsToAvailableHandle() {
    withStorage {
      let model = editor(fingerprint: "fp-stretch-clamp")
      // Remove [48_000,96_000): left handle 48_000, right handle (large) — max = 48_000.
      let id = addRemoval(model, range: 48_000..<96_000, length: 600)

      model.crossfadeStretchBegan(id: id)
      model.crossfadeStretched(toLength: 5_000_000)

      expectNoDifference(model.crossfadeStretchDraft?.length, 48_000)
    }
  }

  @Test func stretchFloorsAtZero() {
    withStorage {
      let model = editor(fingerprint: "fp-stretch-floor")
      let id = addRemoval(model)

      model.crossfadeStretchBegan(id: id)
      model.crossfadeStretched(toLength: -100)

      expectNoDifference(model.crossfadeStretchDraft?.length, 0)
    }
  }

  // MARK: - Commit

  @Test func endingStretchCommitsClampedLengthUndoably() async {
    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
    } operation: {
      let model = editor(fingerprint: "fp-stretch-commit")
      let id = addRemoval(model, length: 600)

      model.crossfadeStretchBegan(id: id)
      model.crossfadeStretched(toLength: 24_000)
      model.crossfadeStretchEnded()

      expectNoDifference(model.crossfadeStretchDraft, nil)
      expectNoDifference(model.timelineRemovals[id: id]?.crossfade.lengthSamples, 24_000)
      #expect(model.canUndo)

      await model.undoTapped()
      expectNoDifference(model.timelineRemovals[id: id]?.crossfade.lengthSamples, 600)
    }
  }

  @Test func endingStretchWithNoChangeRecordsNoUndoEntry() async {
    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
    } operation: {
      let model = editor(fingerprint: "fp-stretch-noop")
      let id = addRemoval(model, length: 600)

      model.crossfadeStretchBegan(id: id)
      model.crossfadeStretchEnded()

      // A single undo returns the ONE real mutation (the setup add) to empty: the no-op
      // stretch pushed no entry of its own.
      await model.undoTapped()
      expectNoDifference(model.timelineRemovals.count, 0)
    }
  }

  // MARK: - Live preview (no commit)

  @Test func draggingWidensBowtieWithoutCommitting() {
    withStorage {
      let model = editor(fingerprint: "fp-stretch-preview")
      primeGeometry(model)
      // Seam near the start so its bowtie sits inside the 1000pt viewport (spp 200).
      let id = addRemoval(model, range: 48_000..<96_000, length: 600)
      let committedWidth = model.seamOverlays.first { $0.id == id }!.span.width

      model.crossfadeStretchBegan(id: id)
      model.crossfadeStretched(toLength: 24_000)

      let previewWidth = model.seamOverlays.first { $0.id == id }!.span.width
      #expect(previewWidth > committedWidth)
      // The document is untouched until release.
      expectNoDifference(model.timelineRemovals[id: id]?.crossfade.lengthSamples, 600)
    }
  }

  // MARK: - Live reflow (Item ②: no reposition on release)

  @Test func draggingReflowsTheCollapsedTimelineLive() {
    withStorage {
      let model = editor(fingerprint: "fp-stretch-reflow")
      primeGeometry(model)
      let id = addRemoval(model, range: 48_000..<96_000, length: 600)
      let committedDuration = model.editedWaveform.timeline.editedDurationSamples

      model.crossfadeStretchBegan(id: id)
      model.crossfadeStretched(toLength: 24_000)

      // A longer crossfade overlaps more audio, so the collapsed timeline shortens by the growth
      // live — the reflow the commit used to defer to mouse-up.
      expectNoDifference(
        model.editedWaveform.timeline.editedDurationSamples,
        committedDuration - (24_000 - 600))
    }
  }

  @Test func committingAStretchLeavesTheWaveformWhereThePreviewHadIt() {
    withStorage {
      let model = editor(fingerprint: "fp-stretch-nojump")
      primeGeometry(model)
      let id = addRemoval(model, range: 48_000..<96_000, length: 600)

      model.crossfadeStretchBegan(id: id)
      model.crossfadeStretched(toLength: 24_000)
      let previewOverlays = model.seamOverlays
      let previewStart = model.editedWaveform.visibleStartSample

      model.crossfadeStretchEnded()

      // Release repositions nothing: the committed geometry equals the last preview frame.
      expectNoDifference(model.seamOverlays, previewOverlays)
      expectNoDifference(model.editedWaveform.visibleStartSample, previewStart)
    }
  }

  @Test func theGrabbedEdgeStaysUnderTheCursorAsTheTimelineReflows() throws {
    try withStorageThrowing {
      let model = editor(fingerprint: "fp-stretch-track")
      model.editedWaveform.viewportWidth = 1000
      model.editedWaveform.samplesPerPixel = 200
      // Center the seam (edited center 479_700) in the viewport so there is room to shift the
      // viewport as the seam grows, keeping the grabbed edge under the cursor.
      model.editedWaveform.visibleStartSample = 379_700
      let id = addRemoval(model, range: 480_000..<528_000, length: 600)

      model.crossfadeStretchBegan(id: id)
      let targetX: CGFloat = 600
      model.crossfadeStretched(.trailing, toX: targetX)

      let overlay = try #require(model.seamOverlays.first { $0.id == id })
      let trailing = try #require(overlay.trailingHandleX)
      expectNoDifference(trailing, targetX)
    }
  }

  @Test func committingAStretchRunsTimelineReconciliation() {
    withStorage {
      let model = editor(fingerprint: "fp-stretch-reconcile")
      let id = addRemoval(model, range: 48_000..<96_000, length: 600)
      // Fit the whole committed timeline in the viewport (max zoom-out).
      model.editedWaveform.viewportResized(width: 1000)
      let fitBefore = model.editedWaveform.samplesPerPixel

      model.crossfadeStretchBegan(id: id)
      model.crossfadeStretched(toLength: 48_000)
      // The live preview reflows the timeline but never re-fits zoom, so the zoom stays too wide
      // for the now-shorter timeline until the commit reconciles it.
      expectNoDifference(model.editedWaveform.samplesPerPixel, fitBefore)

      model.crossfadeStretchEnded()

      // Release must run the full timeline-change reconciliation instead of short-circuiting on
      // the equality guard (the preview already installed the committed timeline). Re-fitting the
      // zoom to the shorter timeline is the observable proof the reconciliation body ran.
      #expect(model.editedWaveform.samplesPerPixel < fitBefore)
    }
  }

  // MARK: - Stale-draft reconciliation

  @Test func restoringTheSeamMidDragDropsTheStaleDraft() {
    withStorage {
      let model = editor(fingerprint: "fp-stretch-stale")
      let id = addRemoval(model, range: 48_000..<96_000, length: 600)

      model.crossfadeStretchBegan(id: id)
      model.crossfadeStretched(toLength: 24_000)
      #expect(model.crossfadeStretchDraft != nil)

      // A restore retires the seam the draft targets; the funnel must drop the orphaned draft.
      model.restoreRemoval(id: id)

      expectNoDifference(model.crossfadeStretchDraft, nil)
    }
  }
}
