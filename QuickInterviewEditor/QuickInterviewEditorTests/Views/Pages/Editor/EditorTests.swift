import CustomDump
import Dependencies
import Foundation
import IdentifiedCollections
import Testing

@testable import QuickInterviewEditor

private final class PlayerGate: @unchecked Sendable {
  private let lock = NSLock()
  private var releaseCont: CheckedContinuation<Void, Never>?
  private var released = false
  private let startedContinuation: AsyncStream<Void>.Continuation
  let started: AsyncStream<Void>

  init() {
    var continuation: AsyncStream<Void>.Continuation!
    started = AsyncStream { continuation = $0 }
    startedContinuation = continuation
  }

  /// Stand-in for `audioPlayer.play`: signals "started", then suspends until `release()`.
  func play() async {
    startedContinuation.yield(())
    await withCheckedContinuation { cont in
      lock.lock()
      if released {
        lock.unlock()
        cont.resume()
        return
      }
      releaseCont = cont
      lock.unlock()
    }
  }

  /// Stand-in for `audioPlayer.stop` (and for natural completion in a test): resumes `play()`.
  func release() {
    lock.lock()
    let cont = releaseCont
    releaseCont = nil
    released = true
    lock.unlock()
    cont?.resume()
  }

  func awaitStarted() async {
    var iterator = started.makeAsyncIterator()
    _ = await iterator.next()
  }
}

