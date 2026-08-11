import CustomDump
import Testing

@testable import QuickInterviewEditor

struct CutSuggestionPresentationTests {

  private func provenance(hash: String, fingerprint: String) -> CutSuggestion.Provenance {
    CutSuggestion.Provenance(
      model: "m", promptVersion: "v1", productSpecVersion: "v1", transcriptHash: hash,
      sourceFingerprint: fingerprint, diarizationHash: nil)
  }

  @Test func freshPendingRowIsAcceptableAndNotStale() {
    var suggestion = Fixtures.cutSuggestion(id: Fixtures.uuid(1), rank: 3)
    suggestion.provenance = provenance(hash: "h", fingerprint: "fp")
    let row = suggestionRow(suggestion, currentTranscriptHash: "h", currentFingerprint: "fp")
    expectNoDifference(row.isStale, false)
    expectNoDifference(row.canAccept, true)
    expectNoDifference(row.showsFreshnessWarning, false)
    expectNoDifference(row.rankLabel, "#3")
    expectNoDifference(row.freshnessLabel, "Up to date")
  }

  @Test func transcriptDriftMakesRowStaleAndUnacceptable() {
    var suggestion = Fixtures.cutSuggestion(id: Fixtures.uuid(1))
    suggestion.provenance = provenance(hash: "old", fingerprint: "fp")
    let row = suggestionRow(suggestion, currentTranscriptHash: "new", currentFingerprint: "fp")
    expectNoDifference(row.isStale, true)
    expectNoDifference(row.canAccept, false)
    expectNoDifference(row.showsFreshnessWarning, true)
  }

  @Test func sourceFingerprintMismatchMakesRowStale() {
    var suggestion = Fixtures.cutSuggestion(id: Fixtures.uuid(1))
    suggestion.provenance = provenance(hash: "h", fingerprint: "other")
    let row = suggestionRow(suggestion, currentTranscriptHash: "h", currentFingerprint: "fp")
    expectNoDifference(row.isStale, true)
  }

  @Test func acceptedRowHidesAcceptRejectControls() {
    var suggestion = Fixtures.cutSuggestion(id: Fixtures.uuid(1), status: .accepted)
    suggestion.provenance = provenance(hash: "h", fingerprint: "fp")
    let row = suggestionRow(suggestion, currentTranscriptHash: "h", currentFingerprint: "fp")
    expectNoDifference(row.showsAcceptButton, false)
    expectNoDifference(row.showsRejectButton, false)
    expectNoDifference(row.statusLabel, "Accepted")
  }

  @Test func songLineMarksUnverifiedSongs() {
    let verified = Fixtures.cutSuggestion(
      id: Fixtures.uuid(1), song: "Hit", songVerified: true)
    let unverified = Fixtures.cutSuggestion(
      id: Fixtures.uuid(2), song: "Hit", songVerified: false)
    let none = Fixtures.cutSuggestion(id: Fixtures.uuid(3), song: nil)
    expectNoDifference(
      suggestionRow(verified, currentTranscriptHash: "h", currentFingerprint: "fp").songLine,
      "Song: Hit")
    expectNoDifference(
      suggestionRow(unverified, currentTranscriptHash: "h", currentFingerprint: "fp").songLine,
      "Song: Hit (unverified)")
    #expect(
      suggestionRow(none, currentTranscriptHash: "h", currentFingerprint: "fp").songLine == nil)
  }

  @Test func sectionsFollowTheGroupOfTheBestRankedCandidate() {
    // Suggestions arrive in ranked order (spotlight #1, then intro #2).
    let spotlight = Fixtures.cutSuggestion(
      id: Fixtures.uuid(1), productType: .spotlight, rank: 1)
    let intro = Fixtures.cutSuggestion(id: Fixtures.uuid(2), productType: .intro, rank: 2)
    let sections = suggestionSections(
      from: [spotlight, intro], currentTranscriptHash: "h", currentFingerprint: "fp")
    expectNoDifference(sections.map(\.title), ["Artist Spotlight", "Intro"])
    expectNoDifference(sections.map { $0.rows.count }, [1, 1])
  }
}
