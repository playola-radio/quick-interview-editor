import Observation

struct NamingComponentRow: Identifiable {
  var id: Int
  var index: Int
  var label: String
  var isLiteral: Bool
  var canMoveUp: Bool
  var canMoveDown: Bool
}

struct NamingGroupingRow: Identifiable {
  var id: String
  var label: String
  var selectionImage: String
}

@MainActor
@Observable
final class NamingTemplateModel: ViewModel {
  // MARK: - Dependencies

  // MARK: - Shared State

  // MARK: - Initialization
  init(
    components: [NamingComponent], fields: [SuggestionField],
    selectedGroupingFieldIDs: [String] = [], sampleFieldValues: [String: String] = [:]
  ) {
    self.components = components
    availableFields = fields
    self.selectedGroupingFieldIDs = selectedGroupingFieldIDs
    self.sampleFieldValues = sampleFieldValues
    componentRowIDs = Array(components.indices)
    nextRowID = components.count
    super.init()
  }

  // MARK: - Properties
  private(set) var components: [NamingComponent]
  var availableFields: [SuggestionField]
  private(set) var selectedGroupingFieldIDs: [String]
  var sampleFieldValues: [String: String]
  private(set) var componentRowIDs: [Int]
  private var nextRowID: Int
  @ObservationIgnored var onChanged: (([NamingComponent], [String]) -> Void)?

  // MARK: - View Helpers
  let title = "Output Name"
  let addLiteralLabel = "Add Text"
  let addFieldLabel = "Add Field"
  let addSequenceLabel = "Add Sequence"
  let literalLabel = "Text"
  let sequenceLabel = "Sequence"
  let removeLabel = "Remove Component"
  let moveUpLabel = "Move Up"
  let moveDownLabel = "Move Down"
  let previewLabel = "Example Name"
  let groupingTitle = "Number Together By"
  let helpText =
    "Arrange text, fields, and Sequence to build the name. The preview uses example values."
  let groupingHelp =
    "Clips of this type with matching values in these fields share a numbering series. "
    + "With no fields selected, all clips of this type share a series. "
    + "Field order in the name does not change numbering."
  let sequenceHelp = "Sequence is optional. Each occurrence shows the same number."

  var previewName: String {
    var values = Dictionary(
      uniqueKeysWithValues: availableFields.map { ($0.id, "Example \($0.name)") })
    values.merge([
      "song-title": "Wildflowers", "artist-name": "Tom Petty",
      "descriptive-title": "A Life in Music",
    ]) {
      _, example in example
    }
    values.merge(sampleFieldValues) { _, sample in sample }
    return renderSuggestionName(
      template: components, values: values, sequence: 1, fallback: "Example")
  }

  var rows: [NamingComponentRow] {
    components.enumerated().map { index, component in
      NamingComponentRow(
        id: componentRowIDs[index], index: index, label: componentLabel(component),
        isLiteral: component.kind == .literal, canMoveUp: index > 0,
        canMoveDown: index < components.count - 1)
    }
  }

  var groupingRows: [NamingGroupingRow] {
    let knownIDs = Set(availableFields.map(\.id))
    return availableFields.map {
      NamingGroupingRow(id: $0.id, label: $0.name, selectionImage: groupingImage($0.id))
    }
      + selectedGroupingFieldIDs.filter { !knownIDs.contains($0) }.map {
        NamingGroupingRow(id: $0, label: "Unknown field: \($0)", selectionImage: groupingImage($0))
      }
  }

  var validationMessages: [String] {
    let messages = SuggestionConfiguration(
      types: [
        SuggestionTypeDefinition(
          id: "preview", name: title, group: .audioImages, guidelines: "Preview",
          template: components, sequenceFieldIDs: selectedGroupingFieldIDs)
      ], fields: availableFields
    ).validationMessages()
    var seen = Set<String>()
    return messages.filter { seen.insert($0).inserted }
  }

  subscript(literalAt index: Int) -> String {
    get { components.indices.contains(index) ? components[index].value ?? "" : "" }
    set { literalChanged(at: index, text: newValue) }
  }

  // MARK: - User Actions
  func addLiteralTapped() { append(.init(kind: .literal, value: "")) }
  func addFieldTapped(_ id: String) { append(.init(kind: .field, value: id)) }
  func addSequenceTapped() { append(.init(kind: .sequence, value: nil)) }

  func literalChanged(at index: Int, text: String) {
    guard components.indices.contains(index), components[index].kind == .literal else { return }
    components[index].value = text
    notifyChanged()
  }

  func removeTapped(at index: Int) {
    guard components.indices.contains(index) else { return }
    components.remove(at: index)
    componentRowIDs.remove(at: index)
    notifyChanged()
  }

  func moveUpTapped(at index: Int) { move(from: index, to: index - 1) }
  func moveDownTapped(at index: Int) { move(from: index, to: index + 1) }

  func groupingFieldTapped(_ id: String) {
    if selectedGroupingFieldIDs.contains(id) {
      selectedGroupingFieldIDs.removeAll { $0 == id }
    } else {
      selectedGroupingFieldIDs.append(id)
    }
    notifyChanged()
  }

  // MARK: - Private Helpers
  private func append(_ component: NamingComponent) {
    components.append(component)
    componentRowIDs.append(nextRowID)
    nextRowID += 1
    notifyChanged()
  }

  private func move(from index: Int, to destination: Int) {
    guard components.indices.contains(index), components.indices.contains(destination) else {
      return
    }
    components.swapAt(index, destination)
    componentRowIDs.swapAt(index, destination)
    notifyChanged()
  }

  private func notifyChanged() { onChanged?(components, selectedGroupingFieldIDs) }

  private func groupingImage(_ id: String) -> String {
    selectedGroupingFieldIDs.contains(id) ? "checkmark.square" : "square"
  }

  private func componentLabel(_ component: NamingComponent) -> String {
    switch component.kind {
    case .literal: return literalLabel
    case .sequence: return sequenceLabel
    case .field:
      return availableFields.first { $0.id == component.value }?.name
        ?? "Unknown field: \(component.value ?? "(empty)")"
    }
  }
}
