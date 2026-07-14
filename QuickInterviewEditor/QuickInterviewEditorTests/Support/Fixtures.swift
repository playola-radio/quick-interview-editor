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

  /// A stand-in canonical audio URL for tests — no file is read (audio I/O is mocked).
  static let canonicalAudioURL = URL(fileURLWithPath: "/tmp/qie-canonical.aiff")

  static func transcriptionResult(
    _ plan: EditPlan = editPlan(), canonicalAudioURL: URL = canonicalAudioURL
  ) -> TranscriptionResult {
    TranscriptionResult(editPlan: plan, canonicalAudioURL: canonicalAudioURL)
  }
}
