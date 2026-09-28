import AVFoundation
import CEbur128
import Foundation

/// Owns one libebur128 state. Its caller keeps it on a single audio worker.
final class LoudnessMeter {
  enum Mode { case integratedAndTruePeak, truePeakOnly }

  private var state: UnsafeMutablePointer<ebur128_state>?
  private let channelCount: Int

  init(channels: Int, sampleRate: Int, mode: Mode) throws {
    guard channels > 0 && sampleRate > 0 else { throw MasteringPreparationError.meterUnavailable }
    let flags =
      Int32(EBUR128_MODE_TRUE_PEAK.rawValue)
      | (mode == .integratedAndTruePeak ? Int32(EBUR128_MODE_I.rawValue) : 0)
    guard let state = ebur128_init(UInt32(channels), UInt(sampleRate), flags) else {
      throw MasteringPreparationError.meterUnavailable
    }
    self.state = state
    self.channelCount = channels
  }

  deinit { ebur128_destroy(&state) }

  func add(_ buffer: AVAudioPCMBuffer) throws {
    guard Int(buffer.format.channelCount) == channelCount,
      let channels = buffer.floatChannelData,
      let state
    else { throw MasteringPreparationError.meterUnavailable }
    let count = Int(buffer.frameLength)
    var interleaved = [Float](repeating: 0, count: count * channelCount)
    for frame in 0..<count {
      for channel in 0..<channelCount {
        let value = channels[channel][frame]
        guard value.isFinite else { throw MasteringPreparationError.invalidLoudnessMeasurement }
        interleaved[frame * channelCount + channel] = value
      }
    }
    guard ebur128_add_frames_float(state, &interleaved, count) == EBUR128_SUCCESS.rawValue else {
      throw MasteringPreparationError.meterUnavailable
    }
  }

  func integratedLUFS() throws -> Double {
    guard let state else { throw MasteringPreparationError.meterUnavailable }
    var value = 0.0
    guard ebur128_loudness_global(state, &value) == EBUR128_SUCCESS.rawValue else {
      throw MasteringPreparationError.meterUnavailable
    }
    return value
  }

  func truePeakDBTP() throws -> Double {
    guard let state else { throw MasteringPreparationError.meterUnavailable }
    var peak = 0.0
    for channel in 0..<channelCount {
      var value = 0.0
      guard ebur128_true_peak(state, UInt32(channel), &value) == EBUR128_SUCCESS.rawValue else {
        throw MasteringPreparationError.meterUnavailable
      }
      peak = max(peak, value)
    }
    return peak > 0 ? 20 * log10(peak) : -.infinity
  }

  static func measure(url: URL, mode: Mode = .integratedAndTruePeak) throws
    -> LoudnessMeasurement
  {
    let file = try AVAudioFile(forReading: url)
    let meter = try LoudnessMeter(
      channels: Int(file.processingFormat.channelCount),
      sampleRate: Int(file.processingFormat.sampleRate.rounded()), mode: mode)
    while file.framePosition < file.length {
      try Task.checkCancellation()
      guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536)
      else { throw ExportRenderError.bufferAllocationFailed }
      try file.read(into: buffer)
      guard buffer.frameLength > 0 else {
        throw ExportRenderError.shortRead(
          requested: 1, got: 0, atFrame: Int(file.framePosition))
      }
      try meter.add(buffer)
    }
    return try LoudnessMeasurement(
      integratedLUFS: mode == .integratedAndTruePeak ? meter.integratedLUFS() : -.infinity,
      truePeakDBTP: meter.truePeakDBTP())
  }
}
