import AVFoundation
import Dependencies
import Foundation
import IssueReporting

// swiftlint:disable:next inclusive_language
struct MasteringPreparationRequest: Equatable, Sendable {
  var snapshot: MasteringSnapshot
  var workDirectory: URL
  var partLimitFrames: Int = MasteringFormat.partLimitFrames
}

struct PreparedPiece: Equatable, Sendable {
  var sliceID: Slice.ID
  var title: String
  var startFrame: Int
  var frameCount: Int
  var lrc: String
}

struct PreparedPart: Equatable, Sendable {
  var wavURL: URL
  var frameCount: Int
  var byteCount: Int
  var pieces: [PreparedPiece]
}

// swiftlint:disable:next inclusive_language
enum MasteringPreparationWarning: Equatable, Sendable {
  case overlongPiece(title: String, seconds: Double)
  case peakLimitedGain(title: String, appliedDB: Double, loudnessDB: Double)
}

// swiftlint:disable:next inclusive_language
struct MasteringPreparationResult: Equatable, Sendable {
  var parts: [PreparedPart]
  var warnings: [MasteringPreparationWarning]
  var inputsDigest: String
}

// swiftlint:disable:next inclusive_language
struct MasteringPreparationProgress: Equatable, Sendable {
  var completedPieces: Int
  var totalPieces: Int
}

// swiftlint:disable:next inclusive_language
struct MasteringAudioClient: Sendable {
  var prepare:
    @Sendable (
      MasteringPreparationRequest, @escaping @Sendable (MasteringPreparationProgress) -> Void
    ) async throws -> MasteringPreparationResult
}

extension MasteringAudioClient: DependencyKey {
  static var liveValue: MasteringAudioClient {
    return MasteringAudioClient(prepare: { request, progress in
      @Dependency(\.loudness) var loudness
      let meter = loudness
      let worker = Task.detached {
        try await MasteringPreparer.prepare(request, loudness: meter, progress: progress)
      }
      return try await withTaskCancellationHandler {
        try await worker.value
      } onCancel: {
        worker.cancel()
      }
    })
  }
}

extension MasteringAudioClient: TestDependencyKey {
  static var testValue: MasteringAudioClient {
    MasteringAudioClient(prepare: { _, _ in
      reportIssue("MasteringAudioClient.prepare called without a test override")
      throw MasteringPreparationError.noPieces
    })
  }
}

extension DependencyValues {
  // swiftlint:disable:next inclusive_language
  var masteringAudio: MasteringAudioClient {
    get { self[MasteringAudioClient.self] }
    set { self[MasteringAudioClient.self] = newValue }
  }
}

// swiftlint:disable:next inclusive_language
enum MasteringPreparationError: Error, Equatable, LocalizedError {
  case unsupportedChannelCount(Int)
  case invalidLoudnessMeasurement
  case conversionFailed(String)
  case meterUnavailable
  case truePeakCeilingExceeded(part: Int, measuredDBTP: Double)
  case partTooLarge(part: Int)
  case noPieces
  case canonicalSourceMismatch

  var errorDescription: String? {
    switch self {
    case .unsupportedChannelCount(let count): "Unsupported audio channel count: \(count)."
    case .invalidLoudnessMeasurement: "The audio loudness measurement was invalid."
    case .conversionFailed(let reason): "Audio conversion failed: \(reason)"
    case .meterUnavailable: "The loudness meter could not start."
    case .truePeakCeilingExceeded(let part, _):
      "Prepared part \(part) exceeds the true-peak ceiling."
    case .partTooLarge(let part): "Prepared part \(part) exceeds the WAV size limit."
    case .noPieces: "There are no intros to prepare."
    case .canonicalSourceMismatch: "The source audio changed after preparation was started."
    }
  }
}

