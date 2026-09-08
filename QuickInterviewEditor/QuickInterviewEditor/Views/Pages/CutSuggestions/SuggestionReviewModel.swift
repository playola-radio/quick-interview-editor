import Foundation
import Observation

struct SuggestionReviewField: Identifiable {
  var id: String
  var title: String
  var evidence: String
}

struct SuggestionNamePreview: Identifiable {
  var id: UUID
  var before: String
  var after: String
}

@MainActor
@Observable
final class SuggestionReviewModel: ViewModel, Identifiable {
  // MARK: - Dependencies
  @ObservationIgnored var currentDocument: () -> EditorDocumentState
  @ObservationIgnored var isLocked: () -> Bool
  @ObservationIgnored var onApply: (SuggestionReviewIntent) throws -> Void
  @ObservationIgnored var onCancelled: () -> Void

  // MARK: - Shared State

  // MARK: - Initialization
  init(
    candidateID: UUID? = nil, sequenceKey: SuggestionSequenceKey? = nil,
    currentDocument: @escaping () -> EditorDocumentState,
    isLocked: @escaping () -> Bool,
    onApply: @escaping (SuggestionReviewIntent) throws -> Void,
    onCancelled: @escaping () -> Void = {}
  ) {
    self.candidateID = candidateID
    self.currentDocument = currentDocument
    self.isLocked = isLocked
    self.onApply = onApply
    self.onCancelled = onCancelled
    let document = currentDocument()
    let candidate = candidateID.flatMap { document.cutSuggestions[id: $0] }
    let batch = document.suggestionBatch
    runID = batch?.snapshot.runID
    self.sequenceKey =
      sequenceKey
      ?? candidate.flatMap { candidate in
        batch.flatMap { reviewSequenceKey(candidate, batch: $0) }
      }
    let naming = candidate?.naming
    originalFields = (naming?.extractedValues ?? [:]).merging(naming?.correctedValues ?? [:]) {
      _, value in value
    }
    fieldValues = originalFields
    let typeID = naming?.typeID ?? sequenceKey?.typeID
    let type = batch?.snapshot.configuration.types.first { $0.id == typeID }
    let referenced = Set(type?.template.compactMap { $0.kind == .field ? $0.value : nil } ?? [])
      .union(type?.sequenceFieldIDs ?? [])
    fields = (batch?.snapshot.configuration.fields ?? []).filter { referenced.contains($0.id) }.map
    {
      .init(
        id: $0.id, title: $0.name,
        evidence: "Extracted: " + (naming?.extractedValues[$0.id] ?? "Missing"))
    }
    groupingFields = fields.filter { type?.sequenceFieldIDs.contains($0.id) == true }
    let key = self.sequenceKey
    let savedDisplay = document.suggestionStarts.groups.first { $0.key == key }?.display
    let canonical =
      batch?.canonicalGroups.first { $0.key == key }?.values
      ?? savedDisplay?.canonicalValues
      ?? Dictionary(uniqueKeysWithValues: (key?.fields ?? []).map { ($0.fieldID, $0.value) })
    canonicalValues = canonical
    display = .init(
      typeName: type?.name ?? savedDisplay?.typeName ?? typeID ?? "Suggestion type",
      fieldNames: savedDisplay?.fieldNames
        ?? Dictionary(uniqueKeysWithValues: groupingFields.map { ($0.id, $0.title) }),
      canonicalValues: canonical)
    startText = String(
      document.suggestionStarts.groups.first { $0.key == key }?.start.number
        ?? typeID.flatMap { document.suggestionStarts.types[$0]?.number } ?? 1)
    super.init()
  }

  // MARK: - Properties
  let candidateID: UUID?
  let sequenceKey: SuggestionSequenceKey?
  let runID: UUID?
  let fields: [SuggestionReviewField]
  let groupingFields: [SuggestionReviewField]
  let display: SuggestionStarts.GroupDisplay
  private let originalFields: [String: String]
  private var fieldValues: [String: String]
  private var canonicalValues: [String: String]
  var startText: String
  private(set) var errorMessage: String?
  private(set) var statusMessage: String?

