import CustomDump
import Testing

@testable import QuickInterviewEditor

@MainActor
struct TranscriptFollowTests {
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

  @Test func playheadWhileFollowingUpdatesScrollTarget() {
    let model = TranscriptPageModel(editPlan: plan)
    model.playheadChanged(sample: 1500, isPlaying: true)
    expectNoDifference(model.scrollTargetWordID, 2)
  }

  @Test func userScrollPausesFollowSoPlayheadStopsMovingTarget() {
    let model = TranscriptPageModel(editPlan: plan)
    model.playheadChanged(sample: 1500, isPlaying: true)
    model.transcriptUserScrolled()
    expectNoDifference(model.followMode, .userPaused)
    model.playheadChanged(sample: 2500, isPlaying: true)
    expectNoDifference(model.scrollTargetWordID, 2)  // unchanged while paused
  }

  @Test func playbackRestartResumesFollowing() {
    let model = TranscriptPageModel(editPlan: plan)
    model.playheadChanged(sample: 1500, isPlaying: true)
    model.transcriptUserScrolled()
    model.playheadChanged(sample: 0, isPlaying: false)  // stop
    model.playheadChanged(sample: 200, isPlaying: true)  // rising edge → resume
    expectNoDifference(model.followMode, .following)
    expectNoDifference(model.scrollTargetWordID, 1)
  }
}
