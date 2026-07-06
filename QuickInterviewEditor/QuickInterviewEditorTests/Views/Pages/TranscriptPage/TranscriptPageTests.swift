import CustomDump
import Dependencies
import Foundation
import Testing

@testable import QuickInterviewEditor

@MainActor
struct TranscriptPageTests {
  @Test func initWithEditPlanPopulatesWordsImmediately() {
    let model = TranscriptPageModel(editPlan: Fixtures.editPlan())
    expectNoDifference(model.words.count, 122)
    #expect(model.words.first { $0.text == "want" }?.isRunTogether == true)
  }

  @Test func viewAppearedLoadsWords() async {
    await withDependencies {
      $0.engine.loadPlan = { _ in Fixtures.editPlan() }
    } operation: {
      let model = TranscriptPageModel(planURL: URL(fileURLWithPath: "/unused"))
      await model.viewAppeared()
      expectNoDifference(model.words.count, 122)
      #expect(model.words.first { $0.text == "want" }?.isRunTogether == true)
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

  @Test func firstClickSelectsSingleWord() async {
    let model = await loadedModel()
    model.wordTapped(1)
    #expect(model.words[id: 1]?.isSelected == true)
    #expect(model.words[id: 2]?.isSelected == false)
    expectNoDifference(model.selectionSummary, "1 word selected")
  }

  @Test func secondClickExtendsInclusiveRange() async {
    let model = await loadedModel()
    model.wordTapped(1)
    model.wordTapped(3)
    #expect(model.words[id: 1]?.isSelected == true)
    #expect(model.words[id: 2]?.isSelected == true)
    #expect(model.words[id: 3]?.isSelected == true)
    #expect(model.words[id: 4]?.isSelected == false)
    expectNoDifference(model.selectionSummary, "3 words selected")
  }

  @Test func thirdClickResetsSelection() async {
    let model = await loadedModel()
    model.wordTapped(1)
    model.wordTapped(3)
    model.wordTapped(5)
    #expect(model.words[id: 1]?.isSelected == false)
    #expect(model.words[id: 5]?.isSelected == true)
    expectNoDifference(model.selectionSummary, "1 word selected")
  }

  @Test func selectedSampleRangeMatchesBoundaryWords() async {
    let model = await loadedModel()
    model.wordTapped(1)
    model.wordTapped(3)
    let plan = model.editPlan!
    let expected = plan.words[0].startSample!..<plan.words[2].endSample!
    expectNoDifference(model.selectedSampleRange, expected)
  }

  @Test func clearSelectionEmptiesIt() async {
    let model = await loadedModel()
    model.wordTapped(1)
    model.wordTapped(3)
    model.clearSelectionTapped()
    #expect(!model.hasSelection)
    #expect(model.words[id: 2]?.isSelected == false)
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
    expectNoDifference(model.words.map(\.text), ["alpha", "beta"])
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
    model.wordTapped(10)
    model.wordTapped(50)
    expectNoDifference(model.selectionSummary, "2 words selected")
    #expect(model.words[id: 10]?.isSelected == true)
    #expect(model.words[id: 50]?.isSelected == true)
    #expect(model.words[id: 90]?.isSelected == false)
    expectNoDifference(model.selectedSampleRange, words[0].startSample!..<words[1].endSample!)
  }

  /// A malformed plan with duplicate word IDs must not trap the app on load.
  @Test func duplicateWordIDsDoNotTrap() async {
    let model = await modelLoaded(with: [
      word(1, "a", start: 0, end: 0.1),
      word(1, "dup", start: 0.2, end: 0.3),
      word(2, "b", start: 0.4, end: 0.5),
    ])
    expectNoDifference(model.words.count, 2)
    expectNoDifference(model.words[id: 1]?.text, "a")
  }
}
