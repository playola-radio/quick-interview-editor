import Foundation

extension EditorModel {
  /// Draft targets are connected when the generalized editor lands in Task 6.
  func openSelectionTapped() {
    guard case .object(.clip(let id)) = selection else { return }
    editSliceTapped(id)
  }

}
