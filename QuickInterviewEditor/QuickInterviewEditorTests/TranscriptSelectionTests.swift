import CustomDump
import Testing

@testable import QuickInterviewEditor

/// The transcript no longer owns the selection — its gesture handlers emit a `SelectionIntent`
/// that `EditorModel` turns into the authoritative `audioSelection`. These tests assert the
/// gesture→intent mapping (which words a click/drag/shift resolves to); the source-range and
/// contiguous-run derivations are covered at the `EditorModel` level.
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

  /// Captures the last selection intent the gesture emitted.
  private func spy(_ model: TranscriptPageModel) -> () -> TranscriptPageModel.SelectionIntent? {
    var last: TranscriptPageModel.SelectionIntent?
    model.onSelectionIntent = { last = $0 }
    return { last }
  }

  @Test func clickSelectsSingleWord() {
    let model = TranscriptPageModel(editPlan: plan)
    let intent = spy(model)
    model.transcriptClicked(atUTF16Offset: 5)  // inside "two"
    expectNoDifference(intent(), .word(2, extending: false))
  }

  @Test func clickingSoleSelectedWordClearsIt() {
    let model = TranscriptPageModel(editPlan: plan)
    let intent = spy(model)
    model.transcriptClicked(atUTF16Offset: 5)
    model.transcriptClicked(atUTF16Offset: 5)
    expectNoDifference(intent(), .clear)
  }

  @Test func dragPaintsContiguousRun() {
    let model = TranscriptPageModel(editPlan: plan)
    let intent = spy(model)
    model.transcriptDragBegan(atUTF16Offset: 0)  // "one"
    model.transcriptDragged(toUTF16Offset: 10)  // into "three"
    expectNoDifference(intent(), .words(anchor: 1, focus: 3))
    expectNoDifference(model.selectionSummary, "3 words selected")
  }

  @Test func dragBackwardStaysContiguous() {
    let model = TranscriptPageModel(editPlan: plan)
    let intent = spy(model)
    model.transcriptDragBegan(atUTF16Offset: 10)  // "three"
    model.transcriptDragged(toUTF16Offset: 0)  // back to "one"
    expectNoDifference(intent(), .words(anchor: 3, focus: 1))
    expectNoDifference(model.selectionSummary, "3 words selected")
  }

  // A drag mutates only the selection; it must not rebuild the document or the
  // run-together set (those are materialized once when the plan loads).
  @Test func dragLeavesDocumentAndRunTogetherUntouched() {
    let model = TranscriptPageModel(editPlan: plan)
    let intent = spy(model)
    let documentBefore = model.document
    let plainTextBefore = model.plainTranscriptText
    let runTogetherBefore = model.runTogetherWordIDSet

    model.transcriptDragBegan(atUTF16Offset: 0)  // "one"
    model.transcriptDragged(toUTF16Offset: 10)  // into "three"

    expectNoDifference(intent(), .words(anchor: 1, focus: 3))
    expectNoDifference(model.document, documentBefore)
    expectNoDifference(model.plainTranscriptText, plainTextBefore)
    expectNoDifference(model.runTogetherWordIDSet, runTogetherBefore)
  }

  @Test func shiftClickExtendsFromAnchorForward() {
    let model = TranscriptPageModel(editPlan: plan)
    let intent = spy(model)
    model.wordClicked(1, extending: false)  // anchor on "one"
    model.wordClicked(3, extending: true)  // extend to "three"
    expectNoDifference(intent(), .words(anchor: 1, focus: 3))
  }

  @Test func shiftClickExtendsBackwardKeepingAnchor() {
    let model = TranscriptPageModel(editPlan: plan)
    let intent = spy(model)
    model.wordClicked(3, extending: false)  // anchor on "three"
    model.wordClicked(1, extending: true)  // extend back to "one"
    expectNoDifference(intent(), .words(anchor: 3, focus: 1))
  }

  @Test func shiftClickWithNoPriorSelectionPlainSelects() {
    let model = TranscriptPageModel(editPlan: plan)
    let intent = spy(model)
    model.wordClicked(2, extending: true)  // nothing selected yet
    expectNoDifference(intent(), .word(2, extending: false))
  }

  @Test func shiftClickSameWordStaysSingleWordNotCleared() {
    let model = TranscriptPageModel(editPlan: plan)
    let intent = spy(model)
    model.wordClicked(2, extending: false)
    model.wordClicked(2, extending: true)  // shift-click the same word
    expectNoDifference(intent(), .words(anchor: 2, focus: 2))  // does NOT toggle-clear
  }

  @Test func plainClickSameWordTogglesClear() {
    let model = TranscriptPageModel(editPlan: plan)
    let intent = spy(model)
    model.wordClicked(2, extending: false)
    model.wordClicked(2, extending: false)  // plain re-click clears
    expectNoDifference(intent(), .clear)
  }

  @Test func transcriptClickExtendingRoutesThroughWordClicked() {
    let model = TranscriptPageModel(editPlan: plan)
    let intent = spy(model)
    model.transcriptClicked(atUTF16Offset: 0, extending: false)  // "one"
    model.transcriptClicked(atUTF16Offset: 10, extending: true)  // extend into "three"
    expectNoDifference(intent(), .words(anchor: 1, focus: 3))
  }
}
