import AVFoundation
import CustomDump
import Dependencies
import Foundation
import Testing

@testable import PlayolaInterviewEditor

// swiftlint:disable:next inclusive_language
struct MasteringPreparationTests {
  private func fixture(directory: URL, amplitude: Float = 0.1) throws
    -> MasteringPreparationRequest
  {
    let source = directory.appendingPathComponent("source.aiff")
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000.0,
      AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsBigEndianKey: true, AVLinearPCMIsFloatKey: false,
    ]
    do {
      let file = try AVAudioFile(forWriting: source, settings: settings)
      let buffer = try #require(
        AVAudioPCMBuffer(
          pcmFormat: file.processingFormat, frameCapacity: 48_000))
      buffer.frameLength = 48_000
      let channel = try #require(buffer.floatChannelData)[0]
      for frame in 0..<48_000 {
        channel[frame] = amplitude * sin(2 * Float.pi * 997 * Float(frame) / 48_000)
      }
      try file.write(from: buffer)
    }
    let pieces = [0..<24_000, 24_000..<48_000].map { range in
      let built = SliceRenderPlanBuilder.plan(sliceRange: range, removals: [])
      return MasteringPieceInput(
        sliceID: UUID(), title: "Intro", render: built.plan,
        editedDurationSamples: built.editedDurationSamples, sourceRange: range,
        localRemovals: [],
        wordStarts: [
          RenderMarker(position: 1_000, name: "inside"),
          RenderMarker(position: 24_000, name: "outside"),
        ], typeProvenance: "explicit")
    }
    let work = directory.appendingPathComponent("work")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    return MasteringPreparationRequest(
      snapshot: MasteringSnapshot(
        artist: "Artist", canonicalAudioURL: source, sourceSampleRate: 48_000,
        sourceDurationSamples: 48_000, pieces: pieces, inputsDigest: "v1:test"),
      workDirectory: work)
  }

  // swiftlint:disable:next function_body_length
  @Test func writesWholePiecesAtActualFrameOffsetsIn24BitStereoWAV() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.aiff")
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 48_000.0,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsBigEndianKey: true,
      AVLinearPCMIsFloatKey: false,
    ]
    do {
      let file = try AVAudioFile(forWriting: source, settings: settings)
      let buffer = try #require(
        AVAudioPCMBuffer(
          pcmFormat: file.processingFormat, frameCapacity: 48_000))
      buffer.frameLength = 48_000
      let channel = try #require(buffer.floatChannelData)[0]
      for frame in 0..<48_000 {
        channel[frame] = 0.1 * sin(2 * Float.pi * 997 * Float(frame) / 48_000)
      }
      try file.write(from: buffer)
    }
    let first = SliceRenderPlanBuilder.plan(sliceRange: 0..<24_000, removals: [])
    let second = SliceRenderPlanBuilder.plan(sliceRange: 24_000..<48_000, removals: [])
    let pieces = [(first, 0..<24_000, "First"), (second, 24_000..<48_000, "Second")]
      .map { built, range, title in
        MasteringPieceInput(
          sliceID: UUID(), title: title, render: built.plan,
          editedDurationSamples: built.editedDurationSamples, sourceRange: range,
          localRemovals: [], wordStarts: [RenderMarker(position: 1_000, name: "word")],
          typeProvenance: "explicit")
      }
    let snapshot = MasteringSnapshot(
      artist: "Artist", canonicalAudioURL: source, sourceSampleRate: 48_000,
      sourceDurationSamples: 48_000, pieces: pieces, inputsDigest: "v1:test")
    let work = directory.appendingPathComponent("work")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let result = try await withDependencies {
      $0.loudness = .liveValue
    } operation: {
      try await MasteringAudioClient.liveValue.prepare(
        MasteringPreparationRequest(snapshot: snapshot, workDirectory: work)
      ) { _ in }
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
