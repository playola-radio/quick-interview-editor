import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

/// Suspends a single caller until `release()`, for putting a transport action's `onStop`/`onPause`
/// mid-flight so a second action can race it. Mirrors `EditorSlicePlaybackTests`'s `PlayGate`,
/// but buffers an early `release()` — if the scheduler hasn't parked the suspending task yet
/// (a lone `Task.yield()` doesn't guarantee it), the release is remembered instead of dropped,
/// so `suspend()` returns immediately and the test can't hang.
private actor VoidGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var bufferedReleases = 0
  func suspend() async {
    if bufferedReleases > 0 {
      bufferedReleases -= 1
      return
    }
    await withCheckedContinuation { continuation = $0 }
  }
  func release() {
    if let continuation {
      continuation.resume()
      self.continuation = nil
    } else {
      bufferedReleases += 1
    }
  }
}

@MainActor
struct EditSliceTests {
  private func makeModel() -> (EditSliceModel, Slice) {
    let plan = Fixtures.editPlan()
    let slice = Slice(
      id: UUID(), name: "Slice 1",
      startSample: 10_000, endSample: 40_000,
      wordIDs: [], snippet: "")
    return (EditSliceModel(slice: slice, editPlan: plan), slice)
  }

  @Test func openingBeginsSessionOnCommittedRange() {
    let (model, slice) = makeModel()
    expectNoDifference(model.fineTune.committedRange, slice.startSample..<slice.endSample)
    expectNoDifference(model.fineTune.draftRange, slice.startSample..<slice.endSample)
    #expect(model.canSave == false)  // no change yet
  }

  @Test func draggingMutatesDraftOnly_savingCommitsOnce() {
    let (model, _) = makeModel()
    var committed: [Range<Int>] = []
    model.onCommit = { committed.append($0) }

    model.fineTune.nudgeCutIn(byMs: 10)  // move the draft
    #expect(model.canSave == true)
    let draft = model.fineTune.draftRange

    model.saveTapped()

    expectNoDifference(committed, [draft].compactMap { $0 })
  }

  @Test func cancelDoesNotCommit_andDismisses() {
    let (model, _) = makeModel()
    var committed = 0
    var dismissed = 0
    model.onCommit = { _ in committed += 1 }
    model.onDismiss = { dismissed += 1 }

    model.fineTune.nudgeCutOut(byMs: -10)
    model.cancelTapped()

    #expect(committed == 0)
    #expect(dismissed == 1)
  }

  @Test func scopedTranscriptContainsExactlyTheSliceWords() {
    let plan = Fixtures.editPlan()
    let sliceWordIDs = Array(plan.words.prefix(3).map(\.id))
    let slice = Slice(
      id: UUID(), name: "S", startSample: 0, endSample: 20_000,
      wordIDs: sliceWordIDs, snippet: "")
    let model = EditSliceModel(slice: slice, editPlan: plan)

    expectNoDifference(
      model.transcript.document.wordRanges.map(\.wordID), sliceWordIDs)
  }

  @Test func overviewWindowIsTheCommittedSliceRange() {
    let plan = Fixtures.editPlan()
    let slice = Slice(
      id: UUID(), name: "S", startSample: 5_000, endSample: 25_000,
      wordIDs: [], snippet: "")
    let model = EditSliceModel(slice: slice, editPlan: plan)
    #expect(model.overviewWindow == 5_000..<25_000)
  }

  @Test func playTappedPlaysTheDraftRange() async {
    let (model, slice) = makeModel()
    var played: [Range<Int>] = []
    model.onPlay = { played.append($0) }

    await model.playPauseTapped()

    expectNoDifference(played, [slice.startSample..<slice.endSample])
  }

  @Test func playTappedUsesTheLiveDraftAfterNudging() async {
    let (model, _) = makeModel()
    var played: [Range<Int>] = []
    model.onPlay = { played.append($0) }
    model.fineTune.nudgeCutIn(byMs: 20)
    let draft = model.fineTune.draftRange

    await model.playPauseTapped()

    expectNoDifference(played, [draft].compactMap { $0 })
  }

  @Test func playStartsFromThePlayheadWhenTheCursorIsInsideTheSlice() async {
    let (model, slice) = makeModel()
    var played: [Range<Int>] = []
    model.onPlay = { played.append($0) }
    model.playheadSample = slice.startSample + 5_000  // cursor parked mid-slice

    await model.playPauseTapped()

    expectNoDifference(played, [(slice.startSample + 5_000)..<slice.endSample])
  }

  @Test func playFallsBackToTheCutInWhenTheCursorIsOutsideTheSlice() async {
    let (model, slice) = makeModel()
    var played: [Range<Int>] = []
    model.onPlay = { played.append($0) }
    model.playheadSample = slice.endSample + 10_000  // cursor past the slice

    await model.playPauseTapped()

    expectNoDifference(played, [slice.startSample..<slice.endSample])
  }

  @Test func seekWhilePlayingReAnchorsPlaybackToTheClick() async {
    let model = laneModel()  // slice 10_000..<20_000, spp 10, start 10_000
    var played: [Range<Int>] = []
    var sought: [Int] = []
    model.onPlay = { played.append($0) }
    model.onSeek = { sought.append($0) }
    model.updatePlayback(sample: 12_000, isPlaying: true)

    await model.waveformSeeked(toX: 150)  // 10_000 + 150*10 = sample 11_500, inside the slice

    expectNoDifference(played, [11_500..<20_000])  // keeps playing from the click to the cut-out
    #expect(sought.isEmpty)  // it re-anchors, it does not merely reposition
  }

