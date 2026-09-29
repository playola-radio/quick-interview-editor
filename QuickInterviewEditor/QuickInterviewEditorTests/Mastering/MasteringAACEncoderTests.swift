// swiftlint:disable inclusive_language
import AVFoundation
import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

struct MasteringAACEncoderTests {
  private func pcm(frames: Int, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent("source.caf")
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100.0,
      AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
    ]
    do {
      let file = try AVAudioFile(forWriting: url, settings: settings)
      for start in stride(from: 0, to: frames, by: 4_096) {
        let count = min(4_096, frames - start)
        let buffer = try #require(
          AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)))
        buffer.frameLength = AVAudioFrameCount(count)
        let channels = try #require(buffer.floatChannelData)
        for index in 0..<count {
          let value: Float = (start + index == frames / 2) ? 0.9 : 0
          channels[0][index] = value
          channels[1][index] = value
        }
        try file.write(from: buffer)
      }
    }
    return url
  }

  @Test func encodesExactLengthsAroundAACBlocks() async throws {
    for frames in [1_023, 1_024, 1_025, 2_047, 44_100] {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let source = try pcm(frames: frames, in: directory)
      let target = MasteredPieceTarget(
        pieceID: UUID(), startFrame: 0, frameCount: frames, artist: "Test Artist",
        title: "Generated Title", lrc: "[00:00.00]café\n")
      let output = directory.appendingPathComponent("final.m4a")
      let result = try await MasteringAACEncoder.encode(source, target: target, outputURL: output)
      expectNoDifference(result.pieceID, target.pieceID)
      #expect(result.byteCount > 0)
      let decoded = try AVAudioFile(forReading: output)
      expectNoDifference(Int(decoded.length), frames)
      let duration = try await AVURLAsset(url: output).load(.duration)
      #expect(abs(CMTimeGetSeconds(duration) - Double(frames) / 44_100) < 0.000_1)
    }
  }

  @Test func preservesFrozenUnicodeLyricsAndTitleByteExactly() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try pcm(frames: 88_200, in: directory)
    let lrc =
      (0..<5_000).map { index in
        let centiseconds = 10 + index * 20
        return String(
          format: "[%02d:%02d.%02d]", centiseconds / 6_000,
          (centiseconds / 100) % 60, centiseconds % 100) + "café—word-\(index)"
      }.joined(separator: "\n") + "\n"
    let target = MasteredPieceTarget(
      pieceID: UUID(), startFrame: 0, frameCount: 88_200, artist: "Test Artist",
      title: "Generated Title", lrc: lrc)
    let output = directory.appendingPathComponent("lyrics.m4a")
    _ = try await MasteringAACEncoder.encode(source, target: target, outputURL: output)
    let metadata = try await AVURLAsset(url: output).load(.metadata)
    func value(_ identifier: AVMetadataIdentifier) -> String? {
      metadata.first(where: { $0.identifier == identifier })?.stringValue
    }
    expectNoDifference(value(.iTunesMetadataArtist), target.artist)
    expectNoDifference(value(.iTunesMetadataSongName), target.title)
    expectNoDifference(value(.iTunesMetadataLyrics), target.lrc)
  }
}

// swiftlint:enable inclusive_language
