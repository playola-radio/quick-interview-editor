import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

struct SuggestionConfigurationTests {
  enum ValidationCase: String, CaseIterable, Sendable {
    case unsupportedSchema
    case noTypes
    case blankTypeID
    case duplicateTypeID
    case blankTypeName
    case duplicateNormalizedTypeName
    case blankGuidelines
    case blankFieldID
    case duplicateFieldID
    case blankFieldName
    case duplicateNormalizedFieldName
    case blankInstructions
    case duplicateGroupingReference
    case missingGroupingField
    case blankFieldTokenID
    case missingTemplateField
    case emptyLiteral
    case sequenceWithValue
    case emptyTemplate
    case whitespaceOnlyLiteralTemplate

    var expectedMessageFragment: String {
      switch self {
      case .unsupportedSchema: "schema version"
      case .noTypes: "at least one type"
      case .blankTypeID: "type ID"
      case .duplicateTypeID: "Duplicate type ID"
      case .blankTypeName: "type name"
      case .duplicateNormalizedTypeName: "Duplicate type name"
      case .blankGuidelines: "guidelines"
      case .blankFieldID: "field ID"
      case .duplicateFieldID: "Duplicate field ID"
      case .blankFieldName: "field name"
      case .duplicateNormalizedFieldName: "Duplicate field name"
      case .blankInstructions: "instructions"
      case .duplicateGroupingReference: "duplicate sequence field"
      case .missingGroupingField: "unknown sequence field"
      case .blankFieldTokenID: "empty field ID"
      case .missingTemplateField: "unknown field"
      case .emptyLiteral: "empty literal"
      case .sequenceWithValue: "Sequence components"
      case .emptyTemplate, .whitespaceOnlyLiteralTemplate: "meaningful naming component"
      }
    }
  }

  @Test func introTemplateCombinesFieldsAndSequence() throws {
    let intro = try #require(SuggestionDefaults.configuration.types.first)

    expectNoDifference(intro.id, "intro")
    expectNoDifference(
      intro.template,
      [
        NamingComponent(kind: .field, value: "song-title"),
        NamingComponent(kind: .literal, value: " "),
        NamingComponent(kind: .sequence, value: nil),
        NamingComponent(kind: .literal, value: ", "),
        NamingComponent(kind: .field, value: "artist-name"),
      ])
    expectNoDifference(intro.sequenceFieldIDs, ["song-title", "artist-name"])
  }

  @Test func defaultsMatchApprovedCatalog() {
    let configuration = SuggestionDefaults.configuration

    expectNoDifference(configuration.schemaVersion, 1)
    expectNoDifference(configuration.revision, 0)
    expectNoDifference(
      configuration.types.map(\.id),
      [
        "intro", "spotlight", "image-id", "image-pre-commercial", "image-post-commercial",
        "image-promo",
      ])
    expectNoDifference(
      configuration.types.map(\.name),
      [
        "Song Intro", "Spotlight", "ID Image", "Pre-commercial Image", "Post-commercial Image",
        "Promo Image",
      ])
    expectNoDifference(
      configuration.types.map(\.group),
      [
        .songIntros, .spotlights, .audioImages, .audioImages, .audioImages, .audioImages,
      ])
    expectNoDifference(
      configuration.fields.map(\.id),
      [
        "song-title", "artist-name", "descriptive-title",
      ])
    expectNoDifference(
      configuration.fields.map(\.name),
      [
        "Song Title", "Artist Name", "Descriptive Title",
      ])
  }

