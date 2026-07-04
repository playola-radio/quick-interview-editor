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
}
