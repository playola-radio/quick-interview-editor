import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
@_spi(Internals) import Sharing
import Testing

@testable import QuickInterviewEditor

/// Suspends every `play` until released, so a test can hold a slice-edit playback "in flight"
/// (mirroring the transport's real suspended-`play` semantics) while it drives pause/resume.
private final class PlayGate: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [CheckedContinuation<PlaybackEnd, Never>] = []
  func play() async -> PlaybackEnd {
    await withCheckedContinuation { cont in
      lock.lock()
      continuations.append(cont)
      lock.unlock()
    }
  }
  func release(_ end: PlaybackEnd = .stopped) {
    lock.lock()
    let conts = continuations
    continuations = []
    lock.unlock()
    for cont in conts { cont.resume(returning: end) }
  }
}

@MainActor
struct EditorEditSlicePresentationTests {
  private func editor(_ plan: EditPlan = Fixtures.editPlan()) -> EditorModel {
    EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: plan)
  }

  private func selectWords(_ transcript: TranscriptPageModel, _ first: Int, _ last: Int) {
    transcript.transcriptDragBegan(
      atUTF16Offset: transcript.document.wordRanges[first].range.location)
    transcript.transcriptDragged(
      toUTF16Offset: transcript.document.wordRanges[last].range.location)
  }

  private func addSlice(_ model: EditorModel, _ first: Int, _ last: Int) {
    selectWords(model.transcript, first, last)
    model.addSliceTapped()
  }

  private func settle(until condition: () -> Bool) async {
    for _ in 0..<1000 where !condition() { await Task.yield() }
  }

  // MARK: - Presentation

  @Test func editSliceTappedPresentsModelForThatSlice() {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]

    model.editSliceTapped(slice.id)

    expectNoDifference(model.editSlice?.sliceID, slice.id)
    expectNoDifference(
      model.editSlice?.fineTune.committedRange, slice.startSample..<slice.endSample)
  }

  @Test func editSliceTappedIsANoOpWhenTheFineTunePaneHasAnUnsavedEdit() {
    let model = editor()
    addSlice(model, 0, 3)
    addSlice(model, 4, 5)
    let first = model.slices[0]
    let second = model.slices[1]
    model.sliceSelected(first.id)
    model.cutOutNudged(byMs: 10)  // dirty fine-tune pane edit
    #expect(model.fineTune.hasUnsavedChange)

    model.editSliceTapped(second.id)

    #expect(model.editSlice == nil)
  }

  @Test func editSliceTappedIsANoOpForAMissingSlice() {
    let model = editor()
    addSlice(model, 0, 3)

    model.editSliceTapped(UUID())

    #expect(model.editSlice == nil)
  }

  /// A slice sheet opened WHILE the waveform is still decoding adopts an empty lane (a one-time
  /// snapshot). Once the decode finishes, `loadWaveform` must re-seed that open sheet so its lane
  /// and fine-tune insets fill in — not stay blank for the sheet's lifetime (the regression the old
  /// live `columnsProvider` closure hid).
  @Test func openingModalMidDecodeReseedsTheLaneOnceTheWaveformLoads() async {
    let plan = Fixtures.editPlan()
    let fixture = Waveform.pyramid(
      baseMins: [0, -0.5], baseMaxs: [0.1, 0.8], sampleRate: plan.source.sampleRate,
      totalSamples: plan.source.durationSamples)

    await withDependencies {
      $0.waveform = WaveformClient(loadWaveform: { _, _, _ in fixture })
    } operation: {
      let model = editor(plan)
      addSlice(model, 0, 3)
      let slice = model.slices[0]

      model.editSliceTapped(slice.id)  // opened before the decode ran
      #expect(model.editSlice?.waveform.showsWaveform == false)

      await model.loadWaveform()  // decode completes

      #expect(model.editSlice?.waveform.showsWaveform == true)
      expectNoDifference(
        model.editSlice?.waveform.totalSamples, plan.source.durationSamples)
    }
  }

  /// The sheet's lane is pinned to the slice: once laid out it fits the slice edge-to-edge and
  /// cannot zoom out or scroll past the slice boundaries (only the slice is navigable).
  @Test func theSliceSheetLaneIsPinnedToTheSlice() async {
    let plan = Fixtures.editPlan()
    let fixture = Waveform.pyramid(
      baseMins: [0, -0.5], baseMaxs: [0.1, 0.8], sampleRate: plan.source.sampleRate,
      totalSamples: plan.source.durationSamples)

    await withDependencies {
      $0.waveform = WaveformClient(loadWaveform: { _, _, _ in fixture })
    } operation: {
      let model = editor(plan)
      await model.loadWaveform()
      addSlice(model, 0, 3)
      let slice = model.slices[0]
      model.editSliceTapped(slice.id)
      let lane = model.editSlice!.waveform
      lane.viewportResized(width: 1000)  // lay the lane out

      #expect(lane.canZoomOut == false)  // fit already shows the whole slice
      expectNoDifference(lane.visibleStartSample, slice.startSample)
      lane.scrolled(toStartSample: 0)  // try to scroll before the slice
      expectNoDifference(lane.visibleStartSample, slice.startSample)  // clamped to the slice start
    }
  }

  // MARK: - Stage 3: parent ⇄ modal timeline sync

  /// A removal on the MAIN timeline while the slice sheet is open fans into the sheet's collapsed
  /// lane immediately, and ⌘Z reverts it in the sheet too — the sheet and the main timeline share
  /// one GLOBAL `EditedTimeline` and never diverge.
  @Test func removalOnTheMainTimelineFansIntoTheOpenModalAndUndoRevertsBoth() async {
    let fileSystem = LockIsolated<[URL: Data]>([:])
    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let model = editor()
      addSlice(model, 0, 5)
      let slice = model.slices[0]
      model.editSliceTapped(slice.id)
      let child = model.editSlice!
      // opens matching the parent (none yet)
      #expect(child.editedWaveform.timeline.removals.isEmpty)

      selectWords(model.transcript, 1, 2)  // a removable span inside the slice
      await model.removeSelectedSectionTapped()

      expectNoDifference(
        child.editedWaveform.timeline.removals.map(\.id), Array(model.timelineRemovals.ids))
      #expect(child.editedWaveform.timeline.removals.count == 1)

      await model.undoTapped()  // ⌘Z reverts the removal
      #expect(child.editedWaveform.timeline.removals.isEmpty)  // and the sheet reverts with it
    }
  }

  // MARK: - Stage 4b: modal remove / restore routes through the parent funnels

  /// A Remove inside the sheet routes to the parent's `removeSourceRange` merge funnel: a marquee
  /// crossing an existing removal collapses BOTH into ONE union removal (full parity with the main
  /// timeline), it's a single ⌘Z, and Restore in the sheet reopens it — all through the same funnels
  /// the main editor uses, and every change fans back into the open sheet.
  @Test func modalRemoveMergesCrossSeamThroughTheParentAndRestoreReopens() async {
    let fileSystem = LockIsolated<[URL: Data]>([:])
    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let model = editor()
      addSlice(model, 0, 5)
      let slice = model.slices[0]
      model.editSliceTapped(slice.id)
      let child = model.editSlice!

      selectWords(model.transcript, 1, 2)  // seed one removal inside the slice
      await model.removeSelectedSectionTapped()
      #expect(model.timelineRemovals.count == 1)
      let seeded = model.timelineRemovals[0].removedRange

      // The sheet removes a span that straddles the seeded removal — the funnel unions them.
      let straddling = (seeded.lowerBound - 500)..<(seeded.upperBound + 500)
      await child.onRemoveSection(straddling)

      expectNoDifference(model.timelineRemovals.count, 1)  // merged, not a second removal
      expectNoDifference(model.timelineRemovals[0].removedRange, straddling)
      expectNoDifference(
        child.editedWaveform.timeline.removals.map(\.id), Array(model.timelineRemovals.ids))

      await model.undoTapped()  // one ⌘Z reverts the merge back to the seeded removal
      expectNoDifference(model.timelineRemovals.map(\.removedRange), [seeded])

      child.onRestore(model.timelineRemovals[0].id)  // Restore in the sheet reopens the audio
      #expect(model.timelineRemovals.isEmpty)
      #expect(child.editedWaveform.timeline.removals.isEmpty)
    }
  }

  // MARK: - Stage 4: crossfade stretch parity (modal == main editor)

  /// A crossfade stretch inside the sheet drives the SHARED document exactly like the same stretch on
  /// the main editor — same clamp, same committed crossfade, one ⌘Z — because both seed from the
  /// stored length and route through the parent's `updateCrossfade` funnel against the one synced
  /// timeline. This is the sync guarantee: an edit on the clip screen equals one on the main screen.
  @Test func stretchInTheSheetCommitsIdenticallyToTheMainEditor() async {
    let fileSystem = LockIsolated<[URL: Data]>([:])
    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let model = editor()
      addSlice(model, 0, 5)
      let slice = model.slices[0]
      model.editSliceTapped(slice.id)
      let child = model.editSlice!

      selectWords(model.transcript, 1, 2)  // seed one removal inside the slice
      await model.removeSelectedSectionTapped()
      let id = model.timelineRemovals[0].id
      let seededLength = model.timelineRemovals[id: id]!.crossfade.lengthSamples
      let target = seededLength / 2  // a real shrink, below the seeded default and any handle

      // Stretch on the MAIN editor and capture the committed crossfade.
      model.crossfadeStretchBegan(id: id)
      model.crossfadeStretched(toLength: target)
      model.crossfadeStretchEnded()
      let mainEditorCrossfade = model.timelineRemovals[id: id]?.crossfade
      #expect(mainEditorCrossfade?.lengthSamples != seededLength)  // a real change, not a no-op

      await model.undoTapped()  // revert to the seeded fade (one ⌘Z)
      expectNoDifference(model.timelineRemovals[id: id]?.crossfade.lengthSamples, seededLength)

      // The SAME stretch, driven from the SHEET, lands on the shared document identically.
      child.crossfadeStretchBegan(id: id)
      child.crossfadeStretched(toLength: target)
      child.crossfadeStretchEnded()

      expectNoDifference(model.timelineRemovals[id: id]?.crossfade, mainEditorCrossfade)
    }
  }

  /// PR #68 locked "an identical drag commits an identical length on both surfaces." This relaxes
  /// that invariant for the one case where the slice-local handle is shorter than the global one: a
  /// slice may never pull audio from outside its cut points, so when the global handle exceeds the
  /// slice-local handle the sheet commits the SLICE-LOCAL ceiling while the main editor still commits
  /// the higher global value. The main waveform shows/stores the global truth; that slice simply
  /// renders it shorter — which is what the slice plays.
  @Test func stretchInTheSheetClampsToTheSliceLocalCeilingWhenGlobalExceedsIt() async {
    let fileSystem = LockIsolated<[URL: Data]>([:])
    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let model = editor()
      addSlice(model, 1, 8)  // a slice that starts well into the recording (audio before it)
      let slice = model.slices[0]
      model.editSliceTapped(slice.id)
      let child = model.editSlice!

      selectWords(model.transcript, 2, 2)  // remove a word just inside the slice's start
      await model.removeSelectedSectionTapped()
      let id = model.timelineRemovals[0].id

      let sliceRange = slice.startSample..<slice.endSample
      let global = child.editedWaveform.timeline
      let globalMax = global.maxCrossfadeLength(forSeamID: id)!
      let localMax = SliceRenderPlanBuilder.localTimeline(
        sliceRange: sliceRange, removals: global.removals
      ).maxCrossfadeLength(forSeamID: id)!
      #expect(localMax < globalMax)  // the audio before the slice widens the global handle

      // MAIN editor: drag to the global ceiling and commit it.
      model.crossfadeStretchBegan(id: id)
      model.crossfadeStretched(toLength: globalMax)
      model.crossfadeStretchEnded()
      expectNoDifference(model.timelineRemovals[id: id]?.crossfade.lengthSamples, globalMax)

      await model.undoTapped()  // back to the seeded fade

      // SHEET: the SAME drag clamps to the shorter slice-local ceiling.
      child.crossfadeStretchBegan(id: id)
      child.crossfadeStretched(toLength: globalMax)
      child.crossfadeStretchEnded()
      expectNoDifference(model.timelineRemovals[id: id]?.crossfade.lengthSamples, localMax)
    }
  }

  /// A no-op stretch inside the sheet (grab a bowtie edge, release without moving) pushes no undo
  /// entry and never collapses the stored fade — the sheet seeds and compares against the stored
  /// length, so a length that renders clamped below what's stored is preserved, matching the main
  /// editor.
  @Test func noOpStretchInTheSheetPushesNoUndoEntry() async {
    let fileSystem = LockIsolated<[URL: Data]>([:])
    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let model = editor()
      addSlice(model, 0, 5)
      let slice = model.slices[0]
      model.editSliceTapped(slice.id)
      let child = model.editSlice!

      selectWords(model.transcript, 1, 2)
      await model.removeSelectedSectionTapped()
      let id = model.timelineRemovals[0].id
      let seededLength = model.timelineRemovals[id: id]!.crossfade.lengthSamples

      child.crossfadeStretchBegan(id: id)
      child.crossfadeStretchEnded()  // released without a drag

      expectNoDifference(model.timelineRemovals[id: id]?.crossfade.lengthSamples, seededLength)
      await model.undoTapped()  // the ONE real edit (the removal) undoes to empty
      #expect(model.timelineRemovals.isEmpty)
    }
  }

  /// Mid-export the parent's `updateCrossfade` funnel refuses, so the sheet must refuse to START a
  /// stretch too — the main lane's begin-time refusal, mirrored — instead of letting a drag preview
  /// and then vanish on release.
  @Test func stretchInTheSheetRefusesToStartMidExport() async {
    let fileSystem = LockIsolated<[URL: Data]>([:])
    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let model = editor()
      addSlice(model, 0, 5)
      let slice = model.slices[0]
      model.editSliceTapped(slice.id)
      let child = model.editSlice!

      selectWords(model.transcript, 1, 2)
      await model.removeSelectedSectionTapped()
      let id = model.timelineRemovals[0].id
      model.exportPhase = .exporting(current: 0, total: 1)

      child.crossfadeStretchBegan(id: id)

      expectNoDifference(child.crossfadeStretchDraft, nil)
    }
  }

  /// ⌘Z pressed INSIDE the sheet (forwarded by `SliceEditKeyMonitor` to `child.undoTapped`) rewinds
  /// the shared document and fans the restored timeline back into the open sheet — the modal removal
  /// is undoable without focus ever leaving the sheet.
  @Test func modalUndoRewindsTheRemovalAndReSyncsTheSheet() async {
    let fileSystem = LockIsolated<[URL: Data]>([:])
    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let model = editor()
      addSlice(model, 0, 5)
      let slice = model.slices[0]
      model.editSliceTapped(slice.id)
      let child = model.editSlice!

      selectWords(model.transcript, 1, 2)
      await child.onRemoveSection(model.selectedSourceRange!)
      #expect(model.timelineRemovals.count == 1)
      #expect(child.editedWaveform.timeline.removals.count == 1)

      await child.undoTapped()  // ⌘Z from within the sheet

      #expect(model.timelineRemovals.isEmpty)
      #expect(child.editedWaveform.timeline.removals.isEmpty)

      await child.redoTapped()  // ⌘⇧Z re-applies it, still synced both ways
      expectNoDifference(model.timelineRemovals.count, 1)
      expectNoDifference(child.editedWaveform.timeline.removals.count, 1)
    }
  }

  /// ⌘Z inside the sheet can rewind the slice's OWN creation. The restored document snapshot
  /// empties `slices`, so the sheet is now editing a slice that no longer exists — reconciliation
  /// must close the orphaned sheet rather than leave it acting on a missing range.
  @Test func undoingASlicesCreationFromInsideTheSheetClosesTheOrphanedSheet() async {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    model.editSliceTapped(slice.id)
    #expect(model.editSlice?.sliceID == slice.id)

    await model.undoTapped()  // ⌘Z rewinds the creation

    #expect(model.slices.isEmpty)
    #expect(model.editSlice == nil)
  }

  /// A ⌘Z routed through the sheet must NOT rewind the shared document while the sheet holds an
  /// unsaved boundary draft: that draft is the modal's deferred existing-slice edit, and undoing
  /// under it would desync the draft from a changed document. The undo no-ops until Save/Cancel —
  /// exactly as a docked draft blocks undo in the main editor.
  @Test func undoIsBlockedWhileTheSheetHoldsAnUnsavedDraft() async {
    let model = editor()
    addSlice(model, 0, 5)
    let slice = model.slices[0]
    model.editSliceTapped(slice.id)
    let child = model.editSlice!

    child.cutInNudgedForward()  // an unsaved boundary draft in the sheet
    #expect(child.fineTune.hasUnsavedChange)
    #expect(model.hasUncommittedSliceEdit)

    await model.undoTapped()  // blocked by the pending draft

    expectNoDifference(model.slices.count, 1)  // creation NOT rewound
    #expect(model.editSlice != nil)  // sheet stays open over its unchanged slice
  }

  /// ⌘Z can rewind a slice's BOUNDARY edit (not just its creation) while that slice's sheet is
  /// open. The slice survives but its range reverts under the modal, whose overview window and
  /// committed range were seeded once at open — a later Save would recommit the stale range. Close
  /// the sheet instead. A modal REMOVAL undo (which leaves the slice's own bounds untouched) must
  /// NOT trip this — that case stays open and re-syncs, covered above.
  @Test func undoingASlicesBoundaryEditClosesTheSheetEditingThatSlice() async {
    let model = editor()
    addSlice(model, 0, 5)
    let slice = model.slices[0]
    let originalRange = slice.startSample..<slice.endSample

    // Save a boundary change through the docked pane (one undo entry).
    model.sliceSelected(slice.id)
    model.cutOutNudged(byMs: 10)
    model.commitEditTapped()
    let committedRange =
      model.slices[id: slice.id]!.startSample..<model.slices[id: slice.id]!.endSample
    #expect(committedRange != originalRange)  // the boundary actually moved

    model.editSliceTapped(slice.id)  // open the modal on the edited slice
    #expect(model.editSlice?.fineTune.committedRange == committedRange)

    await model.undoTapped()  // ⌘Z reverts the boundary edit

    expectNoDifference(
      model.slices[id: slice.id].map { $0.startSample..<$0.endSample }, originalRange)
    #expect(model.editSlice == nil)  // closed rather than left editing the stale range
  }

  // MARK: - Save / cancel round-trip

  @Test func modalSaveCommitsThroughEditorAndDismisses() {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    model.editSliceTapped(slice.id)
    let child = model.editSlice!
    let depthBefore = model.documentUndo.undo.count

    child.fineTune.nudgeCutIn(byMs: 30)
    let draft = child.fineTune.draftRange!
    child.saveTapped()

    expectNoDifference(model.slices[id: slice.id]?.startSample, draft.lowerBound)
    #expect(model.editSlice == nil)
    // Global invariant: commit → exactly one undo entry, even through the modal's save path.
    expectNoDifference(model.documentUndo.undo.count, depthBefore + 1)
  }

  @Test func modalCancelDismissesWithoutCommitting() {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    let before = model.slices
    model.editSliceTapped(slice.id)
    let child = model.editSlice!

    child.fineTune.nudgeCutIn(byMs: 30)
    child.cancelTapped()

    expectNoDifference(model.slices, before)
    #expect(model.editSlice == nil)
  }

  // MARK: - Seek (R4: seek moves the persistent cursor, it does not re-anchor playback)

  @Test func seekMovesThePersistentCursorAndReflectsInTheModal() async {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    model.editSliceTapped(slice.id)
    let child = model.editSlice!
    let target = slice.startSample + 500

    await child.seekTapped(toSample: target)

    expectNoDifference(model.playheadEditedSample, target)
    expectNoDifference(model.editSlice?.playheadSample, target)
    expectNoDifference(model.transportPhase, .stopped)
  }

  /// Stop returns the cursor to the play origin AND publishes it to the sheet, so the sheet's next
  /// "play from the playhead" starts at the origin, not the stale last-tick sample.
  @Test func stopPublishesTheOriginCursorBackToTheModal() async {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    model.editSliceTapped(slice.id)
    let child = model.editSlice!
    model.transportContext = .sliceEdit
    model.transportPhase = .playing(PlaybackSessionID())
    model.transportOriginEditedSample = slice.startSample
    child.updatePlayback(sample: slice.startSample + 5_000, isPlaying: true)  // ticked mid-slice

    await withDependencies {
      $0.audioPlayer.stop = { _ in }
    } operation: {
      await child.stopTapped()
    }

    // back at the origin, not the mid-slice sample the last tick reported
    expectNoDifference(child.playheadSample, slice.startSample)
    #expect(child.isPlaying == false)
  }

  // MARK: - Playhead push during `.sliceEdit` playback

  @Test func observePlaybackPushesPlayingPositionIntoTheModalDuringSliceEdit() async {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    model.editSliceTapped(slice.id)
    let session = PlaybackSessionID()
    model.transportContext = .sliceEdit
    model.transportPhase = .playing(session)
    let (stream, continuation) = AsyncStream.makeStream(of: PlaybackPosition.self)

    await withDependencies {
      $0.audioPlayer.positions = { stream }
    } operation: {
      let task = Task { await model.observePlayback() }
      continuation.yield(
        PlaybackPosition(
          sessionID: session, sample: .source(slice.startSample + 200), isPlaying: true))
      await settle { model.editSlice?.playheadSample == slice.startSample + 200 }

      expectNoDifference(model.playheadEditedSample, slice.startSample + 200)
      expectNoDifference(model.editSlice?.playheadSample, slice.startSample + 200)
      #expect(model.editSlice?.isPlaying == true)

      continuation.finish()
      await task.value
    }
  }

  // MARK: - Modal transport: resume, range-drift, natural finish, open-supersede

  /// Logic model: Pause freezes the playhead; the next Play re-plays FROM THE PLAYHEAD (a fresh
  /// exclusive play), never a bespoke resume. Verifies `play` is re-invoked at the pause point and
  /// `resume` is never used.
  @Test func modalPlayAfterPauseReplaysFromThePlayhead() async {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    model.editSliceTapped(slice.id)
    let child = model.editSlice!
    let gate = PlayGate()
    let ranges = LockIsolated<[Range<Int>]>([])
    let resumes = LockIsolated(0)
    let pausePoint = slice.startSample + 500

    await withDependencies {
      $0.audioPlayer.play = { _, range, _, _, _ in
        ranges.withValue { $0.append(range) }
        return await gate.play()
      }
      $0.audioPlayer.pause = { _ in .source(pausePoint) }  // pause lands the cursor mid-slice
      $0.audioPlayer.resume = { _ in
        resumes.withValue { $0 += 1 }
        return true
      }
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      let play = Task { await child.playPauseTapped() }  // begins the .sliceEdit play (suspends)
      await settle { ranges.value.count == 1 && child.isPlaying }

      await child.playPauseTapped()  // pause -> cursor frozen at pausePoint
      #expect(model.isTransportPaused)
      #expect(child.isPlaying == false)

      let replay = Task { await child.playPauseTapped() }  // play again -> fresh play from playhead
      await settle { ranges.value.count == 2 }

      expectNoDifference(resumes.value, 0)  // no bespoke resume path anymore
      expectNoDifference(ranges.value.last?.lowerBound, pausePoint)  // re-plays from the playhead

      gate.release()  // let both suspended plays unwind
      await play.value
      await replay.value
    }
  }

  /// A draft nudge while paused likewise re-plays fresh (every Pause→Play restarts now).
  @Test func modalPlayAfterPauseWithADriftedDraftRestarts() async {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    model.editSliceTapped(slice.id)
    let child = model.editSlice!
    let gate = PlayGate()
    let plays = LockIsolated(0)
    let resumes = LockIsolated(0)

    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _, _ in
        plays.withValue { $0 += 1 }
        return await gate.play()
      }
      $0.audioPlayer.pause = { _ in .source(500) }
      $0.audioPlayer.resume = { _ in
        resumes.withValue { $0 += 1 }
        return true
      }
      $0.audioPlayer.stop = { _ in gate.release() }
    } operation: {
      let play1 = Task { await child.playPauseTapped() }
      await settle { plays.value == 1 && child.isPlaying }

      await child.playPauseTapped()  // pause
      child.fineTune.nudgeCutIn(byMs: 20)  // the draft range drifts

      let play2 = Task { await child.playPauseTapped() }  // must restart, not resume
      await settle { plays.value == 2 }

      expectNoDifference(plays.value, 2)
      expectNoDifference(resumes.value, 0)

      gate.release()
      await play1.value
      await play2.value
    }
  }

  /// FIX 4: a natural finish returns from the suspended `play` await; the parent must publish the
  /// stopped state back to the modal so its Play/Pause button doesn't stay stuck on "Pause".
  @Test func naturalFinishPublishesStoppedBackToTheModal() async {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    model.editSliceTapped(slice.id)
    let child = model.editSlice!

    await withDependencies {
      $0.audioPlayer.play = { _, _, _, _, _ in .finished }  // completes immediately
    } operation: {
      await child.playPauseTapped()  // starts the play, which finishes right away

      #expect(child.isPlaying == false)
      expectNoDifference(model.transportPhase, .stopped)
    }
  }

  /// FIX 1 (dismiss→reopen race): a stale sheet `onDismiss` callback that fires after a new modal
  /// has taken over must NOT tear down the new modal's transport.
  @Test func sheetDismissCallbackSkipsWhenANewModalIsAlreadyPresent() async {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    let newSession = PlaybackSessionID()
    model.editSliceTapped(slice.id)  // "new" modal already present
    model.transportContext = .sliceEdit
    model.transportPhase = .playing(newSession)
    let stopped = LockIsolated<PlaybackSessionID?>(nil)

    await withDependencies {
      $0.audioPlayer.stop = { stopped.setValue($0) }
    } operation: {
      model.sliceEditSheetDismissed()  // stale callback for the PREVIOUS modal

      expectNoDifference(model.transportPhase, .playing(newSession))  // untouched
      for _ in 0..<5 { await Task.yield() }  // give any errant stop task a chance to run
      #expect(stopped.value == nil)
    }
  }

  /// FIX 2/3: opening the modal must stop a PAUSED main transport (not just a playing one), and
  /// must stop only the captured session so a late stop can't kill a newer `.sliceEdit` session.
  @Test func openingModalStopsAPausedMainTransport() async {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    let mainSession = PlaybackSessionID()
    model.transportContext = .free
    model.transportPhase = .paused(mainSession)
    model.transportOriginEditedSample = 100
    let stopped = LockIsolated<PlaybackSessionID?>(nil)

    await withDependencies {
      $0.audioPlayer.stop = { stopped.setValue($0) }
    } operation: {
      model.editSliceTapped(slice.id)

      expectNoDifference(model.transportPhase, .stopped)  // reset synchronously on open
      #expect(model.editSlice != nil)
      await settle { stopped.value != nil }
      expectNoDifference(stopped.value, mainSession)  // only the captured session stopped
    }
  }

  @Test func observePlaybackPushesTheStoppedTickIntoTheModalDuringSliceEdit() async {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    model.editSliceTapped(slice.id)
    let session = PlaybackSessionID()
    model.transportContext = .sliceEdit
    model.transportPhase = .playing(session)
    let (stream, continuation) = AsyncStream.makeStream(of: PlaybackPosition.self)

    await withDependencies {
      $0.audioPlayer.positions = { stream }
    } operation: {
      let task = Task { await model.observePlayback() }
      continuation.yield(
        PlaybackPosition(
          sessionID: session, sample: .source(slice.startSample + 200), isPlaying: true))
      await settle { model.editSlice?.playheadSample == slice.startSample + 200 }

      continuation.yield(
        PlaybackPosition(
          sessionID: session, sample: .source(slice.startSample + 200), isPlaying: false))
      await settle { model.editSlice?.isPlaying == false }

      #expect(model.editSlice?.isPlaying == false)
      expectNoDifference(model.editSlice?.playheadSample, model.playheadEditedSample)

      continuation.finish()
      await task.value
    }
  }
}
