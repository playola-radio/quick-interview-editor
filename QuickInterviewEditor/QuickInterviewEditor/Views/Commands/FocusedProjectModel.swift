import SwiftUI

/// The `ProjectModel` of the key document window, published by `ProjectHostView` via
/// `focusedSceneValue` so menu commands act on whichever project the user is looking at.
struct ProjectModelFocusedValueKey: FocusedValueKey {
  typealias Value = ProjectModel
}

extension FocusedValues {
  var projectModel: ProjectModel? {
    get { self[ProjectModelFocusedValueKey.self] }
    set { self[ProjectModelFocusedValueKey.self] = newValue }
  }
}
