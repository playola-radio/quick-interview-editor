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

  /// A slice-only mutation (add/rename/delete/reorder — anything that flows through
  /// `mutateSlices` → `mutateDocument` without touching `timelineRemovals`) must not write the
  /// sidecar at all, while a removal mutation must. Inspects the in-memory file system's raw
  /// bytes directly (rather than re-reading `@Shared`, which would mask a spurious write of the
  /// same decoded value) — note that merely subscribing to a `@Shared(.fileStorage(...))` key
  /// writes an empty placeholder `Data()` up front (`FileStorageKey.subscribe`'s file-watcher
  /// setup), so "no write happened" is asserted as "the bytes didn't change", not as "nil".
  @Test func sliceOnlyMutationDoesNotWriteSidecarButRemovalMutationDoes() throws {
    let fingerprint = "fp-persist-guard"
    let url = ProjectState.sidecarURL(fingerprint: fingerprint)
    let fileSystem = LockIsolated<[URL: Data]>([:])
    try withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let model = editor(fingerprint: fingerprint)
      let afterInit = fileSystem.value[url]

      model.mutateSlices {
        $0.append(
          Slice(
            id: Fixtures.uuid(30), name: "A", startSample: 0, endSample: 100, wordIDs: [],
            snippet: "x", warnings: []))
      }
      expectNoDifference(fileSystem.value[url], afterInit)

      model.mutateDocument { doc in
        doc.timelineRemovals.append(
          TimelineRemoval(
            id: Fixtures.uuid(31), removedRange: 100..<200,
            crossfade: Crossfade(lengthSamples: 48, curve: .equalPower)))
      }
      #expect(fileSystem.value[url] != afterInit)
      let onDisk = try JSONDecoder().decode(ProjectState.self, from: fileSystem.value[url]!)
      expectNoDifference(onDisk.timelineRemovals.map(\.id), [Fixtures.uuid(31)])
    }
  }

  /// Undo/redo must persist the sidecar exactly when the restored removals differ from the
  /// current ones: undoing a slice-only add must not write, undoing a removal must persist the
  /// removals back to empty, and redoing it must persist them back.
  @Test func undoRedoPersistsSidecarOnlyWhenRemovalsChange() async throws {
    let fingerprint = "fp-persist-guard-undo"
    let url = ProjectState.sidecarURL(fingerprint: fingerprint)
    let fileSystem = LockIsolated<[URL: Data]>([:])
    try await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let model = editor(fingerprint: fingerprint)
      let afterInit = fileSystem.value[url]

      model.mutateSlices {
        $0.append(
          Slice(
            id: Fixtures.uuid(32), name: "A", startSample: 0, endSample: 100, wordIDs: [],
            snippet: "x", warnings: []))
      }
      expectNoDifference(fileSystem.value[url], afterInit)

      await model.undoTapped()
      expectNoDifference(fileSystem.value[url], afterInit)

      model.mutateDocument { doc in
        doc.timelineRemovals.append(
          TimelineRemoval(
            id: Fixtures.uuid(33), removedRange: 300..<400,
            crossfade: Crossfade(lengthSamples: 48, curve: .equalPower)))
      }
      var onDisk = try JSONDecoder().decode(ProjectState.self, from: fileSystem.value[url]!)
      expectNoDifference(onDisk.timelineRemovals.map(\.id), [Fixtures.uuid(33)])

      await model.undoTapped()
      onDisk = try JSONDecoder().decode(ProjectState.self, from: fileSystem.value[url]!)
      expectNoDifference(onDisk.timelineRemovals, [])

      await model.redoTapped()
      onDisk = try JSONDecoder().decode(ProjectState.self, from: fileSystem.value[url]!)
      expectNoDifference(onDisk.timelineRemovals.map(\.id), [Fixtures.uuid(33)])
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

  /// The removal `72_000..<114_000` fully contains only word 3 ("young", 77704..<98916); it clips
  /// word 2 ("a", 70648..<74176) and word 4 ("Hayes", 107736..<119202) at their edges. Strikethrough
  /// is full-containment, not midpoint — the clipped neighbors keep sounding, so only word 3 is
  /// struck. (Midpoint membership would wrongly strike words 2 and 4 too.)
  @Test func removedWordIDsTracksFullContainmentAndClearsOnUndo() async {
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
            id: Fixtures.uuid(5), removedRange: 72_000..<114_000,
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
      model.playheadEditedSample = 220_000  // a source sample just past the removal
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

  // MARK: - Boundary nudge (freeform selection)

  /// Selects words 1..2 (indices) and returns both the model and the resulting raw selection —
  /// the same words `removeSelectedSectionCreatesRemovalWithDefaultCrossfade` uses, chosen for
  /// their wide margin (28,268 samples) so a 441-sample nudge never hits the file or min-slice
  /// clamp.
  private func selectionEditor(fingerprint: String) -> (model: EditorModel, selection: Range<Int>) {
    let model = editor(fingerprint: fingerprint)
    model.transcript.selectWords(
      anchorID: model.editPlan.words[1].id, focusID: model.editPlan.words[2].id)
    return (model, model.audioSelection!)
  }

  @Test func selectingWordsThenSyncingOpensAPendingSelectionSession() {
    let fileSystem = LockIsolated<[URL: Data]>([:])
    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let (model, selection) = selectionEditor(fingerprint: "fp-nudge-open")
      model.syncEditSession()
      expectNoDifference(model.fineTune.target, .pendingSelection)
      expectNoDifference(model.fineTune.draftRange, selection)
    }
  }

  /// 10 ms at the fixture's 44,100 Hz sample rate is exactly 441 samples. The arrow keys now nudge
  /// the freeform selection (`audioSelection`) directly, so the moved range shows on
  /// `selectedSourceRange`. `syncEditSession()` is called to prove an open fine-tune session no
  /// longer intercepts the nudge.
  @Test func nudgeCutInLaterMovesTheStartLaterBy441Samples() {
    let fileSystem = LockIsolated<[URL: Data]>([:])
    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let (model, selection) = selectionEditor(fingerprint: "fp-nudge-cutin-later")
      model.syncEditSession()
      #expect(model.editorKeyDown(.nudgeCutInLater))
      expectNoDifference(
        model.selectedSourceRange, (selection.lowerBound + 441)..<selection.upperBound)
    }
  }

  @Test func nudgeCutInEarlierMovesTheStartEarlierBy441Samples() {
    let fileSystem = LockIsolated<[URL: Data]>([:])
    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let (model, selection) = selectionEditor(fingerprint: "fp-nudge-cutin-earlier")
      model.syncEditSession()
      #expect(model.editorKeyDown(.nudgeCutInEarlier))
      expectNoDifference(
        model.selectedSourceRange, (selection.lowerBound - 441)..<selection.upperBound)
    }
  }

  @Test func nudgeCutOutLaterMovesTheEndLaterBy441Samples() {
    let fileSystem = LockIsolated<[URL: Data]>([:])
    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let (model, selection) = selectionEditor(fingerprint: "fp-nudge-cutout-later")
      model.syncEditSession()
      #expect(model.editorKeyDown(.nudgeCutOutLater))
      expectNoDifference(
        model.selectedSourceRange, selection.lowerBound..<(selection.upperBound + 441))
    }
  }

  @Test func nudgeCutOutEarlierMovesTheEndEarlierBy441Samples() {
    let fileSystem = LockIsolated<[URL: Data]>([:])
    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let (model, selection) = selectionEditor(fingerprint: "fp-nudge-cutout-earlier")
      model.syncEditSession()
      #expect(model.editorKeyDown(.nudgeCutOutEarlier))
      expectNoDifference(
        model.selectedSourceRange, selection.lowerBound..<(selection.upperBound - 441))
    }
  }

  /// With no selection (so no fine-tune session ever opens), all four nudge keys must fall
  /// through unconsumed rather than crash or silently mutate a nonexistent draft.
  @Test func nudgeKeysAreNoOpsWithNoSelectionOrSessionOpen() {
    let fileSystem = LockIsolated<[URL: Data]>([:])
    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let model = editor(fingerprint: "fp-nudge-no-session")
      expectNoDifference(model.editorKeyDown(.nudgeCutInEarlier), false)
      expectNoDifference(model.editorKeyDown(.nudgeCutInLater), false)
      expectNoDifference(model.editorKeyDown(.nudgeCutOutEarlier), false)
      expectNoDifference(model.editorKeyDown(.nudgeCutOutLater), false)
      expectNoDifference(model.fineTune.target, nil)
    }
  }

  @Test func removeSelectedSectionAfterANudgeRemovesTheNudgedRangeNotTheRawSelection() async {
    let fileSystem = LockIsolated<[URL: Data]>([:])
    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let (model, selection) = selectionEditor(fingerprint: "fp-nudge-remove")
      model.syncEditSession()
      #expect(model.editorKeyDown(.nudgeCutOutLater))
      let nudgedRange = model.selectedSourceRange!
      #expect(nudgedRange != selection)

      await model.removeSelectedSectionTapped()

      expectNoDifference(model.timelineRemovals.count, 1)
      expectNoDifference(model.timelineRemovals.first?.removedRange, nudgedRange)
      // The session tears down with the removal.
      expectNoDifference(model.fineTune.target, nil)
      expectNoDifference(model.fineTune.draftRange, nil)
    }
  }

  /// Reselecting replaces the freeform selection outright, so Remove Section acts on the new
  /// selection — never a stale earlier one. Select A, nudge it, then select B: `audioSelection`
  /// becomes B (there is no separately held draft that could go stale), and the removal uses B.
  @Test func removeSelectedSectionAfterReselectingRemovesTheNewSelectionNotTheStaleNudgedRange()
    async
  {
    let fileSystem = LockIsolated<[URL: Data]>([:])
    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let (model, selectionA) = selectionEditor(fingerprint: "fp-nudge-reselect")
      model.syncEditSession()
      #expect(model.editorKeyDown(.nudgeCutOutLater))
      let nudgedA = model.selectedSourceRange!
      #expect(nudgedA != selectionA)

      // Select different words (B) — the freeform selection is replaced, not merged.
      model.transcript.selectWords(
        anchorID: model.editPlan.words[4].id, focusID: model.editPlan.words[5].id)
      model.syncEditSession()
      let selectionB = model.selectedSourceRange!
      #expect(selectionB != nudgedA)

      await model.removeSelectedSectionTapped()

      expectNoDifference(model.timelineRemovals.count, 1)
      expectNoDifference(model.timelineRemovals.first?.removedRange, selectionB)
    }
  }

  /// Nudging the freeform selection mutates `audioSelection` directly and never opens or dirties a
  /// held fine-tune draft, so it can't wedge `canAddSlice` or block `editSliceTapped` — the class
  /// of deadlock the retired nudge-via-fineTune stopgap could cause is gone by construction.
  @Test func nudgingASelectionNeverBlocksAddSliceOrEditSlice() {
    let fileSystem = LockIsolated<[URL: Data]>([:])
    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let model = editor(fingerprint: "fp-nudge-no-deadlock")
      // An existing slice, added and selection cleared, before the nudge below.
      model.transcript.selectWords(
        anchorID: model.editPlan.words[7].id, focusID: model.editPlan.words[8].id)
      model.addSliceTapped()
      let existingSlice = model.slices[0]
      #expect(!model.transcript.hasSelection)

      model.transcript.selectWords(
        anchorID: model.editPlan.words[1].id, focusID: model.editPlan.words[2].id)
      model.syncEditSession()
      #expect(model.editorKeyDown(.nudgeCutOutLater))
      // The nudge left no unsaved fine-tune draft behind...
      #expect(!model.fineTune.hasUnsavedChange)
      // ...so a fresh add and an existing-slice edit both stay available.
      #expect(model.canAddSlice)
      model.editSliceTapped(existingSlice.id)
      expectNoDifference(model.editSlice?.sliceID, existingSlice.id)
    }
  }

  /// A nudge on one selection followed by a fresh selection: the arrow keys keep working on the
  /// new selection (they always target the live `audioSelection`).
  @Test func nudgeKeysWorkOnAFreshSelectionAfterAPriorNudge() {
    let fileSystem = LockIsolated<[URL: Data]>([:])
    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let (model, _) = selectionEditor(fingerprint: "fp-nudge-fresh")
      model.syncEditSession()
      #expect(model.editorKeyDown(.nudgeCutOutLater))  // moves selection A

      model.transcript.selectWords(
        anchorID: model.editPlan.words[4].id, focusID: model.editPlan.words[5].id)
      model.syncEditSession()
      let selectionB = model.selectedSourceRange!

      #expect(model.editorKeyDown(.nudgeCutOutLater))
      expectNoDifference(
        model.selectedSourceRange, selectionB.lowerBound..<(selectionB.upperBound + 441))
    }
  }

  /// Clearing the selection after a nudge leaves nothing removable: `audioSelection` is nil, so
  /// Remove Section is (correctly) disabled and the fine-tune session clears with the selection.
  @Test func clearingASelectionAfterANudgeDisablesRemove() {
    let fileSystem = LockIsolated<[URL: Data]>([:])
    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let (model, _) = selectionEditor(fingerprint: "fp-nudge-clear")
      model.syncEditSession()
      #expect(model.editorKeyDown(.nudgeCutOutLater))

      model.transcript.clearSelectionTapped()
      model.syncEditSession()

      expectNoDifference(model.selectedSourceRange, nil)
      expectNoDifference(model.canRemoveSelectedSection, false)
      expectNoDifference(model.fineTune.target, nil)
    }
  }
}
