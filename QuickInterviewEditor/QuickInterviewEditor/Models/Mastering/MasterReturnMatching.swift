// swiftlint:disable inclusive_language
import Foundation

enum MasterReturnMatching {
  // The caller passes only unreturned parts, or its one explicit replacement target.
  static func candidates(durationSeconds: Double, parts: [(id: UUID, frameCount: Int)]) -> [UUID] {
    guard durationSeconds.isFinite, durationSeconds > 0 else { return [] }
    return parts.compactMap { part in
      guard part.frameCount > 0,
        abs(durationSeconds - Double(part.frameCount) / Double(MasteringFormat.sampleRate))
          < MasteringFormat.masterDurationToleranceSeconds
      else { return nil }
      return part.id
    }
  }
}

// swiftlint:enable inclusive_language