  @Test func seekAtTheCutOutWhilePlayingStopsInsteadOfLeavingPlaybackRunning() async {
    let model = laneModel()  // slice 10_000..<20_000, spp 10, start 10_000
    var played: [Range<Int>] = []
    var sought: [Int] = []
    var stops = 0
    model.onPlay = { played.append($0) }
    model.onSeek = { sought.append($0) }
    model.onStop = { stops += 1 }
    model.updatePlayback(sample: 12_000, isPlaying: true)

    await model.waveformSeeked(toX: 1000)  // 10_000 + 1000*10, pin clamps to the cut-out (20_000)

    #expect(stops == 1)  // stops rather than leaving playback running past the click
    expectNoDifference(sought, [20_000])  // parks the cursor at the cut-out
    #expect(played.isEmpty)  // does not re-anchor to an empty range
  }

  @Test func rulerDragWhilePlayingRepositionsCursorWithoutReAnchoring() async {
    let model = laneModel()  // slice 10_000..<20_000, spp 10, start 10_000
    var played: [Range<Int>] = []
    var sought: [Int] = []
    model.onPlay = { played.append($0) }
    model.onSeek = { sought.append($0) }
    model.updatePlayback(sample: 12_000, isPlaying: true)

    await model.waveformDragged(toX: 150)  // sample 11_500

    expectNoDifference(sought, [11_500])  // cursor-only — a ruler scrub never restarts playback
    #expect(played.isEmpty)
  }

  @Test func seekWhilePausedRepositionsWithoutReplaying() async {
    let model = laneModel()  // slice 10_000..<20_000, spp 10, start 10_000
    var played: [Range<Int>] = []
    var sought: [Int] = []
    model.onPlay = { played.append($0) }
    model.onSeek = { sought.append($0) }
    // not playing (paused/stopped)

    await model.waveformSeeked(toX: 150)  // sample 11_500

    expectNoDifference(sought, [11_500])  // just moves the cursor
    #expect(played.isEmpty)  // no playback started
  }

  @Test func playTappedWhilePlayingPauses() async {
    let (model, _) = makeModel()
    var pauses = 0
    model.onPause = { pauses += 1 }
    model.updatePlayback(sample: 12_000, isPlaying: true)

    await model.playPauseTapped()

    #expect(pauses == 1)
  }

  @Test func updatePlaybackReflectsPlayheadAndDrivesScopedTranscript() {
    let (model, _) = makeModel()
    model.updatePlayback(sample: 15_000, isPlaying: true)
    #expect(model.playheadSample == 15_000)
    #expect(model.isPlaying == true)
  }

  // MARK: - FIX 1: isPlaying resets on Pause/Stop (the modal's play/pause button no longer wedges)

  @Test func pauseTappedResetsIsPlaying() async {
    let (model, _) = makeModel()
    model.updatePlayback(sample: 12_000, isPlaying: true)

    await model.playPauseTapped()  // isPlaying, so this pauses

    #expect(model.isPlaying == false)
  }

  @Test func stopTappedResetsIsPlaying() async {
    let (model, _) = makeModel()
    model.updatePlayback(sample: 12_000, isPlaying: true)

    await model.stopTapped()

    #expect(model.isPlaying == false)
  }

  @Test func stopTappedDelegatesToOnStop() async {
    let (model, _) = makeModel()
    var stops = 0
    model.onStop = { stops += 1 }
    model.updatePlayback(sample: 12_000, isPlaying: true)

    await model.stopTapped()

    #expect(stops == 1)
    #expect(model.isPlaying == false)
  }

  @Test func returnToStartTappedSeeksToTheCutInWhilePaused() async {
    let (model, slice) = makeModel()
    var sought: [Int] = []
    model.onSeek = { sought.append($0) }

    await model.returnToStartTapped()

    expectNoDifference(sought, [slice.startSample])
  }

  @Test func returnToStartTappedUsesTheLiveDraftCutInAfterNudging() async {
    let (model, _) = makeModel()
    var sought: [Int] = []
    model.onSeek = { sought.append($0) }
    model.fineTune.nudgeCutIn(byMs: 20)
    let cutIn = model.fineTune.draftRange?.lowerBound

    await model.returnToStartTapped()

    expectNoDifference(sought, [cutIn].compactMap { $0 })
  }

  @Test func returnToStartTappedWhilePlayingReAnchorsToTheCutIn() async {
    let model = laneModel()  // slice 10_000..<20_000
    var played: [Range<Int>] = []
    var sought: [Int] = []
    model.onPlay = { played.append($0) }
    model.onSeek = { sought.append($0) }
    model.updatePlayback(sample: 15_000, isPlaying: true)

    await model.returnToStartTapped()

    expectNoDifference(played, [10_000..<20_000])  // restarts from the cut-in
    #expect(sought.isEmpty)  // it re-anchors, it does not merely reposition
  }

  @Test func seekTappedForwardsTheRequestedSampleToOnSeek() async {
    let (model, _) = makeModel()
    var sought: [Int] = []
    model.onSeek = { sought.append($0) }

    await model.seekTapped(toSample: 23_456)

    expectNoDifference(sought, [23_456])
  }

