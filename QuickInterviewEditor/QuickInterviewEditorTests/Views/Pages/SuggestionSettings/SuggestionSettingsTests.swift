import CustomDump
import Dependencies
import Foundation
import Sharing
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct SuggestionSettingsTests {
  @Test func settingsKeepLastActiveProjectWhenSettingsTakesFocus() throws {
    let first = try project(named: "First.pie")
    let second = try project(named: "Second.pie")
    let model = SuggestionSettingsModel(
      configuration: SuggestionDefaults.configuration, isSettingsTab: true)
    model.projectActivityChanged(first, appearsActive: true)
    model.interviewSelected()
    model.projectActivityChanged(first, appearsActive: false)
    model.projectActivityChanged(second, appearsActive: false)
    #expect(model.numberingPage === first.editor?.cutSuggestions)
    expectNoDifference(model.projectName, "First.pie")
    #expect(model.showsInterview)
    #expect(!model.showsDone)
    model.projectUpdated(second)
    model.projectClosed(second)
    #expect(model.numberingPage === first.editor?.cutSuggestions)
  }

  @Test func switchingProjectsPreservesSeparateArtistCountAndGlobalRuleDrafts() throws {
    let first = try project(named: "First.pie")
    let second = try project(named: "Second.pie")
    let model = SuggestionSettingsModel(
      configuration: SuggestionDefaults.configuration, isSettingsTab: true)
    model.typeName = "Unsaved rules"
    let rules = model.draft
    model.projectActivityChanged(first, appearsActive: true)
    model.interviewSelected()
    model.interviewArtistText = "First artist"
    first.editor?.cutSuggestions[futureStart: "intro"] = "41"
    model.projectActivityChanged(second, appearsActive: true)
    expectNoDifference(model.interviewArtistText, "")
    expectNoDifference(model.numberingPage?[futureStart: "intro"], "1")
    model.interviewArtistText = "Second artist"
    second.editor?.cutSuggestions[futureStart: "intro"] = "82"
    model.projectActivityChanged(first, appearsActive: true)
    expectNoDifference(model.interviewArtistText, "First artist")
    expectNoDifference(model.numberingPage?[futureStart: "intro"], "41")
    model.projectActivityChanged(second, appearsActive: true)
    expectNoDifference(model.interviewArtistText, "Second artist")
    expectNoDifference(model.numberingPage?[futureStart: "intro"], "82")
    expectNoDifference(model.draft, rules)
    #expect(model.showsInterview)
  }

  @Test func switchingProjectsRoutesSavesAndUndoToTheirOwningEditor() async throws {
    let first = try project(named: "First.pie")
    let second = try project(named: "Second.pie")
    let firstEditor = try #require(first.editor)
    let secondEditor = try #require(second.editor)
    var firstChanges: [EditorDocumentState] = []
    var secondChanges: [EditorDocumentState] = []
    firstEditor.onDocumentStateChanged = { firstChanges.append($0) }
    secondEditor.onDocumentStateChanged = { secondChanges.append($0) }
    let model = SuggestionSettingsModel(
      configuration: SuggestionDefaults.configuration, isSettingsTab: true)
    model.projectActivityChanged(first, appearsActive: true)
    model.interviewArtistText = "First artist"
    model.projectActivityChanged(second, appearsActive: true)
    model.interviewArtistText = "Second artist"
    model.saveInterviewTapped()
    expectNoDifference(secondEditor.documentState.interviewArtist, "Second artist")
    expectNoDifference(secondChanges.last, secondEditor.documentState)
    #expect(firstChanges.isEmpty)
    model.projectActivityChanged(first, appearsActive: true)
    model.saveInterviewTapped()
    model.numberingPage?[futureStart: "intro"] = "9"
    model.numberingPage?.applyTypeStartTapped("intro")
    expectNoDifference(firstEditor.documentState.interviewArtist, "First artist")
    expectNoDifference(firstEditor.suggestionStarts.types["intro"]?.number, 9)
    expectNoDifference(firstChanges.last, firstEditor.documentState)
    await firstEditor.undoTapped()
    expectNoDifference(firstEditor.suggestionStarts.types["intro"], nil)
    await firstEditor.undoTapped()
    expectNoDifference(firstEditor.documentState.interviewArtist, nil)
    expectNoDifference(secondEditor.documentState.interviewArtist, "Second artist")
    #expect(!model.canSaveInterview)
  }

  @Test func contextChangesDismissGroupReviewAndFollowEditorReplacement() throws {
    let first = try project(named: "First.pie")
    let second = try project(named: "Second.pie")
    let model = SuggestionSettingsModel(
      configuration: SuggestionDefaults.configuration, isSettingsTab: true)
    model.projectActivityChanged(first, appearsActive: true)
    let editor = try #require(first.editor)
    let batch = try #require(editor.suggestionBatch)
    let key = try #require(reviewSequenceKey(editor.documentCutSuggestions[0], batch: batch))
    model.reviewGroupTapped(key)
    #expect(model.numberingReview != nil)
    model.projectActivityChanged(second, appearsActive: true)
    #expect(model.numberingReview == nil)
    model.projectActivityChanged(first, appearsActive: true)
    model.reviewGroupTapped(key)
    first.editor = try SuggestionReviewTests().fixture()
    model.projectUpdated(first)
    #expect(model.numberingPage === first.editor?.cutSuggestions)
    #expect(model.numberingPage !== editor.cutSuggestions)
    #expect(model.numberingReview == nil)
    first.editor = nil
    model.projectUpdated(first)
    #expect(!model.showsNumberingOption)
    first.editor = editor
    model.projectUpdated(first)
    #expect(model.numberingPage === editor.cutSuggestions)
    model.projectClosed(first)
    #expect(model.numberingPage == nil)
    expectNoDifference(model.projectName, nil)
  }

  @Test func settingsExplainMissingProjectAndDoNotRetainClosedProject() throws {
    let model = SuggestionSettingsModel(
      configuration: SuggestionDefaults.configuration, isSettingsTab: true)
    #expect(model.projectContextMessage.contains("Open a project"))
    #expect(model.projectContextMessage.contains("Interview"))
    #expect(model.projectContextMessage.contains("Numbering"))
    #expect(model.showsTypeEditor)
    #expect(model.showsRuleActions)
    #expect(!model.showsDone)
    var active: ProjectModel? = try project(named: "Closing.pie")
    weak var weakProject = active
    weak var weakPage = active?.editor?.cutSuggestions
    model.projectActivityChanged(try #require(active), appearsActive: true)
    model.projectClosed(try #require(active))
    active = nil
    #expect(weakProject == nil)
    #expect(weakPage == nil)
    #expect(model.showsTypeEditor)
    #expect(model.projectContextMessage.contains("Open a project"))
  }

  @Test func activeSettingsContextDoesNotOwnTheProjectLifetime() throws {
    let model = SuggestionSettingsModel(isSettingsTab: true)
    var active: ProjectModel? = try project(named: "Transient.pie")
    weak var weakProject = active
    weak var weakPage = active?.editor?.cutSuggestions
    model.projectActivityChanged(try #require(active), appearsActive: true)
    active = nil
    #expect(weakProject == nil)
    #expect(weakPage == nil)
    #expect(model.numberingPage == nil)
    expectNoDifference(model.projectName, nil)
  }

  @Test func settingsFollowProjectFilenameChanges() throws {
    let project = try project(named: "First.pie")
    let model = SuggestionSettingsModel(isSettingsTab: true)
    model.projectActivityChanged(project, appearsActive: true)
    project.documentURLChanged(URL(fileURLWithPath: "/Renamed.pie"))
    model.projectUpdated(project)
    expectNoDifference(model.projectName, "Renamed.pie")
    #expect(model.projectContextMessage.contains("Renamed.pie"))
  }

  private func project(named name: String) throws -> ProjectModel {
    let project = ProjectModel(
      file: nil, plan: nil, audio: nil, packageURL: URL(fileURLWithPath: "/" + name),
      sink: .init(commit: { _, _, _ in }, registerChange: {}))
    project.editor = try SuggestionReviewTests().fixture()
    return project
  }

  @Test func interviewSaveAndClearAreUndoableAndIndependentOfRuleDraft() async throws {
    @Shared(.suggestionConfiguration) var published = SuggestionDefaults.configuration
    let editor = try SuggestionReviewTests().fixture()
    let before = editor.documentState
    var changes: [EditorDocumentState] = []
    editor.onDocumentStateChanged = { changes.append($0) }
    let settings = SuggestionSettingsModel(numberingPage: editor.cutSuggestions)
    settings.typeName = "Unsaved rule edit"
    let ruleDraft = settings.draft
    settings.interviewSelected()
    #expect(settings.showsInterview)
    #expect(!settings.showsTypeEditor)
    settings.interviewArtistText = "  Brandi Carlile \n"
    expectNoDifference(editor.documentState, before)
    await MainActor.run {
      expectDifference(editor.documentState) {
        settings.saveInterviewTapped()
      } changes: {
        $0.interviewArtist = "Brandi Carlile"
      }
    }
    expectNoDifference(settings.interviewArtistText, "Brandi Carlile")
    expectNoDifference(settings.draft, ruleDraft)
    expectNoDifference(published, SuggestionDefaults.configuration)
    expectNoDifference(changes.last, editor.documentState)
    settings.interviewArtistText = "  \n"
    settings.saveInterviewTapped()
    expectNoDifference(editor.documentState.interviewArtist, nil)
    await editor.undoTapped()
    expectNoDifference(editor.documentState.interviewArtist, "Brandi Carlile")
    await editor.undoTapped()
    expectNoDifference(editor.documentState, before)
    await editor.redoTapped()
    expectNoDifference(editor.documentState.interviewArtist, "Brandi Carlile")
    settings.cancelTapped()
    expectNoDifference(editor.documentState.interviewArtist, "Brandi Carlile")
    expectNoDifference(published, SuggestionDefaults.configuration)
    expectNoDifference(
      SuggestionSettingsModel(numberingPage: editor.cutSuggestions).interviewArtistText,
      "Brandi Carlile")
  }

  @Test func interviewNavigationAndRuleReloadPreserveIndependentProjectDraft() async throws {
    let page = withDependencies {
      $0.suggestionConfiguration = .inMemory()
    } operation: {
      CutSuggestionsPageModel(editPlan: Fixtures.editPlan(), sourceFingerprint: "interview")
    }
    let settings = withDependencies(from: page) { SuggestionSettingsModel(numberingPage: page) }
    settings.interviewSelected()
    settings.interviewArtistText = "Unsaved artist"
    await settings.viewAppeared()
    #expect(settings.showsInterview)
    #expect(settings.showsDone)
    expectNoDifference(settings.interviewArtistText, "Unsaved artist")
    settings.numberingSelected()
    #expect(!settings.showsInterview)
    #expect(settings.showsNumbering)
    settings.interviewSelected()
    #expect(!settings.showsNumbering)
    settings.typeSelected("intro")
    #expect(!settings.showsInterview)
    settings.fieldSelected("artist-name")
    #expect(settings.showsFieldEditor)
    expectNoDifference(settings.interviewArtistText, "Unsaved artist")
    let standalone = SuggestionSettingsModel(configuration: SuggestionDefaults.configuration)
    #expect(!standalone.showsInterviewOption)
    standalone.interviewSelected()
    #expect(!standalone.showsInterview)
  }

  @Test func loadingRulesPreservesNumberingSelection() async {
    @Shared(.suggestionConfiguration) var published = SuggestionDefaults.configuration
    let page = withDependencies {
      $0.suggestionConfiguration = .inMemory()
    } operation: {
      CutSuggestionsPageModel(editPlan: Fixtures.editPlan(), sourceFingerprint: "settings-load")
    }
    let settings = withDependencies(from: page) { SuggestionSettingsModel(numberingPage: page) }
    settings.numberingSelected()
    await settings.viewAppeared()
    #expect(settings.showsNumbering)
    #expect(settings.showsDone)
  }

  @Test func groupReviewBelongsToConfigurationAndKeepsItOpenOnClose() throws {
    let editor = try SuggestionReviewTests().fixture()
    let page = editor.cutSuggestions
    let batch = try #require(editor.suggestionBatch)
    let key = try #require(reviewSequenceKey(editor.documentCutSuggestions[0], batch: batch))
    let settings = withDependencies(from: page) { SuggestionSettingsModel(numberingPage: page) }
    settings.numberingSelected()
    settings.reviewGroupTapped(key)
    let review = try #require(settings.numberingReview)
    #expect(page.suggestionReview == nil)
    review.startText = "9"
    review.applyFutureStartTapped()
    expectNoDifference(editor.suggestionStarts.groups.first { $0.key == key }?.start.number, 9)
    review.cancelTapped()
    #expect(settings.numberingReview == nil)
    #expect(settings.numberingPage === page)
    page.resetSongStartTapped(key)
    #expect(editor.suggestionStarts.groups.isEmpty)
    let before = editor.documentState
    page[futureStart: "intro"] = "invalid"
    page.applyTypeStartTapped("intro")
    #expect(page.actionMessage != nil)
    expectNoDifference(editor.documentState, before)
    page.recoveryBlocksSuggestions = true
    page[futureStart: "intro"] = "10"
    page.applyTypeStartTapped("intro")
    settings.reviewGroupTapped(key)
    expectNoDifference(editor.documentState, before)
    #expect(settings.numberingReview == nil)
  }

  @Test func numberingNavigationKeepsRuleDraftAndProjectStartsIndependent() async throws {
    @Shared(.suggestionConfiguration) var published = SuggestionDefaults.configuration
    let editor = try SuggestionReviewTests().fixture()
    let page = editor.cutSuggestions
    let settings = withDependencies(from: page) { SuggestionSettingsModel(numberingPage: page) }
    #expect(settings.numberingPage === page)
    #expect(settings.showsNumberingOption)
    settings.typeName = "My Song Intro"
    let draft = settings.draft
    settings.numberingSelected()
    #expect(settings.showsNumbering)
    #expect(!settings.showsTypeEditor)
    #expect(settings.showsRuleActions)
    expectNoDifference(settings.draft, draft)
    page[futureStart: "spotlight"] = "7"
    page.applyTypeStartTapped("spotlight")
    expectNoDifference(editor.suggestionStarts.types["spotlight"]?.number, 7)
    settings.typeSelected("intro")
    #expect(!settings.showsNumbering)
    expectNoDifference(settings.typeName, "My Song Intro")
    page[futureStart: "spotlight"] = "99"
    settings.cancelTapped()
    #expect(settings.numberingPage === page)
    expectNoDifference(editor.suggestionStarts.types["spotlight"]?.number, 7)
    expectNoDifference(page[futureStart: "spotlight"], "99")
    expectNoDifference(published, SuggestionDefaults.configuration)
  }

  @Test func standaloneSettingsHaveNoProjectNumbering() {
    let model = SuggestionSettingsModel(configuration: SuggestionDefaults.configuration)
    #expect(!model.showsNumberingOption)
    model.numberingSelected()
    #expect(!model.showsNumbering)
    #expect(model.showsTypeEditor)
  }

  @Test func numberingOnlyVisitShowsDoneAndDoesNotRetainPage() throws {
    var page: CutSuggestionsPageModel? = CutSuggestionsPageModel(
      editPlan: Fixtures.editPlan(), sourceFingerprint: "numbering")
    let model = SuggestionSettingsModel(numberingPage: page)
    model.numberingSelected()
    #expect(model.showsDone)
    #expect(!model.showsRuleActions)
    page = nil
    #expect(model.numberingPage == nil)
  }

  @Test func repeatedInvalidLiteralsProduceOneSaveDiagnosticAndKeepDraftInvalid() async throws {
    let model = SuggestionSettingsModel(configuration: SuggestionDefaults.configuration)
    let template = try #require(model.namingTemplate)
    template.addLiteralTapped()
    template.addLiteralTapped()
    await model.saveTapped()
    expectNoDifference(model.validationMessages.count, 1)
    expectNoDifference(model.loadedRevision, 0)
    template.literalChanged(at: template.components.count - 1, text: "Suffix")
    await model.saveTapped()
    expectNoDifference(model.validationMessages.count, 1)
    expectNoDifference(model.loadedRevision, 0)
  }

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

  @Test func cancellingRulesKeepsProjectConnectionAndIndependentDrafts() {
    let page = CutSuggestionsPageModel(editPlan: Fixtures.editPlan(), sourceFingerprint: "settings")
    let model = SuggestionSettingsModel(
      configuration: SuggestionDefaults.configuration, numberingPage: page, isSettingsTab: true)
    model.typeName = "Unsaved"
    model.interviewArtistText = "Artist draft"
    page[futureStart: "intro"] = "99"
    model.cancelTapped()
    #expect(model.numberingPage === page)
    expectNoDifference(model.typeName, "Song Intro")
    expectNoDifference(model.interviewArtistText, "Artist draft")
    expectNoDifference(page[futureStart: "intro"], "99")
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
