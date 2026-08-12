import CustomDump
import Testing

@testable import QuickInterviewEditor

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
    model.selectWords(anchorID: 1, focusID: 3)
    expectNoDifference(model.selectedWordIDSet, [1, 2, 3])
    expectNoDifference(model.selectedSampleRange, 0..<1500)
    expectNoDifference(model.selectionAnchorID, 1)
    expectNoDifference(model.selectionFocusID, 3)
  }

  @Test func selectWordsWithAnUnknownIDLeavesSelectionUntouched() {
    let model = TranscriptPageModel(editPlan: plan)
    model.selectWord(2)
    model.selectWords(anchorID: 1, focusID: 999)
    expectNoDifference(model.selectedWordIDSet, [2])
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