  /// The parent publishes a natural finish back through `updatePlayback`; the modal must reflect
  /// it as stopped. Guards the FIX 1/4 regression where `isPlaying` was set true AFTER `onPlay`
  /// (which returns only once playback has ended), leaving the button stuck on "Pause".
  @Test func parentPublishingAStoppedTickClearsIsPlaying() {
    let (model, _) = makeModel()
    model.updatePlayback(sample: 12_000, isPlaying: true)
    #expect(model.isPlaying == true)

    model.updatePlayback(sample: 12_000, isPlaying: false)

    #expect(model.isPlaying == false)
  }

  @Test func playTappedFromStoppedSetsIsPlayingAndPlaysTheDraftRange() async {
    let (model, slice) = makeModel()
    var played: [Range<Int>] = []
    model.onPlay = { played.append($0) }

    await model.playPauseTapped()  // not playing, so this plays

    #expect(model.isPlaying == true)
    expectNoDifference(played, [slice.startSample..<slice.endSample])
  }

  // MARK: - Boundary inset playhead (the fixed-window cursor line on the red Cut-in / Cut-out insets)

  @Test func noInsetPlayheadWithoutACursor() {
    let (model, _) = makeModel()
    #expect(model.cutInPlayheadX == nil)
    #expect(model.cutOutPlayheadX == nil)
  }

  /// The cursor maps into the cut-in inset's fixed window exactly like the cut line does: slice
  /// 10_000..<40_000, sr 44_100 -> 175 samples/inset-px, window centered on the committed cut-in, so
  /// the boundary itself sits at the inset center (126 px) and 1_750 samples right of it is +10 px.
  @Test func cutInPlayheadMapsTheCursorIntoTheFixedInsetWindow() {
    let (model, _) = makeModel()
    model.playheadSample = 11_750
    expectNoDifference(model.cutInPlayheadX, 136)
    #expect(model.cutOutPlayheadX == nil)  // the cursor is outside the cut-out window
  }

  /// The cut-out inset is centered on the committed cut-out (40_000), so a cursor there is centered
  /// (126 px); the same cursor is outside the cut-in window and draws no cut-in playhead.
  @Test func cutOutPlayheadMapsTheCursorIntoTheFixedInsetWindow() {
    let (model, _) = makeModel()
    model.playheadSample = 40_000
    expectNoDifference(model.cutOutPlayheadX, 126)
    #expect(model.cutInPlayheadX == nil)
  }

  // MARK: - Waveform lane (the sheet's own EDITED adapter, pinned to the slice; insets still edit)

  /// A model whose collapsed lane is seeded and laid out with predictable geometry, so view-x ↔
  /// sample mapping is exact. The source pyramid is adopted (so the adapter's geometry is usable),
  /// then the pinned lane is laid out: slice 10_000..<20_000 (10_000 wide) over 1000 px -> fit
  /// spp 10, visibleStart 10_000. With no removals the timeline is identity, so edited == source.
  private func laneModel() -> EditSliceModel {
    let plan = Fixtures.editPlan()
    let slice = Slice(
      id: UUID(), name: "S", startSample: 10_000, endSample: 20_000,
      wordIDs: [], snippet: "")
    let model = EditSliceModel(slice: slice, editPlan: plan)
    model.waveform.totalSamples = 100_000
    model.waveform.waveform = Waveform.pyramid(
      baseMins: [0], baseMaxs: [0], sampleRate: 44100,
      totalSamples: 100_000, baseBucketSize: 100_000)
    model.editedWaveform.viewportResized(width: 1000)
    return model
  }

  @Test func laneRendersOnTheEditedAdapterPinnedToTheSlice() {
    let model = laneModel()
    #expect(model.editedWaveform.hasUsableGeometry)
    // Pinned to the 10_000-wide slice over 1000 px: fit fills the slice edge-to-edge and cannot
    // scroll before its start.
    expectNoDifference(model.editedWaveform.samplesPerPixel, 10)
    expectNoDifference(model.editedWaveform.visibleStartSample, 10_000)
  }

  @Test func laneCursorMapsTheSourceCursorOntoTheEditedAxis() {
    let model = laneModel()
    #expect(model.laneCursorSample == nil)  // no cursor yet
    model.updatePlayback(sample: 15_000, isPlaying: true)
    // Identity timeline (no removals): the edited cursor equals the stored source sample.
    #expect(model.laneCursorSample == 15_000)
  }

  @Test func highlightRangeTracksTheLiveDraftRange() {
    let (model, slice) = makeModel()
    expectNoDifference(model.waveformHighlightRange, slice.startSample..<slice.endSample)
    model.fineTune.nudgeCutIn(byMs: 20)
    expectNoDifference(model.waveformHighlightRange, model.fineTune.draftRange)
  }

  @Test func waveformSeekedMapsXToSampleAndForwardsToOnSeek() async {
    let model = laneModel()  // window 10_000..<20_000, spp 10, start 10_000
    var sought: [Int] = []
    model.onSeek = { sought.append($0) }

    await model.waveformSeeked(toX: 150)  // 10_000 + 150 px * 10 spp = sample 11_500

    expectNoDifference(sought, [11_500])
  }