  // MARK: - View Helpers
  let title = "Review Suggestion Naming"
  let fieldsTitle = "Correct Extracted Fields"
  let applyFieldsLabel = "Apply Field Corrections"
  let startLabel = "Start next search at"
  let applyFutureStartLabel = "Save Song Start"
  let renumberLabel = "Renumber Pending Suggestions"
  let spellingTitle = "Group Spelling"
  let spellingHelp =
    "Choose the spelling used by pending names in this group. "
    + "Saved clips and accepted or rejected suggestions keep their names."
  let applySpellingLabel = "Apply Group Spelling"
  let cancelLabel = "Close"
  let beforeLabel = "Before"
  let afterLabel = "After"
  let renumberPreviewTitle = "Pending Names After Renumbering"
  let spellingPreviewTitle = "Pending Names After Spelling Change"
  let futureHelp =
    "Saving a start changes future searches only. "
    + "Renumbering is a separate change to pending suggestions in this search."
  var contextTitle: String {
    display.typeName + " · "
      + (sequenceKey?.fields.compactMap { display.canonicalValues[$0.fieldID] }
        .joined(separator: " · ") ?? "")
  }
  var showsFields: Bool { candidateID != nil }
  var showsGroup: Bool { candidateID == nil && sequenceKey != nil }
  var canEdit: Bool { !isLocked() }
  var canApplyFields: Bool {
    canEdit
      && fieldsIntent.flatMap { try? suggestionReviewChange($0, document: currentDocument()) }
        != nil
  }
  var canRenumber: Bool {
    canEdit
      && renumberIntent.flatMap { try? suggestionReviewChange($0, document: currentDocument()) }
        != nil
  }
  var canApplyGroupSpelling: Bool {
    canEdit
      && spellingIntent.flatMap { try? suggestionReviewChange($0, document: currentDocument()) }
        != nil
  }
  var canApplyFutureStart: Bool {
    canEdit && sequenceKey != nil && (try? parseSuggestionStartingNumber(startText)) != nil
  }
  var thisSearchStart: String {
    let document = currentDocument()
    guard let batch = document.suggestionBatch,
      document.cutSuggestions.contains(where: {
        reviewSequenceKey($0, batch: batch) == sequenceKey
      })
    else { return "This group has no suggestions in the current search." }
    let start =
      document.suggestionBatch?.actualStarts.groups.first { $0.key == sequenceKey }?.start.number
      ?? sequenceKey.flatMap { document.suggestionBatch?.actualStarts.types[$0.typeID]?.number }
      ?? 1
    return "This search started at: \(start)"
  }
  var missingFieldsMessage: String? {
    let missing = fields.filter {
      (fieldValues[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    return missing.isEmpty
      ? nil
      : "Missing fields: " + missing.map(\.title).joined(separator: ", ")
        + ". The descriptive name is kept when naming fields are missing; you can still accept the suggestion."
  }
  var previewNames: [SuggestionNamePreview] { previews(fieldsIntent) }
  var renumberPreviewNames: [SuggestionNamePreview] { previews(renumberIntent) }
  var spellingPreviewNames: [SuggestionNamePreview] { previews(spellingIntent) }
  var fieldsError: String? { validationError(fieldsIntent) }
  var spellingError: String? { validationError(spellingIntent) }
  var numberingError: String? {
    do {
      _ = try parseSuggestionStartingNumber(startText)
      if let intent = renumberIntent {
        _ = try suggestionReviewChange(intent, document: currentDocument())
      }
      return nil
    } catch { return reviewErrorMessage(error) }
  }

  subscript(field id: String) -> String {
    get { fieldValues[id] ?? "" }
    set { fieldChanged(id, value: newValue) }
  }
  subscript(canonical id: String) -> String {
    get { canonicalValues[id] ?? "" }
    set { canonicalValueChanged(id, value: newValue) }
  }

  // MARK: - User Actions
  func fieldChanged(_ id: String, value: String) {
    fieldValues[id] = value
    errorMessage = nil
  }
  func startChanged(_ value: String) {
    startText = value
    errorMessage = nil
  }
  func canonicalValueChanged(_ id: String, value: String) {
    canonicalValues[id] = value
    errorMessage = nil
  }
  func applyFieldsTapped() { apply(fieldsIntent) }
  func renumberTapped() { apply(renumberIntent) }
  func applyGroupSpellingTapped() { apply(spellingIntent) }
  func applyFutureStartTapped() {
    guard let sequenceKey, let number = try? parseSuggestionStartingNumber(startText) else {
      errorMessage = reviewErrorMessage(SuggestionNumberingError.invalidStart)
      return
    }
    var currentDisplay = display
    currentDisplay.canonicalValues =
      currentDocument().suggestionBatch?.canonicalGroups.first {
        $0.key == sequenceKey
      }?.values ?? display.canonicalValues
    apply(.futureGroup(key: sequenceKey, start: number, display: currentDisplay))
  }
  func cancelTapped() { onCancelled() }

  // MARK: - Private Helpers
  private var fieldsIntent: SuggestionReviewIntent? {
    guard let candidateID, let runID else { return nil }
    return .fields(
      candidateID: candidateID, runID: runID,
      values: fieldValues.filter { originalFields[$0.key] != $0.value })
  }
  private var renumberIntent: SuggestionReviewIntent? {
    guard let sequenceKey, let runID, let start = try? parseSuggestionStartingNumber(startText)
    else { return nil }
    return .renumber(key: sequenceKey, runID: runID, start: start)
  }
  private var spellingIntent: SuggestionReviewIntent? {
    guard let sequenceKey, let runID else { return nil }
    return .spelling(key: sequenceKey, runID: runID, values: canonicalValues)
  }
  private func apply(_ intent: SuggestionReviewIntent?) {
    do {
      guard canEdit else { throw SuggestionReviewError.locked }
      guard let intent else { throw SuggestionReviewError.unavailable }
      _ = try suggestionReviewChange(intent, document: currentDocument())
      try onApply(intent)
      errorMessage = nil
      statusMessage = "Applied. You can undo this change in the editor."
    } catch { errorMessage = reviewErrorMessage(error) }
  }
  private func validationError(_ intent: SuggestionReviewIntent?) -> String? {
    do {
      guard canEdit else { throw SuggestionReviewError.locked }
      guard let intent else { throw SuggestionReviewError.unavailable }
      _ = try suggestionReviewChange(intent, document: currentDocument())
      return nil
    } catch { return reviewErrorMessage(error) }
  }
  private func previews(_ intent: SuggestionReviewIntent?) -> [SuggestionNamePreview] {
    let document = currentDocument()
    guard let intent, let change = try? suggestionReviewChange(intent, document: document),
      case .batch(let candidates, _) = change
    else { return [] }
    return candidates.compactMap { candidate in
      guard let old = document.cutSuggestions[id: candidate.id], candidate.isPending,
        candidate.id == candidateID || candidate.title != old.title
      else { return nil }
      return .init(id: candidate.id, before: old.title, after: candidate.title)
    }
  }
}

func reviewErrorMessage(_ error: Error) -> String {
  switch error {
  case SuggestionNumberingError.invalidStart: "Enter a positive whole number."
  case SuggestionNumberingError.minimumSafeStart(let minimum): "The next safe start is \(minimum)."
  case SuggestionNumberingError.exhausted:
    "There are no available numbers at this start. Choose a lower start or another group."
  default: error.localizedDescription
  }
}
