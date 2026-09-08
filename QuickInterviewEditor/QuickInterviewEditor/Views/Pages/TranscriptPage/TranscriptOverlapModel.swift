import Foundation
import Observation

@MainActor
@Observable
final class TranscriptOverlapModel: ViewModel {
  var candidates: [TranscriptObject] = []
  var anchorWordID: Word.ID?
  var selectedID: TranscriptObjectID?
  var previewID: TranscriptObjectID?
  var focusedID: TranscriptObjectID?
  var isPresented = false
  var sampleRate = 1
  @ObservationIgnored var onChoose: ((TranscriptObjectID) -> Void)?

  var presentationToken: String {
    "\(anchorWordID ?? -1):\(controlLabel):\(isPresented):\(String(describing: selectedID))"
  }

  var showsControl: Bool { candidates.count > 1 && anchorWordID != nil }
  var controlLabel: String {
    let clips = candidates.filter {
      if case .clip = $0.id { return true }
      return false
    }.count
    let noun = clips == candidates.count ? "clips" : clips == 0 ? "suggestions" : "items"
    return "\(candidates.count) \(noun)"
  }
  var accessibilityLabel: String { "Choose overlapping \(controlLabel)" }

  func detail(_ object: TranscriptObject) -> String {
    let kind: String = if case .clip = object.id { "Clip" } else { "Suggestion" }
    return String(
      format: "%@ · %.1fs", kind, Double(object.range.count) / Double(max(1, sampleRate)))
  }

  func update(_ objects: [TranscriptObject], anchor: Word.ID?, selected: TranscriptObjectID?) {
    candidates = objects
    anchorWordID = anchor
    selectedID = selected
    if !objects.contains(where: { $0.id == previewID }) { previewID = nil }
    if !objects.contains(where: { $0.id == focusedID }) { focusedID = objects.first?.id }
    if !showsControl { dismiss() }
  }

  func present() {
    guard showsControl else { return }
    focusedID = candidates.first(where: { $0.id == selectedID })?.id ?? candidates.first?.id
    isPresented = true
  }

  func dismiss() {
    isPresented = false
    previewID = nil
  }

  func preview(_ id: TranscriptObjectID?) {
    previewID = candidates.first(where: { $0.id == id })?.id
  }

  func choose(_ id: TranscriptObjectID) {
    guard candidates.contains(where: { $0.id == id }) else { return }
    dismiss()
    onChoose?(id)
  }

  /// The chooser owns navigation and destructive keys while open.
  @discardableResult
  func keyDown(_ keyCode: UInt16) -> Bool {
    guard isPresented else { return false }
    switch keyCode {
    case 53: dismiss()
    case 51, 117, 123, 124: break
    case 36, 49, 76:
      if let focusedID { choose(focusedID) }
    case 125, 126:
      let index = candidates.firstIndex { $0.id == focusedID } ?? 0
      let next = min(max(0, index + (keyCode == 125 ? 1 : -1)), candidates.count - 1)
      if candidates.indices.contains(next) {
        focusedID = candidates[next].id
        preview(focusedID)
      }
    default: return false
    }
    return true
  }
}
