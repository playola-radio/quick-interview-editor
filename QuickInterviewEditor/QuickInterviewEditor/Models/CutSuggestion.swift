import Foundation

/// A ranked product candidate a human editor accepts or rejects. Swift-owned,
/// UI-facing state persisted in the project sidecar (never in `edit-plan.json`).
/// Mirrors the Python `CutCandidate` contract so Swift and the eval agree.
///
/// Sample bounds are derived from the transcript words, NOT from the LLM's own
/// duration guess (per the design). Display strings live here, not in the view.
struct CutSuggestion: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var productType: ProductType
  var title: String
  var song: String?
  var songVerified: Bool
  var wordIDs: [Word.ID]
  var startSample: Int
  var endSample: Int
  var startSec: Double
  var endSec: Double
  var durationSec: Double
  var rank: Int
  var score: Double
  var status: Status
  var provenance: Provenance

  /// Where a suggestion is in its accept/reject lifecycle.
  enum Status: String, Codable, Equatable, Sendable, CaseIterable {
    case pending
    case accepted
    case rejected
  }

  /// How the suggestion was produced. Pinned so a model/prompt/spec upgrade — which
  /// changes behavior silently — is attributable, and stale suggestions are
  /// detectable. `sourceFingerprint` also keys the project sidecar this lives in.
  struct Provenance: Codable, Equatable, Sendable {
    var model: String
    var promptVersion: String
    var productSpecVersion: String
    var transcriptHash: String
    var sourceFingerprint: String
    var diarizationHash: String?
  }
}

// MARK: - Lifecycle transitions

extension CutSuggestion {
  var isPending: Bool { status == .pending }
  var isAccepted: Bool { status == .accepted }
  var isRejected: Bool { status == .rejected }

  mutating func accept() { status = .accepted }
  mutating func reject() { status = .rejected }
  mutating func resetToPending() { status = .pending }

  /// Moves a still-unaccepted suggestion's boundaries in place (leaving its status untouched), so a
  /// transcript edge-drag can resize a pending/rejected clip without minting a slice or approving
  /// it. `wordIDs` is the re-derived membership for the new range.
  mutating func resize(startSample: Int, endSample: Int, wordIDs: [Word.ID]) {
    self.startSample = startSample
    self.endSample = endSample
    self.wordIDs = wordIDs
  }
}

// MARK: - Display values (zero-logic-in-views)

extension CutSuggestion {
  var productTypeLabel: String { productType.displayLabel }

  var statusLabel: String {
    switch status {
    case .pending: "Pending"
    case .accepted: "Accepted"
    case .rejected: "Rejected"
    }
  }

  /// `"0:10.0"` — matches `sampleTimecodeLabel`'s `m:ss.s` style.
  var startTimecode: String { Self.timecode(seconds: startSec) }
  var endTimecode: String { Self.timecode(seconds: endSec) }

  /// `"0:10.0 – 1:40.0"` — en dash, matching the slice range labels in EditorModel.
  var timeRangeDisplay: String { "\(startTimecode) – \(endTimecode)" }

  /// `"90.0s"` — matches `sampleDurationLabel`'s style.
  var durationDisplay: String {
    guard durationSec.isFinite else { return Self.invalidTime }
    return String(format: "%.1fs", max(0, durationSec))
  }

  /// The song label, or a placeholder when a suggestion names no song.
  var songDisplay: String { song ?? "—" }

  private static let invalidTime = "–:––"

  private static func timecode(seconds: Double) -> String {
    // Guard non-finite / absurd values so a corrupted suggestion degrades to a
    // placeholder instead of trapping when `Double` is bridged to `Int`.
    guard seconds.isFinite, seconds >= 0, seconds < 360_000 else { return invalidTime }
    let tenths = Int((seconds * 10).rounded())
    let minutes = tenths / 600
    let secs = Double(tenths % 600) / 10
    return String(format: "%d:%04.1f", minutes, secs)
  }
}
