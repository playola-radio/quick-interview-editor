import CustomDump
import Dependencies
import Foundation
import Sharing
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct EditorClipOffsetTests {
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

  private func sampleShift(forMs ms: Double, plan: EditPlan) -> Int {
    Int((ms / 1000 * Double(plan.source.sampleRate)).rounded())
  }

  // MARK: - addSliceTapped

  @Test func addSliceTappedShiftsBoundariesByTheConfiguredOffsetsButKeepsWordMembership() {
    withDependencies {
      $0.defaultAppStorage = UserDefaults(suiteName: "clip-offset-add-\(UUID())")!
    } operation: {
      @Shared(.clipStartOffsetMs) var startOffsetMs = -20.0
      @Shared(.clipEndOffsetMs) var endOffsetMs = 15.0

      let model = editor()
      let plan = model.editPlan
      selectWords(model.transcript, 0, 3)
      let range = model.audioSelection!
      let expectedWordIDs = wordIDs(anyOverlap: range, words: plan.words)

      model.addSliceTapped()

      let slice = model.slices[0]
      let expectedStart = range.lowerBound + sampleShift(forMs: -20, plan: plan)
      let expectedEnd = range.upperBound + sampleShift(forMs: 15, plan: plan)
      expectNoDifference(slice.startSample, expectedStart)
      expectNoDifference(slice.endSample, expectedEnd)
      expectNoDifference(slice.wordIDs, expectedWordIDs)
    }
  }

  @Test func addSliceTappedWithZeroOffsetsIsUnchanged() {
    withDependencies {
      $0.defaultAppStorage = UserDefaults(suiteName: "clip-offset-add-zero-\(UUID())")!
    } operation: {
      let model = editor()
      selectWords(model.transcript, 0, 3)
      let range = model.audioSelection!

      model.addSliceTapped()

      let slice = model.slices[0]
      expectNoDifference(slice.startSample, range.lowerBound)
      expectNoDifference(slice.endSample, range.upperBound)
    }
  }

  @Test func addSliceTappedOffsetClampsAtEndOfFile() {
    withDependencies {
      $0.defaultAppStorage = UserDefaults(suiteName: "clip-offset-add-eof-\(UUID())")!
    } operation: {
      @Shared(.clipEndOffsetMs) var endOffsetMs = 50.0

      let model = editor()
      let plan = model.editPlan
      let words = plan.words
      // Select the last two words so the selection's upper bound sits near end of file.
      selectWords(model.transcript, words.count - 2, words.count - 1)
      model.addSliceTapped()

      let slice = model.slices[0]
      #expect(slice.endSample <= plan.source.durationSamples)
    }
  }

  // MARK: - Fine-tune commit (.pendingSelection)

  @Test func fineTuneCommitOfPendingSelectionShiftsBoundaries() {
    withDependencies {
      $0.defaultAppStorage = UserDefaults(suiteName: "clip-offset-finetune-\(UUID())")!
    } operation: {
      @Shared(.clipStartOffsetMs) var startOffsetMs = 10.0
      @Shared(.clipEndOffsetMs) var endOffsetMs = -10.0

      let model = editor()
      let plan = model.editPlan
      selectWords(model.transcript, 0, 3)
      model.syncEditSession()
      let draft = model.fineTune.draftRange!
      let expectedWordIDs = wordIDs(anyOverlap: draft, words: plan.words)

      model.commitEditTapped()

      let slice = model.slices.last!
      let expectedStart = draft.lowerBound + sampleShift(forMs: 10, plan: plan)
      let expectedEnd = draft.upperBound + sampleShift(forMs: -10, plan: plan)
      expectNoDifference(slice.startSample, expectedStart)
      expectNoDifference(slice.endSample, expectedEnd)
      expectNoDifference(slice.wordIDs, expectedWordIDs)
    }
  }

  @Test func fineTuneCommitWithZeroOffsetsIsUnchanged() {
    withDependencies {
      $0.defaultAppStorage = UserDefaults(suiteName: "clip-offset-finetune-zero-\(UUID())")!
    } operation: {
      let model = editor()
      selectWords(model.transcript, 0, 3)
      model.syncEditSession()
      let draft = model.fineTune.draftRange!

      model.commitEditTapped()

      let slice = model.slices.last!
      expectNoDifference(slice.startSample, draft.lowerBound)
      expectNoDifference(slice.endSample, draft.upperBound)
    }
  }

  // MARK: - Accepting a cut suggestion

  private func suggestionSlice(_ id: UUID, range: Range<Int>, plan: EditPlan) -> Slice {
    let ids = wordIDs(anyOverlap: range, words: plan.words)
    return buildSlice(id: id, name: "A story", range: range, wordIDs: ids, plan: plan)
  }

  @Test func acceptCutSuggestionSliceShiftsBoundariesButKeepsWordMembership() {
    withDependencies {
      $0.defaultAppStorage = UserDefaults(suiteName: "clip-offset-accept-\(UUID())")!
    } operation: {
      @Shared(.clipStartOffsetMs) var startOffsetMs = -30.0
      @Shared(.clipEndOffsetMs) var endOffsetMs = 30.0

      let model = editor()
      let plan = model.editPlan
      let range = 44_100..<88_200
      let original = suggestionSlice(Fixtures.uuid(1), range: range, plan: plan)

      model.acceptCutSuggestionSlice(original)

      let slice = model.slices[id: original.id]!
      let expectedStart = range.lowerBound + sampleShift(forMs: -30, plan: plan)
      let expectedEnd = range.upperBound + sampleShift(forMs: 30, plan: plan)
      expectNoDifference(slice.startSample, expectedStart)
      expectNoDifference(slice.endSample, expectedEnd)
      expectNoDifference(slice.wordIDs, original.wordIDs)
    }
  }

  @Test func acceptCutSuggestionSliceWithZeroOffsetsIsUnchanged() {
    withDependencies {
      $0.defaultAppStorage = UserDefaults(suiteName: "clip-offset-accept-zero-\(UUID())")!
    } operation: {
      let model = editor()
      let plan = model.editPlan
      let range = 44_100..<88_200
      let original = suggestionSlice(Fixtures.uuid(1), range: range, plan: plan)

      model.acceptCutSuggestionSlice(original)

      let slice = model.slices[id: original.id]!
      expectNoDifference(slice.startSample, range.lowerBound)
      expectNoDifference(slice.endSample, range.upperBound)
    }
  }
}
