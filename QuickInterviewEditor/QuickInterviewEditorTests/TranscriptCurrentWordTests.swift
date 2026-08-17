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

  @Test func playheadHighlightsTheWordUnderIt() {
    let model = TranscriptPageModel(editPlan: plan)
    model.playheadChanged(sample: 1500, isPlaying: true)
    expectNoDifference(model.currentWordID, 2)
  }

  /// The highlight follows the playhead even after the user has paused auto-scroll — it tracks
  /// what's being SAID, independent of where the transcript is scrolled.
  @Test func highlightTracksEvenWhenFollowIsPaused() {
    let model = TranscriptPageModel(editPlan: plan)
    model.playheadChanged(sample: 500, isPlaying: true)
    model.transcriptUserScrolled()
    expectNoDifference(model.followMode, .userPaused)
    model.playheadChanged(sample: 2500, isPlaying: true)
    expectNoDifference(model.currentWordID, 3)  // highlight moved
    expectNoDifference(model.scrollTargetWordID, 1)  // but scroll did not
  }

  /// A playhead that lands in a gap between words (or past the end) leaves the highlight on the
  /// last word rather than clearing it.
  @Test func playheadInAGapKeepsThePreviousWord() {
    let model = TranscriptPageModel(editPlan: plan)
    model.playheadChanged(sample: 500, isPlaying: true)
    model.playheadChanged(sample: 9999, isPlaying: true)  // past the end
    expectNoDifference(model.currentWordID, 1)
  }

  @Test func noCurrentWordUntilPlaybackStarts() {
    let model = TranscriptPageModel(editPlan: plan)
    expectNoDifference(model.currentWordID, nil)
    expectNoDifference(model.canScrollToCurrentWord, false)
  }

  /// The "scroll to current word" button re-reveals the current word and resumes follow, even
  /// after the user scrolled away.
  @Test func scrollToCurrentWordRevealsItAndResumesFollow() {
    let model = TranscriptPageModel(editPlan: plan)
    model.playheadChanged(sample: 1500, isPlaying: true)
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
