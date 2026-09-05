import CustomDump
import Dependencies
import Foundation
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct TranscriptPageTests {
  private func runTogetherID(_ model: TranscriptPageModel, text: String) -> Word.ID {
    model.editPlan!.words.first { $0.text == text }!.id
  }

  @Test func initWithEditPlanPopulatesWordsImmediately() {
    let model = TranscriptPageModel(editPlan: Fixtures.editPlan())
    expectNoDifference(model.document.wordRanges.count, 122)
    #expect(model.runTogetherWordIDSet.contains(runTogetherID(model, text: "want")))
  }

  @Test func initWithV2PlanExposesPauseParagraphs() {
    let model = TranscriptPageModel(editPlan: Fixtures.editPlanV2())
    expectNoDifference(
      model.paragraphs.map(\.wordIDs), [[1, 2, 3, 4], [5, 6, 7, 8, 9], [10, 11, 12]])
  }

  @Test func v2PlanTranscriptBreaksParagraphsWithNewlines() {
    let model = TranscriptPageModel(editPlan: Fixtures.editPlanV2())
    expectNoDifference(
      model.plainTranscriptText, "So a young Hayes.\nHe waits around the concert.\nThen he leaves.")
  }

  /// Clicking the first word after a paragraph break resolves to that word: the newline
  /// separator did not shift the range map, so hit-testing still lands on the right word.
  @Test func clickingWordAfterParagraphBreakSelectsIt() {
    let model = TranscriptPageModel(editPlan: Fixtures.editPlanV2())
    var intent: TranscriptPageModel.SelectionIntent?
    model.onSelectionIntent = { intent = $0 }
    // Word index 4 ("He", id 5) is the first word of the second paragraph.
    model.transcriptClicked(atUTF16Offset: offset(model, wordIndex: 4))
    expectNoDifference(intent, .word(5, extending: false))
  }

  /// Dragging a selection that spans a paragraph break stays contiguous and correct —
  /// the break changes offsets but every word still maps to its own range.
  @Test func selectionSpanningParagraphBreakIsContiguous() {
    let model = TranscriptPageModel(editPlan: Fixtures.editPlanV2())
    var intent: TranscriptPageModel.SelectionIntent?
    model.onSelectionIntent = { intent = $0 }
    // From "Hayes." (id 4, end of paragraph 1) through "waits" (id 6, in paragraph 2).
    model.transcriptDragBegan(atUTF16Offset: offset(model, wordIndex: 3))
    model.transcriptDragged(toUTF16Offset: offset(model, wordIndex: 5))
    expectNoDifference(intent, .words(anchor: 4, focus: 6))
    expectNoDifference(model.selectionSummary, "3 words selected")
  }

  @Test func viewAppearedLoadsWords() async {
    await withDependencies {
      $0.engine.loadPlan = { _ in Fixtures.editPlan() }
    } operation: {
      let model = TranscriptPageModel(planURL: URL(fileURLWithPath: "/unused"))
      await model.viewAppeared()
      expectNoDifference(model.document.wordRanges.count, 122)
      #expect(model.runTogetherWordIDSet.contains(runTogetherID(model, text: "want")))
    }
  }

  private func loadedModel() async -> TranscriptPageModel {
    let model = TranscriptPageModel(planURL: URL(fileURLWithPath: "/unused"))
    await withDependencies {
      $0.engine.loadPlan = { _ in Fixtures.editPlan() }
    } operation: {
      await model.viewAppeared()
    }
    return model
  }

  private func offset(_ model: TranscriptPageModel, wordIndex: Int) -> Int {
    model.document.wordRanges[wordIndex].range.location
  }

  @Test func clickSelectsSingleWordSummary() async {
    let model = await loadedModel()
    model.transcriptClicked(atUTF16Offset: offset(model, wordIndex: 0))
    expectNoDifference(model.selectionSummary, "1 word selected")
  }

  @Test func dragEmitsBoundaryWordIntent() async {
    let model = await loadedModel()
    let plan = model.editPlan!
    var intent: TranscriptPageModel.SelectionIntent?
    model.onSelectionIntent = { intent = $0 }
    model.transcriptDragBegan(atUTF16Offset: offset(model, wordIndex: 0))
    model.transcriptDragged(toUTF16Offset: offset(model, wordIndex: 2))
    expectNoDifference(intent, .words(anchor: plan.words[0].id, focus: plan.words[2].id))
  }

  @Test func clearSelectionEmptiesIt() async {
    let model = await loadedModel()
    var intent: TranscriptPageModel.SelectionIntent?
    model.onSelectionIntent = { intent = $0 }
    model.transcriptDragBegan(atUTF16Offset: offset(model, wordIndex: 0))
    model.transcriptDragged(toUTF16Offset: offset(model, wordIndex: 2))
    model.clearSelectionTapped()
    #expect(!model.hasSelection)
    expectNoDifference(intent, .clear)
  }

  @Test func runTogetherSetPopulatedAtDefaultThreshold() async {
    let model = await loadedModel()
    // Detection still runs at the fixed default threshold and is stored, even though
    // nothing renders it — the "want" → "to" fused pair is flagged.
    #expect(!model.runTogetherWordIDSet.isEmpty)
    #expect(model.runTogetherWordIDSet.contains(runTogetherID(model, text: "want")))
  }

  // MARK: - Synthetic-plan regression tests

  private func word(
    _ id: Int, _ text: String, start: Double, end: Double
  ) -> EditPlan.Word {
    EditPlan.Word(
      id: id, text: text, start: start, end: end,
      startSample: Int(start * 44100), endSample: Int(end * 44100))
  }

  private func plan(_ words: [EditPlan.Word]) -> EditPlan {
    EditPlan(
      schemaVersion: 1,
      source: EditPlan.Source(
        path: "test", sampleRate: 44100, channels: 1, durationSamples: 1_000_000),
      words: words, silences: [], segments: [])
  }

  private func modelLoaded(with words: [EditPlan.Word]) async -> TranscriptPageModel {
    let model = TranscriptPageModel(planURL: URL(fileURLWithPath: "/unused"))
    let synthetic = plan(words)
    await withDependencies {
      $0.engine.loadPlan = { _ in synthetic }
    } operation: {
      await model.viewAppeared()
    }
    return model
  }

  /// Proves the `engine.loadPlan` override is actually exercised: a 2-word
  /// sentinel plan can never be the 122-word bundled fixture, so if injection
  /// were bypassed (e.g. via testValue → .fixture) this would see 122 words.
  @Test func viewAppearedUsesInjectedEngineNotBundle() async {
    let model = await modelLoaded(with: [
      word(1, "alpha", start: 0, end: 0.2),
      word(2, "beta", start: 0.4, end: 0.6),
    ])
    expectNoDifference(
      model.plainTranscriptText.split(separator: " ").map(String.init), ["alpha", "beta"])
  }

  /// Selection counts words by POSITION, not by ID span. With sparse IDs the
  /// old `min(id)...max(id)` arithmetic reported the span (41) and could select
  /// unrelated in-range words.
  @Test func selectionCountsWordsByPositionNotIDSpan() async {
    let words = [
      word(10, "a", start: 0, end: 0.1),
      word(50, "b", start: 0.2, end: 0.3),
      word(90, "c", start: 0.4, end: 0.5),
    ]
    let model = await modelLoaded(with: words)
    var intent: TranscriptPageModel.SelectionIntent?
    model.onSelectionIntent = { intent = $0 }
    model.transcriptDragBegan(atUTF16Offset: offset(model, wordIndex: 0))
    model.transcriptDragged(toUTF16Offset: offset(model, wordIndex: 1))
    expectNoDifference(model.selectionSummary, "2 words selected")
    expectNoDifference(intent, .words(anchor: 10, focus: 50))
  }

  /// A malformed plan with duplicate word IDs must not trap the app on load.
  @Test func duplicateWordIDsDoNotTrap() async {
    let model = await modelLoaded(with: [
      word(1, "a", start: 0, end: 0.1),
      word(1, "dup", start: 0.2, end: 0.3),
      word(2, "b", start: 0.4, end: 0.5),
    ])
    expectNoDifference(model.document.wordRanges.count, 3)
    expectNoDifference(model.plainTranscriptText, "a dup b")
  }

}
