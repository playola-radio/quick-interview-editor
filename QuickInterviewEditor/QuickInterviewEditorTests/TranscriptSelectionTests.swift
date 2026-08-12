import CustomDump
import Testing

@testable import QuickInterviewEditor

@MainActor
struct TranscriptSelectionTests {
  private var plan: EditPlan {
    EditPlan(
      schemaVersion: 1,
      source: .init(path: "", sampleRate: 1000, channels: 1, durationSamples: 10_000),
      words: [
        Word(id: 1, text: "one", start: 0, end: 0.5, startSample: 0, endSample: 500),
        Word(id: 2, text: "two", start: 0.5, end: 1.0, startSample: 500, endSample: 1000),
        Word(id: 3, text: "three", start: 1.0, end: 1.5, startSample: 1000, endSample: 1500),
      ], silences: [], segments: [])
  }
  // text: "one two three"; ranges: one=0..3, two=4..7, three=8..13

  @Test func clickSelectsSingleWord() {
    let model = TranscriptPageModel(editPlan: plan)
    model.transcriptClicked(atUTF16Offset: 5)  // inside "two"
    expectNoDifference(model.selectedWordIDSet, [2])
    expectNoDifference(model.selectedSampleRange, 500..<1000)
  }

  @Test func clickingSoleSelectedWordClearsIt() {
    let model = TranscriptPageModel(editPlan: plan)
    model.transcriptClicked(atUTF16Offset: 5)
    model.transcriptClicked(atUTF16Offset: 5)
    expectNoDifference(model.selectedWordIDSet, [])
    expectNoDifference(model.selectedSampleRange, nil)
  }

  @Test func dragPaintsContiguousRun() {
    let model = TranscriptPageModel(editPlan: plan)
    model.transcriptDragBegan(atUTF16Offset: 0)  // "one"
    model.transcriptDragged(toUTF16Offset: 10)  // into "three"
    expectNoDifference(model.selectedWordIDSet, [1, 2, 3])
    expectNoDifference(model.selectedSampleRange, 0..<1500)
  }

  @Test func dragBackwardStaysContiguous() {
    let model = TranscriptPageModel(editPlan: plan)
    model.transcriptDragBegan(atUTF16Offset: 10)  // "three"
    model.transcriptDragged(toUTF16Offset: 0)  // back to "one"
    expectNoDifference(model.selectedWordIDSet, [1, 2, 3])
  }

  // A drag mutates only the selection; it must not rebuild the document or the
  // run-together set (those are materialized once when the plan loads).
  @Test func dragLeavesDocumentAndRunTogetherUntouched() {
    let model = TranscriptPageModel(editPlan: plan)
    let documentBefore = model.document
    let plainTextBefore = model.plainTranscriptText
    let runTogetherBefore = model.runTogetherWordIDSet

    model.transcriptDragBegan(atUTF16Offset: 0)  // "one"
    model.transcriptDragged(toUTF16Offset: 10)  // into "three"

    expectNoDifference(model.selectedWordIDSet, [1, 2, 3])
    expectNoDifference(model.selectedSampleRange, 0..<1500)
    expectNoDifference(model.document, documentBefore)
    expectNoDifference(model.plainTranscriptText, plainTextBefore)
    expectNoDifference(model.runTogetherWordIDSet, runTogetherBefore)
  }

  @Test func shiftClickExtendsFromAnchorForward() {
    let model = TranscriptPageModel(editPlan: plan)
    model.wordClicked(1, extending: false)  // anchor on "one"
    model.wordClicked(3, extending: true)  // extend to "three"
    expectNoDifference(model.selectedWordIDSet, [1, 2, 3])
    expectNoDifference(model.selectionAnchorID, 1)
    expectNoDifference(model.selectionFocusID, 3)
  }

  @Test func shiftClickExtendsBackwardKeepingAnchor() {
    let model = TranscriptPageModel(editPlan: plan)
    model.wordClicked(3, extending: false)  // anchor on "three"
    model.wordClicked(1, extending: true)  // extend back to "one"
    expectNoDifference(model.selectedWordIDSet, [1, 2, 3])
    expectNoDifference(model.selectionAnchorID, 3)
  }

  @Test func shiftClickWithNoPriorSelectionPlainSelects() {
    let model = TranscriptPageModel(editPlan: plan)
    model.wordClicked(2, extending: true)  // nothing selected yet
    expectNoDifference(model.selectedWordIDSet, [2])
    expectNoDifference(model.selectionAnchorID, 2)
  }

  @Test func shiftClickSameWordStaysSingleWordNotCleared() {
    let model = TranscriptPageModel(editPlan: plan)
    model.wordClicked(2, extending: false)
    model.wordClicked(2, extending: true)  // shift-click the same word
    expectNoDifference(model.selectedWordIDSet, [2])  // does NOT toggle-clear
  }

  @Test func plainClickSameWordTogglesClear() {
    let model = TranscriptPageModel(editPlan: plan)
    model.wordClicked(2, extending: false)
    model.wordClicked(2, extending: false)  // plain re-click clears
    expectNoDifference(model.selectedWordIDSet, [])
  }

  @Test func shiftClickWithStaleAnchorPlainSelects() {
    let model = TranscriptPageModel(editPlan: plan)
    model.selectionAnchorID = 999  // id not in the plan
    model.selectionFocusID = 999
    model.wordClicked(2, extending: true)
    expectNoDifference(model.selectedWordIDSet, [2])
    expectNoDifference(model.selectionAnchorID, 2)
  }

  @Test func hasSelectionFalseWhenAnchorStale() {
    let model = TranscriptPageModel(editPlan: plan)
    model.selectionAnchorID = 999  // set but unresolvable
    model.selectionFocusID = 999
    expectNoDifference(model.hasSelection, false)
  }

  @Test func transcriptClickExtendingRoutesThroughWordClicked() {
    let model = TranscriptPageModel(editPlan: plan)
    model.transcriptClicked(atUTF16Offset: 0, extending: false)  // "one"
    model.transcriptClicked(atUTF16Offset: 10, extending: true)  // extend into "three"
    expectNoDifference(model.selectedWordIDSet, [1, 2, 3])
  }
}