@MainActor
struct EditorTests {
  private func editor(_ plan: EditPlan = Fixtures.editPlan()) -> EditorModel {
    EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: plan)
  }

  @Test func addSliceFromSelectionCreatesSlice() {
    let model = editor()
    model.transcript.wordTapped(model.transcript.words[0].id)
    model.transcript.wordTapped(model.transcript.words[3].id)
    let selectedWordIDs = model.transcript.orderedSelectedWordIDs
    model.addSliceTapped()
    expectNoDifference(model.slices.count, 1)
    let slice = model.slices[0]
    expectNoDifference(slice.name, "Slice 1")
    expectNoDifference(slice.wordIDs, selectedWordIDs)
    #expect(slice.startSample < slice.endSample)
    #expect(!slice.snippet.isEmpty)
  }

  // MARK: - Snippet middle-truncation

  @Test func shortSnippetPassesThroughUnchanged() {
    expectNoDifference(
      middleTruncatedSnippet("So a young Hayes Carl", maxLength: 68),
      "So a young Hayes Carl")
  }

  @Test func longSnippetKeepsFirstAndLastWordsWithMiddleEllipsis() {
    let text = "So a young Hayes Carl goes to a Ray Wiley Hubbard concert and it was great"
    let out = middleTruncatedSnippet(text, maxLength: 40)
    #expect(out.hasPrefix("So "))
    #expect(out.hasSuffix(" great"))
    #expect(out.contains("…"))
    #expect(out.count <= 40)
  }

  @Test func fewerThanThreeWordsPassThrough() {
    let longTwoWords = String(repeating: "a", count: 40) + " " + String(repeating: "b", count: 40)
    expectNoDifference(middleTruncatedSnippet(longTwoWords, maxLength: 20), longTwoWords)
  }

  @Test func oversizedFirstOrLastWordStillRespectsMaxLength() {
    // A single run-on word (or long URL) as the first/last word must not let the
    // result exceed maxLength — the minimal first…last window itself overflows.
    let text = String(repeating: "x", count: 80) + " b " + String(repeating: "y", count: 80)
    let out = middleTruncatedSnippet(text, maxLength: 20)
    #expect(out.count <= 20)
    #expect(out.hasSuffix("…"))
  }

  @Test func sliceSnippetShowsFirstAndLastWordsOfSelection() {
    let model = editor()
    let words = model.transcript.words
    model.transcript.wordTapped(words[0].id)  // "So"
    model.transcript.wordTapped(words[words.count - 1].id)  // last word: "Carl"
    model.addSliceTapped()
    let snippet = model.slices[0].snippet
    #expect(snippet.hasPrefix("“So"))
    #expect(snippet.hasSuffix("Carl”"))
    #expect(snippet.contains("…"))
  }

  @Test func addSliceRejectedWithoutSelection() {
    let model = editor()
    #expect(!model.canAddSlice)
    model.addSliceTapped()
    expectNoDifference(model.slices.count, 0)
  }

  @Test func addSliceNamesSequentially() {
    let model = editor()
    model.transcript.wordTapped(model.transcript.words[0].id)
    model.transcript.wordTapped(model.transcript.words[1].id)
    model.addSliceTapped()
    model.transcript.wordTapped(model.transcript.words[2].id)
    model.transcript.wordTapped(model.transcript.words[3].id)
    model.addSliceTapped()
    expectNoDifference(model.slices.map(\.name), ["Slice 1", "Slice 2"])
  }

  @Test func renameReorderDeleteMutateSlices() async {
    let model = editor()
    for pair in [(0, 1), (2, 3), (4, 5)] {
      model.transcript.wordTapped(model.transcript.words[pair.0].id)
      model.transcript.wordTapped(model.transcript.words[pair.1].id)
      model.addSliceTapped()
    }
    let firstID = model.slices[0].id
    model.renameSlice(firstID, to: "Intro")
    expectNoDifference(model.slices[id: firstID]?.name, "Intro")
    model.moveSlices(fromOffsets: IndexSet(integer: 0), toOffset: 3)
    expectNoDifference(model.slices.last?.id, firstID)
    await model.deleteSlice(firstID)
    #expect(model.slices[id: firstID] == nil)
    expectNoDifference(model.slices.count, 2)
  }

  // MARK: - Undo / Redo

  @Test func addThenUndoRemovesSliceAndRedoRestores() async {
    let model = editor()
    #expect(!model.canUndo)
    addSlices(model, [(0, 1)])
    let slice = model.slices[0]
    expectNoDifference(model.slices.count, 1)
    #expect(model.canUndo)

    await model.undoTapped()
    expectNoDifference(model.slices, [])
    #expect(!model.canUndo)
    #expect(model.canRedo)

    await model.redoTapped()
    expectNoDifference(model.slices, [slice])
    #expect(!model.canRedo)
  }

  @Test func deleteThenUndoRestoresSlice() async {
    let model = editor()
    addSlices(model, [(0, 1)])
    let slice = model.slices[0]
    await model.deleteSlice(slice.id)
    expectNoDifference(model.slices, [])

    await model.undoTapped()
    expectNoDifference(model.slices, [slice])
  }

  @Test func renameThenUndoRestoresPreviousName() async {
    let model = editor()
    addSlices(model, [(0, 1)])
    let id = model.slices[0].id
    model.renameSlice(id, to: "Intro")
    expectNoDifference(model.slices[id: id]?.name, "Intro")

    await model.undoTapped()
    expectNoDifference(model.slices[id: id]?.name, "Slice 1")
  }

  @Test func reorderThenUndoRestoresOrder() async {
    let model = editor()
    addSlices(model, [(0, 1), (2, 3), (4, 5)])
    let originalOrder = model.slices.map(\.id)
    model.moveSlices(fromOffsets: IndexSet(integer: 0), toOffset: 3)
    #expect(model.slices.map(\.id) != originalOrder)

    await model.undoTapped()
    expectNoDifference(model.slices.map(\.id), originalOrder)
  }

  @Test func editAfterUndoTruncatesRedoBranch() async {
    let model = editor()
    addSlices(model, [(0, 1)])  // Slice 1
    addSlices(model, [(2, 3)])  // Slice 2
    await model.undoTapped()  // removes Slice 2
    #expect(model.canRedo)

    addSlices(model, [(4, 5)])  // Slice 3 — new branch, redo gone
    #expect(!model.canRedo)
    expectNoDifference(model.slices.map(\.name), ["Slice 1", "Slice 3"])
  }

  @Test func undoRemovingPlayingSliceReconcilesPlayback() async {
    let gate = PlayerGate()
    let stopped = LockIsolated(false)
    let model = editor()
    addSlices(model, [(0, 1)])  // one undo entry: the add
    let slice = model.slices[0]
    await withDependencies {
      $0.audioPlayer.play = { _, _, _ in await gate.play() }
      $0.audioPlayer.stop = {
        stopped.setValue(true)
        gate.release()
      }
    } operation: {
      let task = Task { await model.playSliceTapped(slice.id) }
      await gate.awaitStarted()
      expectNoDifference(model.playingSliceID, slice.id)
      // Undoing the add removes the currently-playing slice; reconcile must stop playback.
      await model.undoTapped()
      await task.value
      expectNoDifference(model.slices, [])
      expectNoDifference(model.playingSliceID, nil)
      #expect(stopped.value)
    }
  }

  @Test func undoLeavesUnrelatedPlaybackRunning() async {
    let gate = PlayerGate()
    let stopped = LockIsolated(false)
    let model = editor()
    addSlices(model, [(0, 1)])  // Slice 1 — the slice we'll keep playing
    addSlices(model, [(2, 3)])  // Slice 2 — the mutation we'll undo
    let playing = model.slices[0]
    await withDependencies {
      $0.audioPlayer.play = { _, _, _ in await gate.play() }
      $0.audioPlayer.stop = {
        stopped.setValue(true)
        gate.release()
      }
    } operation: {
      let task = Task { await model.playSliceTapped(playing.id) }
      await gate.awaitStarted()
      // Undoing the Slice 2 add leaves the playing Slice 1 intact — playback continues.
      await model.undoTapped()
      expectNoDifference(model.playingSliceID, playing.id)
      #expect(!stopped.value)
      gate.release()  // finish the test cleanly
      await task.value
    }
  }

  @Test func sliceRowsFormatDurationAndRange() {
    let model = editor()
    model.transcript.wordTapped(model.transcript.words[0].id)
    model.transcript.wordTapped(model.transcript.words[2].id)
    model.addSliceTapped()
    let row = model.sliceRows[0]
    #expect(row.durationLabel.hasSuffix("s"))
    #expect(row.rangeLabel.contains("–"))
    expectNoDifference(row.isPlaying, false)
  }

  @Test func sliceCountLabelPluralises() {
    let model = editor()
    expectNoDifference(model.sliceCountLabel, "0 clips")
    model.transcript.wordTapped(model.transcript.words[0].id)
    model.transcript.wordTapped(model.transcript.words[1].id)
    model.addSliceTapped()
    expectNoDifference(model.sliceCountLabel, "1 clip")
  }

  @Test func playSetsPlayingDuringPlaybackAndRecordsSourceRange() async {
    let gate = PlayerGate()
    // swiftlint:disable:next large_tuple
    let recorded = LockIsolated<(URL, Range<Int>, Int)?>(nil)
    let model = editor()
    model.transcript.wordTapped(model.transcript.words[0].id)
    model.transcript.wordTapped(model.transcript.words[2].id)
    model.addSliceTapped()
    let slice = model.slices[0]
    await withDependencies {
      $0.audioPlayer.play = { url, range, rate in
        recorded.setValue((url, range, rate))
        await gate.play()
      }
      $0.audioPlayer.stop = { gate.release() }
    } operation: {
      let task = Task { await model.playSliceTapped(slice.id) }
      await gate.awaitStarted()
      expectNoDifference(model.playingSliceID, slice.id)
      // Playback reads the canonical AIFF, not the original source.
      expectNoDifference(recorded.value?.0, model.canonicalAudioURL)
      expectNoDifference(recorded.value?.1, slice.startSample..<slice.endSample)
      expectNoDifference(recorded.value?.2, model.editPlan.source.sampleRate)
      gate.release()  // natural completion
      await task.value
      expectNoDifference(model.playingSliceID, nil)
    }
  }

  @Test func stopPlaybackClearsPlayingSlice() async {
    let gate = PlayerGate()
    let model = editor()
    model.transcript.wordTapped(model.transcript.words[0].id)
    model.transcript.wordTapped(model.transcript.words[1].id)
    model.addSliceTapped()
    let slice = model.slices[0]
    await withDependencies {
      $0.audioPlayer.play = { _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { gate.release() }
    } operation: {
      let task = Task { await model.playSliceTapped(slice.id) }
      await gate.awaitStarted()
      await model.stopPlaybackTapped()
      await task.value
      expectNoDifference(model.playingSliceID, nil)
    }
  }

  @Test func playStopTappedTogglesPlayback() async {
    let gate = PlayerGate()
    let model = editor()
    model.transcript.wordTapped(model.transcript.words[0].id)
    model.transcript.wordTapped(model.transcript.words[1].id)
    model.addSliceTapped()
    let slice = model.slices[0]
    await withDependencies {
      $0.audioPlayer.play = { _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { gate.release() }
    } operation: {
      let task = Task { await model.playStopTapped(slice.id) }
      await gate.awaitStarted()
      expectNoDifference(model.playingSliceID, slice.id)
      await model.playStopTapped(slice.id)  // second tap stops
      await task.value
      expectNoDifference(model.playingSliceID, nil)
    }
  }

  @Test func playSliceRollsBackPlayingIDOnError() async {
    let model = editor()
    model.transcript.wordTapped(model.transcript.words[0].id)
    model.transcript.wordTapped(model.transcript.words[1].id)
    model.addSliceTapped()
    let slice = model.slices[0]
    await withDependencies {
      $0.audioPlayer.play = { _, _, _ in throw EngineClientError.engineFailed("boom") }
    } operation: {
      await withKnownIssue {
        await model.playSliceTapped(slice.id)
      }
    }
    expectNoDifference(model.playingSliceID, nil)
  }

  @Test func sliceRowPlayButtonLabelReflectsPlayingState() async {
    let gate = PlayerGate()
    let model = editor()
    for pair in [(0, 1), (2, 3)] {
      model.transcript.wordTapped(model.transcript.words[pair.0].id)
      model.transcript.wordTapped(model.transcript.words[pair.1].id)
      model.addSliceTapped()
    }
    let first = model.slices[0]
    let second = model.slices[1]
    expectNoDifference(model.sliceRows[id: first.id]?.playButtonLabel, model.playLabel)
    await withDependencies {
      $0.audioPlayer.play = { _, _, _ in await gate.play() }
      $0.audioPlayer.stop = { gate.release() }
    } operation: {
      let task = Task { await model.playStopTapped(first.id) }
      await gate.awaitStarted()
      expectNoDifference(model.sliceRows[id: first.id]?.playButtonLabel, model.stopLabel)
      expectNoDifference(model.sliceRows[id: second.id]?.playButtonLabel, model.playLabel)
      gate.release()
      await task.value
    }
  }

  @Test func deletingPlayingSliceStopsPlayback() async {
    let gate = PlayerGate()
    let stopped = LockIsolated(false)
    let model = editor()
    model.transcript.wordTapped(model.transcript.words[0].id)
    model.transcript.wordTapped(model.transcript.words[2].id)
    model.addSliceTapped()
    let slice = model.slices[0]
    await withDependencies {
      $0.audioPlayer.play = { _, _, _ in await gate.play() }
      $0.audioPlayer.stop = {
        stopped.setValue(true)
        gate.release()
      }
    } operation: {
      let task = Task { await model.playSliceTapped(slice.id) }
      await gate.awaitStarted()
      await model.deleteSlice(slice.id)
      await task.value
      expectNoDifference(model.playingSliceID, nil)
      #expect(stopped.value)
      #expect(model.slices[id: slice.id] == nil)
    }
  }

  @Test func renameSlicePreservesInternalSpaces() {
    let model = editor()
    model.transcript.wordTapped(model.transcript.words[0].id)
    model.transcript.wordTapped(model.transcript.words[1].id)
    model.addSliceTapped()
    let slice = model.slices[0]
    model.renameSlice(slice.id, to: "My Clip")
    expectNoDifference(model.slices[id: slice.id]?.name, "My Clip")
    model.renameSlice(slice.id, to: "   ")
    expectNoDifference(model.slices[id: slice.id]?.name, "   ")
  }

  @Test func addSliceDoesNotReuseNumberAfterDeletion() async {
    let model = editor()
    for pair in [(0, 1), (2, 3), (4, 5)] {
      model.transcript.wordTapped(model.transcript.words[pair.0].id)
      model.transcript.wordTapped(model.transcript.words[pair.1].id)
      model.addSliceTapped()
    }
    expectNoDifference(model.slices.map(\.name), ["Slice 1", "Slice 2", "Slice 3"])
    let middleID = model.slices[1].id
    await model.deleteSlice(middleID)
    model.transcript.wordTapped(model.transcript.words[6].id)
    model.transcript.wordTapped(model.transcript.words[7].id)
    model.addSliceTapped()
    expectNoDifference(model.slices.map(\.name), ["Slice 1", "Slice 3", "Slice 4"])
  }

  @Test func multiRowDeleteRemovesExactlyTheSelectedRows() async {
    let model = editor()
    for pair in [(0, 1), (2, 3), (4, 5)] {
      model.transcript.wordTapped(model.transcript.words[pair.0].id)
      model.transcript.wordTapped(model.transcript.words[pair.1].id)
      model.addSliceTapped()
    }
    let middleID = model.slices[1].id
    let ids = [model.slices[0].id, model.slices[2].id]
    for id in ids { await model.deleteSlice(id) }
    expectNoDifference(model.slices.map(\.id), [middleID])
  }

  // MARK: - Playhead (playback position)

  @Test func observePlaybackMapsPositionThenClearsOnExit() async {
    let model = editor()
    model.playingSliceID = UUID()  // this editor owns playback
    let (stream, continuation) = AsyncStream.makeStream(of: PlaybackPosition.self)
    await withDependencies {
      $0.audioPlayer.positions = { stream }
    } operation: {
      let task = Task { await model.observePlayback() }
      continuation.yield(PlaybackPosition(sample: 1000, isPlaying: true))
      await settle { model.waveform.playheadSample == 1000 }
      #expect(model.waveform.playheadSample == 1000)  // maps the live position
      continuation.finish()  // stands in for the task being cancelled / stream ending
      await task.value
      #expect(model.waveform.playheadSample == nil)  // cleared on exit — no phantom marker
    }
  }

  @Test func observePlaybackIgnoresTicksWhenThisEditorIsNotPlaying() async {
    let model = editor()  // playingSliceID is nil — another tab owns playback
    let (stream, continuation) = AsyncStream.makeStream(of: PlaybackPosition.self)
    await withDependencies {
      $0.audioPlayer.positions = { stream }
    } operation: {
      let task = Task { await model.observePlayback() }
      continuation.yield(PlaybackPosition(sample: 5000, isPlaying: true))
      await settle { false }  // let the tick be processed
      #expect(model.waveform.playheadSample == nil)  // never adopts another tab's position
      continuation.finish()
      await task.value
    }
  }

  @Test func observePlaybackClearsPlayheadOnStopTick() async {
    let model = editor()
    model.playingSliceID = UUID()  // this editor owns playback
    let (stream, continuation) = AsyncStream.makeStream(of: PlaybackPosition.self)
    await withDependencies {
      $0.audioPlayer.positions = { stream }
    } operation: {
      let task = Task { await model.observePlayback() }
      continuation.yield(PlaybackPosition(sample: 1000, isPlaying: true))
      await settle { model.waveform.playheadSample == 1000 }
      continuation.yield(PlaybackPosition(sample: 1200, isPlaying: false))  // stop tick
      await settle { model.waveform.playheadSample == nil }
      #expect(model.waveform.playheadSample == nil)
      continuation.finish()
      await task.value
    }
  }

  // MARK: - Waveform sync

  /// Sets identity geometry (1 sample per pixel, no scroll) so xToSample(x) == x.
  private func identityGeometry(_ model: EditorModel, viewportWidth: CGFloat = 1_000_000) {
    model.waveform.viewportWidth = viewportWidth
    model.waveform.samplesPerPixel = 1
    model.waveform.visibleStartSample = 0
  }

  @Test func waveformTapSelectsContainingWord() {
    let model = editor()
    identityGeometry(model)
    let word = model.editPlan.words.first { $0.startSample != nil && $0.endSample != nil }!
    model.waveformTapped(atX: CGFloat(word.startSample! + 1))
    expectNoDifference(model.transcript.orderedSelectedWordIDs, [word.id])
  }

  @Test func waveformTapAtWordStartIsInclusiveAtEndIsExclusive() {
    let model = editor()
    identityGeometry(model)
    // choose a non-final word with sample bounds
    let words = model.editPlan.words
    let index = words.firstIndex {
      $0.startSample != nil && $0.endSample != nil && $0.id != words.last?.id
    }!
    let word = words[index]
    model.waveformTapped(atX: CGFloat(word.startSample!))  // start is inclusive
    expectNoDifference(model.transcript.orderedSelectedWordIDs, [word.id])
    // Clear first: a tap at the exclusive end lands in the next word or a gap, never
    // back on this word — so the selection must not be this word afterward.
    model.transcript.clearSelectionTapped()
    model.waveformTapped(atX: CGFloat(word.endSample!))  // end is exclusive
    #expect(model.transcript.orderedSelectedWordIDs != [word.id])
  }

  @Test func waveformTapInEmptyAreaLeavesSelectionUntouched() {
    let model = editor()
    identityGeometry(model)
    model.transcript.wordTapped(model.transcript.words[0].id)
    let before = model.transcript.orderedSelectedWordIDs
    // a sample far beyond the audio belongs to no word
    model.waveformTapped(atX: CGFloat(model.editPlan.source.durationSamples + 10_000))
    expectNoDifference(model.transcript.orderedSelectedWordIDs, before)
  }

  @Test func highlightedSampleRangeMirrorsTranscriptSelection() {
    let model = editor()
    #expect(model.highlightedSampleRange == nil)
    model.transcript.wordTapped(model.transcript.words[0].id)
    model.transcript.wordTapped(model.transcript.words[2].id)
    expectNoDifference(model.highlightedSampleRange, model.transcript.selectedSampleRange)
    #expect(model.highlightedSampleRange != nil)
  }

  @Test func waveformHighlightSpanCombinesSelectionWithGeometry() {
    let model = editor()
    identityGeometry(model)
    model.transcript.selectWord(model.transcript.words[0].id)
    let range = model.highlightedSampleRange!
    expectNoDifference(model.waveformHighlightSpan, model.waveform.span(for: range))
    #expect(model.waveformHighlightSpan != nil)
  }

  @Test func redRangesTrackRunTogetherWordsAndSensitivity() {
    let model = editor()
    model.transcript.sensitivityChanged(10)
    let tight = model.redRanges.count
    model.transcript.sensitivityChanged(80)
    let loose = model.redRanges.count
    #expect(tight < loose)
    for range in model.redRanges { #expect(range.lowerBound < range.upperBound) }
  }

  @Test func loadWaveformPopulatesChildViaClientFromCanonicalURL() async {
    let plan = Fixtures.editPlan()
    let fixture = Waveform.pyramid(
      baseMins: [0], baseMaxs: [0.5], sampleRate: plan.source.sampleRate,
      totalSamples: plan.source.durationSamples)
    let canonical = URL(fileURLWithPath: "/tmp/qie-canonical-load.aiff")
    let loadedURL = LockIsolated<URL?>(nil)
    let model = withDependencies {
      $0.waveform = WaveformClient(loadWaveform: { url, _, _ in
        loadedURL.setValue(url)
        return fixture
      })
    } operation: {
      EditorModel(
        sourceURL: URL(fileURLWithPath: "/clip.m4a"),
        canonicalAudioURL: canonical, editPlan: plan)
    }
    await model.loadWaveform()
    expectNoDifference(model.waveform.waveform, fixture)
    #expect(model.waveform.totalSamples == plan.source.durationSamples)
    // The waveform is built from the canonical AIFF, not the original source.
    expectNoDifference(loadedURL.value, canonical)
  }

  // MARK: - Export

  private func addSlices(_ model: EditorModel, _ pairs: [(Int, Int)]) {
    for pair in pairs {
      model.transcript.wordTapped(model.transcript.words[pair.0].id)
      model.transcript.wordTapped(model.transcript.words[pair.1].id)
      model.addSliceTapped()
    }
  }

  /// Yields cooperatively until `condition` holds (or a generous bound), so a
  /// worker task on the shared main actor can advance without `Task.sleep`.
  private func settle(until condition: () -> Bool) async {
    for _ in 0..<1000 where !condition() { await Task.yield() }
  }

  private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("qie-export-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func writeTempAIFF(in dir: URL, named name: String) throws -> URL {
    let url = dir.appendingPathComponent(name)
    try Data("aiff".utf8).write(to: url)
    return url
  }

  /// A stream that reports rendering `ids` and completes with a temp AIFF per id.
  private func renderedSlices(
    for ids: [Slice.ID], workDir: URL
  ) throws -> [RenderedSlice] {
    try ids.map { id in
      RenderedSlice(id: id, url: try writeTempAIFF(in: workDir, named: "\(id.uuidString).aiff"))
    }
  }

  @Test func exportAllCopiesRevealsAndRemembersDestination() async throws {
    let model = editor()
    addSlices(model, [(0, 1), (2, 3)])
    let ids = model.slices.map(\.id)
    let workDir = try makeTempDir()
    let destination = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: destination) }
    let rendered = try renderedSlices(for: ids, workDir: workDir)
    let revealed = LockIsolated<[URL]>([])
    let capturedRequest = LockIsolated<RenderRequest?>(nil)

    await withDependencies {
      $0.engine.renderSlices = { request in
        capturedRequest.setValue(request)
        return AsyncThrowingStream { continuation in
          continuation.yield(.progress(RenderProgress(message: "", index: 1, total: ids.count)))
          continuation.yield(.completed(RenderResult(slices: rendered, workDir: workDir)))
          continuation.finish()
        }
      }
      $0.workspace.reveal = { revealed.setValue($0) }
    } operation: {
      model.destinationURL = destination
      model.exportAllTapped()
      await model.exportTask?.value
    }

    expectNoDifference(model.exportPhase, .done(count: 2))
    expectNoDifference(Set(capturedRequest.value?.slices.map(\.id) ?? []), Set(ids))
    // Render is driven from the canonical AIFF, not the original source file, and
    // carries the plan's duration so the engine can verify the exact file.
    expectNoDifference(capturedRequest.value?.audioURL, model.canonicalAudioURL)
    expectNoDifference(
      capturedRequest.value?.durationSamples, model.editPlan.source.durationSamples)
    let contents = try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted()
    expectNoDifference(contents.count, 2)
    expectNoDifference(revealed.value.count, 2)
    expectNoDifference(
      Set(revealed.value.map { $0.deletingLastPathComponent().path }), [destination.path])
    // The engine work-dir is removed after the copy.
    #expect(!FileManager.default.fileExists(atPath: workDir.path))
  }

  @Test func exportAllMapsResultsByIdNotOrder() async throws {
    let model = editor()
    addSlices(model, [(0, 1), (2, 3)])
    let ids = model.slices.map(\.id)
    let stem = model.sourceURL.deletingPathExtension().lastPathComponent
    let workDir = try makeTempDir()
    let destination = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: destination) }
    // Render results returned in REVERSE order; copy must still match slice → name by id.
    let rendered = try renderedSlices(for: ids, workDir: workDir).reversed()

    await withDependencies {
      $0.engine.renderSlices = { _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.completed(RenderResult(slices: Array(rendered), workDir: workDir)))
          continuation.finish()
        }
      }
      $0.workspace.reveal = { _ in }
    } operation: {
      model.destinationURL = destination
      model.exportAllTapped()
      await model.exportTask?.value
    }

    let contents = Set(try FileManager.default.contentsOfDirectory(atPath: destination.path))
    expectNoDifference(contents, ["\(stem) - Slice 1.aiff", "\(stem) - Slice 2.aiff"])
  }

  @Test func missingDestinationPromptsChooseDirectory() async throws {
    let model = editor()
    addSlices(model, [(0, 1)])
    let ids = model.slices.map(\.id)
    let workDir = try makeTempDir()
    let destination = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: destination) }
    let rendered = try renderedSlices(for: ids, workDir: workDir)
    let promptCount = LockIsolated(0)

    await withDependencies {
      $0.workspace.chooseDirectory = {
        promptCount.withValue { $0 += 1 }
        return destination
      }
      $0.workspace.reveal = { _ in }
      $0.engine.renderSlices = { _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.completed(RenderResult(slices: rendered, workDir: workDir)))
          continuation.finish()
        }
      }
    } operation: {
      model.exportAllTapped()
      await model.exportTask?.value
    }

    expectNoDifference(promptCount.value, 1)
    expectNoDifference(model.destinationURL, destination)
    expectNoDifference(model.exportPhase, .done(count: 1))
  }

  @Test func cancellingDestinationPromptLeavesIdle() async {
    let model = editor()
    addSlices(model, [(0, 1)])
    let revealed = LockIsolated(false)

    await withDependencies {
      $0.workspace.chooseDirectory = { nil }  // user cancelled the panel
      $0.workspace.reveal = { _ in revealed.setValue(true) }
    } operation: {
      model.exportAllTapped()
      await model.exportTask?.value
    }

    expectNoDifference(model.exportPhase, .idle)
    #expect(!revealed.value)
    #expect(model.destinationURL == nil)
  }

  @Test func throwingRenderStreamSetsFailed() async throws {
    let model = editor()
    addSlices(model, [(0, 1)])
    let destination = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: destination) }

    await withDependencies {
      $0.engine.renderSlices = { _ in
        AsyncThrowingStream { continuation in
          continuation.finish(throwing: EngineClientError.renderFailed("boom"))
        }
      }
    } operation: {
      model.destinationURL = destination
      model.exportAllTapped()
      await model.exportTask?.value
    }

    guard case .failed(let message) = model.exportPhase else {
      Issue.record("expected .failed, got \(model.exportPhase)")
      return
    }
    #expect(message.contains("boom"))
  }

  @Test func partialRenderResultIsReportedAsFailureNotSuccess() async throws {
    let model = editor()
    addSlices(model, [(0, 1), (2, 3)])
    let ids = model.slices.map(\.id)
    let workDir = try makeTempDir()
    let destination = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: destination) }
    // Engine returns only the FIRST of two requested slices.
    let rendered = Array(try renderedSlices(for: ids, workDir: workDir).prefix(1))
    let revealed = LockIsolated(false)

    await withDependencies {
      $0.engine.renderSlices = { _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.completed(RenderResult(slices: rendered, workDir: workDir)))
          continuation.finish()
        }
      }
      $0.workspace.reveal = { _ in revealed.setValue(true) }
    } operation: {
      model.destinationURL = destination
      model.exportAllTapped()
      await model.exportTask?.value
    }

    guard case .failed(let message) = model.exportPhase else {
      Issue.record("expected .failed, got \(model.exportPhase)")
      return
    }
    #expect(message.contains("1 of 2"))
    #expect(!revealed.value)  // no partial reveal
    #expect(!FileManager.default.fileExists(atPath: workDir.path))  // still cleaned up
  }

  @Test func progressEventsWalkExportingThenDone() async throws {
    let model = editor()
    addSlices(model, [(0, 1), (2, 3)])
    let ids = model.slices.map(\.id)
    let workDir = try makeTempDir()
    let destination = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: destination) }
    let rendered = try renderedSlices(for: ids, workDir: workDir)
    let (stream, continuation) = AsyncThrowingStream<RenderEvent, Error>.makeStream()

    await withDependencies {
      $0.engine.renderSlices = { _ in stream }
      $0.workspace.reveal = { _ in }
    } operation: {
      model.destinationURL = destination
      model.exportAllTapped()

      continuation.yield(.progress(RenderProgress(message: "", index: 1, total: 2)))
      await settle { model.exportPhase == .exporting(current: 1, total: 2) }
      expectNoDifference(model.exportPhase, .exporting(current: 1, total: 2))

      continuation.yield(.progress(RenderProgress(message: "", index: 2, total: 2)))
      await settle { model.exportPhase == .exporting(current: 2, total: 2) }
      expectNoDifference(model.exportPhase, .exporting(current: 2, total: 2))

      continuation.yield(.completed(RenderResult(slices: rendered, workDir: workDir)))
      continuation.finish()
      await model.exportTask?.value
      expectNoDifference(model.exportPhase, .done(count: 2))
    }
  }

  @Test func cancelExportReportsPartialAndCleansTemp() async throws {
    let model = editor()
    addSlices(model, [(0, 1), (2, 3)])
    let destination = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: destination) }
    let (stream, continuation) = AsyncThrowingStream<RenderEvent, Error>.makeStream()
    let terminated = LockIsolated(false)
    continuation.onTermination = { _ in terminated.setValue(true) }

    await withDependencies {
      $0.engine.renderSlices = { _ in stream }
      $0.workspace.reveal = { _ in }
    } operation: {
      model.destinationURL = destination
      model.exportAllTapped()  // sync fire; stores the cancellable task
      continuation.yield(.progress(RenderProgress(message: "", index: 1, total: 2)))
      await Task.yield()
      #expect(model.isExporting)
      model.cancelExportTapped()
      await model.exportTask?.value
    }

    #expect(terminated.value)
    guard case .failed(let message) = model.exportPhase else {
      Issue.record("expected .failed, got \(model.exportPhase)")
      return
    }
    #expect(message.contains("cancelled"))
    // Nothing was copied to the destination.
    let contents = try FileManager.default.contentsOfDirectory(atPath: destination.path)
    expectNoDifference(contents, [])
  }

  @Test func tightJoinWarningCarriedIntoSummary() async throws {
    let model = editor()
    let tight = Slice(
      id: UUID(), name: "Intro", startSample: 10, endSample: 200,
      wordIDs: [], snippet: "x", warnings: [.tightStart])
    model.slices.append(tight)
    let workDir = try makeTempDir()
    let destination = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: destination) }
    let rendered = try renderedSlices(for: [tight.id], workDir: workDir)

    await withDependencies {
      $0.engine.renderSlices = { _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.completed(RenderResult(slices: rendered, workDir: workDir)))
          continuation.finish()
        }
      }
      $0.workspace.reveal = { _ in }
    } operation: {
      model.destinationURL = destination
      model.exportAllTapped()
      await model.exportTask?.value
    }

    #expect(model.exportTightWarning.contains("Intro"))
    #expect(model.exportTightWarning.contains("tight"))
  }

  @Test func renderRequestNudgesCollidingMarkerPositions() async {
    let plan = EditPlan(
      schemaVersion: 1,
      source: .init(path: "/clip.m4a", sampleRate: 44100, channels: 1, durationSamples: 100_000),
      words: [
        .init(id: 1, text: "a", start: 0.1, end: 0.2, startSample: 4410, endSample: 8820),
        .init(id: 2, text: "b", start: 0.1, end: 0.2, startSample: 4410, endSample: 8820),
      ],
      silences: [], segments: [])
    let model = editor(plan)
    model.slices.append(
      Slice(
        id: UUID(), name: "A", startSample: 0, endSample: 8820, wordIDs: [1, 2], snippet: "x",
        warnings: []))
    let captured = LockIsolated<RenderRequest?>(nil)

    await withDependencies {
      $0.engine.renderSlices = { request in
        captured.setValue(request)
        return AsyncThrowingStream { $0.finish() }
      }
    } operation: {
      model.destinationURL = URL(fileURLWithPath: NSTemporaryDirectory())
      model.exportAllTapped()
      await model.exportTask?.value
    }

    // Colliding start samples become strictly increasing marker positions.
    expectNoDifference(captured.value?.markers.map(\.position), [4410, 4411])
  }

  @Test func exportControlsGatedByStateAndExporting() async {
    let model = editor()
    expectNoDifference(model.canExportAll, false)  // no slices yet
    addSlices(model, [(0, 1)])
    expectNoDifference(model.canExportAll, true)
    model.exportPhase = .exporting(current: 0, total: 1)
    expectNoDifference(model.canExportAll, false)
    expectNoDifference(model.canExportSlice, false)
    expectNoDifference(model.showsCancelExport, true)
  }
}
