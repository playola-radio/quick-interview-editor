import Foundation

@testable import QuickInterviewEditor

private final class BundleToken {}

enum Fixtures {
  static func editPlan() -> EditPlan {
    let url = Bundle(for: BundleToken.self)
      .url(forResource: "edit-plan", withExtension: "json")!
    // A missing or corrupt bundled fixture should fail the test suite loudly.
    // swiftlint:disable:next force_try
    return try! EditPlan.decoded(from: url)
  }
}
