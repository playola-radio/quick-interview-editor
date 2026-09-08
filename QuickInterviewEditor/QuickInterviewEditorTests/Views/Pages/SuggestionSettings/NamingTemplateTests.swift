import CustomDump
import Dependencies
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct NamingTemplateTests {
  @Test func literalEditUpdatesPreview() {
    let model = NamingTemplateModel(
      components: [
        NamingComponent(kind: .literal, value: "Promo "),
        NamingComponent(kind: .sequence, value: nil),
      ],
      fields: SuggestionDefaults.configuration.fields)
    expectNoDifference(model.previewName, "Promo 1")
    model.literalChanged(at: 0, text: "ID ")
    expectNoDifference(model.previewName, "ID 1")
  }

  @Test func combinedIntroUsesExampleFieldsAndRenameRetainsReferences() {
    let model = NamingTemplateModel(
      components: SuggestionDefaults.types[0].template, fields: SuggestionDefaults.fields,
      selectedGroupingFieldIDs: ["song-title", "artist-name"],
      sampleFieldValues: ["song-title": "Wildflowers", "artist-name": "Tom Petty"])
    expectNoDifference(model.previewName, "Wildflowers 1, Tom Petty")
    let components = model.components
    model.availableFields[0].name = "Recording"
    expectNoDifference(model.components, components)
    expectNoDifference(model.previewName, "Wildflowers 1, Tom Petty")
    #expect(model.rows.contains { $0.label == "Recording" })
  }

  @Test func sequenceIsOptionalAndMayRepeat() {
    let model = NamingTemplateModel(
      components: [.init(kind: .literal, value: "ID")], fields: [])
    expectNoDifference(model.previewName, "ID")
    model.addSequenceTapped()
    model.addSequenceTapped()
    expectNoDifference(model.previewName, "ID11")
  }

  @Test func movementKeepsStableRowIDsAndGroupingIndependent() {
    let model = NamingTemplateModel(
      components: [.init(kind: .field, value: "artist-name"), .init(kind: .sequence, value: nil)],
      fields: SuggestionDefaults.fields, selectedGroupingFieldIDs: ["artist-name"])
    let rowIDs = model.componentRowIDs
    model.moveDownTapped(at: 0)
    expectNoDifference(model.componentRowIDs, [rowIDs[1], rowIDs[0]])
    expectNoDifference(model.components.map(\.kind), [.sequence, .field])
    expectNoDifference(model.selectedGroupingFieldIDs, ["artist-name"])
    model.moveUpTapped(at: 1)
    expectNoDifference(model.componentRowIDs, rowIDs)
    model.groupingFieldTapped("song-title")
    expectNoDifference(model.selectedGroupingFieldIDs, ["artist-name", "song-title"])
    model.groupingFieldTapped("artist-name")
    expectNoDifference(model.selectedGroupingFieldIDs, ["song-title"])
    model.removeTapped(at: 0)
    expectNoDifference(model.componentRowIDs, [rowIDs[1]])
  }

  @Test func unknownFieldsRemainVisibleAndInvalid() {
    let model = NamingTemplateModel(
      components: [.init(kind: .field, value: "missing")], fields: [],
      selectedGroupingFieldIDs: ["missing-group"])
    expectNoDifference(model.components, [.init(kind: .field, value: "missing")])
    #expect(model.rows[0].label.contains("missing"))
    #expect(model.validationMessages.contains { $0.contains("missing") })
    #expect(model.validationMessages.contains { $0.contains("missing-group") })
    expectNoDifference(model.previewName, "Example")
  }

  @Test func emptyLiteralsInvalidButSeparatorsAllowed() {
    let model = NamingTemplateModel(components: [], fields: SuggestionDefaults.fields)
    model.addLiteralTapped()
    #expect(!model.validationMessages.isEmpty)
    model.literalChanged(at: 0, text: " ")
    model.addFieldTapped("song-title")
    expectNoDifference(model.validationMessages, [])
    model.literalChanged(at: 0, text: "")
    #expect(model.validationMessages.contains { $0.contains("empty literal") })
  }
}