  @Test func waveformSeekedClampsInsideTheSliceBeingEdited() async {
    let model = laneModel()  // window 10_000..<20_000, pinned lane
    var sought: [Int] = []
    model.onSeek = { sought.append($0) }

    await model.waveformSeeked(toX: 0)  // left edge -> the pin holds it at the slice start
    await model.waveformSeeked(toX: 2000)  // far past the slice -> clamps to the cut-out

    expectNoDifference(sought, [10_000, 20_000])
  }

  @Test func waveformSeekedIsANoOpWithoutUsableGeometry() async {
    let (model, _) = makeModel()  // lane never seeded/laid out
    var sought: [Int] = []
    model.onSeek = { sought.append($0) }

    await model.waveformSeeked(toX: 150)

    #expect(sought.isEmpty)
  }

  @Test func zoomButtonsForwardToTheLane() {
    let model = laneModel()  // fit spp 10; the min-samples-per-pixel floor is 8
    model.zoomInTapped()  // 10 -> 5 desired, clamped to the floor 8
    expectNoDifference(model.editedWaveform.samplesPerPixel, 8)
    model.zoomOutTapped()  // 8 -> 16 desired, clamped back to fit 10
    expectNoDifference(model.editedWaveform.samplesPerPixel, 10)
  }

  @Test func zoomFitTogglesAgainstTheSlice() {
    let model = laneModel()  // slice 10_000..<20_000, fit spp 10
    model.zoomInTapped()  // spp 8 (floor), so a fit is a visible change
    // fit the whole slice (10_000..<20_000, 10_000 wide over 1000 px) -> spp 10
    model.zoomFitTapped()
    expectNoDifference(model.editedWaveform.samplesPerPixel, 10)
    model.zoomFitTapped()  // same slice -> restore the pre-fit zoom
    expectNoDifference(model.editedWaveform.samplesPerPixel, 8)
  }

  // MARK: - Stage 3: parent → modal timeline sync (re-pin + cursor remap)

  /// `syncTimeline` seeds the collapsed lane with the parent's GLOBAL timeline, then re-pins to the
  /// slice's now-shorter edited extent: a 3_000-sample removal inside the 10_000-wide slice shrinks
  /// its edited span to 7_000, so the fit re-clamps to spp 7 — still anchored at the slice start.
  @Test func syncTimelineCollapsesThePinnedLaneForARemovalInsideTheSlice() {
    let model = laneModel()  // slice 10_000..<20_000, identity, fit spp 10
    expectNoDifference(model.editedWaveform.samplesPerPixel, 10)

    let removal = TimelineRemoval(
      id: UUID(), removedRange: 12_000..<15_000, crossfade: Crossfade(lengthSamples: 0))
    model.syncTimeline(EditedTimeline(sourceDurationSamples: 100_000, removals: [removal]))

    expectNoDifference(model.editedWaveform.timeline.removals.map(\.id), [removal.id])
    expectNoDifference(model.editedWaveform.samplesPerPixel, 7)  // 7_000 wide over 1000 px
    // still pinned to the start
    expectNoDifference(model.editedWaveform.visibleStartSample, 10_000)
  }

  /// The cursor is stored as a GLOBAL source sample and mapped live through the current timeline, so
  /// a removal ahead of it slides it left on the collapsed axis without any bespoke remap: source
  /// 18_000 with 3_000 removed before it resolves to edited 15_000.
  @Test func syncTimelineRemapsTheCursorOntoTheCollapsedAxis() {
    let model = laneModel()
    model.updatePlayback(sample: 18_000, isPlaying: false)
    expectNoDifference(model.laneCursorSample, 18_000)  // identity so far

    let removal = TimelineRemoval(
      id: UUID(), removedRange: 12_000..<15_000, crossfade: Crossfade(lengthSamples: 0))
    model.syncTimeline(EditedTimeline(sourceDurationSamples: 100_000, removals: [removal]))

    expectNoDifference(model.laneCursorSample, 15_000)
  }

  /// A parent restore/undo can retire the seam this sheet had selected. `syncTimeline` must drop the
  /// stale selection before the lane reads it, or ⌫ would restore a removal the timeline no longer
  /// has (the `removeSectionKeyPressed` seam branch).
  @Test func syncTimelineDropsAStaleSeamSelection() {
    let model = laneModel()
    let removal = TimelineRemoval(
      id: UUID(), removedRange: 12_000..<15_000, crossfade: Crossfade(lengthSamples: 0))
    model.syncTimeline(EditedTimeline(sourceDurationSamples: 100_000, removals: [removal]))
    _ = model.waveformContextMenuItems(atX: model.seamOverlays[0].span.positionX)
    #expect(model.selectedSeamID == removal.id)

    // The parent restores the removal: the synced timeline no longer contains that seam.
    model.syncTimeline(EditedTimeline(sourceDurationSamples: 100_000, removals: []))

    expectNoDifference(model.selectedSeamID, nil)
  }

