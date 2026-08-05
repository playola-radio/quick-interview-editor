import CustomDump
import Foundation
import Testing
@testable import QuickInterviewEditor

@MainActor
struct TranscriptRunTogetherRangesTests {
  private var plan: EditPlan {
    EditPlan(
      schemaVersion: 1,
      source: .init(path: "", sampleRate: 1000, channels: 1, durationSamples: 3000),
      words: [
        Word(id: 1, text: "one", start: 0.0, end: 0.10, startSample: 0, endSample: 100),
        Word(id: 2, text: "two", start: 0.12, end: 0.30, startSample: 120, endSample: 300),  // 20ms gap
        Word(id: 3, text: "three", start: 0.90, end: 1.0, startSample: 900, endSample: 1000),
      ], silences: [], segments: [])
  }

  @Test func exposesRunTogetherSetAndRanges() {
    let model = TranscriptPageModel(editPlan: plan)  // default 30ms → words 1,2 run together
    expectNoDifference(model.runTogetherWordIDSet, [1, 2])
    expectNoDifference(model.runTogetherSampleRanges, [0..<100, 120..<300])
    expectNoDifference(model.runTogetherCount, 2)
  }

  @Test func editorRedRangesTrackTranscript() {
    let editor = EditorModel(
      sourceURL: URL(fileURLWithPath: "/tmp/x.wav"),
      canonicalAudioURL: URL(fileURLWithPath: "/tmp/x.aiff"),
      editPlan: plan)
    expectNoDifference(editor.redRanges, [0..<100, 120..<300])
  }

  /// A malformed plan with a duplicate word ID among run-together words must not emit one
  /// range per occurrence — matching the old `words` array's dedup-by-first-occurrence
  /// semantics (`IdentifiedArray(states, uniquingIDsWith: { first, _ in first })`).
  private var planWithDuplicateRunTogetherID: EditPlan {
    EditPlan(
      schemaVersion: 1,
      source: .init(path: "", sampleRate: 1000, channels: 1, durationSamples: 3000),
      words: [
        Word(id: 1, text: "one", start: 0.0, end: 0.10, startSample: 0, endSample: 100),
        Word(id: 2, text: "two", start: 0.12, end: 0.30, startSample: 120, endSample: 300),  // 20ms gap
        Word(id: 2, text: "two-dup", start: 0.50, end: 0.60, startSample: 500, endSample: 600),
        Word(id: 3, text: "three", start: 0.90, end: 1.0, startSample: 900, endSample: 1000),
      ], silences: [], segments: [])
  }

  @Test func runTogetherSampleRangesDedupesDuplicateWordIDKeepingFirstOccurrence() {
    let model = TranscriptPageModel(editPlan: planWithDuplicateRunTogetherID)
    expectNoDifference(model.runTogetherWordIDSet, [1, 2])
    expectNoDifference(model.runTogetherSampleRanges, [0..<100, 120..<300])
  }
}
