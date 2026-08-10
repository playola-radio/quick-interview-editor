import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

struct TranscriptHashTests {

  /// A word for the hand-built plans below. Only `id`, `text`, and sample bounds matter.
  private struct WordSpec {
    var id: Int
    var text: String
    var startSample: Int
    var endSample: Int
    init(_ id: Int, _ text: String, _ startSample: Int, _ endSample: Int) {
      self.id = id
      self.text = text
      self.startSample = startSample
      self.endSample = endSample
    }
  }

  /// A minimal plan built from `WordSpec`s — only word content and samples matter to the
  /// hash.
  private func plan(_ words: [WordSpec], durationSamples: Int = 100_000) -> EditPlan {
    EditPlan(
      schemaVersion: 1,
      source: EditPlan.Source(
        path: "t.aiff", sampleRate: 44100, channels: 1, durationSamples: durationSamples),
      words: words.map {
        EditPlan.Word(
          id: $0.id, text: $0.text, start: 0, end: nil,
          startSample: $0.startSample, endSample: $0.endSample)
      },
      silences: [], segments: [])
  }

  @Test func sameWordsProduceSameHash() {
    let first = plan([WordSpec(1, "So", 0, 100), WordSpec(2, "a", 100, 200)])
    let second = plan([WordSpec(1, "So", 0, 100), WordSpec(2, "a", 100, 200)])
    expectNoDifference(first.transcriptHash, second.transcriptHash)
  }

  @Test func changingWordTextChangesHash() {
    let first = plan([WordSpec(1, "So", 0, 100), WordSpec(2, "a", 100, 200)])
    let second = plan([WordSpec(1, "So", 0, 100), WordSpec(2, "the", 100, 200)])
    #expect(first.transcriptHash != second.transcriptHash)
  }

  @Test func changingWordIDChangesHash() {
    #expect(
      plan([WordSpec(1, "So", 0, 100)]).transcriptHash
        != plan([WordSpec(9, "So", 0, 100)]).transcriptHash)
  }

  @Test func addingAWordChangesHash() {
    let first = plan([WordSpec(1, "So", 0, 100), WordSpec(2, "a", 100, 200)])
    let second = plan([
      WordSpec(1, "So", 0, 100), WordSpec(2, "a", 100, 200), WordSpec(3, "song", 200, 300),
    ])
    #expect(first.transcriptHash != second.transcriptHash)
  }

  @Test func sampleAlignmentShiftDoesNotChangeHash() {
    // Same words + IDs, re-aligned samples: the content identity is unchanged (a slice's
    // samples are re-derived from the current words at accept time), so the hash is stable.
    let first = plan([WordSpec(1, "So", 0, 100), WordSpec(2, "a", 100, 200)])
    let second = plan(
      [WordSpec(1, "So", 500, 650), WordSpec(2, "a", 650, 900)], durationSamples: 200_000)
    expectNoDifference(first.transcriptHash, second.transcriptHash)
  }

  @Test func idAndTextBoundaryCannotCollide() {
    // (id: 1, "23") and (id: 12, "3") both concatenate to "123"; the delimiter must keep
    // their digests distinct.
    #expect(
      plan([WordSpec(1, "23", 0, 100)]).transcriptHash
        != plan([WordSpec(12, "3", 0, 100)]).transcriptHash)
  }

  @Test func hashIsPrefixedLowercaseHex() {
    let hash = plan([WordSpec(1, "So", 0, 100)]).transcriptHash
    #expect(hash.hasPrefix("sha256:"))
    expectNoDifference(hash.count, "sha256:".count + 64)
  }
}