  /// Same reconciliation for a live stretch draft: if the parent retires the seam mid-drag, the
  /// orphaned draft (which would preview a gone seam) is dropped on the next sync.
  @Test func syncTimelineDropsAStaleStretchDraft() {
    let model = laneModel()
    let removal = TimelineRemoval(
      id: UUID(), removedRange: 12_000..<15_000, crossfade: Crossfade(lengthSamples: 600))
    model.currentCrossfadeLength = { $0 == removal.id ? 600 : nil }
    model.syncTimeline(EditedTimeline(sourceDurationSamples: 100_000, removals: [removal]))
    model.crossfadeStretchBegan(id: removal.id)
    model.crossfadeStretched(toLength: 1_200)
    #expect(model.crossfadeStretchDraft != nil)

    model.syncTimeline(EditedTimeline(sourceDurationSamples: 100_000, removals: []))

    expectNoDifference(model.crossfadeStretchDraft, nil)
  }

  /// The guard also fires when an undo/redo changes the dragged seam's crossfade length (not just
  /// removes it): the draft's baseline no longer matches the fanned timeline, so releasing it would
  /// rewrite the restored value — the sync must drop the stale draft.
  @Test func syncTimelineDropsADraftWhenTheSeamLengthChangesUnderIt() {
    let model = laneModel()
    let id = UUID()
    let removal = TimelineRemoval(
      id: id, removedRange: 12_000..<15_000, crossfade: Crossfade(lengthSamples: 600))
    model.currentCrossfadeLength = { $0 == id ? 600 : nil }
    model.syncTimeline(EditedTimeline(sourceDurationSamples: 100_000, removals: [removal]))
    model.crossfadeStretchBegan(id: id)
    model.crossfadeStretched(toLength: 1_200)
    #expect(model.crossfadeStretchDraft != nil)

    // The parent reverts the seam to a different committed length under the live drag.
    let reverted = TimelineRemoval(
      id: id, removedRange: 12_000..<15_000, crossfade: Crossfade(lengthSamples: 900))
    model.syncTimeline(EditedTimeline(sourceDurationSamples: 100_000, removals: [reverted]))

    expectNoDifference(model.crossfadeStretchDraft, nil)
  }

  // MARK: - FIX 2: updatePlayback highlights the current word in the scoped transcript

  @Test func updatePlaybackHighlightsTheCurrentWordInTheScopedTranscript() {
    let plan = Fixtures.editPlan()
    let sliceWordIDs = Array(plan.words.prefix(3).map(\.id))
    let slice = Slice(
      id: UUID(), name: "S", startSample: 0, endSample: 20_000,
      wordIDs: sliceWordIDs, snippet: "")
    let model = EditSliceModel(slice: slice, editPlan: plan)
    let targetWord = plan.words.first { $0.id == sliceWordIDs[1] }!
    let sampleInsideWord = targetWord.startSample!

    model.updatePlayback(sample: sampleInsideWord, isPlaying: true)

    expectNoDifference(model.transcript.currentWordID, targetWord.id)
  }

  // MARK: - Stage 4b: modal marquee → remove / restore (routed to the parent funnels)

  /// A body drag on the collapsed lane builds a removal marquee: begin+change map view-x to source
  /// samples (window 10_000..<20_000, spp 10), so the selection is 11_000..<13_000, the highlight
  /// tracks it, and Remove is enabled.
  @Test func marqueeDragBuildsARemovalSelection() {
    let model = laneModel()
    model.waveformAreaSelectBegan(atX: 100, extending: false)  // 10_000 + 100*10
    model.waveformAreaSelectChanged(toX: 300)  // 10_000 + 300*10
    model.waveformAreaSelectEnded(toX: 300)

    expectNoDifference(model.waveformSelection, 11_000..<13_000)
    expectNoDifference(model.waveformHighlightRange, 11_000..<13_000)
    #expect(model.canRemoveSelection)
  }

  /// A marquee whose anchor AND focus both land on the slice's exclusive upper bound (the lane's
  /// right edge, where `clampedToWindow` is inclusive) must not escape the slice by expanding to the
  /// 1-sample minimum past it — it should collapse to the slice's last sample instead.
  @Test func marqueeAtTheRightEdgeStaysInsideTheSlice() throws {
    // slice 10_000..<20_000, spp 10, viewport 1000px -> right edge maps to source sample 20_000
    let model = laneModel()
    model.waveformAreaSelectBegan(atX: 1000, extending: false)
    model.waveformAreaSelectChanged(toX: 1000)
    model.waveformAreaSelectEnded(toX: 1000)

    let selection = try #require(model.waveformSelection)
    #expect(selection.upperBound <= model.overviewWindow.upperBound)
    expectNoDifference(selection, 19_999..<20_000)
  }

  /// A marquee drag is a no-op until the lane geometry is usable (nothing to map view-x against).
  @Test func marqueeIsANoOpWithoutUsableGeometry() {
    let (model, _) = makeModel()  // lane never seeded/laid out
    model.waveformAreaSelectBegan(atX: 100, extending: false)
    #expect(model.waveformSelection == nil)
    #expect(!model.canRemoveSelection)
  }

  /// Remove forwards the mapped source range to `onRemoveSection` (the parent's merge funnel) and
  /// clears the selection.
  @Test func removeSelectionTappedForwardsTheSourceRangeAndClears() async {
    let model = laneModel()
    var removed: [Range<Int>] = []
    model.onRemoveSection = { removed.append($0) }

    model.waveformAreaSelectBegan(atX: 100, extending: false)
    model.waveformAreaSelectChanged(toX: 300)
    model.waveformAreaSelectEnded(toX: 300)
    await model.removeSelectionTapped()

    expectNoDifference(removed, [11_000..<13_000])
    #expect(model.waveformSelection == nil)
    #expect(!model.canRemoveSelection)
  }