  @Test func defaultGuidelinesAndFieldInstructionsArePinned() {
    let configuration = SuggestionDefaults.configuration
    let byID = Dictionary(uniqueKeysWithValues: configuration.types.map { ($0.id, $0) })
    let fieldsByID = Dictionary(uniqueKeysWithValues: configuration.fields.map { ($0.id, $0) })

    expectNoDifference(
      byID["spotlight"]?.guidelines,
      "one self-contained story or anecdote (~40-120s)")
    expectNoDifference(
      byID["intro"]?.guidelines,
      "sets up ONE named song and ends on the handoff (~15-45s)")
    expectNoDifference(
      byID["image-id"]?.guidelines,
      "a complete spoken artist/station identification or station-branding liner, including listening-to "
        + "statements. A brief self-identification at the beginning of a longer anecdote is not automatically "
        + "a separate ID. Prefer a more specific imaging subtype for explicit break transitions or direct promotions."
    )
    expectNoDifference(
      byID["image-pre-commercial"]?.guidelines,
      "introduces an upcoming commercial break, asks the listener to stay through ads, or explains that the "
        + "upcoming commercials support musicians. Include short transitions about paying the musicians."
    )
    expectNoDifference(
      byID["image-post-commercial"]?.guidelines,
      "returns from a commercial break, welcomes the listener back, or explicitly resumes station "
        + "programming after the break."
    )
    expectNoDifference(
      byID["image-promo"]?.guidelines,
      "directly promotes a website, subscription, event/tour, release, or other listener action. A passing "
        + "factual mention within a story is not automatically promotional imaging."
    )
    expectNoDifference(
      fieldsByID["song-title"]?.instructions,
      "Identify the title of the recording this clip introduces. Use the candidate and relevant context elsewhere "
        + "in the source transcript. Distinguish the introduced recording from songs mentioned as background. "
        + "Return missing when the text does not establish the title; do not invent it."
    )
    expectNoDifference(
      fieldsByID["artist-name"]?.instructions,
      "Identify the performer singing the introduced recording. Do not substitute the station DJ, the speaker, "
        + "the songwriter, or the first musician mentioned. For explicit collaborations, include the established "
        + "performers. Use speaker identity elsewhere in the transcript only when the text establishes that this is "
        + "their performance. Return missing when the performer cannot be established."
    )
    expectNoDifference(
      fieldsByID["descriptive-title"]?.instructions,
      "Produce a concise 3–6-word description of this clip's complete thought or purpose, using only the source "
        + "transcript. Do not make this output name control candidate merging."
    )
  }

  @Test func everyDefaultHasItsApprovedNamingTemplate() {
    let types = SuggestionDefaults.configuration.types
    let templatesByID = Dictionary(uniqueKeysWithValues: types.map { ($0.id, $0.template) })
    let sequenceFieldsByID = Dictionary(
      uniqueKeysWithValues: types.map { ($0.id, $0.sequenceFieldIDs) })

    expectNoDifference(
      templatesByID["spotlight"],
      [
        NamingComponent(kind: .literal, value: "Spotlight "),
        NamingComponent(kind: .sequence, value: nil),
      ])
    expectNoDifference(
      templatesByID["image-id"],
      [
        NamingComponent(kind: .literal, value: "ID "),
        NamingComponent(kind: .sequence, value: nil),
      ])
    expectNoDifference(
      templatesByID["image-pre-commercial"],
      [
        NamingComponent(kind: .literal, value: "Pre-Com "),
        NamingComponent(kind: .sequence, value: nil),
      ])
    expectNoDifference(
      templatesByID["image-post-commercial"],
      [
        NamingComponent(kind: .literal, value: "Post-Com "),
        NamingComponent(kind: .sequence, value: nil),
      ])
    expectNoDifference(
      templatesByID["image-promo"],
      [
        NamingComponent(kind: .literal, value: "Promo "),
        NamingComponent(kind: .sequence, value: nil),
      ])
    expectNoDifference(sequenceFieldsByID["spotlight"], [])
    expectNoDifference(sequenceFieldsByID["image-id"], [])
    expectNoDifference(sequenceFieldsByID["image-pre-commercial"], [])
    expectNoDifference(sequenceFieldsByID["image-post-commercial"], [])
    expectNoDifference(sequenceFieldsByID["image-promo"], [])
  }

