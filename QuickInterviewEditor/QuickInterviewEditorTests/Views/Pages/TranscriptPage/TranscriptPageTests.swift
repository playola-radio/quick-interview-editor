import CustomDump
import Dependencies
import Foundation
import Testing
@testable import QuickInterviewEditor

@MainActor
struct TranscriptPageTests {
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
    let m = TranscriptPageModel(planURL: URL(fileURLWithPath: "/unused"))
    await withDependencies { $0.engine.loadPlan = { _ in Fixtures.editPlan() } } operation: {
      await m.viewAppeared()
    }
    return m
  }

  @Test func firstClickSelectsSingleWord() async {
    let m = await loadedModel()
    m.wordTapped(1)
    #expect(m.words[id: 1]?.isSelected == true)
    #expect(m.words[id: 2]?.isSelected == false)
    expectNoDifference(m.selectionSummary, "1 word selected")
  }

  @Test func secondClickExtendsInclusiveRange() async {
    let m = await loadedModel()
    m.wordTapped(1)
    m.wordTapped(3)
    #expect(m.words[id: 1]?.isSelected == true)
    #expect(m.words[id: 2]?.isSelected == true)
    #expect(m.words[id: 3]?.isSelected == true)
    #expect(m.words[id: 4]?.isSelected == false)
    expectNoDifference(m.selectionSummary, "3 words selected")
  }

  @Test func thirdClickResetsSelection() async {
    let m = await loadedModel()
    m.wordTapped(1); m.wordTapped(3); m.wordTapped(5)
    #expect(m.words[id: 1]?.isSelected == false)
    #expect(m.words[id: 5]?.isSelected == true)
    expectNoDifference(m.selectionSummary, "1 word selected")
  }

  @Test func selectedSampleRangeMatchesBoundaryWords() async {
    let m = await loadedModel()
    m.wordTapped(1); m.wordTapped(3)
    let plan = m.editPlan!
    let expected = plan.words[0].startSample!..<plan.words[2].endSample!
    expectNoDifference(m.selectedSampleRange, expected)
  }

  @Test func clearSelectionEmptiesIt() async {
    let m = await loadedModel()
    m.wordTapped(1); m.wordTapped(3)
    m.clearSelectionTapped()
    #expect(!m.hasSelection)
    #expect(m.words[id: 2]?.isSelected == false)
  }

  @Test func sensitivityChangesRunTogetherCount() async {
    let m = await loadedModel()
    m.sensitivityChanged(10)
    let tight = m.runTogetherCount
    m.sensitivityChanged(80)
    let loose = m.runTogetherCount
    #expect(tight < loose)
    // default 30 flags the known 25-pair set → 40 unique words on this fixture
    m.sensitivityChanged(30)
    #expect(m.runTogetherCount > 0)
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
    let m = TranscriptPageModel(planURL: URL(fileURLWithPath: "/unused"))
    let synthetic = plan(words)
    await withDependencies { $0.engine.loadPlan = { _ in synthetic } } operation: {
      await m.viewAppeared()
    }
    return m
  }

  /// Proves the `engine.loadPlan` override is actually exercised: a 2-word
  /// sentinel plan can never be the 122-word bundled fixture, so if injection
  /// were bypassed (e.g. via testValue → .fixture) this would see 122 words.
  @Test func viewAppearedUsesInjectedEngineNotBundle() async {
    let m = await modelLoaded(with: [
      word(1, "alpha", start: 0, end: 0.2),
      word(2, "beta", start: 0.4, end: 0.6),
    ])
    expectNoDifference(m.words.map(\.text), ["alpha", "beta"])
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
    let m = await modelLoaded(with: words)
    m.wordTapped(10)
    m.wordTapped(50)
    expectNoDifference(m.selectionSummary, "2 words selected")
    #expect(m.words[id: 10]?.isSelected == true)
    #expect(m.words[id: 50]?.isSelected == true)
    #expect(m.words[id: 90]?.isSelected == false)
    expectNoDifference(m.selectedSampleRange, words[0].startSample!..<words[1].endSample!)
  }

  /// A malformed plan with duplicate word IDs must not trap the app on load.
  @Test func duplicateWordIDsDoNotTrap() async {
    let m = await modelLoaded(with: [
      word(1, "a", start: 0, end: 0.1),
      word(1, "dup", start: 0.2, end: 0.3),
      word(2, "b", start: 0.4, end: 0.5),
    ])
    expectNoDifference(m.words.count, 2)
    expectNoDifference(m.words[id: 1]?.text, "a")
  }
}
