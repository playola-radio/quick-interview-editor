import CustomDump
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct TranscriptRevealTests {
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

  @Test func selectWordsSelectsTheContiguousRun() {
    let model = TranscriptPageModel(editPlan: plan)
    var intent: TranscriptPageModel.SelectionIntent?
    model.onSelectionIntent = { intent = $0 }
    #expect(model.selectWords(anchorID: 1, focusID: 3))
    expectNoDifference(intent, .words(anchor: 1, focus: 3))
    expectNoDifference(model.selectionSummary, "3 words selected")
  }

  @Test func selectWordsWithAnUnknownIDLeavesSelectionUntouched() {
    let model = TranscriptPageModel(editPlan: plan)
    var intent: TranscriptPageModel.SelectionIntent?
    model.onSelectionIntent = { intent = $0 }
    model.selectWord(2)
    // An unknown focus resolves to nothing: `selectWords` returns false and emits no new intent.
    #expect(!model.selectWords(anchorID: 1, focusID: 999))
    expectNoDifference(intent, .word(2, extending: false))
  }

  @Test func revealSelectionTargetsTheFirstSelectedWord() {
    let model = TranscriptPageModel(editPlan: plan)
    model.selectWords(anchorID: 1, focusID: 3)
    model.revealSelection()
    expectNoDifference(model.reveal, TranscriptReveal(wordID: 1, token: 1))
  }

  @Test func revealSelectionBumpsTheTokenEachTimeSoARepeatReScrolls() {
    let model = TranscriptPageModel(editPlan: plan)
    model.selectWords(anchorID: 2, focusID: 2)
    model.revealSelection()
    model.revealSelection()
    expectNoDifference(model.reveal, TranscriptReveal(wordID: 2, token: 2))
  }

  @Test func revealSelectionIsANoOpWithNoSelection() {
    let model = TranscriptPageModel(editPlan: plan)
    model.revealSelection()
    #expect(model.reveal == nil)
  }
}
