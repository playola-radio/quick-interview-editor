import AVFoundation
import CustomDump
import Dependencies
import Foundation
import Testing

@testable import PlayolaInterviewEditor

// swiftlint:disable:next inclusive_language
struct MasteringPreparationTests {
  private func fixture(
    directory: URL, amplitude: Float = 0.1, sampleRate: Int = 48_000,
    channels: Int = 1, transient: Bool = false
  ) throws -> MasteringPreparationRequest {
    let source = directory.appendingPathComponent("source.aiff")
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Double(sampleRate),
      AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsBigEndianKey: true, AVLinearPCMIsFloatKey: false,
    ]
    do {
      let file = try AVAudioFile(forWriting: source, settings: settings)
      let buffer = try #require(
        AVAudioPCMBuffer(
          pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(sampleRate)))
      buffer.frameLength = AVAudioFrameCount(sampleRate)
      let output = try #require(buffer.floatChannelData)
      for frame in 0..<sampleRate {
        let base = amplitude * sin(2 * Float.pi * 997 * Float(frame) / Float(sampleRate))
        let value =
          transient && (frame == sampleRate / 4 || frame == 3 * sampleRate / 4)
          ? 0.9 : base
        for channel in 0..<channels { output[channel][frame] = value }
      }
      try file.write(from: buffer)
    }
    let half = sampleRate / 2
    let pieces = [0..<half, half..<sampleRate].enumerated().map { index, range in
      let built = SliceRenderPlanBuilder.plan(sliceRange: range, removals: [])
      return MasteringPieceInput(
        sliceID: UUID(), title: index == 0 ? "First" : "Second", render: built.plan,
        editedDurationSamples: built.editedDurationSamples, sourceRange: range,
        localRemovals: [],
        wordStarts: [
          RenderMarker(position: 1_000, name: "word"),
          RenderMarker(position: half, name: "outside"),
        ], typeProvenance: "explicit")
    }
    let work = directory.appendingPathComponent("work")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    return MasteringPreparationRequest(
      snapshot: MasteringSnapshot(
        artist: "Artist", canonicalAudioURL: source,
        canonicalFingerprint: SourceFingerprint.compute(for: source),
        sourceSampleRate: sampleRate,
        sourceDurationSamples: sampleRate, pieces: pieces, inputsDigest: "v1:test"),
      workDirectory: work)
  }

  @Test func writesWholePiecesAtActualFrameOffsetsIn24BitStereoWAV() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let request = try fixture(directory: directory)
    let result = try await withDependencies {
      $0.loudness = .liveValue
    } operation: {
      try await MasteringAudioClient.liveValue.prepare(request) { _ in }
    }
    expectNoDifference(result.parts.count, 1)
    let part = try #require(result.parts.first)
    expectNoDifference(part.frameCount, 44_100)
    expectNoDifference(part.pieces.map(\.startFrame), [0, part.pieces[0].frameCount])
    expectNoDifference(part.pieces.map(\.frameCount), [22_050, 22_050])
    expectNoDifference(part.pieces[0].lrc, "[00:00.02]word\n")
    let wav = try AVAudioFile(forReading: part.wavURL)
    expectNoDifference(Int(wav.length), part.frameCount)
    expectNoDifference(Int(wav.fileFormat.sampleRate), 44_100)
    expectNoDifference(Int(wav.fileFormat.channelCount), 2)
    expectNoDifference(Int(wav.fileFormat.streamDescription.pointee.mBitsPerChannel), 24)
  }

  @Test func splitsWholePiecesAndOmitsEndBoundaryMarkers() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var request = try fixture(directory: directory)
    request.partLimitFrames = 22_050
    let result = try await withDependencies {
      $0.loudness = .liveValue
    } operation: {
      try await MasteringAudioClient.liveValue.prepare(request) { _ in }
    }
    expectNoDifference(result.parts.count, 2)
    expectNoDifference(result.parts.map(\.frameCount), [22_050, 22_050])
    expectNoDifference(result.parts.flatMap(\.pieces).map(\.startFrame), [0, 0])
    #expect(result.parts.flatMap(\.pieces).allSatisfy { !$0.lrc.contains("outside") })
  }

  @Test func prepares44kStereoWithoutChangingItsFrameCount() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let request = try fixture(directory: directory, sampleRate: 44_100, channels: 2)
    let result = try await withDependencies {
      $0.loudness = .liveValue
    } operation: {
      try await MasteringAudioClient.liveValue.prepare(request) { _ in }
    }
    expectNoDifference(result.parts.map(\.frameCount), [44_100])
    expectNoDifference(result.parts[0].pieces.map(\.frameCount), [22_050, 22_050])
  }

  @Test func successfulPeakLimitedRunStaysUnderQuantizedCeiling() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let request = try fixture(directory: directory, amplitude: 0.05, transient: true)
    let result = try await withDependencies {
      $0.loudness = .liveValue
    } operation: {
      try await MasteringAudioClient.liveValue.prepare(request) { _ in }
    }
    #expect(
      result.warnings.contains { warning in
        if case .peakLimitedGain = warning { return true }
        return false
      })
    let part = try #require(result.parts.first)
    let measured = try LoudnessMeter.measure(url: part.wavURL, mode: .truePeakOnly)
    #expect(measured.truePeakDBTP <= -1.5 + MasteringFormat.truePeakToleranceDB)
  }

  @Test func sourceIdentityMismatchCannotStampTheFrozenDigest() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var request = try fixture(directory: directory)
    request.snapshot.canonicalFingerprint = "sha256:wrong"
    await #expect(throws: MasteringPreparationError.canonicalSourceMismatch) {
      try await withDependencies {
        $0.loudness = .liveValue
      } operation: {
        try await MasteringAudioClient.liveValue.prepare(request) { _ in }
      }
    }
  }

  @Test func cancellationAfterProgressReturnsNoPreparedRun() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let request = try fixture(directory: directory)
    await #expect(throws: CancellationError.self) {
      try await withDependencies {
        $0.loudness = .liveValue
      } operation: {
        try await MasteringAudioClient.liveValue.prepare(request) { progress in
          if progress.completedPieces == 1 {
            withUnsafeCurrentTask { $0?.cancel() }
          }
        }
      }
    }
  }

  @Test func finalWAVPeakReadbackRejectsBadMeterInput() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let request = try fixture(directory: directory, amplitude: 0.9)
    await #expect(throws: MasteringPreparationError.self) {
      try await withDependencies {
        $0.loudness = LoudnessClient(measure: { _ in
          LoudnessMeasurement(integratedLUFS: -30, truePeakDBTP: -30)
        })
      } operation: {
        try await MasteringAudioClient.liveValue.prepare(request) { _ in }
      }
    }
  }
}
