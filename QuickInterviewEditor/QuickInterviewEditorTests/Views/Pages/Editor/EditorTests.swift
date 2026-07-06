import CustomDump
import Dependencies
import Foundation
import IdentifiedCollections
import Testing

@testable import QuickInterviewEditor

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

  @Test func renameReorderDeleteMutateSlices() {
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
    model.deleteSlice(firstID)
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

  @Test func playSliceCallsAudioPlayerWithSourceRange() async {
    // swiftlint:disable:next large_tuple
    let recorded = LockIsolated<(URL, Range<Int>, Int)?>(nil)
    let model = editor()
    model.transcript.wordTapped(model.transcript.words[0].id)
    model.transcript.wordTapped(model.transcript.words[2].id)
    model.addSliceTapped()
    let slice = model.slices[0]
    await withDependencies {
      $0.audioPlayer.play = { url, range, rate in recorded.setValue((url, range, rate)) }
    } operation: {
      await model.playSliceTapped(slice.id)
    }
    expectNoDifference(recorded.value?.0, model.sourceURL)
    expectNoDifference(recorded.value?.1, slice.startSample..<slice.endSample)
    expectNoDifference(recorded.value?.2, model.editPlan.source.sampleRate)
    expectNoDifference(model.playingSliceID, slice.id)
  }

  @Test func stopPlaybackClearsPlayingSlice() async {
    let model = editor()
    model.transcript.wordTapped(model.transcript.words[0].id)
    model.transcript.wordTapped(model.transcript.words[1].id)
    model.addSliceTapped()
    await withDependencies {
      $0.audioPlayer.play = { _, _, _ in }
      $0.audioPlayer.stop = {}
    } operation: {
      await model.playSliceTapped(model.slices[0].id)
      await model.stopPlaybackTapped()
    }
    expectNoDifference(model.playingSliceID, nil)
  }
}
