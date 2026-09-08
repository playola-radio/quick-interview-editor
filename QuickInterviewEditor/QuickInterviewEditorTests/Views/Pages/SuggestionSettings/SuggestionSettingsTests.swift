import CustomDump
import Dependencies
import Foundation
import Sharing
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct SuggestionSettingsTests {
  @Test func referencedArtistFieldCannotBeRemoved() {
    let model = SuggestionSettingsModel(configuration: SuggestionDefaults.configuration)
    let originalIDs = model.draft.fields.map(\.id)
    model.removeFieldTapped("artist-name")
    expectNoDifference(model.draft.fields.map(\.id), originalIDs)
    #expect(model.validationMessages.contains { $0.contains("Song Intro") })
  }

  @Test func newRulesNeedUserContentAndKeepStableCustomIDs() async {
    let model = withDependencies {
      $0.uuid = .incrementing
      $0.suggestionConfiguration = .inMemory()
    } operation: {
      SuggestionSettingsModel(configuration: SuggestionDefaults.configuration)
    }
    model.addTypeTapped()
    let typeID = model.selectedTypeID
    #expect(typeID?.hasPrefix("custom-") == true)
    expectNoDifference(model.typeGroup, .audioImages)
    model.typeName = "Station Visit"
    model.typeGuidelines = "Find complete station visit announcements."
    model.namingTemplate?.literalChanged(at: 0, text: "Visit")
    model.addFieldTapped()
    let fieldID = model.selectedFieldID
    #expect(fieldID?.hasPrefix("custom-") == true)
    await model.saveTapped()
    #expect(!model.validationMessages.isEmpty)
    expectNoDifference(model.loadedRevision, 0)
    model.fieldName = "Station Name"
    model.fieldInstructions = "Extract the explicitly named station; leave missing if not stated."
    await model.saveTapped()
    expectNoDifference(model.loadedRevision, 1)
    expectNoDifference(model.draft.types.last?.id, typeID)
    expectNoDifference(model.draft.fields.last?.id, fieldID)
    expectNoDifference(model.draft.fields.last?.instructions, model.fieldInstructions)
  }

  @Test func twoWindowsKeepIndependentDraftsAndRejectStaleSave() async {
    @Shared(.suggestionConfiguration) var published = SuggestionDefaults.configuration
    let directory = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SuggestionConfigurationStore(fileURL: directory.appending(component: "rules.json"))
    let client = SuggestionConfigurationClient(
      load: { try await store.load() },
      save: { try await store.save($0, expectedRevision: $1) })
    let first = withDependencies {
      $0.suggestionConfiguration = client
    } operation: {
      SuggestionSettingsModel(configuration: SuggestionDefaults.configuration)
    }
    let second = withDependencies {
      $0.suggestionConfiguration = client
    } operation: {
      SuggestionSettingsModel(configuration: SuggestionDefaults.configuration)
    }
    first.typeName = "Opening Song"
    second.typeName = "My Intro"
    await first.saveTapped()
    expectNoDifference(published?.types[0].name, "Opening Song")
    #expect(second.savedRevisionStatus != nil)
    expectNoDifference(second.loadedRevision, 0)
    expectNoDifference(second.typeName, "My Intro")
    await second.saveTapped()
    #expect(second.statusMessage?.contains("another window") == true)
    expectNoDifference(second.typeName, "My Intro")
    await second.reloadTapped()
    expectNoDifference(second.typeName, "Opening Song")
    expectNoDifference(second.loadedRevision, 1)
  }

  @Test func cancelPublishesNothingAndRestoresLastLoadedDraft() {
    @Shared(.suggestionConfiguration) var published = SuggestionDefaults.configuration
    var cancelled = false
    let model = SuggestionSettingsModel(
      configuration: SuggestionDefaults.configuration,
      onCancelled: { cancelled = true })
    model.typeName = "Unsaved"
    model.cancelTapped()
    #expect(cancelled)
    expectNoDifference(published, SuggestionDefaults.configuration)
    expectNoDifference(model.draft, SuggestionDefaults.configuration)
  }

  @Test func failedSaveKeepsDraftAndPresentationOpen() async {
    @Shared(.suggestionConfiguration) var published = SuggestionDefaults.configuration
    var saved = false
    let model = withDependencies {
      $0.suggestionConfiguration.save = { _, _ in throw CocoaError(.fileWriteNoPermission) }
    } operation: {
      SuggestionSettingsModel(
        configuration: SuggestionDefaults.configuration, onSaved: { saved = true })
    }
    model.typeName = "My Intro"
    await model.saveTapped()
    #expect(!saved)
    #expect(!model.isSaving)
    #expect(model.statusMessage != nil)
    expectNoDifference(model.typeName, "My Intro")
    expectNoDifference(published, SuggestionDefaults.configuration)
  }

  @Test func loadOnceAndFailedReloadProtectDraft() async {
    let model = withDependencies {
      $0.suggestionConfiguration = .inMemory()
    } operation: {
      SuggestionSettingsModel()
    }
    #expect(!model.canSave)
    await model.viewAppeared()
    #expect(model.canSave)
    model.typeName = "Unsaved"
    await model.viewAppeared()
    expectNoDifference(model.typeName, "Unsaved")
  }

  @Test func failedReloadKeepsDraft() async {
    let model = withDependencies {
      $0.suggestionConfiguration.load = { throw CocoaError(.fileReadCorruptFile) }
    } operation: {
      SuggestionSettingsModel(configuration: SuggestionDefaults.configuration)
    }
    model.typeName = "Unsaved"
    await model.reloadTapped()
    expectNoDifference(model.typeName, "Unsaved")
    #expect(model.statusMessage != nil)
  }

  @Test func lastTypeCannotBeDeletedAndRestoreOnlyMissingPreset() {
    var configuration = SuggestionDefaults.configuration
    configuration.types = [configuration.types[0]]
    configuration.fields[1].instructions = "Edited artist instructions"
    let model = SuggestionSettingsModel(configuration: configuration)
    model.removeTypeTapped("intro")
    expectNoDifference(model.draft.types, configuration.types)
    #expect(!model.validationMessages.isEmpty)
    model.restoreBuiltInTapped("spotlight")
    expectNoDifference(model.draft.types.map(\.id), ["intro", "spotlight"])
    model.typeSelected("intro")
    model.typeName = "My Intro"
    model.restoreBuiltInTapped("intro")
    expectNoDifference(model.draft.types[0].name, "My Intro")
    expectNoDifference(model.draft.fields[1].instructions, "Edited artist instructions")
    model.removeTypeTapped("intro")
    model.restoreBuiltInTapped("intro")
    expectNoDifference(model.draft.types.last?.name, "Song Intro")
  }

  @Test func fieldRenamePreservesNamingAndGroupingReferences() {
    let model = SuggestionSettingsModel(configuration: SuggestionDefaults.configuration)
    let template = model.draft.types[0].template
    model.fieldSelected("artist-name")
    model.fieldName = "Performer"
    expectNoDifference(model.draft.fields[1].id, "artist-name")
    expectNoDifference(model.draft.types[0].template, template)
    expectNoDifference(model.draft.types[0].sequenceFieldIDs, ["song-title", "artist-name"])
  }

  @Test func panelCreatesFreshEditorAndCancelClosesOnlyRulesSheet() throws {
    let page = CutSuggestionsPageModel(editPlan: Fixtures.editPlan(), sourceFingerprint: "settings")
    page.configureSuggestionsTapped()
    let first = try #require(page.suggestionSettings)
    first.typeName = "Unsaved"
    first.cancelTapped()
    #expect(page.suggestionSettings == nil)
    page.configureSuggestionsTapped()
    let second = try #require(page.suggestionSettings)
    #expect(first !== second)
    expectNoDifference(second.typeName, "Song Intro")
  }

  @Test func failedInitialLoadPreventsSavingDefaults() async {
    let model = withDependencies {
      $0.suggestionConfiguration.load = { throw CocoaError(.fileReadCorruptFile) }
      $0.suggestionConfiguration.save = { _, _ in
        Issue.record("A failed initial load must not save defaults")
        return SuggestionDefaults.configuration
      }
    } operation: {
      SuggestionSettingsModel()
    }
    await model.viewAppeared()
    await model.saveTapped()
    #expect(!model.canSave)
    #expect(model.statusMessage?.contains("Could not load") == true)
  }

  @Test func builderEditsPersistInDraftAndSavedType() async {
    let client = SuggestionConfigurationClient.inMemory()
    let model = withDependencies {
      $0.suggestionConfiguration = client
    } operation: {
      SuggestionSettingsModel(configuration: SuggestionDefaults.configuration)
    }
    model.namingTemplate?.moveDownTapped(at: 0)
    model.namingTemplate?.groupingFieldTapped("song-title")
    await model.saveTapped()
    let saved = try? await client.load()
    expectNoDifference(saved?.types[0].template.first, NamingComponent(kind: .literal, value: " "))
    expectNoDifference(saved?.types[0].sequenceFieldIDs, ["artist-name"])
  }

  @Test func onlyTunedTypesExplainDiscoveryConfigurationChanges() {
    let model = SuggestionSettingsModel(configuration: SuggestionDefaults.configuration)
    for id in ["intro", "spotlight"] {
      model.typeSelected(id)
      #expect(model.showsTunedDiscoveryHelp)
    }
    for id in ["image-id", "image-pre-commercial", "image-post-commercial", "image-promo"] {
      model.typeSelected(id)
      #expect(!model.showsTunedDiscoveryHelp)
    }
    #expect(
      model.builtInHelp.contains("Editing their discovery guidelines or removing either type"))
    #expect(model.builtInHelp.contains("only while both keep their default guidelines"))
  }
}
