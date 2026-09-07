import Foundation

func suggestionSequenceKey(
  type: SuggestionTypeDefinition,
  values: [String: String],
  candidateID: UUID
) -> SuggestionSequenceKey {
  let fields = type.sequenceFieldIDs
    .sorted()
    .map { fieldID in
      SequenceFieldValue(fieldID: fieldID, value: canonicalSequenceValue(values[fieldID] ?? ""))
    }
  let hasMissingValue = fields.contains { $0.value.isEmpty }
  return SuggestionSequenceKey(
    typeID: type.id,
    fields: fields,
    provisionalCandidateID: hasMissingValue ? candidateID : nil)
}

func renderSuggestionName(
  template: [NamingComponent],
  values: [String: String],
  sequence: Int?,
  fallback: String
) -> String {
  var result = ""
  for component in template {
    switch component.kind {
    case .literal:
      result += component.value ?? ""
    case .field:
      guard let fieldID = component.value,
            let value = values[fieldID],
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return fallback }
      result += value
    case .sequence:
      guard let sequence, sequence > 0 else { return fallback }
      result += String(sequence)
    }
  }
  return result
}

private func canonicalSequenceValue(_ value: String) -> String {
  value
    .trimmingCharacters(in: .whitespacesAndNewlines)
    .precomposedStringWithCanonicalMapping
    .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    .lowercased()
}
