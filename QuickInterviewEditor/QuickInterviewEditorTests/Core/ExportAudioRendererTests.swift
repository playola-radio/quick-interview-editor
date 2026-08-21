import AVFoundation
import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

/// Integration tests for the export renderer against real AIFF files on disk — no
/// subprocess, no playback, no engine. They assert at the byte level because the
/// whole point of the export path is that it reproduces the canonical audio (and the
/// audition's crossfade) exactly.
struct ExportAudioRendererTests {
  private static let sampleRate = 48000
  private static let sourceFrames = 8000
  private static let bytesPerFrame = 2

  // MARK: - Fixtures

  private func makeSandbox() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("qie-export-render-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// A deterministic, exactly-representable 16-bit sample for frame `index`, kept well
  /// inside full scale so nothing can clip on the float round trip.
  private func sourceSample(at index: Int) -> Int16 {
    Int16((index * 37) % 20001 - 10000)
  }

  /// Writes a canonical-style AIFF: mono, 16-bit big-endian PCM at 48 kHz.
  private func writeFixture(to url: URL, frames: Int = sourceFrames) throws {
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: Double(Self.sampleRate),
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsBigEndianKey: true,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let buffer = try #require(
      AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    let channel = try #require(buffer.floatChannelData)[0]
    for index in 0..<frames { channel[index] = Float(sourceSample(at: index)) / 32768 }
    try file.write(from: buffer)
  }

  private func job(
    source: URL, output: URL, plan: AudioEditRenderPlan, editedDuration: Int,
    sampleRate: Int = ExportAudioRendererTests.sampleRate,
    sourceDuration: Int = ExportAudioRendererTests.sourceFrames
  ) -> ExportRenderJob {
    ExportRenderJob(
      canonicalAudioURL: source,
      plan: plan,
      editedDurationSamples: editedDuration,
      sampleRate: sampleRate,
      sourceDurationSamples: sourceDuration,
      outputURL: output)
  }

  // MARK: - AIFF parsing (FORM / COMM / SSND walk)

  private struct ParsedAIFF {
    var frameCount: Int
    var channels: Int
    var bitsPerSample: Int
    var audio: Data
  }

  private func bigEndianInt(_ data: Data, _ offset: Int, bytes: Int) -> Int {
    var value = 0
    for index in 0..<bytes { value = value << 8 | Int(data[offset + index]) }
    return value
  }

  private func parseAIFF(_ url: URL) throws -> ParsedAIFF {
    let data = try Data(contentsOf: url)
    #expect(String(bytes: data[0..<4], encoding: .ascii) == "FORM")
    var offset = 12
    var parsed = ParsedAIFF(frameCount: 0, channels: 0, bitsPerSample: 0, audio: Data())
    while offset + 8 <= data.count {
      let chunkID = String(bytes: data[offset..<(offset + 4)], encoding: .ascii) ?? ""
      let size = bigEndianInt(data, offset + 4, bytes: 4)
      let payload = offset + 8
      switch chunkID {
      case "COMM":
        parsed.channels = bigEndianInt(data, payload, bytes: 2)
        parsed.frameCount = bigEndianInt(data, payload + 2, bytes: 4)
        parsed.bitsPerSample = bigEndianInt(data, payload + 6, bytes: 2)
      case "SSND":
        let dataOffset = bigEndianInt(data, payload, bytes: 4)
        let start = payload + 8 + dataOffset
        let end = min(payload + size, data.count)
        parsed.audio = data.subdata(in: start..<end)
      default:
        break
      }
      offset = payload + size + (size % 2)
    }
    return parsed
  }

  /// The index of the first differing byte (or the shorter length when the sizes
  /// disagree) — a readable failure for buffers far too large to diff.
  private func firstDifferingByte(_ lhs: Data, _ rhs: Data) -> Int? {
    guard lhs.count == rhs.count else { return min(lhs.count, rhs.count) }
    for index in lhs.indices where lhs[index] != rhs[index] { return index }
    return nil
  }

  private func readFrames(_ url: URL, from start: Int, count: Int) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let buffer = try #require(
      AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)))
    file.framePosition = AVAudioFramePosition(start)
    try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
    let channel = try #require(buffer.floatChannelData)[0]
    return (0..<Int(buffer.frameLength)).map { channel[$0] }
  }

  // MARK: - Tests

  @Test func identityRenderReproducesTheSourceBytesExactly() throws {
    let dir = try makeSandbox()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("canonical.aiff")
    let output = dir.appendingPathComponent("slice.aiff")
    try writeFixture(to: source)

    let timeline = EditedTimeline(sourceDurationSamples: Self.sourceFrames, removals: [])
    try ExportAudioRenderer.render(
      job(
        source: source, output: output, plan: AudioEditRenderPlan(timeline: timeline),
        editedDuration: Self.sourceFrames))

    let expected = try parseAIFF(source)
    let actual = try parseAIFF(output)
    expectNoDifference(actual.frameCount, Self.sourceFrames)
    expectNoDifference(actual.channels, expected.channels)
    expectNoDifference(actual.bitsPerSample, expected.bitsPerSample)
    expectNoDifference(actual.audio.count, expected.audio.count)
    // Cornerstone: the int16 → float → int16 round trip through AVAudioFile is
    // bit-exact, which is what makes audition == export a byte-level claim.
    expectNoDifference(firstDifferingByte(actual.audio, expected.audio), nil)
  }

  @Test func subRangeSliceCopiesTheCorrespondingSourceBytes() throws {
    let dir = try makeSandbox()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("canonical.aiff")
    let output = dir.appendingPathComponent("slice.aiff")
    try writeFixture(to: source)

    let built = SliceRenderPlanBuilder.plan(sliceRange: 2000..<5000, removals: [])
    try ExportAudioRenderer.render(
      job(
        source: source, output: output, plan: built.plan,
        editedDuration: built.editedDurationSamples))

    let expected = try parseAIFF(source)
    let actual = try parseAIFF(output)
    expectNoDifference(actual.frameCount, 3000)
    let slice = expected.audio.subdata(
      in: (2000 * Self.bytesPerFrame)..<(5000 * Self.bytesPerFrame))
    expectNoDifference(actual.audio.count, slice.count)
    expectNoDifference(firstDifferingByte(actual.audio, slice), nil)
  }

  @Test func removalWithACrossfadeMatchesTheSharedRenderer() throws {
    let dir = try makeSandbox()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("canonical.aiff")
    let output = dir.appendingPathComponent("slice.aiff")
    try writeFixture(to: source)

    // Whole file as the slice; remove [3000,5000) with a 200-sample crossfade.
    // Kept [0,2800) → seam over [2800,3000) x [5000,5200) → kept [5200,8000).
    let removal = TimelineRemoval(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      removedRange: 3000..<5000,
      crossfade: Crossfade(lengthSamples: 200, curve: .equalPower))
    let built = SliceRenderPlanBuilder.plan(
      sliceRange: 0..<Self.sourceFrames, removals: [removal])
    expectNoDifference(built.editedDurationSamples, 5800)

    try ExportAudioRenderer.render(
      job(
        source: source, output: output, plan: built.plan,
        editedDuration: built.editedDurationSamples))

    let expected = try parseAIFF(source)
    let actual = try parseAIFF(output)
    expectNoDifference(actual.frameCount, 5800)

    // Everything outside the seam is untouched source audio.
    let head = actual.audio.subdata(in: 0..<(2800 * Self.bytesPerFrame))
    expectNoDifference(
      firstDifferingByte(head, expected.audio.subdata(in: 0..<(2800 * Self.bytesPerFrame))), nil)
    let tail = actual.audio.subdata(
      in: (3000 * Self.bytesPerFrame)..<(5800 * Self.bytesPerFrame))
    expectNoDifference(
      firstDifferingByte(
        tail, expected.audio.subdata(in: (5200 * Self.bytesPerFrame)..<(8000 * Self.bytesPerFrame))),
      nil)

    // The seam itself is the shared renderer's blend, to within int16 quantization.
    let outgoing = (2800..<3000).map { Float(sourceSample(at: $0)) / 32768 }
    let incoming = (5000..<5200).map { Float(sourceSample(at: $0)) / 32768 }
    let blended = CrossfadeRenderer.blend(
      out: [outgoing], incoming: [incoming], curve: .equalPower, fadeOffset: 0, fadeTotal: 200)[0]
    let rendered = try readFrames(output, from: 2800, count: 200)
    expectNoDifference(rendered.count, blended.count)
    let tolerance: Float = 1.0 / 32768
    let worst = zip(rendered, blended).map { abs($0 - $1) }.max() ?? 0
    #expect(worst <= tolerance)
  }

  @Test func renderingTheSameJobTwiceProducesIdenticalFiles() throws {
    let dir = try makeSandbox()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("canonical.aiff")
    try writeFixture(to: source)

    let removal = TimelineRemoval(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      removedRange: 3000..<5000,
      crossfade: Crossfade(lengthSamples: 200, curve: .equalPower))
    let built = SliceRenderPlanBuilder.plan(
      sliceRange: 0..<Self.sourceFrames, removals: [removal])

    let first = dir.appendingPathComponent("first.aiff")
    let second = dir.appendingPathComponent("second.aiff")
    for output in [first, second] {
      try ExportAudioRenderer.render(
        job(
          source: source, output: output, plan: built.plan,
          editedDuration: built.editedDurationSamples))
    }

    let firstBytes = try Data(contentsOf: first)
    let secondBytes = try Data(contentsOf: second)
    expectNoDifference(firstDifferingByte(firstBytes, secondBytes), nil)
  }

  @Test func aFrameCountMismatchFailsLoud() throws {
    let dir = try makeSandbox()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("canonical.aiff")
    let output = dir.appendingPathComponent("slice.aiff")
    try writeFixture(to: source)

    let timeline = EditedTimeline(sourceDurationSamples: Self.sourceFrames, removals: [])
    #expect(
      throws: ExportRenderError.frameCountMismatch(actual: 8000, expected: 7999)
    ) {
      try ExportAudioRenderer.render(
        job(
          source: source, output: output, plan: AudioEditRenderPlan(timeline: timeline),
          editedDuration: Self.sourceFrames, sourceDuration: 7999))
    }
  }

  @Test func aSampleRateMismatchFailsLoud() throws {
    let dir = try makeSandbox()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("canonical.aiff")
    let output = dir.appendingPathComponent("slice.aiff")
    try writeFixture(to: source)

    let timeline = EditedTimeline(sourceDurationSamples: Self.sourceFrames, removals: [])
    #expect(
      throws: ExportRenderError.sampleRateMismatch(actual: 48000, expected: 44100)
    ) {
      try ExportAudioRenderer.render(
        job(
          source: source, output: output, plan: AudioEditRenderPlan(timeline: timeline),
          editedDuration: Self.sourceFrames, sampleRate: 44100))
    }
  }

  /// A malformed plan whose seam reads past the file's last frame used to be zero-padded
  /// silently: `readFloats` filled the tail with zeros and `writeSeam` still reported a full
  /// seam, so `framesWritten` matched `editedDurationSamples` and the export "succeeded" with
  /// silence spliced into kept audio. The read is strict now, so it fails loud instead.
  @Test func aSeamReadingPastTheEndOfTheFileFailsLoudInsteadOfPaddingSilence() throws {
    let dir = try makeSandbox()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("canonical.aiff")
    let output = dir.appendingPathComponent("slice.aiff")
    try writeFixture(to: source)

    // Frame-count and rate checks both pass; only the seam's incoming range is bogus, and it
    // straddles EOF so the frame totals still add up to the declared 5800.
    var plan = AudioEditRenderPlan(
      timeline: EditedTimeline(sourceDurationSamples: Self.sourceFrames, removals: []))
    plan.items = [
      .segment(source: 0..<2800, editedStart: 0),
      .seam(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        leftTail: 2800..<3000, rightHead: 7900..<8100, length: 200, editedStart: 2800,
        fadeOffset: 0),
      .segment(source: 5200..<8000, editedStart: 3000),
    ]
    #expect(throws: ExportRenderError.shortRead(requested: 200, got: 100, atFrame: 7900)) {
      try ExportAudioRenderer.render(
        job(source: source, output: output, plan: plan, editedDuration: 5800))
    }
  }

  /// A crossfade longer than one read chunk is rendered in pieces, and each piece must
  /// CONTINUE the fade rather than restart it. Chunked output has to be identical to a
  /// single unchunked blend of the whole overlap — that equivalence is what lets the
  /// renderer bound its memory without changing a single sample.
  @Test func aCrossfadeLongerThanOneReadChunkMatchesAnUnchunkedBlend() throws {
    let dir = try makeSandbox()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("canonical.aiff")
    let output = dir.appendingPathComponent("slice.aiff")
    let frames = 300_000
    try writeFixture(to: source, frames: frames)

    // 70_000 samples of overlap — more than the renderer's 65_536-frame chunk.
    let fadeLength = 70_000
    let removal = TimelineRemoval(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
      removedRange: 100_000..<150_000,
      crossfade: Crossfade(lengthSamples: fadeLength, curve: .equalPower))
    let built = SliceRenderPlanBuilder.plan(sliceRange: 0..<frames, removals: [removal])
    let editedDuration = frames - 50_000 - fadeLength
    expectNoDifference(built.editedDurationSamples, editedDuration)

    try ExportAudioRenderer.render(
      job(
        source: source, output: output, plan: built.plan, editedDuration: editedDuration,
        sourceDuration: frames))

    let actual = try parseAIFF(output)
    expectNoDifference(actual.frameCount, editedDuration)

    // Kept [0, 30_000) → seam over [30_000, 100_000) x [150_000, 220_000) → kept [220_000, …).
    let outgoing = (30_000..<100_000).map { Float(sourceSample(at: $0)) / 32768 }
    let incoming = (150_000..<220_000).map { Float(sourceSample(at: $0)) / 32768 }
    let blended = CrossfadeRenderer.blend(
      out: [outgoing], incoming: [incoming], curve: .equalPower, fadeOffset: 0,
      fadeTotal: fadeLength)[0]
    let rendered = try readFrames(output, from: 30_000, count: fadeLength)
    expectNoDifference(rendered.count, blended.count)
    let tolerance: Float = 1.0 / 32768
    let worst = zip(rendered, blended).map { abs($0 - $1) }.max() ?? 0
    #expect(worst <= tolerance)
  }

  @Test func aPlanShorterThanItsEditedDurationFailsLoud() throws {
    let dir = try makeSandbox()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("canonical.aiff")
    let output = dir.appendingPathComponent("slice.aiff")
    try writeFixture(to: source)

    let built = SliceRenderPlanBuilder.plan(sliceRange: 0..<1000, removals: [])
    #expect(throws: ExportRenderError.shortRender(written: 1000, expected: 2000)) {
      try ExportAudioRenderer.render(
        job(source: source, output: output, plan: built.plan, editedDuration: 2000))
    }
  }
}
