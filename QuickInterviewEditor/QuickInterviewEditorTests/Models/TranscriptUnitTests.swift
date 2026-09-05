import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

struct TranscriptUnitTests {

  @Test func bundledFixtureBuildsOneUnitCoveringAllWords() {
    // The engine fixture is one silence-aware chunk over all 122 words.
    let plan = Fixtures.editPlan()
    let units = plan.transcriptUnits

    expectNoDifference(units.count, 1)
    let unit = units[0]
    expectNoDifference(unit.id, plan.segments[0].index)
    expectNoDifference(unit.wordIDs.count, 122)
    expectNoDifference(unit.speakerID, nil)
    #expect(unit.text.hasPrefix("So a"))
    // Samples are the min/max of the member words, not from any segment field.
    expectNoDifference(unit.startSample, plan.words.compactMap(\.startSample).min())
    expectNoDifference(unit.endSample, plan.words.compactMap(\.endSample).max())
  }

  @Test func derivesTextAndSamplesFromMemberWords() {
    let plan = EditPlan(
      schemaVersion: 1,
      source: EditPlan.Source(path: "t", sampleRate: 44100, channels: 1, durationSamples: 1000),
      words: [
        EditPlan.Word(id: 1, text: "hello", start: 0, end: 0.1, startSample: 10, endSample: 100),
        EditPlan.Word(id: 2, text: "world", start: 0.2, end: 0.3, startSample: 120, endSample: 250),
      ],
      silences: [],
      segments: [
        EditPlan.Segment(
          index: 0, outputName: "x", wordIDs: [1, 2], startStatus: "clean", endStatus: "clean")
      ])

    expectNoDifference(
      plan.transcriptUnits,
      [
        TranscriptUnit(
          id: 0, text: "hello world", wordIDs: [1, 2], startSample: 10, endSample: 250,
          startSec: 0, endSec: 0.3, speakerID: nil)
      ])
  }

  @Test func fallsBackToSampleBoundForEndSecWhenLastWordHasNoEnd() {
    // The final word carries no `end` second but does carry sample bounds: `endSec` must
    // track `endSample` (88200 / 44100 = 2.0s), not collapse onto an earlier word's end.
    let plan = EditPlan(
      schemaVersion: 1,
      source: EditPlan.Source(path: "t", sampleRate: 44100, channels: 1, durationSamples: 100_000),
      words: [
        EditPlan.Word(id: 1, text: "hello", start: 0, end: 0.5, startSample: 0, endSample: 22050),
        EditPlan.Word(
          id: 2, text: "world", start: 1, end: nil, startSample: 44100, endSample: 88200),
      ],
      silences: [],
      segments: [
        EditPlan.Segment(
          index: 0, outputName: "x", wordIDs: [1, 2], startStatus: "clean", endStatus: "clean")
      ])
    let unit = plan.transcriptUnits[0]
    expectNoDifference(unit.endSample, 88200)
    expectNoDifference(unit.endSec, 2.0)
  }

  @Test func includesOnlyWordsThatCarrySampleBounds() {
    // The middle word has no sample bounds: it must drop out of the unit's IDs, text, and
    // span so the cutter is never handed a word it can't anchor in audio.
    let plan = EditPlan(
      schemaVersion: 1,
      source: EditPlan.Source(path: "t", sampleRate: 44100, channels: 1, durationSamples: 1000),
      words: [
        EditPlan.Word(id: 1, text: "hello", start: 0, end: 0.1, startSample: 10, endSample: 100),
        EditPlan.Word(id: 2, text: "gap", start: 0.2, end: 0.3, startSample: nil, endSample: nil),
        EditPlan.Word(id: 3, text: "world", start: 0.4, end: 0.5, startSample: 120, endSample: 250),
      ],
      silences: [],
      segments: [
        EditPlan.Segment(
          index: 0, outputName: "x", wordIDs: [1, 2, 3], startStatus: "clean", endStatus: "clean")
      ])
    let unit = plan.transcriptUnits[0]
    expectNoDifference(unit.wordIDs, [1, 3])
    expectNoDifference(unit.text, "hello world")
    expectNoDifference(unit.startSample, 10)
    expectNoDifference(unit.endSample, 250)
  }

