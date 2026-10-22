import AVFoundation
import CEbur128
import Foundation

/// libebur128's `ebur128_init` recomputes process-wide static constants on every
/// call (see `Vendor/libebur128/ebur128/ebur128.c`), so concurrent init/measure
/// calls across meter instances race. Serialize the whole lifecycle on this lock.
private let ebur128Lock = NSLock()

/// Owns one libebur128 state. Its caller keeps it on a single audio worker.
final class LoudnessMeter {
  enum Mode { case integratedAndTruePeak, truePeakOnly }

  private var state: UnsafeMutablePointer<ebur128_state>?
  private let channelCount: Int

  init(channels: Int, sampleRate: Int, mode: Mode) throws {
    guard channels > 0 && sampleRate > 0 else {
      throw MasteringPreparationError.meterUnavailable(
        "invalid meter format (\(channels) channels, \(sampleRate) Hz)")
    }
    let flags =
      Int32(EBUR128_MODE_TRUE_PEAK.rawValue)
      | (mode == .integratedAndTruePeak ? Int32(EBUR128_MODE_I.rawValue) : 0)
    ebur128Lock.lock()
    let state = ebur128_init(UInt32(channels), UInt(sampleRate), flags)
    ebur128Lock.unlock()
    guard let state else {
      throw MasteringPreparationError.meterUnavailable(
        "libebur128 could not allocate a meter (\(channels) channels, \(sampleRate) Hz)")
    }
    self.state = state
    self.channelCount = channels
  }

  deinit {
    ebur128Lock.lock()
    ebur128_destroy(&state)
    ebur128Lock.unlock()
  }

  func add(_ buffer: AVAudioPCMBuffer) throws {
    guard Int(buffer.format.channelCount) == channelCount else {
      throw MasteringPreparationError.meterUnavailable(
        "buffer has \(buffer.format.channelCount) channels; the meter expects \(channelCount)")
    }
    guard let channels = buffer.floatChannelData else {
      throw MasteringPreparationError.meterUnavailable("buffer is not float PCM")
    }
    guard let state else {
      throw MasteringPreparationError.meterUnavailable("the meter was already released")
    }
    let count = Int(buffer.frameLength)
    var interleaved = [Float](repeating: 0, count: count * channelCount)
    for frame in 0..<count {
      for channel in 0..<channelCount {
        let value = channels[channel][frame]
        guard value.isFinite else {
          throw MasteringPreparationError.invalidLoudnessMeasurement(
            "sample \(value) at frame \(frame), channel \(channel)")
        }
        interleaved[frame * channelCount + channel] = value
      }
    }
    ebur128Lock.lock()
    let result = ebur128_add_frames_float(state, &interleaved, count)
    ebur128Lock.unlock()
    guard result == EBUR128_SUCCESS.rawValue else {
      throw MasteringPreparationError.meterUnavailable(
        "ebur128_add_frames_float failed: \(Self.describe(result))")
    }
  }

  func integratedLUFS() throws -> Double {
    guard let state else {
      throw MasteringPreparationError.meterUnavailable("the meter was already released")
    }
    var value = 0.0
    ebur128Lock.lock()
    let result = ebur128_loudness_global(state, &value)
    ebur128Lock.unlock()
    guard result == EBUR128_SUCCESS.rawValue else {
      throw MasteringPreparationError.meterUnavailable(
        "ebur128_loudness_global failed: \(Self.describe(result))")
    }
    return value
  }

  func truePeakDBTP() throws -> Double {
    guard let state else {
      throw MasteringPreparationError.meterUnavailable("the meter was already released")
    }
    var peak = 0.0
    ebur128Lock.lock()
    defer { ebur128Lock.unlock() }
    for channel in 0..<channelCount {
      var value = 0.0
      let result = ebur128_true_peak(state, UInt32(channel), &value)
      guard result == EBUR128_SUCCESS.rawValue else {
        throw MasteringPreparationError.meterUnavailable(
          "ebur128_true_peak failed for channel \(channel): \(Self.describe(result))")
      }
      peak = max(peak, value)
    }
    return peak > 0 ? 20 * log10(peak) : -.infinity
  }

  private static func describe(_ code: Int32) -> String {
    switch code {
    case Int32(EBUR128_ERROR_NOMEM.rawValue): "out of memory (code \(code))"
    case Int32(EBUR128_ERROR_INVALID_MODE.rawValue): "invalid mode (code \(code))"
    case Int32(EBUR128_ERROR_INVALID_CHANNEL_INDEX.rawValue): "invalid channel index (code \(code))"
    case Int32(EBUR128_ERROR_NO_CHANGE.rawValue): "no change (code \(code))"
    default: "code \(code)"
    }
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
      else {
        throw ExportRenderError.bufferAllocationFailed(
          format: file.processingFormat, frames: 65_536)
      }
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