  /// Remove is a no-op with no selection (nothing to forward).
  @Test func removeSelectionTappedIsANoOpWithoutASelection() async {
    let model = laneModel()
    var removed: [Range<Int>] = []
    model.onRemoveSection = { removed.append($0) }
    await model.removeSelectionTapped()
    #expect(removed.isEmpty)
  }

  /// ⌫ in the sheet removes the current marquee selection through the same funnel as the Remove
  /// button (parity with the main editor's ⌫ shortcut), then clears it.
  @Test func deleteKeyRemovesTheMarqueeSelection() async {
    let model = laneModel()
    var removed: [Range<Int>] = []
    model.onRemoveSection = { removed.append($0) }

    model.waveformAreaSelectBegan(atX: 100, extending: false)
    model.waveformAreaSelectChanged(toX: 300)
    model.waveformAreaSelectEnded(toX: 300)
    await model.removeSectionKeyPressed()

    expectNoDifference(removed, [11_000..<13_000])
    #expect(model.waveformSelection == nil)
  }

  /// ⌫ with a seam selected restores that removal (the seam branch of the shortcut) instead of
  /// removing a selection — forwarding the seam's id to the parent's restore funnel.
  @Test func deleteKeyRestoresTheSelectedSeam() async {
    let model = laneModel()
    var restored: [TimelineRemoval.ID] = []
    model.onRestore = { restored.append($0) }
    let removal = TimelineRemoval(
      id: UUID(), removedRange: 12_000..<15_000, crossfade: Crossfade(lengthSamples: 0))
    model.syncTimeline(EditedTimeline(sourceDurationSamples: 100_000, removals: [removal]))
    // Right-clicking the seam selects it (the only public path to a seam selection).
    _ = model.waveformContextMenuItems(atX: model.seamOverlays[0].span.positionX)
    #expect(model.selectedSeamID == removal.id)

    await model.removeSectionKeyPressed()

    expectNoDifference(restored, [removal.id])
  }

  /// ⌫ is a no-op when nothing is selected — no removal, no restore (the monitor still consumes it,
  /// matching how it consumes ⌘Z with nothing to undo).
  @Test func deleteKeyIsANoOpWithNoSelectionOrSeam() async {
    let model = laneModel()
    var removed = 0
    var restored = 0
    model.onRemoveSection = { _ in removed += 1 }
    model.onRestore = { _ in restored += 1 }

    await model.removeSectionKeyPressed()

    #expect(removed == 0)
    #expect(restored == 0)
  }

  /// Seams derive from the shared timeline the parent syncs in, so an existing removal inside the
  /// slice draws a bowtie on the collapsed lane.
  @Test func seamOverlaysDeriveFromTheSharedTimeline() {
    let model = laneModel()
    #expect(model.seamOverlays.isEmpty)
    let removal = TimelineRemoval(
      id: UUID(), removedRange: 12_000..<15_000, crossfade: Crossfade(lengthSamples: 0))
    model.syncTimeline(EditedTimeline(sourceDurationSamples: 100_000, removals: [removal]))

    expectNoDifference(model.seamOverlays.map(\.id), [removal.id])
  }

  /// Right-clicking a seam selects it and offers Restore, which forwards the seam's id to `onRestore`
  /// (the parent's restore funnel).
  @Test func contextMenuOnASeamSelectsAndRestores() {
    let model = laneModel()
    var restored: [TimelineRemoval.ID] = []
    model.onRestore = { restored.append($0) }
    let removal = TimelineRemoval(
      id: UUID(), removedRange: 12_000..<15_000, crossfade: Crossfade(lengthSamples: 0))
    model.syncTimeline(EditedTimeline(sourceDurationSamples: 100_000, removals: [removal]))
    let seamX = model.seamOverlays[0].span.positionX

    let items = model.waveformContextMenuItems(atX: seamX)

    expectNoDifference(model.selectedSeamID, removal.id)
    expectNoDifference(items.map(\.title), [model.restoreRemovedAudioLabel])
    items[0].action()
    expectNoDifference(restored, [removal.id])
  }

  /// Off a seam, the menu offers Remove when a marquee selection exists (the action routes to the
  /// same `onRemoveSection` funnel that `removeSelectionTappedForwardsTheSourceRangeAndClears`
  /// covers directly).
  @Test func contextMenuOffASeamOffersRemoveForTheSelection() {
    let model = laneModel()
    model.waveformAreaSelectBegan(atX: 100, extending: false)
    model.waveformAreaSelectChanged(toX: 300)
    model.waveformAreaSelectEnded(toX: 300)

    let items = model.waveformContextMenuItems(atX: 700)  // no seam here

    expectNoDifference(items.map(\.title), [model.removeSectionLabel])
  }

  /// Off a seam with no selection, the menu is empty (nothing to remove or restore).
  @Test func contextMenuOffASeamWithNoSelectionIsEmpty() {
    let model = laneModel()
    let items = model.waveformContextMenuItems(atX: 700)
    #expect(items.isEmpty)
  }

