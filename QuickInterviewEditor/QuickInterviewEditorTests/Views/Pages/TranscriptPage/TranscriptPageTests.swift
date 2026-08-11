import CustomDump
import Dependencies
import Foundation
import Testing

@testable import QuickInterviewEditor

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
    // Word index 4 ("He", id 5) is the first word of the second paragraph.
    model.transcriptClicked(atUTF16Offset: offset(model, wordIndex: 4))
    expectNoDifference(model.selectedWordIDSet, [5])
  }

  /// Dragging a selection that spans a paragraph break stays contiguous and correct —
  /// the break changes offsets but every word still maps to its own range.
  @Test func selectionSpanningParagraphBreakIsContiguous() {
    let model = TranscriptPageModel(editPlan: Fixtures.editPlanV2())
    // From "Hayes." (id 4, end of paragraph 1) through "waits" (id 6, in paragraph 2).
    model.transcriptDragBegan(atUTF16Offset: offset(model, wordIndex: 3))
    model.transcriptDragged(toUTF16Offset: offset(model, wordIndex: 5))
    expectNoDifference(model.selectedWordIDSet, [4, 5, 6])
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

  @Test func selectedSampleRangeMatchesBoundaryWords() async {
    let model = await loadedModel()
    let plan = model.editPlan!
    model.transcriptDragBegan(atUTF16Offset: offset(model, wordIndex: 0))
    model.transcriptDragged(toUTF16Offset: offset(model, wordIndex: 2))
    let expected = plan.words[0].startSample!..<plan.words[2].endSample!
    expectNoDifference(model.selectedSampleRange, expected)
  }

  @Test func clearSelectionEmptiesIt() async {
    let model = await loadedModel()
    model.transcriptDragBegan(atUTF16Offset: offset(model, wordIndex: 0))
    model.transcriptDragged(toUTF16Offset: offset(model, wordIndex: 2))
    model.clearSelectionTapped()
    #expect(!model.hasSelection)
    expectNoDifference(model.selectedWordIDSet, [])
  }

  @Test func sensitivityChangesRunTogetherCount() async {
    let model = await loadedModel()
    model.sensitivityChanged(10)
    let tight = model.runTogetherCount
    model.sensitivityChanged(80)
    let loose = model.runTogetherCount
    #expect(tight < loose)
    // default 30 flags the known 25-pair set → 40 unique words on this fixture
    model.sensitivityChanged(30)
    #expect(model.runTogetherCount > 0)
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
    model.transcriptDragBegan(atUTF16Offset: offset(model, wordIndex: 0))
    model.transcriptDragged(toUTF16Offset: offset(model, wordIndex: 1))
    expectNoDifference(model.selectionSummary, "2 words selected")
    expectNoDifference(model.selectedWordIDSet, [10, 50])
    expectNoDifference(model.selectedSampleRange, words[0].startSample!..<words[1].endSample!)
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

  @Test func orderedSelectionExposesIDsAndSnippet() {
    let model = TranscriptPageModel(editPlan: Fixtures.editPlan())
    let planWords = model.editPlan!.words
    model.transcriptDragBegan(atUTF16Offset: offset(model, wordIndex: 2))
    model.transcriptDragged(toUTF16Offset: offset(model, wordIndex: 4))
    expectNoDifference(
      model.orderedSelectedWordIDs, [planWords[2].id, planWords[3].id, planWords[4].id])
    #expect(!model.selectionSnippet.isEmpty)
    #expect(model.selectionSnippet == model.selectionSnippet.trimmingCharacters(in: .whitespaces))
  }

  @Test func orderedSelectionEmptyWithoutSelection() {
    let model = TranscriptPageModel(editPlan: Fixtures.editPlan())
    expectNoDifference(model.orderedSelectedWordIDs, [])
    expectNoDifference(model.selectionSnippet, "")
  }
}
