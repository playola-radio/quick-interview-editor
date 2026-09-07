import Foundation

enum SuggestionGroup: String, Codable, CaseIterable, Sendable {
  case spotlights
  case songIntros
  case audioImages
}

struct NamingComponent: Codable, Equatable, Sendable {
  enum Kind: String, Codable, Sendable {
    case literal
    case field
    case sequence
  }

  var kind: Kind
  var value: String?
}

struct SuggestionField: Identifiable, Codable, Equatable, Sendable {
  var id: String
  var name: String
  var instructions: String
}

struct SuggestionTypeDefinition: Identifiable, Codable, Equatable, Sendable {
  var id: String
  var name: String
  var group: SuggestionGroup
  var guidelines: String
  var template: [NamingComponent]
  var sequenceFieldIDs: [String]
}

struct SuggestionConfiguration: Codable, Equatable, Sendable {
  var schemaVersion: Int = 1
  var revision: Int = 0
  var types: [SuggestionTypeDefinition]
  var fields: [SuggestionField]

  init(
    schemaVersion: Int = 1,
    revision: Int = 0,
    types: [SuggestionTypeDefinition],
    fields: [SuggestionField]
  ) {
    self.schemaVersion = schemaVersion
    self.revision = revision
    self.types = types
    self.fields = fields
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion
    case revision
    case types
    case fields
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    revision = try container.decode(Int.self, forKey: .revision)
    types = try container.decode([SuggestionTypeDefinition].self, forKey: .types)
    fields = try container.decode([SuggestionField].self, forKey: .fields)
  }
}

enum SuggestionBuiltInRestoreResult: Equatable, Sendable {
  case restored
  case alreadyPresent
  case unknownBuiltIn
  case typeNameConflict(existingTypeID: String)
  case fieldNameConflict(existingFieldID: String, presetFieldID: String)
}

extension SuggestionConfiguration {
  static let currentSchemaVersion = 1

  func validationMessages() -> [String] {
    configurationValidationMessages()
      + typeValidationMessages()
      + fieldValidationMessages()
      + referenceValidationMessages()
  }

  private func configurationValidationMessages() -> [String] {
    var messages: [String] = []
    if schemaVersion != Self.currentSchemaVersion {
      messages.append("Unsupported suggestion configuration schema version \(schemaVersion).")
    }
    if types.isEmpty {
      messages.append("Suggestion configuration must contain at least one type.")
    }
    return messages
  }

  private func typeValidationMessages() -> [String] {
    var messages: [String] = []
    var typeIDs: Set<String> = []
    var typeNamesByGroup: Set<String> = []
    for type in types {
      if type.id.isBlank {
        messages.append("Suggestion type ID cannot be empty.")
      } else if !typeIDs.insert(type.id).inserted {
        messages.append("Duplicate type ID '\(type.id)'.")
      }

      if type.name.isBlank {
        messages.append("Suggestion type name cannot be empty for '\(type.id)'.")
      } else {
        let nameKey = "\(type.group.rawValue)\u{0}\(type.name.normalizedConfigurationName)"
        if !typeNamesByGroup.insert(nameKey).inserted {
          messages.append("Duplicate type name '\(type.name)' in the \(type.group.rawValue) group.")
        }
      }

      if type.guidelines.isBlank {
        messages.append("Suggestion type guidelines cannot be empty for '\(type.id)'.")
      }
    }
    return messages
  }

  private func fieldValidationMessages() -> [String] {
    var messages: [String] = []
    var fieldIDs: Set<String> = []
    var fieldNames: Set<String> = []
    for field in fields {
      if field.id.isBlank {
        messages.append("Suggestion field ID cannot be empty.")
      } else if !fieldIDs.insert(field.id).inserted {
        messages.append("Duplicate field ID '\(field.id)'.")
      }

      if field.name.isBlank {
        messages.append("Suggestion field name cannot be empty for '\(field.id)'.")
      } else if !fieldNames.insert(field.name.normalizedConfigurationName).inserted {
        messages.append("Duplicate field name '\(field.name)'.")
      }

      if field.instructions.isBlank {
        messages.append("Suggestion field instructions cannot be empty for '\(field.id)'.")
      }
    }
    return messages
  }