  /// Starting a marquee clears any seam selection so the two selections never coexist.
  @Test func startingAMarqueeClearsTheSeamSelection() {
    let model = laneModel()
    let removal = TimelineRemoval(
      id: UUID(), removedRange: 12_000..<15_000, crossfade: Crossfade(lengthSamples: 0))
    model.syncTimeline(EditedTimeline(sourceDurationSamples: 100_000, removals: [removal]))
    _ = model.waveformContextMenuItems(atX: model.seamOverlays[0].span.positionX)
    #expect(model.selectedSeamID == removal.id)

    model.waveformAreaSelectBegan(atX: 100, extending: false)

    #expect(model.selectedSeamID == nil)
  }

  // MARK: - Pin correctness / undo forwarding

  /// A removal that swallows the whole slice leaves no kept audio, so the pinned lane is empty and
  /// unusable — NOT a fallback to the entire project. (The old endpoint-bias pin inverted here and
  /// pinned `0..<editedDuration`, rendering the full recording inside the sheet.)
  @Test func aRemovalCoveringTheWholeSliceEmptiesTheLaneInsteadOfShowingTheProject() {
    let model = laneModel()  // slice 10_000..<20_000
    #expect(model.editedWaveform.hasUsableGeometry)

    let removal = TimelineRemoval(
      id: UUID(), removedRange: 8_000..<22_000, crossfade: Crossfade(lengthSamples: 0))
    model.syncTimeline(EditedTimeline(sourceDurationSamples: 100_000, removals: [removal]))

    #expect(!model.editedWaveform.hasUsableGeometry)
  }

  /// ⌘Z / ⌘⇧Z inside the sheet forward to the shared-document undo/redo (the parent wires these to
  /// its own `undoTapped`/`redoTapped`, since the main window's shortcut can't fire while the sheet
  /// is key).
  @Test func undoRedoForwardToTheSharedDocumentHandlers() async {
    let model = laneModel()
    var events: [String] = []
    model.onUndo = { events.append("undo") }
    model.onRedo = { events.append("redo") }

    await model.undoTapped()
    await model.redoTapped()

    expectNoDifference(events, ["undo", "redo"])
  }

  // MARK: - Audition (In/Out) — mirrors EditorModel's audition feature, scoped to the slice

  @Test func auditionInPlaysDraftRangeFromCutIn() async {
    let (model, slice) = makeModel()
    var played: [Range<Int>] = []
    model.onPlay = { played.append($0) }

    await model.auditionInTapped()

    expectNoDifference(played, [slice.startSample..<slice.endSample])
    #expect(model.isPlaying == true)
    #expect(model.isAuditioningIn == true)
  }

  @Test func auditionOutPlaysLastTwoSecondsBeforeCutOut() async {
    let plan = Fixtures.editPlan()
    let slice = Slice(
      id: UUID(), name: "S", startSample: 0, endSample: 200_000,
      wordIDs: [], snippet: "")
    let model = EditSliceModel(slice: slice, editPlan: plan)
    var played: [Range<Int>] = []
    model.onPlay = { played.append($0) }
    let preRoll = Int(2.0 * Double(model.fineTune.sampleRate))

    await model.auditionOutTapped()

    expectNoDifference(played, [(200_000 - preRoll)..<200_000])
    #expect(model.isAuditioningOut == true)
  }

  /// The makeModel() slice is 30_000 samples wide — shorter than the 2s (88_200-sample) pre-roll —
  /// so the pre-roll clamps to the cut-in and the whole draft plays.
  @Test func auditionOutPreRollClampsToCutIn() async {
    let (model, slice) = makeModel()
    var played: [Range<Int>] = []
    model.onPlay = { played.append($0) }

    await model.auditionOutTapped()

    expectNoDifference(played, [slice.startSample..<slice.endSample])
  }

  @Test func auditionInTappedAgainStops() async {
    let (model, _) = makeModel()
    var stops = 0
    model.onStop = { stops += 1 }
    model.onPlay = { _ in }

    await model.auditionInTapped()
    await model.auditionInTapped()

    #expect(stops == 1)
    #expect(model.activeAudition == nil)
    #expect(model.isPlaying == false)
  }

  @Test func auditionOutTappedAgainStops() async {
    let (model, _) = makeModel()
    var stops = 0
    model.onStop = { stops += 1 }
    model.onPlay = { _ in }

    await model.auditionOutTapped()
    await model.auditionOutTapped()

    #expect(stops == 1)
    #expect(model.activeAudition == nil)
    #expect(model.isPlaying == false)
  }

  @Test func switchingAuditionsSupersedes() async {
    let plan = Fixtures.editPlan()
    let slice = Slice(
      id: UUID(), name: "S", startSample: 0, endSample: 200_000,
      wordIDs: [], snippet: "")
    let model = EditSliceModel(slice: slice, editPlan: plan)
    var played: [Range<Int>] = []
    model.onPlay = { played.append($0) }
    let preRoll = Int(2.0 * Double(model.fineTune.sampleRate))

    await model.auditionInTapped()
    await model.auditionOutTapped()

    #expect(model.isAuditioningOut == true)
    expectNoDifference(played.last, (200_000 - preRoll)..<200_000)
  }

  @Test func playbackEndClearsAudition() async {
    let (model, _) = makeModel()
    model.onPlay = { _ in }
    await model.auditionInTapped()
    #expect(model.activeAudition != nil)

    model.updatePlayback(sample: 12_000, isPlaying: false)

    #expect(model.activeAudition == nil)
  }

