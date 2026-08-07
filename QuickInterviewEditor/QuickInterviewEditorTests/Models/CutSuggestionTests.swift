import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

struct CutSuggestionTests {

  // MARK: - Decoding / round-trip

  @Test func decodesFromCommittedFixture() {
    let state = Fixtures.projectState()
    let byIndex = state.cutSuggestions.elements
    expectNoDifference(byIndex.count, 2)
    expectNoDifference(byIndex[0].productType, .spotlight)
    expectNoDifference(byIndex[0].songVerified, false)
    expectNoDifference(byIndex[0].song, nil)
    expectNoDifference(byIndex[0].wordIDs, [10, 11, 12, 13, 14, 15, 16])
    expectNoDifference(byIndex[0].durationSec, 90)
    expectNoDifference(byIndex[0].status, .pending)
    expectNoDifference(byIndex[0].provenance.model, "claude-sonnet-5")
    expectNoDifference(byIndex[0].provenance.diarizationHash, nil)
    expectNoDifference(byIndex[1].productType, .intro)
    expectNoDifference(byIndex[1].song, "Wildwood")
    expectNoDifference(byIndex[1].songVerified, true)
    expectNoDifference(byIndex[1].provenance.diarizationHash, "sha256:diar-1")
  }

  @Test func encodeDecodeRoundTrips() throws {
    let original = Fixtures.projectState()
    let data = try JSONEncoder().encode(original)
    let reloaded = try JSONDecoder().decode(ProjectState.self, from: data)
    expectNoDifference(reloaded, original)
  }

  // MARK: - Lifecycle transitions

  @Test func acceptTransitionsPendingToAccepted() {
    var suggestion = Fixtures.cutSuggestion(id: Fixtures.uuid(1), status: .pending)
    suggestion.accept()
    expectNoDifference(suggestion.status, .accepted)
    expectNoDifference(suggestion.isAccepted, true)
    expectNoDifference(suggestion.isPending, false)
  }

  @Test func rejectTransitionsPendingToRejected() {
    var suggestion = Fixtures.cutSuggestion(id: Fixtures.uuid(1), status: .pending)
    suggestion.reject()
    expectNoDifference(suggestion.status, .rejected)
    expectNoDifference(suggestion.isRejected, true)
  }

  @Test func resetToPendingReturnsToPending() {
    var suggestion = Fixtures.cutSuggestion(id: Fixtures.uuid(1), status: .accepted)
    suggestion.resetToPending()
    expectNoDifference(suggestion.status, .pending)
  }

  // MARK: - Display values

  @Test func displayValuesFormatForTheView() {
    let suggestion = Fixtures.cutSuggestion(
      id: Fixtures.uuid(1),
      productType: .spotlight,
      song: nil,
      startSec: 10,
      endSec: 100,
      durationSec: 90,
      status: .pending)
    expectNoDifference(suggestion.productTypeLabel, "Artist Spotlight")
    expectNoDifference(suggestion.statusLabel, "Pending")
    expectNoDifference(suggestion.startTimecode, "0:10.0")
    expectNoDifference(suggestion.endTimecode, "1:40.0")
    expectNoDifference(suggestion.timeRangeDisplay, "0:10.0 – 1:40.0")
    expectNoDifference(suggestion.durationDisplay, "90.0s")
    expectNoDifference(suggestion.songDisplay, "—")
  }

  @Test func displayValuesAreCrashSafeForNonFiniteSeconds() {
    let suggestion = Fixtures.cutSuggestion(
      id: Fixtures.uuid(3),
      startSec: .nan,
      endSec: .infinity,
      durationSec: .nan)
    // Corrupted seconds must degrade to a placeholder, never trap on Double→Int.
    expectNoDifference(suggestion.startTimecode, "–:––")
    expectNoDifference(suggestion.endTimecode, "–:––")
    expectNoDifference(suggestion.durationDisplay, "–:––")
    expectNoDifference(suggestion.timeRangeDisplay, "–:–– – –:––")
  }

  @Test func songDisplayShowsTheNamedSong() {
    let suggestion = Fixtures.cutSuggestion(
      id: Fixtures.uuid(2), productType: .intro, song: "Wildwood", songVerified: true)
    expectNoDifference(suggestion.songDisplay, "Wildwood")
    expectNoDifference(suggestion.productTypeLabel, "Intro")
  }
}