  @Test func buildsUnitsFromTranscriptSegmentsWhenOutputSegmentsAreEmpty() {
    // A freshly analyzed v2 plan: the WhisperX sentence grouping is in
    // `transcript_segments`; the output `segments` are EMPTY (populated only on
    // cut/render). Units must come from the grouping, or the cutter gets nothing.
    let plan = EditPlan(
      schemaVersion: 2,
      source: EditPlan.Source(path: "t", sampleRate: 44100, channels: 1, durationSamples: 1000),
      words: [
        EditPlan.Word(id: 1, text: "hello", start: 0, end: 0.1, startSample: 10, endSample: 100),
        EditPlan.Word(id: 2, text: "world", start: 0.2, end: 0.3, startSample: 120, endSample: 250),
      ],
      silences: [],
      segments: [],  // no output slices yet — this is a plan, not a cut
      transcriptSegments: [
        EditPlan.TranscriptSegment(id: 7, wordIDs: [1, 2], text: "hello world")
      ])

    expectNoDifference(
      plan.transcriptUnits,
      [
        TranscriptUnit(
          id: 7, text: "hello world", wordIDs: [1, 2], startSample: 10, endSample: 250,
          startSec: 0, endSec: 0.3, speakerID: nil)
      ])
  }

  @Test func transcriptSegmentsTakePrecedenceOverOutputSegments() {
    // When both are present, the sentence grouping wins (output segments are slices,
    // not the LLM's sentence-level input).
    let plan = EditPlan(
      schemaVersion: 2,
      source: EditPlan.Source(path: "t", sampleRate: 44100, channels: 1, durationSamples: 1000),
      words: [
        EditPlan.Word(id: 1, text: "a", start: 0, end: 0.1, startSample: 10, endSample: 100),
        EditPlan.Word(id: 2, text: "b", start: 0.2, end: 0.3, startSample: 120, endSample: 250),
      ],
      silences: [],
      segments: [
        EditPlan.Segment(
          index: 0, outputName: "x", wordIDs: [1, 2], startStatus: "clean", endStatus: "clean")
      ],
      transcriptSegments: [
        EditPlan.TranscriptSegment(id: 5, wordIDs: [1], text: "a"),
        EditPlan.TranscriptSegment(id: 6, wordIDs: [2], text: "b"),
      ])

    expectNoDifference(plan.transcriptUnits.map(\.id), [5, 6])
    expectNoDifference(plan.transcriptUnits.map(\.wordIDs), [[1], [2]])
  }

  @Test func skipsSegmentWithNoWords() {
    let plan = EditPlan(
      schemaVersion: 1,
      source: EditPlan.Source(path: "t", sampleRate: 44100, channels: 1, durationSamples: 1000),
      words: [
        EditPlan.Word(id: 1, text: "a", start: 0, end: 0.1, startSample: 0, endSample: 100)
      ],
      silences: [],
      segments: [
        EditPlan.Segment(
          index: 0, outputName: "x", wordIDs: [], startStatus: "clean", endStatus: "clean")
      ])
    expectNoDifference(plan.transcriptUnits, [])
  }

  @Test func skipsSegmentWhoseWordsLackSampleBounds() {
    let plan = EditPlan(
      schemaVersion: 1,
      source: EditPlan.Source(path: "t", sampleRate: 44100, channels: 1, durationSamples: 1000),
      words: [
        EditPlan.Word(id: 1, text: "a", start: 0, end: 0.1, startSample: nil, endSample: nil)
      ],
      silences: [],
      segments: [
        EditPlan.Segment(
          index: 0, outputName: "x", wordIDs: [1], startStatus: "clean", endStatus: "clean")
      ])
    expectNoDifference(plan.transcriptUnits, [])
  }
}
