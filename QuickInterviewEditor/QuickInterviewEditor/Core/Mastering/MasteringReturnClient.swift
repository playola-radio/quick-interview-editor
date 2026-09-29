// swiftlint:disable inclusive_language
import AVFoundation
import AudioToolbox
import Dependencies
import Foundation
import IssueReporting

struct MasterInspection: Equatable, Sendable {
  var fileName: String
  var sampleRate: Double
  var channels: Int
  var sourceFrames: Int

  var durationSeconds: Double { Double(sourceFrames) / sampleRate }
}

struct MasteredPieceTarget: Equatable, Sendable {
  var pieceID: UUID
  var startFrame: Int
  var frameCount: Int
  var artist: String
  var title: String
  var lrc: String
}

struct MasteredPartTarget: Equatable, Sendable {
  var partFrameCount: Int
  var pieces: [MasteredPieceTarget]
}

struct EncodedPiece: Equatable, Sendable {
  var pieceID: UUID
  var url: URL
  var byteCount: Int
}

enum MasteringReturnError: Error, Equatable, LocalizedError {
  case unreadable(fileName: String)
  case unsupportedContainer(fileName: String)
  case unsupportedCodec(fileName: String)
  case unsupportedChannelCount(fileName: String, count: Int)
  case tooShort(fileName: String, frames: Int, required: Int)
  case encodeFailed(title: String, reason: String)
  case encodedLengthMismatch(title: String, expected: Int, actual: Int)

  var errorDescription: String? {
    switch self {
    case .unreadable(let fileName): "\(fileName) is not readable audio."
    case .unsupportedContainer(let fileName):
      "\(fileName) must contain WAV, RF64, AIFF, AIFC, or FLAC audio."
    case .unsupportedCodec(let fileName):
      "\(fileName) must contain uncompressed PCM or FLAC audio, not a lossy codec."
    case .unsupportedChannelCount(let fileName, let count):
      "\(fileName) has \(count) channels; one or two are supported."
    case .tooShort(let fileName, let frames, let required):
      "\(fileName) is too short: \(frames) frames, but \(required) are needed."
    case .encodeFailed(let title, let reason): "Could not encode \(title): \(reason)"
    case .encodedLengthMismatch(let title, let expected, let actual):
      "\(title) decoded to \(actual) frames; expected \(expected)."
    }
  }
}

struct MasteringReturnClient: Sendable {
  var inspect: @Sendable (URL) async throws -> MasterInspection
  var encodePart:
    @Sendable (_ master: URL, _ target: MasteredPartTarget, _ workDirectory: URL) async throws
      -> [EncodedPiece]
}

extension MasteringReturnClient: DependencyKey {
  static var liveValue: MasteringReturnClient {
    MasteringReturnClient(
      inspect: { try MasteringReturnInspector.inspect($0) },
      encodePart: { master, target, workDirectory in
        let worker = Task.detached {
          try await MasteringReturnWorker.encodePart(master, target, workDirectory)
        }
        return try await withTaskCancellationHandler {
          let result = try await worker.value
          if Task.isCancelled {
            for piece in result { try? FileManager.default.removeItem(at: piece.url) }
            throw CancellationError()
          }
          return result
        } onCancel: {
          worker.cancel()
        }
      })
  }
}

extension MasteringReturnClient: TestDependencyKey {
  static var testValue: MasteringReturnClient {
    MasteringReturnClient(
      inspect: { _ in
        reportIssue("MasteringReturnClient.inspect called without a test override")
        throw MasteringReturnError.unreadable(fileName: "")
      },
      encodePart: { _, _, _ in
        reportIssue("MasteringReturnClient.encodePart called without a test override")
        throw MasteringReturnError.unreadable(fileName: "")
      })
  }
}

extension DependencyValues {
  var masteringReturn: MasteringReturnClient {
    get { self[MasteringReturnClient.self] }
    set { self[MasteringReturnClient.self] = newValue }
  }
}

private enum MasteringReturnInspector {
  static func inspect(_ url: URL) throws -> MasterInspection {
    let name = url.lastPathComponent
    var fileID: AudioFileID?
    let status = AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID)
    guard status == noErr, let fileID else {
      throw MasteringReturnError.unreadable(fileName: name)
    }
    defer { AudioFileClose(fileID) }
    var type: AudioFileTypeID = 0
    var size = UInt32(MemoryLayout<AudioFileTypeID>.size)
    guard AudioFileGetProperty(fileID, kAudioFilePropertyFileFormat, &size, &type) == noErr else {
      throw MasteringReturnError.unreadable(fileName: name)
    }
    guard
      [
        kAudioFileWAVEType, kAudioFileRF64Type, kAudioFileAIFFType, kAudioFileAIFCType,
        kAudioFileFLACType,
      ].contains(type)
    else { throw MasteringReturnError.unsupportedContainer(fileName: name) }
    var streamDescription = AudioStreamBasicDescription()
    var streamDescriptionSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard
      AudioFileGetProperty(
        fileID, kAudioFilePropertyDataFormat, &streamDescriptionSize, &streamDescription) == noErr
    else { throw MasteringReturnError.unreadable(fileName: name) }
    guard [kAudioFormatLinearPCM, kAudioFormatFLAC].contains(streamDescription.mFormatID) else {
      throw MasteringReturnError.unsupportedCodec(fileName: name)
    }
    guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else {
      throw MasteringReturnError.unreadable(fileName: name)
    }
    let channels = Int(file.fileFormat.channelCount)
    guard channels == 1 || channels == 2 else {
      throw MasteringReturnError.unsupportedChannelCount(fileName: name, count: channels)
    }
    return MasterInspection(
      fileName: name, sampleRate: file.fileFormat.sampleRate, channels: channels,
      sourceFrames: Int(file.length))
  }
}

