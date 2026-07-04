import Foundation
@testable import QuickInterviewEditor

private final class BundleToken {}

enum Fixtures {
  static func editPlan() -> EditPlan {
    let url = Bundle(for: BundleToken.self)
      .url(forResource: "edit-plan", withExtension: "json")!
    return try! EditPlan.decoded(from: url)
  }
}
