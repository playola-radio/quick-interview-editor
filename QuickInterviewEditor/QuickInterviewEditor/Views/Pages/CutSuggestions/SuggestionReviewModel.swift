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
    let canonical = Self.canonicalValues(for: key, document: document)
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
  private var fieldDraftValues: [String: String] = [:]
  private var canonicalDraftValues: [String: String] = [:]
  var startText: String
  private(set) var errorMessage: String?
  private(set) var statusMessage: String?

  // MARK: - View Helpers
  let title = "Review Suggestion Naming"
  let fieldsTitle = "Correct Extracted Fields"
  let applyFieldsLabel = "Apply Field Corrections"
  let startLabel = "Start numbering at"
  let applyFutureStartLabel = "Save Song Start"
  let spellingTitle = "Group Spelling"
  let spellingHelp =
    "Choose the spelling used when accepting clips in this group. "
    + "Saved clips and previously issued names stay unchanged."
  let applySpellingLabel = "Apply Group Spelling"
  let cancelLabel = "Close"
  let beforeLabel = "If Accepted Now"
  let afterLabel = "If Accepted After Corrections"
  let spellingPreviewTitle = "Names If Accepted Next"
  let futureHelp =
    "The next accepted clip starts at this number or after the highest previously issued number, "
    + "whichever is greater. Pending suggestions do not consume numbers."
  var contextTitle: String {
    display.typeName + " · "
      + (sequenceKey?.fields.compactMap { display.canonicalValues[$0.fieldID] }
        .joined(separator: " · ") ?? "")
  }
  var showsFields: Bool { candidateID != nil }
  var showsGroup: Bool { candidateID == nil && sequenceKey != nil }
  var canEdit: Bool { !isLocked() }
  var canApplyFields: Bool {
    canEdit && !fieldDraftValues.isEmpty
      && fieldsIntent.flatMap { try? suggestionReviewChange($0, document: currentDocument()) }
        != nil
  }
  var canApplyGroupSpelling: Bool {
    canEdit && canonicalValues != currentCanonicalValues
      && spellingIntent.flatMap { try? suggestionReviewChange($0, document: currentDocument()) }
        != nil
  }
  var canApplyFutureStart: Bool {
    canEdit && sequenceKey != nil && (try? parseSuggestionStartingNumber(startText)) != nil
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
  var spellingPreviewNames: [SuggestionNamePreview] {
    canonicalValues == currentCanonicalValues ? [] : previews(spellingIntent)
  }
  var fieldsError: String? { validationError(fieldsIntent) }
  var spellingError: String? { validationError(spellingIntent) }

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
    fieldDraftValues[id] = value == (currentFieldValues[id] ?? "") ? nil : value
    errorMessage = nil
  }
  func startChanged(_ value: String) {
    startText = value
    errorMessage = nil
  }
  func canonicalValueChanged(_ id: String, value: String) {
    canonicalDraftValues[id] = value == (currentCanonicalValues[id] ?? "") ? nil : value
    errorMessage = nil
  }
  func applyFieldsTapped() {
    guard !fieldDraftValues.isEmpty, apply(fieldsIntent) else { return }
    fieldDraftValues = [:]
  }
  func applyGroupSpellingTapped() {
    guard canonicalValues != currentCanonicalValues, apply(spellingIntent) else { return }
    canonicalDraftValues = [:]
  }
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
  private var currentCanonicalValues: [String: String] {
    Self.canonicalValues(for: sequenceKey, document: currentDocument())
  }
  private var canonicalValues: [String: String] {
    currentCanonicalValues.merging(canonicalDraftValues) { _, draft in draft }
  }
  private static func canonicalValues(
    for key: SuggestionSequenceKey?, document: EditorDocumentState
  ) -> [String: String] {
    guard let key else { return [:] }
    let batch = document.suggestionBatch
    let type = batch?.snapshot.configuration.types.first { $0.id == key.typeID }
    let groupCandidate = document.cutSuggestions.first { candidate in
      batch.map { reviewSequenceKey(candidate, batch: $0) == key } == true
    }
    let candidateValues = groupCandidate?.naming.map {
      $0.extractedValues.merging($0.correctedValues) { _, corrected in corrected }
    }
    let sourceCanonical =
      batch?.canonicalGroups.first { $0.key == key }?.values
      ?? document.issuedSuggestionNumbers.first { $0.key == key && !$0.canonicalValues.isEmpty }?
      .canonicalValues
      ?? document.suggestionStarts.groups.first { $0.key == key }?.display?.canonicalValues
      ?? candidateValues
      ?? Dictionary(uniqueKeysWithValues: key.fields.map { ($0.fieldID, $0.value) })
    let groupingIDs = Set(type?.sequenceFieldIDs ?? key.fields.map(\.fieldID))
    return sourceCanonical.filter { groupingIDs.contains($0.key) }
  }
  private var currentFieldValues: [String: String] {
    guard let candidateID, let naming = currentDocument().cutSuggestions[id: candidateID]?.naming
    else { return [:] }
    return naming.extractedValues.merging(naming.correctedValues) { _, value in value }
  }
  private var fieldValues: [String: String] {
    currentFieldValues.merging(fieldDraftValues) { _, draft in draft }
  }
  private var fieldsIntent: SuggestionReviewIntent? {
    guard let candidateID, let runID else { return nil }
    return .fields(
      candidateID: candidateID, runID: runID,
      values: fieldDraftValues)
  }
  private var spellingIntent: SuggestionReviewIntent? {
    guard let sequenceKey, let runID else { return nil }
    return .spelling(key: sequenceKey, runID: runID, values: canonicalValues)
  }
  @discardableResult
  private func apply(_ intent: SuggestionReviewIntent?) -> Bool {
    do {
      guard canEdit else { throw SuggestionReviewError.locked }
      guard let intent else { throw SuggestionReviewError.unavailable }
      _ = try suggestionReviewChange(intent, document: currentDocument())
      try onApply(intent)
      errorMessage = nil
      statusMessage = "Applied. You can undo this change in the editor."
      return true
    } catch {
      errorMessage = reviewErrorMessage(error)
      return false
    }
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
      case .batch(let candidates, let batch) = change,
      let previousBatch = document.suggestionBatch
    else { return [] }
    return candidates.compactMap { candidate in
      guard let old = document.cutSuggestions[id: candidate.id], candidate.isPending,
        candidate.id == candidateID || reviewSequenceKey(candidate, batch: batch) == sequenceKey,
        let before = try? suggestionForAcceptance(
          old, batch: previousBatch,
          starts: document.suggestionStarts, issued: document.issuedSuggestionNumbers),
        let after = try? suggestionForAcceptance(
          candidate, batch: batch,
          starts: document.suggestionStarts, issued: document.issuedSuggestionNumbers)
      else { return nil }
      return .init(id: candidate.id, before: before.candidate.title, after: after.candidate.title)
    }
  }

}

func reviewErrorMessage(_ error: Error) -> String {
  switch error {
  case SuggestionNumberingError.invalidStart: "Enter a positive whole number."
  case SuggestionNumberingError.minimumSafeStart(let minimum): "The next safe start is \(minimum)."
  case SuggestionNumberingError.exhausted:
    "This group's numbering has reached the largest supported number. No clip was added."
  default: error.localizedDescription
  }
}
