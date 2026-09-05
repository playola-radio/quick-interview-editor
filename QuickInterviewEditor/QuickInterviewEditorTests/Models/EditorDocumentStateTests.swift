import CustomDump
import Foundation
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
}
