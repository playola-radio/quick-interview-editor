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

  /// Asserts the rendered `output`'s first `fadeInCount` and last `fadeOutCount` frames
  /// ramp exactly like `DeclickFade.gain` applied to the un-faded source, within int16
  /// quantization tolerance. `fadeInSourceStart` is the source-file frame the clip's frame
  /// 0 corresponds to; `fadeOutSourceStart` is the source-file frame the clip's *first*
  /// fade-out frame corresponds to (both default to a simple contiguous copy — pass an
  /// explicit `fadeOutSourceStart` when a removal's seam shifts the tail relative to the
  /// head, so the two boundaries no longer share one offset).
  private func expectBoundaryDeclick(
    output: URL, totalFrames: Int, fadeInCount: Int, fadeOutCount: Int,
    fadeInSourceStart: Int = 0, fadeOutSourceStart: Int? = nil
  ) throws {
    let tolerance: Float = 2.0 / 32768

    if fadeInCount > 0 {
      let rendered = try readFrames(output, from: 0, count: fadeInCount)
      let expected = (0..<fadeInCount).map { frame -> Float in
        let gain = DeclickFade.gain(
          atFrame: frame, totalFrames: totalFrames, fadeInCount: fadeInCount,
          fadeOutCount: fadeOutCount)
        return Float(sourceSample(at: fadeInSourceStart + frame)) / 32768 * gain
      }
      let worst = zip(rendered, expected).map { abs($0 - $1) }.max() ?? 0
      #expect(worst <= tolerance)
      // The very first sample of a fade-in must be silent (or as close as int16 allows).
      #expect(abs(rendered[0]) <= tolerance)
    }

    if fadeOutCount > 0 {
      let start = totalFrames - fadeOutCount
      // The source frame the clip's first fade-out frame corresponds to.
      let tailSourceStart = fadeOutSourceStart ?? (fadeInSourceStart + start)
      let rendered = try readFrames(output, from: start, count: fadeOutCount)
      let expected = (0..<fadeOutCount).map { offset -> Float in
        let frame = start + offset
        let gain = DeclickFade.gain(
          atFrame: frame, totalFrames: totalFrames, fadeInCount: fadeInCount,
          fadeOutCount: fadeOutCount)
        return Float(sourceSample(at: tailSourceStart + offset)) / 32768 * gain
      }
      let worst = zip(rendered, expected).map { abs($0 - $1) }.max() ?? 0
      #expect(worst <= tolerance)
      // The very last sample of a fade-out must be silent (or as close as int16 allows).
      #expect(abs(rendered[fadeOutCount - 1]) <= tolerance)
    }
  }

  // MARK: - Tests

  /// Every rendered clip gets a short boundary declick (fade in at its first samples,
  /// fade out at its last) so a hard cut never clicks — see `DeclickFade`. That means an
  /// "identity" render is no longer byte-exact end to end; it's byte-exact in the
  /// interior, and its edges must match `DeclickFade.gain` applied to the source.
  @Test func identityRenderAppliesTheBoundaryDeclickAndReproducesTheInteriorExactly() throws {
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

    let declickCount = DeclickFade.frameCount(
      totalFrames: Self.sourceFrames, sampleRate: Self.sampleRate)
    let interior = actual.audio.subdata(
      in: (declickCount * Self.bytesPerFrame)..<((Self.sourceFrames - declickCount)
        * Self.bytesPerFrame))
    let expectedInterior = expected.audio.subdata(
      in: (declickCount * Self.bytesPerFrame)..<((Self.sourceFrames - declickCount)
        * Self.bytesPerFrame))
    expectNoDifference(firstDifferingByte(interior, expectedInterior), nil)

    try expectBoundaryDeclick(
      output: output, totalFrames: Self.sourceFrames, fadeInCount: declickCount,
      fadeOutCount: declickCount)
  }

  @Test func subRangeSliceAppliesTheBoundaryDeclickAndReproducesTheInteriorExactly() throws {
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

    let declickCount = DeclickFade.frameCount(totalFrames: 3000, sampleRate: Self.sampleRate)
    let interior = actual.audio.subdata(
      in: (declickCount * Self.bytesPerFrame)..<((3000 - declickCount) * Self.bytesPerFrame))
    let expectedInterior = expected.audio.subdata(
      in: ((2000 + declickCount) * Self.bytesPerFrame)..<((5000 - declickCount) * Self.bytesPerFrame)
    )
    expectNoDifference(firstDifferingByte(interior, expectedInterior), nil)

    try expectBoundaryDeclick(
      output: output, totalFrames: 3000, fadeInCount: declickCount, fadeOutCount: declickCount,
      fadeInSourceStart: 2000)
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

    // Everything outside the seam AND outside the clip's boundary declick is untouched
    // source audio. The declick (720 samples here) touches the head's leading edge and
    // the tail's trailing edge, so those slivers are checked separately below.
    let declickCount = DeclickFade.frameCount(totalFrames: 5800, sampleRate: Self.sampleRate)
    let head = actual.audio.subdata(
      in: (declickCount * Self.bytesPerFrame)..<(2800 * Self.bytesPerFrame))
    expectNoDifference(
      firstDifferingByte(
        head,
        expected.audio.subdata(
          in: (declickCount * Self.bytesPerFrame)..<(2800 * Self.bytesPerFrame))),
      nil)
    let tailEnd = 5800 - declickCount
    let tail = actual.audio.subdata(
      in: (3000 * Self.bytesPerFrame)..<(tailEnd * Self.bytesPerFrame))
    expectNoDifference(
      firstDifferingByte(
        tail,
        expected.audio.subdata(
          in: (5200 * Self.bytesPerFrame)..<((5200 + (tailEnd - 3000)) * Self.bytesPerFrame))),
      nil)

    // The tail's first fade-out frame (edited [5080,5800)) is source frame 5200 + (5080-3000).
    try expectBoundaryDeclick(
      output: output, totalFrames: 5800, fadeInCount: declickCount, fadeOutCount: declickCount,
      fadeOutSourceStart: 5200 + (5800 - declickCount - 3000))

    // The seam itself is the shared renderer's blend, to within int16 quantization. It sits
    // well inside the clip (frames 2800-3000 of 5800), so the boundary declick never reaches it.
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

  /// A seam can itself be the render's FIRST item — a removal that starts right at the clip's own
  /// edge leaves no leading kept segment. The leading boundary declick must still reach into the
  /// blended seam samples exactly as it would an ordinary segment's, since `writeSeam` applies
  /// `DeclickFade` at the seam's own position in the whole clip rather than special-casing it away.
  @Test func aSeamAsTheFirstItemAlsoReceivesTheLeadingBoundaryDeclick() throws {
    let dir = try makeSandbox()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("canonical.aiff")
    let output = dir.appendingPathComponent("slice.aiff")
    try writeFixture(to: source)

    let totalFrames = 2000
    var plan = AudioEditRenderPlan(
      timeline: EditedTimeline(sourceDurationSamples: Self.sourceFrames, removals: []))
    plan.items = [
      .seam(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
        leftTail: 1000..<1800, rightHead: 3000..<3800, length: 800, editedStart: 0,
        fadeOffset: 0),
      .segment(source: 5000..<6200, editedStart: 800),
    ]

    try ExportAudioRenderer.render(
      job(source: source, output: output, plan: plan, editedDuration: totalFrames))

    let declickCount = DeclickFade.frameCount(totalFrames: totalFrames, sampleRate: Self.sampleRate)
    expectNoDifference(declickCount, 720)  // the whole 800-sample seam extends past the fade window

    let outgoing = (1000..<1800).map { Float(sourceSample(at: $0)) / 32768 }
    let incoming = (3000..<3800).map { Float(sourceSample(at: $0)) / 32768 }
    let blended = CrossfadeRenderer.blend(
      out: [outgoing], incoming: [incoming], curve: .equalPower, fadeOffset: 0, fadeTotal: 800)[0]
    let expected = (0..<800).map { index in
      blended[index]
        * DeclickFade.gain(
          atFrame: index, totalFrames: totalFrames, fadeInCount: declickCount,
          fadeOutCount: declickCount)
    }
    let rendered = try readFrames(output, from: 0, count: 800)
    let tolerance: Float = 1.0 / 32768
    let worst = zip(rendered, expected).map { abs($0 - $1) }.max() ?? 0
    #expect(worst <= tolerance)
    // The seam's very first sample sits at the clip's outer edge, so the fade must silence it
    // exactly like an ordinary segment's leading edge.
    #expect(abs(rendered[0]) <= tolerance)
  }

  /// The mirror case: a seam as the render's LAST item (a removal ending right at the clip's own
  /// edge, so there is no trailing kept segment). The trailing boundary declick must reach into
  /// the blended seam samples the same way.
  @Test func aSeamAsTheLastItemAlsoReceivesTheTrailingBoundaryDeclick() throws {
    let dir = try makeSandbox()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("canonical.aiff")
    let output = dir.appendingPathComponent("slice.aiff")
    try writeFixture(to: source)

    let totalFrames = 2000
    var plan = AudioEditRenderPlan(
      timeline: EditedTimeline(sourceDurationSamples: Self.sourceFrames, removals: []))
    plan.items = [
      .segment(source: 0..<1200, editedStart: 0),
      .seam(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
        leftTail: 1000..<1800, rightHead: 3000..<3800, length: 800, editedStart: 1200,
        fadeOffset: 0),
    ]

    try ExportAudioRenderer.render(
      job(source: source, output: output, plan: plan, editedDuration: totalFrames))

    let declickCount = DeclickFade.frameCount(totalFrames: totalFrames, sampleRate: Self.sampleRate)
    expectNoDifference(declickCount, 720)  // the fade window reaches 80 samples into the seam

    let outgoing = (1000..<1800).map { Float(sourceSample(at: $0)) / 32768 }
    let incoming = (3000..<3800).map { Float(sourceSample(at: $0)) / 32768 }
    let blended = CrossfadeRenderer.blend(
      out: [outgoing], incoming: [incoming], curve: .equalPower, fadeOffset: 0, fadeTotal: 800)[0]
    let expected = (0..<800).map { index in
      blended[index]
        * DeclickFade.gain(
          atFrame: 1200 + index, totalFrames: totalFrames, fadeInCount: declickCount,
          fadeOutCount: declickCount)
    }
    let rendered = try readFrames(output, from: 1200, count: 800)
    let tolerance: Float = 1.0 / 32768
    let worst = zip(rendered, expected).map { abs($0 - $1) }.max() ?? 0
    #expect(worst <= tolerance)
    // The seam's very last sample sits at the clip's outer edge, so the fade must silence it too.
    #expect(abs(rendered[799]) <= tolerance)
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
