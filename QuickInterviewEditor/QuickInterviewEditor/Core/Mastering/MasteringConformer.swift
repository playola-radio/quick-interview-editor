import AVFoundation

// Converts a sequence of bounded PCM buffers to 44.1 kHz stereo float PCM.
// swiftlint:disable:next inclusive_language
final class MasteringConformer {
  private enum Path {
    case stereoCopy, monoCopy
    case converted(AVAudioConverter)
  }

  private let path: Path
  private(set) var outputFrameCount = 0

  init(inputFormat: AVAudioFormat) throws {
    let channels = Int(inputFormat.channelCount)
    guard channels == 1 || channels == 2 else {
      throw MasteringPreparationError.unsupportedChannelCount(channels)
    }
    if inputFormat.sampleRate == 44_100,
      inputFormat.commonFormat == .pcmFormatFloat32, !inputFormat.isInterleaved
    {
      path = channels == 2 ? .stereoCopy : .monoCopy
    } else {
      guard
        let converter = AVAudioConverter(
          from: inputFormat, to: MasteringFormat.processingFormat)
      else { throw MasteringPreparationError.conversionFailed("Could not initialize converter") }
      if channels == 1 { converter.channelMap = [0, 0] }
      path = .converted(converter)
    }
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  func push(_ input: AVAudioPCMBuffer, sink: (AVAudioPCMBuffer) throws -> Void) throws {
    try Task.checkCancellation()
    switch path {
    case .stereoCopy:
      try emit(input, sink: sink)
    case .monoCopy:
      guard let source = input.floatChannelData?[0],
        let output = AVAudioPCMBuffer(
          pcmFormat: MasteringFormat.processingFormat, frameCapacity: input.frameLength),
        let channels = output.floatChannelData
      else { throw ExportRenderError.bufferAllocationFailed }
      output.frameLength = input.frameLength
      for frame in 0..<Int(input.frameLength) {
        let value = source[frame]
        channels[0][frame] = value
        channels[1][frame] = value
      }
      try emit(output, sink: sink)
    case .converted(let converter):
      var supplied = false
      var stalled = 0
      repeat {
        try Task.checkCancellation()
        guard
          let output = AVAudioPCMBuffer(
            pcmFormat: MasteringFormat.processingFormat, frameCapacity: 65_536)
        else { throw ExportRenderError.bufferAllocationFailed }
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
          if supplied {
            inputStatus.pointee = .noDataNow
            return nil
          }
          supplied = true
          inputStatus.pointee = .haveData
          return input
        }
        if let error {
          throw MasteringPreparationError.conversionFailed(error.localizedDescription)
        }
        if output.frameLength > 0 {
          try emit(output, sink: sink)
          stalled = 0
        } else {
          stalled += 1
        }
        if status == .error || stalled > 2 {
          throw MasteringPreparationError.conversionFailed(
            "Converter stopped before consuming input")
        }
        if status == .inputRanDry { break }
      } while true
      guard supplied else {
        throw MasteringPreparationError.conversionFailed("Converter did not consume input")
      }
    }
  }

  func finish(sink: (AVAudioPCMBuffer) throws -> Void) throws {
    guard case .converted(let converter) = path else { return }
    var stalled = 0
    while true {
      try Task.checkCancellation()
      guard
        let output = AVAudioPCMBuffer(
          pcmFormat: MasteringFormat.processingFormat, frameCapacity: 65_536)
      else { throw ExportRenderError.bufferAllocationFailed }
      var error: NSError?
      let status = converter.convert(to: output, error: &error) { _, inputStatus in
        inputStatus.pointee = .endOfStream
        return nil
      }
      if let error { throw MasteringPreparationError.conversionFailed(error.localizedDescription) }
      if output.frameLength > 0 {
        try emit(output, sink: sink)
        stalled = 0
      } else {
        stalled += 1
      }
      if status == .endOfStream { return }
      if status == .error || stalled > 2 {
        throw MasteringPreparationError.conversionFailed("Converter failed to finish")
      }
    }
  }

  private func emit(_ buffer: AVAudioPCMBuffer, sink: (AVAudioPCMBuffer) throws -> Void) throws {
    guard let channels = buffer.floatChannelData else {
      throw ExportRenderError.bufferAllocationFailed
    }
    for channel in 0..<Int(buffer.format.channelCount) {
      for frame in 0..<Int(buffer.frameLength) {
        guard channels[channel][frame].isFinite else {
          throw MasteringPreparationError.invalidLoudnessMeasurement
        }
      }
    }
    try sink(buffer)
    outputFrameCount += Int(buffer.frameLength)
  }
}
