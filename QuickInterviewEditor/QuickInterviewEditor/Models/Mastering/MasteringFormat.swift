import AVFoundation

// swiftlint:disable:next inclusive_language
enum MasteringFormat {
  static let sampleRate = 44_100
  static let channels = 2
  static let partLimitFrames = 3_000 * sampleRate
  static let targetLUFS = -16.0
  static let truePeakCeilingDBTP = -1.5
  static let truePeakToleranceDB = 0.1
  static let aacBitRate = 256_000
  // swiftlint:disable:next inclusive_language
  static let masterDurationToleranceSeconds = 5.0
  static var processingFormat: AVAudioFormat {
    AVAudioFormat(
      standardFormatWithSampleRate: Double(sampleRate), channels: AVAudioChannelCount(channels))!
  }
}
