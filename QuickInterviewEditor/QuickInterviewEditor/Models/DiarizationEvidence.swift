import Foundation

/// Speaker-diarization evidence for the cut-suggester. Reserved for the speaker-aware
/// track (paragraph/speaker spec): it will carry per-turn / per-word speaker labels so the
/// cutter can prefer the subject and down-rank interviewer-only spans. It is `nil` for now
/// — solo files and the first suggestion pass need no speaker evidence — and PR 6 populates
/// it. `diarizationHash` pins the evidence a suggestion was produced against, mirroring
/// `transcriptHash`; it is stamped into `CutSuggestion.Provenance.diarizationHash`.
struct DiarizationEvidence: Equatable, Sendable {
  var diarizationHash: String
}
