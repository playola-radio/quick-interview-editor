import Dependencies
import Foundation
import Observation
import Sharing

struct SuggestionSettingsRow: Identifiable {
  var id: String
  var title: String
  var isSelected = false
}

struct SuggestionGroupOption: Identifiable {
  var id: SuggestionGroup
  var title: String
}

@MainActor
@Observable
final class SuggestionSettingsModel: ViewModel, Identifiable {
  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.suggestionConfiguration) var configurationClient
  @ObservationIgnored @Dependency(\.uuid) var uuid

  // MARK: - Shared State
  @ObservationIgnored @Shared(.suggestionConfiguration) var savedConfiguration

  // MARK: - Initialization
  init(
    configuration: SuggestionConfiguration? = nil,
    numberingPage: CutSuggestionsPageModel? = nil,
    onSaved: (() -> Void)? = nil, onCancelled: (() -> Void)? = nil
  ) {
    let initial = configuration ?? SuggestionDefaults.configuration
    draft = initial
    loadedConfiguration = initial
    loadedRevision = initial.revision
    hasLoaded = configuration != nil
    selectedTypeID = initial.types.first?.id
    self.onSaved = onSaved
    self.onCancelled = onCancelled
    self.numberingPage = numberingPage
    super.init()
    rebuildNamingTemplate()
  }

  // MARK: - Properties
  var draft: SuggestionConfiguration {
    didSet { namingTemplate?.availableFields = draft.fields }
  }
  private(set) var loadedRevision: Int
  private(set) var selectedTypeID: String?
  private(set) var selectedFieldID: String?
  weak var numberingPage: CutSuggestionsPageModel?
  private(set) var isNumberingSelected = false
  var numberingReview: SuggestionReviewModel?
  private var validationErrors: [String] = []
  private(set) var statusMessage: String?
  private(set) var isSaving = false
  private(set) var isLoading = false
  private(set) var namingTemplate: NamingTemplateModel?
  private var hasLoaded: Bool
  private var attemptedLoad = false
  private var loadedConfiguration: SuggestionConfiguration
  @ObservationIgnored private var onSaved: (() -> Void)?
  @ObservationIgnored private var onCancelled: (() -> Void)?

  // MARK: - View Helpers
  var validationMessages: [String] {
    var seen = Set<String>()
    return validationErrors.filter { seen.insert($0).inserted }
  }

  let title = "Configure Suggestions"
  let numberingTitle = "Numbering"
  let projectScopeTitle = "This project"
  let doneLabel = "Done"
  let typesTitle = "Types"
  let fieldsTitle = "Fields"
  let addTypeLabel = "Add Type"
  let removeTypeLabel = "Remove Type"
  let addFieldLabel = "Add Field"
  let removeFieldLabel = "Remove Field"
  let restoreLabel = "Restore Missing Preset"
  let nameLabel = "Name"
  let groupLabel = "Display Group"
  let guidelinesLabel = "Discovery Guidelines"
  let fieldInstructionsLabel = "Extraction Instructions"
  let saveLabel = "Save Rules"
  let cancelLabel = "Cancel Rule Edits"
  let reloadLabel = "Reload Saved Rules"
  let selectionPrompt = "Choose a type or field to edit."
  var helpText: String {
    showsNumbering
      ? "Starting counts belong to this project. Save Rules and Cancel Rule Edits apply only to the rule draft."
      : "Saved rules apply to future searches in all projects. Removing a type keeps its existing suggestions visible."
  }
  let builtInHelp =
    "Song Intro and Spotlight use tuned discovery. Editing their discovery guidelines or removing either type "
    + "changes the default discovery configuration. The original discovery prompt is preserved only while both keep "
    + "their default guidelines. Naming, fields, and imaging/custom types do not change that prompt."
  let guidelinesHelp =
    "Describe the complete clips this type should find, including useful context and exclusions."
  let instructionsHelp =
    "Describe what to extract from the transcript and when the value should be left missing."
  let groupOptions = [
    SuggestionGroupOption(id: .spotlights, title: "Spotlights"),
    SuggestionGroupOption(id: .songIntros, title: "Song Intros"),
    SuggestionGroupOption(id: .audioImages, title: "Audio Images"),
  ]

  var typeRows: [SuggestionSettingsRow] {
    draft.types.map {
      .init(
        id: $0.id, title: $0.name.isEmpty ? "Untitled Type" : $0.name,
        isSelected: !isNumberingSelected && $0.id == selectedTypeID)
    }
  }
  var fieldRows: [SuggestionSettingsRow] {
    draft.fields.map {
      .init(
        id: $0.id, title: $0.name.isEmpty ? "Untitled Field" : $0.name,
        isSelected: !isNumberingSelected && $0.id == selectedFieldID)
    }
  }
  var missingPresets: [SuggestionSettingsRow] {
    SuggestionDefaults.types.filter { preset in !draft.types.contains { $0.id == preset.id } }
      .map { .init(id: $0.id, title: $0.name) }
  }
  var showsRestore: Bool { !missingPresets.isEmpty }
  var showsNumberingOption: Bool { numberingPage != nil }
  var showsNumbering: Bool { isNumberingSelected && showsNumberingOption }
  var showsRuleActions: Bool { !showsNumbering || draft != loadedConfiguration }
  var showsDone: Bool { !showsRuleActions }
  var showsTypeEditor: Bool { !showsNumbering && typeIndex != nil }
  var showsFieldEditor: Bool { !showsNumbering && fieldIndex != nil }
  var showsTunedDiscoveryHelp: Bool { selectedTypeID == "intro" || selectedTypeID == "spotlight" }
  var isBusy: Bool { isSaving || isLoading }
  var canEdit: Bool { hasLoaded && !isBusy }
  var canSave: Bool { canEdit }
  var canCancel: Bool { !isBusy }
  var canReload: Bool { !isBusy }
  var canRemoveType: Bool { draft.types.count > 1 }
  var savedRevisionStatus: String? {
    guard hasLoaded, let savedConfiguration, savedConfiguration.revision > loadedRevision else {
      return nil
    }
    return
      "Newer rules were saved in another window. Reload saved rules to replace this draft with them."
  }

  var typeName: String {
    get { typeIndex.map { draft.types[$0].name } ?? "" }
    set { if let index = typeIndex { draft.types[index].name = newValue } }
  }
  var typeGroup: SuggestionGroup {
    get { typeIndex.map { draft.types[$0].group } ?? .audioImages }
    set { if let index = typeIndex { draft.types[index].group = newValue } }
  }
  var typeGuidelines: String {
    get { typeIndex.map { draft.types[$0].guidelines } ?? "" }
    set { if let index = typeIndex { draft.types[index].guidelines = newValue } }
  }
  var fieldName: String {
    get { fieldIndex.map { draft.fields[$0].name } ?? "" }
    set { if let index = fieldIndex { draft.fields[index].name = newValue } }
  }
  var fieldInstructions: String {
    get { fieldIndex.map { draft.fields[$0].instructions } ?? "" }
    set { if let index = fieldIndex { draft.fields[index].instructions = newValue } }
  }

  // MARK: - User Actions
  func viewAppeared() async {
    guard !hasLoaded, !attemptedLoad else { return }
    attemptedLoad = true
    await reloadTapped()
  }

  func reloadTapped() async {
    guard !isBusy else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      applyLoaded(try await configurationClient.load())
      statusMessage = "Loaded saved rules."
    } catch {
      statusMessage =
        "Could not load saved rules. Your draft is unchanged. \(error.localizedDescription)"
    }
  }

  func typeSelected(_ id: String) {
    isNumberingSelected = false
    selectedTypeID = id
    selectedFieldID = nil
    rebuildNamingTemplate()
  }

  func fieldSelected(_ id: String) {
    isNumberingSelected = false
    selectedFieldID = id
    selectedTypeID = nil
    namingTemplate = nil
  }

  func numberingSelected() {
    guard showsNumberingOption else { return }
    isNumberingSelected = true
  }

  func addTypeTapped() {
    let id = SuggestionConfiguration.customID(using: uuid())
    draft.types.append(
      .init(
        id: id, name: "", group: .audioImages, guidelines: "",
        template: [.init(kind: .literal, value: "")], sequenceFieldIDs: []))
    typeSelected(id)
  }

  func removeTypeTapped(_ id: String) {
    guard draft.types.contains(where: { $0.id == id }) else { return }
    guard canRemoveType else {
      validationErrors = ["Keep at least one suggestion type."]
      return
    }
    draft.types.removeAll { $0.id == id }
    validationErrors = []
    if selectedTypeID == id, let first = draft.types.first { typeSelected(first.id) }
  }

  func restoreBuiltInTapped(_ id: String) {
    switch draft.restoreBuiltInType(id: id) {
    case .restored:
      validationErrors = []
      statusMessage = "Restored the missing preset. Save to use it in future searches."
      typeSelected(id)
    case .alreadyPresent:
      statusMessage = "This preset is already present. Your edits were kept."
    case .unknownBuiltIn:
      statusMessage = "This preset is unavailable."
    case .typeNameConflict:
      validationErrors = [
        "A type already uses this preset's name in its display group. Rename it before restoring."
      ]
    case .fieldNameConflict:
      validationErrors = [
        "A field already uses a name needed by this preset. Rename it before restoring."
      ]
    }
  }

  func addFieldTapped() {
    let id = SuggestionConfiguration.customID(using: uuid())
    draft.fields.append(.init(id: id, name: "", instructions: ""))
    fieldSelected(id)
  }

  func removeFieldTapped(_ id: String) {
    let references = draft.removeField(id: id)
    validationErrors = references.map {
      "This field is used by \($0). Remove its naming and numbering references first."
    }
    if references.isEmpty, selectedFieldID == id {
      selectedFieldID = draft.fields.first?.id
    }
  }

  func removeSelectedTypeTapped() {
    if let id = selectedTypeID { removeTypeTapped(id) }
  }
  func removeSelectedFieldTapped() {
    if let id = selectedFieldID { removeFieldTapped(id) }
  }

  func saveTapped() async {
    guard canSave else { return }
    validationErrors = draft.validationMessages()
    guard validationMessages.isEmpty else {
      statusMessage = "Resolve the issues below before saving."
      return
    }
    isSaving = true
    defer { isSaving = false }
    do {
      let saved = try await configurationClient.save(draft, loadedRevision)
      applyLoaded(saved)
      statusMessage = "Saved. Future searches will use these rules."
      onSaved?()
    } catch SuggestionConfigurationStoreError.staleDraft {
      statusMessage =
        "Rules were saved in another window. Reload saved rules before editing and saving again."
    } catch {
      statusMessage = "Could not save rules. Your draft is unchanged. \(error.localizedDescription)"
    }
  }

  func cancelTapped() {
    guard canCancel else { return }
    applyLoaded(loadedConfiguration, markLoaded: hasLoaded)
    statusMessage = nil
    onCancelled?()
  }

  // MARK: - Private Helpers
  private var typeIndex: Int? { draft.types.firstIndex { $0.id == selectedTypeID } }
  private var fieldIndex: Int? { draft.fields.firstIndex { $0.id == selectedFieldID } }

  private func applyLoaded(_ configuration: SuggestionConfiguration, markLoaded: Bool = true) {
    let wasNumberingSelected = isNumberingSelected
    draft = configuration
    loadedConfiguration = configuration
    loadedRevision = configuration.revision
    hasLoaded = markLoaded
    validationErrors = []
    if let id = selectedFieldID, configuration.fields.contains(where: { $0.id == id }) {
      fieldSelected(id)
    } else {
      typeSelected(
        configuration.types.first(where: { $0.id == selectedTypeID })?.id
          ?? configuration.types.first?.id ?? "")
    }
    isNumberingSelected = wasNumberingSelected
  }

  private func rebuildNamingTemplate() {
    guard let index = typeIndex else {
      namingTemplate = nil
      return
    }
    let type = draft.types[index]
    let builder = NamingTemplateModel(
      components: type.template, fields: draft.fields,
      selectedGroupingFieldIDs: type.sequenceFieldIDs)
    builder.onChanged = { [weak self] components, grouping in
      guard let self, let index = draft.types.firstIndex(where: { $0.id == type.id }) else {
        return
      }
      draft.types[index].template = components
      draft.types[index].sequenceFieldIDs = grouping
    }
    namingTemplate = builder
  }
}