// swiftlint:disable:next inclusive_language
private enum MasteringPreparer {
  private struct StagedPiece {
    var input: MasteringPieceInput
    var cafURL: URL
    var frameCount: Int
    var gainDB: Double
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  static func prepare(
    _ request: MasteringPreparationRequest, loudness: LoudnessClient,
    progress: @escaping @Sendable (MasteringPreparationProgress) -> Void
  ) async throws -> MasteringPreparationResult {
    let snapshot = request.snapshot
    guard !snapshot.pieces.isEmpty else { throw MasteringPreparationError.noPieces }
    guard request.partLimitFrames > 0 else {
      throw MasteringPreparationError.conversionFailed("Part length must be positive")
    }
    try Task.checkCancellation()
    guard
      SourceFingerprint.compute(for: snapshot.canonicalAudioURL)
        == snapshot.canonicalFingerprint
    else { throw MasteringPreparationError.canonicalSourceMismatch }
    try Task.checkCancellation()
    let source = try ExportAudioRenderer.openCanonical(
      snapshot.canonicalAudioURL, sampleRate: snapshot.sourceSampleRate,
      sourceDurationSamples: snapshot.sourceDurationSamples)
    var staged: [StagedPiece] = []
    var warnings: [MasteringPreparationWarning] = []
    for (index, piece) in snapshot.pieces.enumerated() {
      try Task.checkCancellation()
      guard piece.editedDurationSamples > 0 else {
        throw MasteringPreparationError.conversionFailed("Intro has no rendered audio")
      }
      let cafURL = request.workDirectory.appendingPathComponent("piece-\(index).caf")
      let frameCount = try ExportAudioRenderer.renderConformed(
        from: source, plan: piece.render, editedDurationSamples: piece.editedDurationSamples,
        sampleRate: snapshot.sourceSampleRate, to: cafURL,
        settings: MasteringFormat.float32CAFSettings)
      let measurement = try await loudness.measure(cafURL)
      let gain = try MasteringGain.decibels(
        integratedLUFS: measurement.integratedLUFS,
        truePeakDBTP: measurement.truePeakDBTP)
      if measurement.integratedLUFS.isFinite {
        let loudnessGain = MasteringFormat.targetLUFS - measurement.integratedLUFS
        if gain < loudnessGain - 0.001 {
          warnings.append(
            .peakLimitedGain(
              title: piece.title, appliedDB: gain, loudnessDB: loudnessGain))
        }
      }
      if frameCount > request.partLimitFrames {
        warnings.append(
          .overlongPiece(
            title: piece.title, seconds: Double(frameCount) / 44_100))
      }
      staged.append(
        StagedPiece(
          input: piece, cafURL: cafURL, frameCount: frameCount, gainDB: gain))
      progress(
        MasteringPreparationProgress(
          completedPieces: index + 1, totalPieces: snapshot.pieces.count))
      try Task.checkCancellation()
    }
    let groups = MasteringPartPacking.pack(
      staged.map(\.frameCount), limit: request.partLimitFrames)
    var parts: [PreparedPart] = []
    for (partIndex, group) in groups.enumerated() {
      try Task.checkCancellation()
      let partNumber = partIndex + 1
      let totalFrames = group.reduce(0) { $0 + staged[$1].frameCount }
      guard Int64(totalFrames) * 6 + 256 < Int64(UInt32.max) else {
        throw MasteringPreparationError.partTooLarge(part: partNumber)
      }
      let wavURL = request.workDirectory.appendingPathComponent("part-\(partNumber).wav")
      var prepared: [PreparedPiece] = []
      var frameCount = 0
      do {
        let writer = try AVAudioFile(forWriting: wavURL, settings: MasteringFormat.pcm24WAVSettings)
        for index in group {
          try Task.checkCancellation()
          let piece = staged[index]
          let start = frameCount
          let input = try AVAudioFile(forReading: piece.cafURL)
          let linearGain = Float(pow(10, piece.gainDB / 20))
          while input.framePosition < input.length {
            try Task.checkCancellation()
            guard
              let buffer = AVAudioPCMBuffer(
                pcmFormat: input.processingFormat, frameCapacity: 65_536)
            else { throw ExportRenderError.bufferAllocationFailed }
            try input.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
              throw ExportRenderError.shortRead(
                requested: 1, got: 0, atFrame: Int(input.framePosition))
            }
            for channel in 0..<2 {
              for frame in 0..<Int(buffer.frameLength) {
                channels[channel][frame] *= linearGain
              }
            }
            try writer.write(from: buffer)
            frameCount += Int(buffer.frameLength)
          }
          guard frameCount - start == piece.frameCount else {
            throw ExportRenderError.shortRender(
              written: frameCount - start, expected: piece.frameCount)
          }
          let words = piece.input.wordStarts.compactMap { marker -> (frame: Int, text: String)? in
            let position = MasteringFrames.conformed(
              marker.position, fromRate: snapshot.sourceSampleRate)
            guard position >= 0 && position < piece.frameCount else { return nil }
            return (position, marker.name)
          }
          prepared.append(
            PreparedPiece(
              sliceID: piece.input.sliceID, title: piece.input.title, startFrame: start,
              frameCount: piece.frameCount, lrc: MasteringLRC.text(wordStarts: words)))
          try FileManager.default.removeItem(at: piece.cafURL)
        }
      }
      let readback = try AVAudioFile(forReading: wavURL)
      guard Int(readback.length) == totalFrames,
        Int(readback.fileFormat.sampleRate) == 44_100,
        Int(readback.fileFormat.channelCount) == 2,
        Int(readback.fileFormat.streamDescription.pointee.mBitsPerChannel) == 24
      else {
        throw MasteringPreparationError.conversionFailed("Prepared WAV properties do not match")
      }
      let peak = try LoudnessMeter.measure(url: wavURL, mode: .truePeakOnly).truePeakDBTP
      guard peak <= MasteringFormat.truePeakCeilingDBTP + MasteringFormat.truePeakToleranceDB else {
        throw MasteringPreparationError.truePeakCeilingExceeded(
          part: partNumber, measuredDBTP: peak)
      }
      let attributes = try FileManager.default.attributesOfItem(atPath: wavURL.path)
      guard let size = attributes[.size] as? NSNumber, size.intValue > 0 else {
        throw MasteringPreparationError.conversionFailed("Prepared WAV is empty")
      }
      parts.append(
        PreparedPart(
          wavURL: wavURL, frameCount: totalFrames,
          byteCount: size.intValue, pieces: prepared))
    }
    try Task.checkCancellation()
    return MasteringPreparationResult(
      parts: parts, warnings: warnings, inputsDigest: snapshot.inputsDigest)
  }

}
