import CustomDump
import Foundation
import IdentifiedCollections
import Testing

@testable import PlayolaInterviewEditor

// swiftlint:disable:next inclusive_language
struct MasteringEligibilityTests {
  private func slice(_ name: String, typeID: String? = nil, start: Int = 0, end: Int = 100) -> Slice
  {
    Slice(
      id: UUID(), name: name, startSample: start, endSample: end,
      wordIDs: [], snippet: "", suggestionTypeID: typeID)
  }

  @Test func includesOnlyExportableIntroTypesInDocumentOrder() {
    let intro = slice("First", typeID: "intro")
    let spotlight = slice("Intro to Jazz", typeID: "spotlight")
    let blank = slice("  ", typeID: "intro")
    let removed = slice("Removed", typeID: "intro", start: 200, end: 300)
    let document = EditorDocumentState(
      slices: [intro, spotlight, blank, removed],
      timelineRemovals: [
        TimelineRemoval(
          id: UUID(), removedRange: 200..<300, crossfade: Crossfade(lengthSamples: 0))
      ])
    let result = MasteringEligibilityRule.evaluate(document)
    expectNoDifference(result.intros.map(\.id), [intro.id, blank.id])
    expectNoDifference(result.blankTitledIntroIDs, [blank.id])
    expectNoDifference(result.excluded.map(\.reason), [.notIntro, .fullyRemoved])
  }

  @Test func explicitTypeTakesPrecedenceOverNaming() {
    var candidate = slice("Named")
    candidate.suggestionNaming = SuggestionNamingRecord(
      runID: UUID(), typeID: "intro", typeName: "Intro", typeGroup: .songIntros,
      discoveryLabel: "", extractedValues: [:], missingFieldIDs: [],
      correctedValues: [:], reservation: nil)
    let document = EditorDocumentState(slices: [candidate])
    expectNoDifference(MasteringEligibilityRule.evaluate(document).intros.map(\.id), [candidate.id])
    candidate.suggestionTypeID = "spotlight"
    expectNoDifference(
      MasteringEligibilityRule.evaluate(EditorDocumentState(slices: [candidate])).intros.count, 0)
  }

  @Test func legacyAcceptedSuggestionUsesItsIdentityAndCustomTypesStayExcluded() {
    let legacy = slice("Legacy")
    var suggestion = Fixtures.cutSuggestion(id: legacy.id, productType: .intro, status: .accepted)
    suggestion.naming = SuggestionNamingRecord(
      runID: UUID(), typeID: "intro", typeName: "Intro", typeGroup: .songIntros,
      discoveryLabel: "", extractedValues: [:], missingFieldIDs: [],
      correctedValues: [:], reservation: nil)
    var custom = slice("Custom")
    custom.suggestionNaming = SuggestionNamingRecord(
      runID: UUID(), typeID: "custom-intro", typeName: "Intro", typeGroup: .songIntros,
      discoveryLabel: "", extractedValues: [:], missingFieldIDs: [],
      correctedValues: [:], reservation: nil)
    let manual = slice("Manual")
    let document = EditorDocumentState(
      slices: [legacy, custom, manual], cutSuggestions: [suggestion])
    let result = MasteringEligibilityRule.evaluate(document)
    expectNoDifference(result.intros.map(\.id), [legacy.id])
    expectNoDifference(result.excluded.map(\.sliceID), [custom.id, manual.id])
  }
}
