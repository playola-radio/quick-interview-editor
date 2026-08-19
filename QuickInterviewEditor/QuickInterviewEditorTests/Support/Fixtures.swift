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

  /// A schema-v2 solo transcript: per-word `confidence`, `transcript_segments`,
  /// and long inter-word silences at sentence ends.
  static func editPlanV2() -> EditPlan {
    let url = Bundle(for: BundleToken.self)
      .url(forResource: "edit-plan-v2", withExtension: "json")!
    // swiftlint:disable:next force_try
    return try! EditPlan.decoded(from: url)
  }

  /// The committed project-sidecar fixture: two pending cut suggestions and empty
  /// reserved speaker fields.
  static func projectStateData() -> Data {
    let url = Bundle(for: BundleToken.self)
      .url(forResource: "project-state", withExtension: "json")!
    // swiftlint:disable:next force_try
    return try! Data(contentsOf: url)
  }

  static func projectState() -> ProjectState {
    // swiftlint:disable:next force_try
    try! JSONDecoder().decode(ProjectState.self, from: projectStateData())
  }

  /// A `CutSuggestion` with sensible defaults; override only what a test cares about.
  static func cutSuggestion(
    id: UUID,
    productType: ProductType = .spotlight,
    title: String = "A story",
    song: String? = nil,
    songVerified: Bool = false,
    wordIDs: [Word.ID] = [1, 2, 3],
    startSample: Int = 44100,
    endSample: Int = 441000,
    startSec: Double = 1,
    endSec: Double = 10,
    durationSec: Double = 9,
    rank: Int = 0,
    score: Double = 0.5,
    status: CutSuggestion.Status = .pending
  ) -> CutSuggestion {
    CutSuggestion(
      id: id, productType: productType, title: title, song: song,
      songVerified: songVerified, wordIDs: wordIDs,
      startSample: startSample, endSample: endSample,
      startSec: startSec, endSec: endSec, durationSec: durationSec,
      rank: rank, score: score, status: status,
      provenance: CutSuggestion.Provenance(
        model: "claude-sonnet-5", promptVersion: "v1", productSpecVersion: "v1",
        transcriptHash: "t", sourceFingerprint: "fp", diarizationHash: nil))
  }

  static func uuid(_ index: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
  }

  /// A stand-in canonical audio URL for tests. A tiny real file backs it so export's
  /// pre-render existence check passes; its bytes are never decoded (audio I/O is mocked).
  static let canonicalAudioURL: URL = {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("qie-canonical.aiff")
    if !FileManager.default.fileExists(atPath: url.path) {
      try? Data("canonical".utf8).write(to: url)
    }
    return url
  }()

  static func transcriptionResult(
    _ plan: EditPlan = editPlan(), canonicalAudioURL: URL = canonicalAudioURL
  ) -> TranscriptionResult {
    TranscriptionResult(editPlan: plan, canonicalAudioURL: canonicalAudioURL)
  }
}
