import AVFoundation
import AudioToolbox
import CustomDump
import Testing

@testable import PlayolaInterviewEditor

// swiftlint:disable:next inclusive_language
struct MasteringConformerTests {
  @Test func varied48kLengthsStayWithinOneFrameOfRoundedRate() throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    for length in [1_023, 1_024, 1_025, 44_099, 44_101] {
      let converter = try MasteringConformer(inputFormat: format)
      let input = try #require(
        AVAudioPCMBuffer(
          pcmFormat: format, frameCapacity: AVAudioFrameCount(length)))
      input.frameLength = AVAudioFrameCount(length)
      let channels = try #require(input.floatChannelData)
      for frame in 0..<length {
        channels[0][frame] = 0
        channels[1][frame] = 0
      }
      var written = 0
      try converter.push(input) { written += Int($0.frameLength) }
      try converter.finish { written += Int($0.frameLength) }
      let expected = MasteringFrames.conformed(length, fromRate: 48_000)
      expectNoDifference(written, expected)
      expectNoDifference(converter.outputFrameCount, written)
    }
  }

  @Test func stereo48kImpulsePositionsSurviveConversion() throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    let converter = try MasteringConformer(inputFormat: format)
    let impulses = [480, 12_000, 36_000, 60_000, 94_560]
    var samples: [Float] = []
    for start in stride(from: 0, to: 96_000, by: 4_096) {
      let count = min(4_096, 96_000 - start)
      let input = try #require(
        AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
      input.frameLength = AVAudioFrameCount(count)
      let channels = try #require(input.floatChannelData)
      for frame in 0..<count {
        let value: Float = impulses.contains(start + frame) ? 1 : 0
        channels[0][frame] = value
        channels[1][frame] = value
      }
      try converter.push(input) { output in
        let channel = try #require(output.floatChannelData)[0]
        samples += (0..<Int(output.frameLength)).map { channel[$0] }
      }
    }
    try converter.finish { output in
      let channel = try #require(output.floatChannelData)[0]
      samples += (0..<Int(output.frameLength)).map { channel[$0] }
    }
    expectNoDifference(converter.outputFrameCount, 88_200)
    expectNoDifference(samples.count, 88_200)
    for expected in [441, 11_025, 33_075, 55_125, 86_877] {
      let neighborhood = (expected - 2)...(expected + 2)
      let peak = neighborhood.max { abs(samples[$0]) < abs(samples[$1]) }
      expectNoDifference(peak, expected)
    }
  }

  @Test func monoIsDuplicatedWithoutChangingFrames() throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
    let converter = try MasteringConformer(inputFormat: format)
    let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 5))
    input.frameLength = 5
    let mono = try #require(input.floatChannelData)[0]
    for frame in 0..<5 { mono[frame] = Float(frame) / 10 }
    try converter.push(input) { output in
      let channels = try #require(output.floatChannelData)
      for frame in 0..<5 { expectNoDifference(channels[0][frame], channels[1][frame]) }
    }
    try converter.finish { _ in }
    expectNoDifference(converter.outputFrameCount, 5)
  }

  @Test func stereoIntegerPCMIsConvertedToProcessingFloatFormat() throws {
    let format = try #require(
      AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 44_100,
        channels: 2, interleaved: false))
    let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100))
    input.frameLength = 100
    let channels = try #require(input.int16ChannelData)
    for frame in 0..<100 {
      channels[0][frame] = 8_192
      channels[1][frame] = -8_192
    }
    let converter = try MasteringConformer(inputFormat: format)
    var written = 0
    try converter.push(input) { output in
      written += Int(output.frameLength)
      let floats = try #require(output.floatChannelData)
      #expect(abs(floats[0][0] - 0.25) < 0.001)
      #expect(abs(floats[1][0] + 0.25) < 0.001)
    }
    try converter.finish { output in written += Int(output.frameLength) }
    expectNoDifference(written, 100)
  }

  @Test func rejectsMultichannelSource() throws {
    let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_3_0_A))
    let format = try #require(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
        interleaved: false, channelLayout: layout))
    #expect(throws: MasteringPreparationError.unsupportedChannelCount(3)) {
      try MasteringConformer(inputFormat: format)
    }
  }
}
