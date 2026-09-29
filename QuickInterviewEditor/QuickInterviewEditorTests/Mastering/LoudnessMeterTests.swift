import AVFoundation
import CustomDump
import Testing

@testable import PlayolaInterviewEditor

struct LoudnessMeterTests {
  @Test func fixedGainPreservesDynamicsAndRespectsPeakCeiling() throws {
    expectNoDifference(try MasteringGain.decibels(integratedLUFS: -20, truePeakDBTP: -6), 4)
    expectNoDifference(try MasteringGain.decibels(integratedLUFS: -30, truePeakDBTP: -3), 1.5)
    expectNoDifference(try MasteringGain.decibels(integratedLUFS: -.infinity, truePeakDBTP: -10), 0)
    expectNoDifference(
      try MasteringGain.decibels(integratedLUFS: -.infinity, truePeakDBTP: 0.5), -2)
    expectNoDifference(
      try MasteringGain.decibels(integratedLUFS: -.infinity, truePeakDBTP: -.infinity), 0)
  }

  @Test func rejectsInvalidPeak() {
    #expect(throws: MasteringPreparationError.invalidLoudnessMeasurement) {
      try MasteringGain.decibels(integratedLUFS: -20, truePeakDBTP: .nan)
    }
  }

  @Test func shortToneHasUndefinedIntegratedLoudness() throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 9_600))
    buffer.frameLength = 9_600
    let channels = try #require(buffer.floatChannelData)
    for frame in 0..<9_600 {
      let sample = 0.1 * sin(2 * Float.pi * 997 * Float(frame) / 48_000)
      channels[0][frame] = sample
      channels[1][frame] = sample
    }
    let meter = try LoudnessMeter(channels: 2, sampleRate: 48_000, mode: .integratedAndTruePeak)
    try meter.add(buffer)
    let loudness = try meter.integratedLUFS()
    #expect(!loudness.isFinite)
    #expect(
      try MasteringGain.decibels(integratedLUFS: loudness, truePeakDBTP: meter.truePeakDBTP()) <= 0)
  }

  /// FFmpeg 8.1.2 `ebur128=peak=true` independently reports -20.0 LUFS and
  /// -20.0 dBTP for stereo 997 Hz, 48 kHz, 20 s, amplitude 0.1 PCM16.
  @Test func twentySecondSineAgreesWithIndependentMeter() throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    let meter = try LoudnessMeter(channels: 2, sampleRate: 48_000, mode: .integratedAndTruePeak)
    for start in stride(from: 0, to: 960_000, by: 48_000) {
      let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
      buffer.frameLength = 48_000
      let channels = try #require(buffer.floatChannelData)
      for frame in 0..<48_000 {
        let sample =
          Float(
            Int16(
              clamping: Int(
                (0.1
                  * sin(
                    2 * Double.pi * 997 * Double(start + frame) / 48_000) * 32_767).rounded())))
          / 32_768
        channels[0][frame] = sample
        channels[1][frame] = sample
      }
      try meter.add(buffer)
    }
    #expect(abs(try meter.integratedLUFS() - (-20)) <= 0.1)
    #expect(abs(try meter.truePeakDBTP() - (-20)) <= 0.2)
  }

  /// FFmpeg 8.1.2 `ebur128=peak=true` measured -30.0 LUFS and -16.1 dBTP.
  /// Fixture: 8 s stereo PCM16 at 48 kHz; LCG seed 0x12345678, one-pole
  /// low-pass coefficient 0.985, 0.7 Hz speech-like level envelope.
  @Test func modulatedPinkNoiseAgreesWithIndependentMeter() throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    let meter = try LoudnessMeter(channels: 2, sampleRate: 48_000, mode: .integratedAndTruePeak)
    var state: UInt32 = 0x1234_5678
    var pink = 0.0
    for start in stride(from: 0, to: 384_000, by: 48_000) {
      let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
      buffer.frameLength = 48_000
      let channels = try #require(buffer.floatChannelData)
      for frame in 0..<48_000 {
        state = state &* 1_664_525 &+ 1_013_904_223
        let white = Double(state) / 4_294_967_296 * 2 - 1
        pink = 0.985 * pink + 0.015 * white
        let envelope =
          0.5 + 0.5
          * sin(
            2 * Double.pi * 0.7 * Double(start + frame) / 48_000)
        let quantized = Int16(clamping: Int(pink * 0.8 * envelope * 32_767))
        let sample = Float(quantized) / 32_768
        channels[0][frame] = sample
        channels[1][frame] = sample
      }
      try meter.add(buffer)
    }
    #expect(abs(try meter.integratedLUFS() - (-30)) <= 0.1)
    #expect(abs(try meter.truePeakDBTP() - (-16.1)) <= 0.2)
  }
}