  @Test(arguments: ValidationCase.allCases)
  func reportsEveryInvalidConfigurationRule(_ testCase: ValidationCase) {
    var configuration = validConfiguration()
    applyConfigurationCase(testCase, to: &configuration)
    applyTypeCase(testCase, to: &configuration)
    applyFieldCase(testCase, to: &configuration)
    applyTemplateCase(testCase, to: &configuration)

    #expect(
      configuration.validationMessages().contains {
        $0.localizedCaseInsensitiveContains(testCase.expectedMessageFragment)
      })
  }

  private func applyConfigurationCase(
    _ testCase: ValidationCase, to configuration: inout SuggestionConfiguration
  ) {
    switch testCase {
    case .unsupportedSchema:
      configuration.schemaVersion = 2
    case .noTypes:
      configuration.types = []
    default:
      break
    }
  }

  private func applyTypeCase(
    _ testCase: ValidationCase, to configuration: inout SuggestionConfiguration
  ) {
    switch testCase {
    case .blankTypeID:
      configuration.types[0].id = " \n"
    case .duplicateTypeID:
      configuration.types.append(configuration.types[0])
    case .blankTypeName:
      configuration.types[0].name = "\t"
    case .duplicateNormalizedTypeName:
      var duplicate = configuration.types[0]
      duplicate.id = "other"
      duplicate.name = "  EXAMPLE   TYPE "
      configuration.types.append(duplicate)
    case .blankGuidelines:
      configuration.types[0].guidelines = " "
    default:
      break
    }
  }

  private func applyFieldCase(
    _ testCase: ValidationCase, to configuration: inout SuggestionConfiguration
  ) {
    switch testCase {
    case .blankFieldID:
      configuration.fields[0].id = "\n"
    case .duplicateFieldID:
      configuration.fields.append(configuration.fields[0])
    case .blankFieldName:
      configuration.fields[0].name = " "
    case .duplicateNormalizedFieldName:
      configuration.fields.append(
        SuggestionField(id: "other", name: "  EXAMPLE   FIELD", instructions: "Extract it"))
    case .blankInstructions:
      configuration.fields[0].instructions = "\t"
    default:
      break
    }
  }

  private func applyTemplateCase(
    _ testCase: ValidationCase, to configuration: inout SuggestionConfiguration
  ) {
    switch testCase {
    case .duplicateGroupingReference:
      configuration.types[0].sequenceFieldIDs = ["field", "field"]
    case .missingGroupingField:
      configuration.types[0].sequenceFieldIDs = ["missing"]
    case .blankFieldTokenID:
      configuration.types[0].template = [NamingComponent(kind: .field, value: " ")]
    case .missingTemplateField:
      configuration.types[0].template = [NamingComponent(kind: .field, value: "missing")]
    case .emptyLiteral:
      configuration.types[0].template = [
        NamingComponent(kind: .literal, value: ""),
        NamingComponent(kind: .sequence, value: nil),
      ]
    case .sequenceWithValue:
      configuration.types[0].template = [NamingComponent(kind: .sequence, value: "1")]
    case .emptyTemplate:
      configuration.types[0].template = []
    case .whitespaceOnlyLiteralTemplate:
      configuration.types[0].template = [NamingComponent(kind: .literal, value: " \t")]
    default:
      break
    }
  }

  @Test func defaultsAreValid() {
    expectNoDifference(SuggestionDefaults.configuration.validationMessages(), [String]())
  }

  @Test func whitespaceSeparatorsRepeatedSequencesAndNoSequenceAreValid() {
    var configuration = validConfiguration()
    configuration.types[0].template = [
      NamingComponent(kind: .field, value: "field"),
      NamingComponent(kind: .literal, value: " "),
      NamingComponent(kind: .sequence, value: nil),
      NamingComponent(kind: .sequence, value: nil),
    ]
    expectNoDifference(configuration.validationMessages(), [String]())

    configuration.types[0].template = [NamingComponent(kind: .field, value: "field")]
    expectNoDifference(configuration.validationMessages(), [String]())
  }

  @Test func duplicateTypeNamesAreAllowedAcrossGroups() {
    var configuration = validConfiguration()
    var other = configuration.types[0]
    other.id = "other"
    other.group = .audioImages
    configuration.types.append(other)

    expectNoDifference(configuration.validationMessages(), [String]())
  }

  @Test func referencedFieldRemovalReturnsAffectedTypeNamesAndDoesNotDelete() {
    var configuration = SuggestionDefaults.configuration
    let before = configuration

    expectNoDifference(configuration.removeField(id: "song-title"), ["Song Intro"])
    expectNoDifference(configuration, before)
  }

  @Test func unreferencedFieldRemovalDeletesTheField() {
    var configuration = SuggestionDefaults.configuration

    expectDifference(configuration) {
      expectNoDifference(configuration.removeField(id: "descriptive-title"), [String]())
    } changes: {
      $0.fields.removeAll { $0.id == "descriptive-title" }
    }
  }

  @Test func restoringBuiltInBlocksAConflictingTypeNameWithoutMutation() {
    var configuration = SuggestionDefaults.configuration
    configuration.types.removeAll { $0.id == "spotlight" }
    configuration.types.append(
      SuggestionTypeDefinition(
        id: "custom-one", name: "  SPOTLIGHT ", group: .spotlights,
        guidelines: "Custom rules",
        template: [NamingComponent(kind: .literal, value: "Custom")],
        sequenceFieldIDs: []))
    let before = configuration

    expectNoDifference(
      configuration.restoreBuiltInType(id: "spotlight"),
      .typeNameConflict(existingTypeID: "custom-one"))
    expectNoDifference(configuration, before)
  }

  @Test func restoringBuiltInBlocksAConflictingFieldNameWithoutMutation() {
    var configuration = SuggestionDefaults.configuration
    configuration.types.removeAll { $0.id == "intro" }
    configuration.fields.removeAll { $0.id == "song-title" }
    configuration.fields.append(
      SuggestionField(id: "custom-field", name: " song TITLE ", instructions: "Custom"))
    let before = configuration

    expectNoDifference(
      configuration.restoreBuiltInType(id: "intro"),
      .fieldNameConflict(existingFieldID: "custom-field", presetFieldID: "song-title"))
    expectNoDifference(configuration, before)
  }

  @Test func restoringBuiltInAtomicallyRestoresMissingReferencedFields() throws {
    var configuration = SuggestionDefaults.configuration
    let intro = try #require(configuration.types.first { $0.id == "intro" })
    let songTitle = try #require(configuration.fields.first { $0.id == "song-title" })
    let artistName = try #require(configuration.fields.first { $0.id == "artist-name" })
    configuration.types.removeAll { $0.id == "intro" }
    configuration.fields.removeAll { ["song-title", "artist-name"].contains($0.id) }

    expectDifference(configuration) {
      expectNoDifference(configuration.restoreBuiltInType(id: "intro"), .restored)
    } changes: {
      $0.types.append(intro)
      $0.fields.append(contentsOf: [songTitle, artistName])
    }
  }

  @Test func restoringBuiltInPreservesExistingFieldsByStableID() throws {
    var configuration = SuggestionDefaults.configuration
    configuration.types.removeAll { $0.id == "intro" }
    configuration.fields.removeAll { $0.id == "song-title" }
    let artistIndex = try #require(configuration.fields.firstIndex { $0.id == "artist-name" })
    configuration.fields[artistIndex].instructions = "User-edited artist instructions"

    expectNoDifference(configuration.restoreBuiltInType(id: "intro"), .restored)
    expectNoDifference(
      configuration.fields.first { $0.id == "artist-name" }?.instructions,
      "User-edited artist instructions")
  }

  @Test func restoringNeverOverwritesAnExistingTypeIdentity() {
    var configuration = SuggestionDefaults.configuration
    configuration.types[1].guidelines = "User-edited rules"
    let before = configuration

    expectNoDifference(configuration.restoreBuiltInType(id: "spotlight"), .alreadyPresent)
    expectNoDifference(configuration, before)
  }

  @Test func unknownBuiltInCannotBeRestored() {
    var configuration = SuggestionDefaults.configuration
    let before = configuration

    expectNoDifference(configuration.restoreBuiltInType(id: "unknown"), .unknownBuiltIn)
    expectNoDifference(configuration, before)
  }

  @Test func fieldRenamePreservesTemplateAndGroupingIDs() throws {
    var configuration = SuggestionDefaults.configuration
    let introBefore = try #require(configuration.types.first { $0.id == "intro" })
    let index = try #require(configuration.fields.firstIndex { $0.id == "song-title" })

    configuration.fields[index].name = "Recording Title"

    let introAfter = try #require(configuration.types.first { $0.id == "intro" })
    expectNoDifference(introAfter.template, introBefore.template)
    expectNoDifference(introAfter.sequenceFieldIDs, introBefore.sequenceFieldIDs)
  }

  @Test func decodingExistingConfigurationRequiresSchemaVersionAndRevision() throws {
    for data in [
      Data(#"{"revision": 0, "types": [], "fields": []}"#.utf8),
      Data(#"{"schemaVersion": 1, "types": [], "fields": []}"#.utf8),
    ] {
      #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(SuggestionConfiguration.self, from: data)
      }
    }
  }

  @Test func customIDUsesTheInjectedUUID() {
    expectNoDifference(
      SuggestionConfiguration.customID(
        using: UUID(uuidString: "12345678-1234-5678-9ABC-DEF012345678")!),
      "custom-12345678-1234-5678-9abc-def012345678")
  }

  @Test func productTypePreservesHistoricalAndCustomIDsInSingleStringJSON() throws {
    let custom = try #require(ProductType(rawValue: "future-v2"))
    expectNoDifference(ProductType(rawValue: " "), nil)
    expectNoDifference(
      try JSONEncoder().encode(custom),
      Data(#""future-v2""#.utf8))
    expectNoDifference(
      try JSONDecoder().decode(ProductType.self, from: Data(#""future-v2""#.utf8)), custom)
  }

  @Test func bundledContractFixtureDecodesToTheDefaults() throws {
    let url = try #require(
      Bundle(for: FixtureBundle.self).url(
        forResource: "suggestion-contract-v2", withExtension: "json"))
    struct Contract: Decodable {
      var configuration: SuggestionConfiguration
    }
    let fixture = try JSONDecoder().decode(Contract.self, from: Data(contentsOf: url))

    expectNoDifference(fixture.configuration, SuggestionDefaults.configuration)
  }

  private func validConfiguration() -> SuggestionConfiguration {
    SuggestionConfiguration(
      types: [
        SuggestionTypeDefinition(
          id: "example", name: "Example Type", group: .spotlights,
          guidelines: "Find an example",
          template: [NamingComponent(kind: .field, value: "field")],
          sequenceFieldIDs: ["field"])
      ],
      fields: [
        SuggestionField(id: "field", name: "Example Field", instructions: "Extract it")
      ])
  }
}

private final class FixtureBundle {}
