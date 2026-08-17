import CustomDump
import Testing

@testable import QuickInterviewEditor

@MainActor
struct TranscriptCurrentWordTests {
  private var plan: EditPlan {
    EditPlan(
      schemaVersion: 1,
      source: .init(path: "", sampleRate: 1000, channels: 1, durationSamples: 3000),
      words: [
        Word(id: 1, text: "one", start: 0, end: 1, startSample: 0, endSample: 1000),
        Word(id: 2, text: "two", start: 1, end: 2, startSample: 1000, endSample: 2000),
        Word(id: 3, text: "three", start: 2, end: 3, startSample: 2000, endSample: 3000),
      ], silences: [], segments: [])
  }

  @Test func noCurrentWordUntilTheCursorPlacesOne() {
    let model = TranscriptPageModel(editPlan: plan)
    expectNoDifference(model.currentWordID, nil)
    expectNoDifference(model.canScrollToCurrentWord, false)
  }

  /// The "scroll to current word" button re-reveals the current word and resumes follow, even
  /// after the user scrolled away.
  @Test func scrollToCurrentWordRevealsItAndResumesFollow() {
    let model = TranscriptPageModel(editPlan: plan)
    model.currentWordID = 2
    model.transcriptUserScrolled()
    #expect(model.canScrollToCurrentWord)
    model.scrollToCurrentWordTapped()
    expectNoDifference(model.followMode, .following)
    expectNoDifference(model.reveal?.wordID, 2)
  }

  @Test func scrollToCurrentWordIsNoOpWithoutACurrentWord() {
    let model = TranscriptPageModel(editPlan: plan)
    model.scrollToCurrentWordTapped()
    expectNoDifference(model.reveal, nil)
  }
}
