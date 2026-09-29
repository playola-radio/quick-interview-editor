// swiftlint:disable inclusive_language
import AVFoundation
import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

struct MasteringReturnTests {
  private var fixtures: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
  }

  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func pcm(
    _ url: URL, channels: Int = 2, frames: Int = 4_800, sampleRate: Int = 48_000,
    impulses: [Int] = []
  ) throws {
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Double(sampleRate),
      AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    for start in stride(from: 0, to: frames, by: 4_096) {
      let count = min(4_096, frames - start)
      let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)))
      buffer.frameLength = AVAudioFrameCount(count)
      let channelsData = try #require(buffer.floatChannelData)
      for frame in 0..<count {
        let value: Float = impulses.contains(start + frame) ? 0.9 : 0
        for channel in 0..<channels { channelsData[channel][frame] = value }
      }
      try file.write(from: buffer)
    }
  }

  @Test func inspectsActualWAVAIFFAndFLAC() async throws {
    let work = try directory()
    defer { try? FileManager.default.removeItem(at: work) }
    for name in ["return.wav", "return.aiff"] {
      let url = work.appendingPathComponent(name)
      try pcm(url)
      let inspected = try await MasteringReturnClient.liveValue.inspect(url)
      expectNoDifference(inspected.fileName, name)
      expectNoDifference(inspected.sampleRate, 48_000)
      expectNoDifference(inspected.channels, 2)
      expectNoDifference(inspected.sourceFrames, 4_800)
    }
    let flac = try await MasteringReturnClient.liveValue.inspect(
      fixtures.appendingPathComponent("mono-48k.flac"))
    expectNoDifference(flac.sampleRate, 48_000)
    expectNoDifference(flac.channels, 1)
    expectNoDifference(flac.sourceFrames, 4_800)
    for (name, channels) in [("mono-48k.aifc", 1), ("stereo-48k-rf64.wav", 2)] {
      let inspected = try await MasteringReturnClient.liveValue.inspect(
        fixtures.appendingPathComponent(name))
      expectNoDifference(inspected.sampleRate, 48_000)
      expectNoDifference(inspected.channels, channels)
      expectNoDifference(inspected.sourceFrames, 4_800)
    }
  }

  @Test func rejectsLossyAudioInAGenuineAIFCContainer() async throws {
    await #expect(throws: MasteringReturnError.unsupportedCodec(fileName: "mono-48k-lossy.aifc")) {
      try await MasteringReturnClient.liveValue.inspect(
        fixtures.appendingPathComponent("mono-48k-lossy.aifc"))
    }
  }

  @Test func rejectsMisnamedAACUnreadableBytesAndMultichannel() async throws {
    let work = try directory()
    defer { try? FileManager.default.removeItem(at: work) }
    let mislabeled = work.appendingPathComponent("renamed.wav")
    try FileManager.default.copyItem(
      at: fixtures.appendingPathComponent("stereo-aac.m4a"), to: mislabeled)
    await #expect(throws: MasteringReturnError.unsupportedContainer(fileName: "renamed.wav")) {
      try await MasteringReturnClient.liveValue.inspect(mislabeled)
    }
    let unreadable = work.appendingPathComponent("broken.wav")
    try Data([1, 2, 3, 4]).write(to: unreadable)
    await #expect(throws: MasteringReturnError.unreadable(fileName: "broken.wav")) {
      try await MasteringReturnClient.liveValue.inspect(unreadable)
    }
    let surround = work.appendingPathComponent("surround.wav")
    try pcm(surround, channels: 6)
    await #expect(
      throws: MasteringReturnError.unsupportedChannelCount(
        fileName: "surround.wav", count: 6)
    ) {
      try await MasteringReturnClient.liveValue.inspect(surround)
    }
  }

  @Test func conformsWhole48kReturnAndSplitsThreeSavedRanges() async throws {
    let work = try directory()
    defer { try? FileManager.default.removeItem(at: work) }
    let source = work.appendingPathComponent("master.wav")
    try pcm(
      source, frames: 5 * 48_000,
      impulses: [480, 48_000 + 12_000, 96_000 + 36_000])
    let output = work.appendingPathComponent("output")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let targets = (0..<3).map { index in
      MasteredPieceTarget(
        pieceID: UUID(), startFrame: index * 44_100, frameCount: 44_100,
        artist: "Frozen Artist", title: "Piece \(index)", lrc: "[00:00.00]word\n")
    }
    let result = try await MasteringReturnClient.liveValue.encodePart(
      source, MasteredPartTarget(partFrameCount: 3 * 44_100, pieces: targets), output)
    expectNoDifference(result.map(\.pieceID), targets.map(\.pieceID))
    for (index, piece) in result.enumerated() {
      let audio = try AVAudioFile(forReading: piece.url)
      expectNoDifference(Int(audio.length), 44_100)
      let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 44_100))
      try audio.read(into: buffer)
      let samples = try #require(buffer.floatChannelData)[0]
      let expected = [441, 11_025, 33_075][index]
      let peak = ((expected - 3)...(expected + 3)).max { abs(samples[$0]) < abs(samples[$1]) }
      expectNoDifference(peak, expected)
    }
    expectNoDifference(
      try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "caf" }, [])
  }

  @Test func rejectsPieceRangesWithGapsOrOverlaps() async throws {
    let work = try directory()
    defer { try? FileManager.default.removeItem(at: work) }
    let source = work.appendingPathComponent("master.wav")
    try pcm(source, frames: 4 * 44_100, sampleRate: 44_100)
    let output = work.appendingPathComponent("output")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

    let gap = [
      MasteredPieceTarget(
        pieceID: UUID(), startFrame: 0, frameCount: 44_100,
        artist: "A", title: "First", lrc: ""),
      MasteredPieceTarget(
        pieceID: UUID(), startFrame: 88_200, frameCount: 44_100,
        artist: "A", title: "Second", lrc: ""),
    ]
    await #expect(
      throws: MasteringReturnError.encodeFailed(
        title: "First", reason: "Saved piece ranges are invalid")
    ) {
      try await MasteringReturnClient.liveValue.encodePart(
        source, MasteredPartTarget(partFrameCount: 4 * 44_100, pieces: gap), output)
    }

    let overlap = [
      MasteredPieceTarget(
        pieceID: UUID(), startFrame: 0, frameCount: 44_100,
        artist: "A", title: "First", lrc: ""),
      MasteredPieceTarget(
        pieceID: UUID(), startFrame: 22_050, frameCount: 44_100,
        artist: "A", title: "Second", lrc: ""),
    ]
    await #expect(
      throws: MasteringReturnError.encodeFailed(
        title: "First", reason: "Saved piece ranges are invalid")
    ) {
      try await MasteringReturnClient.liveValue.encodePart(
        source, MasteredPartTarget(partFrameCount: 4 * 44_100, pieces: overlap), output)
    }
    expectNoDifference(
      try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil), [])
  }

  @Test func rejectsOneFrameShortBeforePublishingAnyPiece() async throws {
    let work = try directory()
    defer { try? FileManager.default.removeItem(at: work) }
    let source = work.appendingPathComponent("short.wav")
    try pcm(source, frames: 88_199, sampleRate: 44_100)
    let output = work.appendingPathComponent("output")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let targets = [0, 1].map { index in
      MasteredPieceTarget(
        pieceID: UUID(), startFrame: index * 44_100, frameCount: 44_100,
        artist: "A", title: "Piece \(index)", lrc: "")
    }
    await #expect(
      throws: MasteringReturnError.tooShort(
        fileName: "short.wav", frames: 88_199, required: 88_200)
    ) {
      try await MasteringReturnClient.liveValue.encodePart(
        source, MasteredPartTarget(partFrameCount: 88_200, pieces: targets), output)
    }
    expectNoDifference(
      try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil), [])
  }

  @Test func refusesAChangedReturnThatIsOutsideMatchingTolerance() async throws {
    let work = try directory()
    defer { try? FileManager.default.removeItem(at: work) }
    let source = work.appendingPathComponent("changed.wav")
    try pcm(source, frames: 10 * 44_100, sampleRate: 44_100)
    let output = work.appendingPathComponent("output")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let target = MasteredPieceTarget(
      pieceID: UUID(), startFrame: 0, frameCount: 44_100,
      artist: "A", title: "Changed", lrc: "")
    await #expect(
      throws: MasteringReturnError.encodeFailed(
        title: "Changed", reason: "Returned audio duration changed after matching")
    ) {
      try await MasteringReturnClient.liveValue.encodePart(
        source, MasteredPartTarget(partFrameCount: 44_100, pieces: [target]), output)
    }
    expectNoDifference(
      try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil), [])
  }

  @Test func reportsWorkDirectoryFailureAsATypedReturnError() async throws {
    let work = try directory()
    defer { try? FileManager.default.removeItem(at: work) }
    let source = work.appendingPathComponent("valid.wav")
    try pcm(source, frames: 1_024, sampleRate: 44_100)
    let blockedDirectory = work.appendingPathComponent("blocked")
    try Data([1]).write(to: blockedDirectory)
    let target = MasteredPieceTarget(
      pieceID: UUID(), startFrame: 0, frameCount: 1_024,
      artist: "A", title: "Blocked", lrc: "")
    await #expect(throws: MasteringReturnError.self) {
      try await MasteringReturnClient.liveValue.encodePart(
        source, MasteredPartTarget(partFrameCount: 1_024, pieces: [target]), blockedDirectory)
    }
  }

  @Test func monoReturnDuplicatesChannels() async throws {
    let work = try directory()
    defer { try? FileManager.default.removeItem(at: work) }
    let source = work.appendingPathComponent("mono.wav")
    try pcm(source, channels: 1, frames: 1_024, sampleRate: 44_100, impulses: [512])
    let output = work.appendingPathComponent("output")
    let target = MasteredPieceTarget(
      pieceID: UUID(), startFrame: 0, frameCount: 1_024,
      artist: "A", title: "Mono", lrc: "")
    let result = try await MasteringReturnClient.liveValue.encodePart(
      source, MasteredPartTarget(partFrameCount: 1_024, pieces: [target]), output)
    let audio = try AVAudioFile(forReading: try #require(result.first).url)
    expectNoDifference(Int(audio.fileFormat.channelCount), 2)
    let buffer = try #require(
      AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 1_024))
    try audio.read(into: buffer)
    let channels = try #require(buffer.floatChannelData)
    for frame in 0..<1_024 {
      #expect(abs(channels[0][frame] - channels[1][frame]) < 0.001)
    }
  }

  @Test func uneven48kReturnKeepsExactSavedFrameCount() async throws {
    let work = try directory()
    defer { try? FileManager.default.removeItem(at: work) }
    let source = work.appendingPathComponent("uneven.wav")
    try pcm(source, frames: 48_001, impulses: [12_000])
    let output = work.appendingPathComponent("output")
    let target = MasteredPieceTarget(
      pieceID: UUID(), startFrame: 0, frameCount: 44_101,
      artist: "A", title: "Uneven", lrc: "")
    let result = try await MasteringReturnClient.liveValue.encodePart(
      source, MasteredPartTarget(partFrameCount: 44_101, pieces: [target]), output)
    let audio = try AVAudioFile(forReading: try #require(result.first).url)
    expectNoDifference(Int(audio.length), 44_101)
  }

  @Test func twoSecondReturnKeepsFiveImpulsePositionsAndPlaybackDuration() async throws {
    let work = try directory()
    defer { try? FileManager.default.removeItem(at: work) }
    let source = work.appendingPathComponent("impulses.wav")
    try pcm(source, frames: 96_000, impulses: [480, 12_000, 36_000, 60_000, 94_560])
    let output = work.appendingPathComponent("output")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let target = MasteredPieceTarget(
      pieceID: UUID(), startFrame: 0, frameCount: 88_200,
      artist: "A", title: "Impulses", lrc: "[00:00.01]word\n")
    let result = try await MasteringReturnClient.liveValue.encodePart(
      source, MasteredPartTarget(partFrameCount: 88_200, pieces: [target]), output)
    let file = try #require(result.first)
    let audio = try AVAudioFile(forReading: file.url)
    expectNoDifference(Int(audio.length), 88_200)
    let duration = try await AVURLAsset(url: file.url).load(.duration)
    expectNoDifference(CMTimeGetSeconds(duration), 2)
    let buffer = try #require(
      AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 88_200))
    try audio.read(into: buffer)
    let samples = try #require(buffer.floatChannelData)[0]
    for expected in [441, 11_025, 33_075, 55_125, 86_877] {
      let peak = ((expected - 3)...(expected + 3)).max { abs(samples[$0]) < abs(samples[$1]) }
      expectNoDifference(peak, expected)
    }
  }

  @Test func cancellationRemovesPartialAACAndTemporaryCAF() async throws {
    let work = try directory()
    defer { try? FileManager.default.removeItem(at: work) }
    let source = work.appendingPathComponent("long.wav")
    try pcm(source, frames: 60 * 44_100, sampleRate: 44_100)
    let output = work.appendingPathComponent("output")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let targets = [0, 1].map { index in
      MasteredPieceTarget(
        pieceID: UUID(), startFrame: index * 30 * 44_100, frameCount: 30 * 44_100,
        artist: "A", title: "Long \(index)", lrc: "")
    }
    let task = Task {
      try await MasteringReturnClient.liveValue.encodePart(
        source, MasteredPartTarget(partFrameCount: 60 * 44_100, pieces: targets), output)
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    var started = false
    while ContinuousClock.now < deadline {
      let files = try FileManager.default.contentsOfDirectory(
        at: output, includingPropertiesForKeys: nil)
      if files.filter({ $0.pathExtension == "m4a" }).count == 2 {
        started = true
        break
      }
      await Task.yield()
    }
    task.cancel()
    #expect(started)
    await #expect(throws: CancellationError.self) { try await task.value }
    expectNoDifference(
      try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil), [])
  }
}

// swiftlint:enable inclusive_language
