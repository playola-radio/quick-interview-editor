import Foundation

/// One LLM-facing transcript unit: a contiguous run of words (an engine segment, ~a
/// sentence). Carries a stable `id`, its text, the word IDs it covers, and the audio
/// samples/seconds it occupies. `speakerID` is reserved for the speaker-aware track and
/// stays `nil` until diarization lands (paragraph/speaker spec, PR 6).
///
/// Mirrors the Python `Sentence` contract (`cut_suggester/models.py`) so the eval and
/// the app agree on the shape of the LLM's input. Distinct from `TranscriptParagraph`
/// (offline display grouping) and `CutSuggestion` (a product candidate), per the design.
struct TranscriptUnit: Identifiable, Equatable, Sendable {
  var id: Int
  var text: String
  var wordIDs: [Word.ID]
  var startSample: Int
  var endSample: Int
  var startSec: Double
  var endSec: Double
  var speakerID: String?
}

extension EditPlan {
  /// The LLM-facing transcript units for this plan: one per non-empty segment, with text,
  /// samples, and seconds derived from the member words — the engine's `edit-plan.json`
  /// segments carry no text of their own. A segment with no locatable, sample-bounded
  /// words is skipped (nothing to anchor in audio), mirroring the Python loader.
  var transcriptUnits: [TranscriptUnit] {
    let wordsByID = Dictionary(words.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var units: [TranscriptUnit] = []
    for segment in segments {
      // Keep only words that carry sample bounds, so the unit's `wordIDs`, text, and span
      // stay consistent — a member the cutter can't anchor in audio must not appear in the
      // ID list while being excluded from the span.
      let members = segment.wordIDs.compactMap { wordsByID[$0] }
        .filter { $0.startSample != nil && $0.endSample != nil }
      guard !members.isEmpty else { continue }
      guard
        let startSample = members.compactMap(\.startSample).min(),
        let endSample = members.compactMap(\.endSample).max()
      else { continue }
      // Span the unit from its first word's start to its last word's end (words are in
      // transcript order). When the last word carries no `end` second, fall back to the
      // sample bound (which does cover the real audio) rather than to an earlier word's end
      // — keeping `endSec` consistent with `endSample` instead of underreporting duration.
      let startSec = members.first?.start ?? 0
      let endSec = members.last?.end ?? Double(endSample) / Double(max(1, source.sampleRate))
      units.append(
        TranscriptUnit(
          id: segment.index,
          text: members.map(\.text).joined(separator: " "),
          wordIDs: members.map(\.id),
          startSample: startSample,
          endSample: endSample,
          startSec: startSec,
          endSec: endSec,
          speakerID: nil))
    }
    return units
  }
}
