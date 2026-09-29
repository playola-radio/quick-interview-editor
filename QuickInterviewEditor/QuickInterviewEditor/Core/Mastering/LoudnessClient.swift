import Dependencies
import Foundation
import IssueReporting

struct LoudnessMeasurement: Equatable, Sendable {
  var integratedLUFS: Double
  var truePeakDBTP: Double
}

// swiftlint:disable:next inclusive_language
enum MasteringGain {
  static func decibels(integratedLUFS: Double, truePeakDBTP: Double) throws -> Double {
    guard !truePeakDBTP.isNaN && truePeakDBTP != .infinity,
      !integratedLUFS.isNaN && integratedLUFS != .infinity
    else { throw MasteringPreparationError.invalidLoudnessMeasurement }
    let loudnessGain = integratedLUFS.isFinite ? MasteringFormat.targetLUFS - integratedLUFS : 0
    let peakGain =
      truePeakDBTP.isFinite
      ? MasteringFormat.truePeakCeilingDBTP - truePeakDBTP : 0
    return min(loudnessGain, peakGain)
  }
}

struct LoudnessClient: Sendable {
  var measure: @Sendable (URL) async throws -> LoudnessMeasurement
}

extension LoudnessClient: DependencyKey {
  static var liveValue: LoudnessClient {
    LoudnessClient(measure: { url in try LoudnessMeter.measure(url: url) })
  }
}

extension LoudnessClient: TestDependencyKey {
  static var testValue: LoudnessClient {
    LoudnessClient(measure: { _ in
      reportIssue("LoudnessClient.measure called without a test override")
      throw MasteringPreparationError.meterUnavailable
    })
  }
}

extension DependencyValues {
  var loudness: LoudnessClient {
    get { self[LoudnessClient.self] }
    set { self[LoudnessClient.self] = newValue }
  }
}
