import AVFoundation
import CoreMedia
import Foundation

// swiftlint:disable:next inclusive_language
enum MasteringAACEncoder {
  // The source is a fully conformed, 44.1 kHz stereo Float32 CAF. The caller validates
  // every saved range before starting any encoder.
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  static func encode(
    _ sourceURL: URL, target: MasteredPieceTarget, outputURL: URL
  ) async throws -> EncodedPiece {
    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
    do {
      try Task.checkCancellation()
      let source = try AVAudioFile(forReading: sourceURL)
      guard source.processingFormat.sampleRate == 44_100,
        source.processingFormat.channelCount == 2
      else { throw failed(target, "Conformed source format changed") }
      let format = try audioFormatDescription(source.processingFormat, target: target)
      let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: Double(MasteringFormat.sampleRate),
        AVNumberOfChannelsKey: MasteringFormat.channels,
        AVEncoderBitRateKey: MasteringFormat.aacBitRate,
      ]
      let input = AVAssetWriterInput(
        mediaType: .audio, outputSettings: settings, sourceFormatHint: format)
      guard writer.canAdd(input) else { throw failed(target, "AAC writer rejected its input") }
      writer.add(input)
      writer.metadata = [
        metadata(.iTunesMetadataArtist, target.artist),
        metadata(.iTunesMetadataSongName, target.title),
        metadata(.iTunesMetadataLyrics, target.lrc),
      ]
      guard writer.startWriting() else {
        throw failed(target, writer.error?.localizedDescription ?? "Could not start AAC writer")
      }
      writer.startSession(atSourceTime: .zero)
      source.framePosition = AVAudioFramePosition(target.startFrame)
      var written = 0
      while written < target.frameCount {
        try Task.checkCancellation()
        let count = min(4_096, target.frameCount - written)
        guard
          let buffer = AVAudioPCMBuffer(
            pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(count))
        else { throw failed(target, "Could not allocate audio buffer") }
        try source.read(into: buffer, frameCount: AVAudioFrameCount(count))
        guard Int(buffer.frameLength) == count else {
          throw failed(target, "Conformed source ended during encoding")
        }
        let sample = try sampleBuffer(
          buffer, format: format, presentationFrame: written, target: target)
        while !input.isReadyForMoreMediaData {
          try Task.checkCancellation()
          guard writer.status == .writing else {
            throw failed(target, writer.error?.localizedDescription ?? "AAC writer stopped")
          }
          await Task.yield()
        }
        guard input.append(sample) else {
          throw failed(target, writer.error?.localizedDescription ?? "AAC writer rejected samples")
        }
        written += count
      }
      try Task.checkCancellation()
      writer.endSession(
        atSourceTime: CMTime(value: CMTimeValue(target.frameCount), timescale: 44_100))
      input.markAsFinished()
      await writer.finishWriting()
      try Task.checkCancellation()
      guard writer.status == .completed else {
        throw failed(target, writer.error?.localizedDescription ?? "AAC writer did not finish")
      }
      let decoded = try AVAudioFile(forReading: outputURL)
      guard Int(decoded.length) == target.frameCount else {
        throw MasteringReturnError.encodedLengthMismatch(
          title: target.title, expected: target.frameCount, actual: Int(decoded.length))
      }
      let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
      guard let byteCount = (attributes[.size] as? NSNumber)?.intValue, byteCount > 0 else {
        throw failed(target, "AAC output is empty")
      }
      return EncodedPiece(pieceID: target.pieceID, url: outputURL, byteCount: byteCount)
    } catch {
      writer.cancelWriting()
      try? FileManager.default.removeItem(at: outputURL)
      throw error
    }
  }

  private static func metadata(_ identifier: AVMetadataIdentifier, _ value: String)
    -> AVMetadataItem
  {
    let item = AVMutableMetadataItem()
    item.identifier = identifier
    item.value = value as NSString
    return item
  }

  private static func audioFormatDescription(
    _ format: AVAudioFormat, target: MasteredPieceTarget
  ) throws -> CMAudioFormatDescription {
    var description: CMAudioFormatDescription?
    let status = CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault, asbd: format.streamDescription,
      layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
      extensions: nil, formatDescriptionOut: &description)
    guard status == noErr, let description else {
      throw failed(target, "Could not describe PCM input (\(status))")
    }
    return description
  }

  private static func sampleBuffer(
    _ buffer: AVAudioPCMBuffer, format: CMAudioFormatDescription,
    presentationFrame: Int, target: MasteredPieceTarget
  ) throws -> CMSampleBuffer {
    var sample: CMSampleBuffer?
    let status = CMAudioSampleBufferCreateWithPacketDescriptions(
      allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
      makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
      sampleCount: Int(buffer.frameLength),
      presentationTimeStamp: CMTime(value: CMTimeValue(presentationFrame), timescale: 44_100),
      packetDescriptions: nil, sampleBufferOut: &sample)
    guard status == noErr, let sample else {
      throw failed(target, "Could not make PCM sample (\(status))")
    }
    let copyStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
      sample, blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
      bufferList: buffer.audioBufferList)
    guard copyStatus == noErr, CMSampleBufferMakeDataReady(sample) == noErr else {
      throw failed(target, "Could not copy PCM sample (\(copyStatus))")
    }
    return sample
  }

  private static func failed(_ target: MasteredPieceTarget, _ reason: String)
    -> MasteringReturnError
  {
    .encodeFailed(title: target.title, reason: reason)
  }
}