  @Test func playPauseTappedClearsAudition() async {
    let (model, _) = makeModel()
    model.onPlay = { _ in }
    await model.auditionInTapped()
    #expect(model.activeAudition != nil)

    await model.playPauseTapped()  // isPlaying, so this pauses — and ends the audition

    #expect(model.activeAudition == nil)
  }

  @Test func waveformSeekedClearsAudition() async {
    let model = laneModel()  // slice 10_000..<20_000, spp 10, start 10_000
    model.onPlay = { _ in }
    model.onSeek = { _ in }
    await model.auditionInTapped()
    #expect(model.activeAudition != nil)

    await model.waveformSeeked(toX: 150)

    #expect(model.activeAudition == nil)
  }

  @Test func auditionLabelsShowHotkeys() {
    let (model, _) = makeModel()
    #expect(model.auditionInHotkey == "[")
    #expect(model.auditionOutHotkey == "]")
    #expect(model.auditionPanelCaption.localizedCaseInsensitiveContains("preview"))
  }

  @Test func statusTextWhileAuditioning() async {
    let (model, _) = makeModel()
    model.onPlay = { _ in }
    model.onStop = {}
    #expect(model.auditionStatusText == nil)

    await model.auditionInTapped()
    expectNoDifference(model.auditionStatusText, "Auditioning in-cut — Space to pause")

    await model.auditionInTapped()  // toggle off
    #expect(model.auditionStatusText == nil)

    await model.auditionOutTapped()
    expectNoDifference(model.auditionStatusText, "Auditioning out-cut — Space to pause")
  }

  // MARK: - Transport action races (stale-continuation guard)

  /// `[` toggles the in-cut audition off — suspending inside `stopTapped`'s `onStop` — then `]`
  /// starts the out-cut audition before that `onStop` resolves. The old `stopTapped` continuation
  /// must lose the race: it resumes into a world where a NEWER audition already started, so it must
  /// not stomp `activeAudition`/`isPlaying` back to nil/false.
  @Test func stopTappedSupersededByAuditionOutTappedKeepsTheNewerAudition() async {
    let plan = Fixtures.editPlan()
    let slice = Slice(
      id: UUID(), name: "S", startSample: 0, endSample: 200_000,
      wordIDs: [], snippet: "")
    let model = EditSliceModel(slice: slice, editPlan: plan)
    model.onPlay = { _ in }
    let stopGate = VoidGate()
    model.onStop = { await stopGate.suspend() }

    // Establishes the in-cut audition, no suspension (onPlay is a no-op).
    await model.auditionInTapped()
    #expect(model.isAuditioningIn == true)

    let toggleOff = Task { await model.auditionInTapped() }  // toggles off → suspends in onStop
    await Task.yield()

    await model.auditionOutTapped()  // races ahead of the still-suspended stopTapped
    #expect(model.isAuditioningOut == true)
    #expect(model.isPlaying == true)

    await stopGate.release()
    await toggleOff.value

    #expect(model.activeAudition == .cutOut)
    #expect(model.isPlaying == true)
  }

  /// A body click at/after the cut-out while playing suspends inside `waveformSeeked`'s `onStop`,
  /// then `]` starts an audition before the stop resolves. The stale continuation must not fire its
  /// deferred park-the-cursor seek — that would yank the playhead out from under the newer audition.
  @Test func waveformSeekedPastCutOutSupersededByAuditionOutTappedDropsTheStaleSeek() async {
    let model = laneModel()  // slice 10_000..<20_000, spp 10 — x=1000 maps to the cut-out
    var seeks: [Int] = []
    model.onPlay = { _ in }
    model.onSeek = { seeks.append($0) }
    let stopGate = VoidGate()
    model.onStop = { await stopGate.suspend() }

    // Establishes playback, no suspension (onPlay is a no-op).
    await model.auditionInTapped()
    #expect(model.isPlaying == true)

    // Past the cut-out → suspends in onStop.
    let staleSeek = Task { await model.waveformSeeked(toX: 1000) }
    await Task.yield()

    await model.auditionOutTapped()  // races ahead of the still-suspended seek
    #expect(model.isAuditioningOut == true)

    await stopGate.release()
    await staleSeek.value

    expectNoDifference(seeks, [])
    #expect(model.activeAudition == .cutOut)
    #expect(model.isPlaying == true)
  }

  /// Space (pause) suspends inside `playPauseTapped`'s `onPause`, then `[` starts an audition
  /// before the pause resolves. The stale pause continuation must not clear `isPlaying` out from
  /// under the audition that superseded it.
  @Test func playPauseTappedPauseSupersededByAuditionInTappedKeepsPlaying() async {
    let (model, _) = makeModel()
    model.onPlay = { _ in }
    let pauseGate = VoidGate()
    model.onPause = { await pauseGate.suspend() }

    await model.playPauseTapped()  // starts playing, no suspension (onPlay is a no-op)
    #expect(model.isPlaying == true)

    let pause = Task { await model.playPauseTapped() }  // pauses → suspends in onPause
    await Task.yield()

    await model.auditionInTapped()  // races ahead of the still-suspended pause
    #expect(model.isAuditioningIn == true)
    #expect(model.isPlaying == true)

    await pauseGate.release()
    await pause.value

    #expect(model.isPlaying == true)
  }
}
