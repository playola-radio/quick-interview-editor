import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

struct SuggestionNamingTests {
  @Test func sequenceKeyCanonicalizesValuesAndSortsFields() {
    let type = SuggestionDefaults.types[0]
    let first = suggestionSequenceKey(
      type: type,
      values: ["artist-name": "  Beyoncé  ", "song-title": "Café"],
      candidateID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let second = suggestionSequenceKey(
      type: type,
      values: ["song-title": "Cafe\u{301}", "artist-name": "BEYONCÉ"],
      candidateID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    expectNoDifference(first, second)
    expectNoDifference(first.fields.map(\.fieldID), ["artist-name", "song-title"])
  }

  @Test func sequenceKeyKeepsPunctuationDistinctAndProvisionsMissingCandidates() {
    let type = SuggestionDefaults.types[0]
    let id1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let id2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let punctuated = suggestionSequenceKey(
      type: type, values: ["song-title": "Hello!", "artist-name": "A"], candidateID: id1)
    let plain = suggestionSequenceKey(
      type: type, values: ["song-title": "Hello", "artist-name": "A"], candidateID: id1)
    #expect(punctuated != plain)
    #expect(
      suggestionSequenceKey(type: type, values: ["song-title": "Hello"], candidateID: id1)
        != suggestionSequenceKey(type: type, values: ["song-title": "Hello"], candidateID: id2))
  }

  @Test func rendersTemplateAndFallsBackForIncompleteRequiredValues() {
    let type = SuggestionDefaults.types[0]
    let values = ["song-title": "Nobody Wins", "artist-name": "American Aquarium"]
    expectNoDifference(
      renderSuggestionName(template: type.template, values: values, sequence: 4, fallback: "fallback"),
      "Nobody Wins 4, American Aquarium")
    expectNoDifference(
      renderSuggestionName(template: type.template, values: ["song-title": "  "], sequence: 4, fallback: "fallback"),
      "fallback")
    expectNoDifference(
      renderSuggestionName(template: [.literal(value: "x")], values: [:], sequence: nil, fallback: "fallback"),
      "x")
    expectNoDifference(
      renderSuggestionName(
        template: [.literal(value: "#"), .sequence(value: nil), .literal(value: "-"), .sequence(value: nil)],
        values: [:], sequence: 2, fallback: "fallback"),
      "#2-2")
    expectNoDifference(
      renderSuggestionName(template: [.sequence(value: nil)], values: [:], sequence: 0, fallback: "fallback"),
      "fallback")
  }

  @Test func reservationIdentityIgnoresCanonicalValuesButReservationEqualityDoesNot() throws {
    let key = SuggestionSequenceKey(typeID: "intro", fields: [], provisionalCandidateID: nil)
    let candidateID = UUID()
    let first = SequenceReservation(
      candidateID: candidateID, key: key, number: 1, canonicalValues: ["title": "Cafe"])
    let second = SequenceReservation(
      candidateID: candidateID, key: key, number: 1, canonicalValues: ["title": "Café"])
    expectNoDifference(first.identity, second.identity)
    #expect(first != second)
    let data = try JSONEncoder().encode(first)
    expectNoDifference(try JSONDecoder().decode(SequenceReservation.self, from: data), first)
  }
}

private extension NamingComponent {
  static func literal(value: String) -> Self {
    Self(kind: .literal, value: value)
  }

  static func sequence(value: String?) -> Self {
    Self(kind: .sequence, value: value)
  }
}
