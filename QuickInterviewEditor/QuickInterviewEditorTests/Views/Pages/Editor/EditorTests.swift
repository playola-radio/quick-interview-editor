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
    EditorModel(sourceURL: URL(fileURLWithPath: "/clip.m4a"), editPlan: plan)
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
      expectNoDifference(recorded.value?.0, model.sourceURL)
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
}