  private func referenceValidationMessages() -> [String] {
    let fieldIDs = Set(fields.map(\.id))
    var messages: [String] = []
    for type in types {
      messages.append(contentsOf: templateValidationMessages(for: type, fieldIDs: fieldIDs))
      messages.append(contentsOf: sequenceFieldValidationMessages(for: type, fieldIDs: fieldIDs))
    }
    return messages
  }

  private func sequenceFieldValidationMessages(
    for type: SuggestionTypeDefinition, fieldIDs: Set<String>
  ) -> [String] {
    var messages: [String] = []
    var groupingIDs: Set<String> = []
    for fieldID in type.sequenceFieldIDs {
      if !groupingIDs.insert(fieldID).inserted {
        messages.append("Type '\(type.name)' has duplicate sequence field '\(fieldID)'.")
      }
      if !fieldIDs.contains(fieldID) {
        messages.append("Type '\(type.name)' references unknown sequence field '\(fieldID)'.")
      }
    }
    return messages
  }

  static func customID(using uuid: UUID) -> String {
    "custom-\(uuid.uuidString.lowercased())"
  }

  mutating func removeField(id: String) -> [String] {
    let referringTypeNames = types.compactMap { type in
      let referencesField =
        type.sequenceFieldIDs.contains(id)
        || type.template.contains { $0.kind == .field && $0.value == id }
      return referencesField ? type.name : nil
    }
    guard referringTypeNames.isEmpty else { return referringTypeNames }
    fields.removeAll { $0.id == id }
    return []
  }

  mutating func restoreBuiltInType(id: String) -> SuggestionBuiltInRestoreResult {
    guard let presetType = SuggestionDefaults.types.first(where: { $0.id == id }) else {
      return .unknownBuiltIn
    }
    guard !types.contains(where: { $0.id == id }) else { return .alreadyPresent }

    if let conflictingType = types.first(where: {
      $0.group == presetType.group
        && $0.name.normalizedConfigurationName == presetType.name.normalizedConfigurationName
    }) {
      return .typeNameConflict(existingTypeID: conflictingType.id)
    }

    let referencedFieldIDs = Set(presetType.sequenceFieldIDs).union(
      presetType.template.compactMap { $0.kind == .field ? $0.value : nil })
    let presetFields = SuggestionDefaults.fields.filter { referencedFieldIDs.contains($0.id) }
    for presetField in presetFields where !fields.contains(where: { $0.id == presetField.id }) {
      if let conflictingField = fields.first(where: {
        $0.name.normalizedConfigurationName == presetField.name.normalizedConfigurationName
      }) {
        return .fieldNameConflict(
          existingFieldID: conflictingField.id, presetFieldID: presetField.id)
      }
    }

    types.append(presetType)
    fields.append(
      contentsOf: presetFields.filter { presetField in
        !fields.contains { $0.id == presetField.id }
      })
    return .restored
  }

  private func templateValidationMessages(
    for type: SuggestionTypeDefinition, fieldIDs: Set<String>
  ) -> [String] {
    var messages: [String] = []
    var hasMeaningfulComponent = false

    for component in type.template {
      switch component.kind {
      case .literal:
        guard let value = component.value, !value.isEmpty else {
          messages.append("Type '\(type.name)' contains an empty literal component.")
          continue
        }
        hasMeaningfulComponent = hasMeaningfulComponent || !value.isBlank

      case .field:
        guard let fieldID = component.value, !fieldID.isBlank else {
          messages.append("Type '\(type.name)' contains a field component with an empty field ID.")
          continue
        }
        hasMeaningfulComponent = true
        if !fieldIDs.contains(fieldID) {
          messages.append("Type '\(type.name)' references unknown field '\(fieldID)'.")
        }

      case .sequence:
        hasMeaningfulComponent = true
        if component.value != nil {
          messages.append("Sequence components for type '\(type.name)' must have a nil value.")
        }
      }
    }

    if !hasMeaningfulComponent {
      messages.append("Type '\(type.name)' must contain at least one meaningful naming component.")
    }
    return messages
  }
}

extension String {
  fileprivate var isBlank: Bool {
    trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  fileprivate var normalizedConfigurationName: String {
    components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
      .folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
      )
      .lowercased()
  }
}