private enum MasteringReturnWorker {
  static func encodePart(
    _ master: URL, _ target: MasteredPartTarget, _ workDirectory: URL
  ) async throws -> [EncodedPiece] {
    try Task.checkCancellation()
    try validate(target)
    let inspection = try MasteringReturnInspector.inspect(master)
    let difference = abs(inspection.durationSeconds - Double(target.partFrameCount) / 44_100)
    guard difference < MasteringFormat.masterDurationToleranceSeconds else {
      throw MasteringReturnError.encodeFailed(
        title: target.pieces[0].title, reason: "Returned audio duration changed after matching")
    }
    let caf = workDirectory.appendingPathComponent(UUID().uuidString + ".caf")
    var completed: [EncodedPiece] = []
    do {
      defer { try? FileManager.default.removeItem(at: caf) }
      try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
      let frames = try conform(master, to: caf)
      let required = target.pieces.map { $0.startFrame + $0.frameCount }.max()!
      guard frames >= required else {
        throw MasteringReturnError.tooShort(
          fileName: master.lastPathComponent, frames: frames, required: required)
      }
      for piece in target.pieces {
        try Task.checkCancellation()
        let output = workDirectory.appendingPathComponent(UUID().uuidString.lowercased() + ".m4a")
        completed.append(
          try await MasteringAACEncoder.encode(caf, target: piece, outputURL: output))
      }
      try Task.checkCancellation()
      return completed
    } catch {
      for piece in completed { try? FileManager.default.removeItem(at: piece.url) }
      if error is CancellationError { throw error }
      if let error = error as? MasteringReturnError { throw error }
      throw MasteringReturnError.encodeFailed(
        title: target.pieces[0].title, reason: error.localizedDescription)
    }
  }

  private static func validate(_ target: MasteredPartTarget) throws {
    guard target.partFrameCount > 0, !target.pieces.isEmpty else {
      throw invalidTarget(target)
    }
    var expectedStartFrame = 0
    for piece in target.pieces {
      guard piece.startFrame == expectedStartFrame,
        piece.frameCount > 0,
        piece.frameCount <= target.partFrameCount - piece.startFrame
      else { throw invalidTarget(target) }
      expectedStartFrame += piece.frameCount
    }
    guard expectedStartFrame == target.partFrameCount else { throw invalidTarget(target) }
  }

  private static func invalidTarget(_ target: MasteredPartTarget) -> MasteringReturnError {
    .encodeFailed(
      title: target.pieces.first?.title ?? "Returned part",
      reason: "Saved piece ranges are invalid")
  }

  private static func conform(_ master: URL, to caf: URL) throws -> Int {
    let source: AVAudioFile
    do { source = try AVAudioFile(forReading: master) } catch {
      throw MasteringReturnError.unreadable(fileName: master.lastPathComponent)
    }
    var frames = 0
    do {
      let writer = try AVAudioFile(
        forWriting: caf,
        settings: [
          AVFormatIDKey: kAudioFormatLinearPCM,
          AVSampleRateKey: Double(MasteringFormat.sampleRate),
          AVNumberOfChannelsKey: MasteringFormat.channels,
          AVLinearPCMBitDepthKey: 32,
          AVLinearPCMIsFloatKey: true,
          AVLinearPCMIsNonInterleaved: false,
        ])
      let conformer = try MasteringConformer(inputFormat: source.processingFormat)
      while source.framePosition < source.length {
        try Task.checkCancellation()
        guard
          let input = AVAudioPCMBuffer(
            pcmFormat: source.processingFormat, frameCapacity: 65_536)
        else { throw ExportRenderError.bufferAllocationFailed }
        try source.read(into: input)
        guard input.frameLength > 0 else {
          throw MasteringReturnError.unreadable(fileName: master.lastPathComponent)
        }
        try conformer.push(input) { output in
          try writer.write(from: output)
          frames += Int(output.frameLength)
        }
      }
      try conformer.finish { output in
        try writer.write(from: output)
        frames += Int(output.frameLength)
      }
    } catch let error as MasteringPreparationError {
      if error == .invalidLoudnessMeasurement {
        throw MasteringReturnError.encodeFailed(
          title: master.lastPathComponent, reason: "Returned audio contains invalid samples")
      }
      throw MasteringReturnError.encodeFailed(
        title: master.lastPathComponent, reason: error.localizedDescription)
    }
    let readback = try AVAudioFile(forReading: caf)
    guard Int(readback.length) == frames else {
      throw MasteringReturnError.encodeFailed(
        title: master.lastPathComponent, reason: "Conformed audio length changed on disk")
    }
    return frames
  }
}

// swiftlint:enable inclusive_language
