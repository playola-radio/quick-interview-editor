import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

struct ProjectStateTests {

  // MARK: - Codable round-trip + reserved fields

  @Test func emptyStateHasEmptyCollectionsAndNoOverride() {
    let state = ProjectState()
    expectNoDifference(state.cutSuggestions, [])
    expectNoDifference(state.speakerCountOverride, nil)
    expectNoDifference(state.speakerDisplayNames, [:])
  }

  @Test func decodesLegacySidecarMissingSpeakerFields() throws {
    // A sidecar written before the speaker fields existed has only cutSuggestions.
    let json = #"{"cutSuggestions":[]}"#
    let state = try JSONDecoder().decode(ProjectState.self, from: Data(json.utf8))
    expectNoDifference(state.cutSuggestions, [])
    expectNoDifference(state.speakerCountOverride, nil)
    expectNoDifference(state.speakerDisplayNames, [:])
  }

  @Test func decodesPartialSidecarMissingCutSuggestions() throws {
    // A sidecar written by a future speaker-only path must not fail to decode here.
    let json = #"{"speakerCountOverride":2,"speakerDisplayNames":{"SPEAKER_00":"Host"}}"#
    let state = try JSONDecoder().decode(ProjectState.self, from: Data(json.utf8))
    expectNoDifference(state.cutSuggestions, [])
    expectNoDifference(state.speakerCountOverride, 2)
    expectNoDifference(state.speakerDisplayNames, ["SPEAKER_00": "Host"])
  }

  @Test func decodesEmptyObjectToEmptyState() throws {
    let state = try JSONDecoder().decode(ProjectState.self, from: Data("{}".utf8))
    expectNoDifference(state, ProjectState())
  }

  @Test func reservedSpeakerFieldsRoundTrip() throws {
    let state = ProjectState(
      cutSuggestions: [Fixtures.cutSuggestion(id: Fixtures.uuid(1))],
      speakerCountOverride: 2,
      speakerDisplayNames: ["SPEAKER_00": "Host", "SPEAKER_01": "Guest"])
    let data = try JSONEncoder().encode(state)
    let reloaded = try JSONDecoder().decode(ProjectState.self, from: data)
    expectNoDifference(reloaded, state)
    expectNoDifference(reloaded.speakerCountOverride, 2)
    expectNoDifference(reloaded.speakerDisplayNames["SPEAKER_00"], "Host")
  }

  // MARK: - Accept / reject through the store

  @Test func acceptSuggestionUpdatesOnlyThatSuggestion() {
    var state = ProjectState(cutSuggestions: [
      Fixtures.cutSuggestion(id: Fixtures.uuid(1)),
      Fixtures.cutSuggestion(id: Fixtures.uuid(2)),
    ])
    state.acceptSuggestion(Fixtures.uuid(1))
    expectNoDifference(state.cutSuggestions[id: Fixtures.uuid(1)]?.status, .accepted)
    expectNoDifference(state.cutSuggestions[id: Fixtures.uuid(2)]?.status, .pending)
  }

  @Test func rejectSuggestionUpdatesStatus() {
    var state = ProjectState(cutSuggestions: [Fixtures.cutSuggestion(id: Fixtures.uuid(1))])
    state.rejectSuggestion(Fixtures.uuid(1))
    expectNoDifference(state.cutSuggestions[id: Fixtures.uuid(1)]?.status, .rejected)
  }

  @Test func acceptingUnknownIDIsANoOp() {
    var state = ProjectState(cutSuggestions: [Fixtures.cutSuggestion(id: Fixtures.uuid(1))])
    state.acceptSuggestion(Fixtures.uuid(99))
    expectNoDifference(state.cutSuggestions[id: Fixtures.uuid(1)]?.status, .pending)
  }

  // MARK: - Ranking

  @Test func rankedSuggestionsSortByRankThenScore() {
    let state = ProjectState(cutSuggestions: [
      Fixtures.cutSuggestion(id: Fixtures.uuid(1), rank: 2, score: 0.9),
      Fixtures.cutSuggestion(id: Fixtures.uuid(2), rank: 0, score: 0.4),
      Fixtures.cutSuggestion(id: Fixtures.uuid(3), rank: 1, score: 0.8),
    ])
    expectNoDifference(
      state.rankedSuggestions.map(\.id),
      [
        Fixtures.uuid(2), Fixtures.uuid(3), Fixtures.uuid(1),
      ])
  }

  @Test func rankedSuggestionsBreakRankTiesByHigherScore() {
    let state = ProjectState(cutSuggestions: [
      Fixtures.cutSuggestion(id: Fixtures.uuid(1), rank: 0, score: 0.3),
      Fixtures.cutSuggestion(id: Fixtures.uuid(2), rank: 0, score: 0.7),
    ])
    expectNoDifference(state.rankedSuggestions.map(\.id), [Fixtures.uuid(2), Fixtures.uuid(1)])
  }

  @Test func rankedSuggestionsPutPendingFirst() {
    let state = ProjectState(cutSuggestions: [
      Fixtures.cutSuggestion(id: Fixtures.uuid(1), rank: 0, score: 0.9, status: .accepted),
      Fixtures.cutSuggestion(id: Fixtures.uuid(2), rank: 5, score: 0.1, status: .pending),
      Fixtures.cutSuggestion(id: Fixtures.uuid(3), rank: 1, score: 0.9, status: .rejected),
    ])
    // Pending outranks a better-ranked accepted; rejected sinks to the bottom.
    expectNoDifference(
      state.rankedSuggestions.map(\.id),
      [
        Fixtures.uuid(2), Fixtures.uuid(1), Fixtures.uuid(3),
      ])
    expectNoDifference(state.pendingSuggestions.map(\.id), [Fixtures.uuid(2)])
  }

  @Test func rankedSuggestionsAreStableWithNaNScores() {
    let state = ProjectState(cutSuggestions: [
      Fixtures.cutSuggestion(id: Fixtures.uuid(1), rank: 0, score: .nan),
      Fixtures.cutSuggestion(id: Fixtures.uuid(2), rank: 0, score: 0.5),
    ])
    // NaN must not break the sort's total order; it sinks below finite scores.
    expectNoDifference(state.rankedSuggestions.map(\.id), [Fixtures.uuid(2), Fixtures.uuid(1)])
  }
}
