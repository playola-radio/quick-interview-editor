import CustomDump
import Foundation
import IdentifiedCollections
import Testing

@testable import PlayolaInterviewEditor

struct EditorDocumentStateTests {
  @Test func decodesLegacyShapeWithNewFieldDefaults() throws {
    let json = Data(#"{"slices":[],"timelineRemovals":[]}"#.utf8)
    let state = try JSONDecoder().decode(EditorDocumentState.self, from: json)
    expectNoDifference(state.cutSuggestions, [])
    expectNoDifference(state.speakerCountOverride, nil)
    expectNoDifference(state.speakerDisplayNames, [:])
  }

  @Test func roundTripsAllFields() throws {
    let state = Fixtures.editorDocumentState()
    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(EditorDocumentState.self, from: data)
    expectNoDifference(decoded, state)
  }

  @Test func rekeyingToAReplacementPlanRederivesClipWordsAndDropsSuggestions() throws {
    let plan = Fixtures.editPlan()
    let replacement: EditPlan = {
      var replacement = plan
      replacement.words = plan.words.map { word in
        var word = word
        word.text = word.text.uppercased()
        return word
      }
      return replacement
    }()
    let range = try #require(plan.words[0].startSample)..<(try #require(plan.words[1].endSample))
    let stale = Slice(
      id: UUID(), name: "Slice 1", startSample: range.lowerBound, endSample: range.upperBound,
      wordIDs: [99], snippet: "stale")
    var state = Fixtures.editorDocumentState()
    state.slices = [stale]
    state.cutSuggestions = [Fixtures.cutSuggestion(id: UUID())]

    let rekeyed = state.rekeyed(to: replacement)

    let expectedIDs = wordIDs(anyOverlap: range, words: replacement.words)
    expectNoDifference(rekeyed.slices[0].wordIDs, expectedIDs)
    expectNoDifference(
      rekeyed.slices[0].snippet,
      displaySliceSnippet(sliceSnippet(for: expectedIDs, words: replacement.words)))
    expectNoDifference(rekeyed.slices[0].startSample..<rekeyed.slices[0].endSample, range)
    expectNoDifference(rekeyed.cutSuggestions, [])
    expectNoDifference(rekeyed.timelineRemovals, state.timelineRemovals)
    expectNoDifference(rekeyed.speakerCountOverride, state.speakerCountOverride)
    expectNoDifference(rekeyed.speakerDisplayNames, state.speakerDisplayNames)
  }
}
