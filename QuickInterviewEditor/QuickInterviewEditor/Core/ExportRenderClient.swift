import AVFoundation
import Dependencies
import Foundation
import IssueReporting

/// One slice to render: the plan's source ranges are ABSOLUTE canonical-file
/// coordinates, its edited axis is slice-local, and `outputURL` receives an audio
/// file in the canonical file's exact format.
///
/// `sampleRate` and `sourceDurationSamples` are the plan's own values, and the
/// renderer requires the file to match both EXACTLY. That makes the file-to-plan
/// sample ratio exactly 1, so every plan coordinate is a native frame coordinate and
/// no rounding enters the export path (unlike playback, which tolerates a resampled
/// file).
struct ExportRenderJob: Equatable, Sendable {
  var canonicalAudioURL: URL
  var plan: AudioEditRenderPlan
  var editedDurationSamples: Int
  var sampleRate: Int
  var sourceDurationSamples: Int
  var outputURL: URL
}

struct ExportRenderClient: Sendable {
  var renderSlice: @Sendable (ExportRenderJob) async throws -> Void
}

extension ExportRenderClient: DependencyKey {
  static let liveValue = ExportRenderClient(
    renderSlice: { job in
      // Reading and writing whole slices must never run on the main actor — but a bare
      // detached task also severs cancellation: the renderer's `Task.checkCancellation()`
      // would consult the detached task, never the cancelled export. Forward it
      // explicitly so Cancel/tab-close interrupts a long render at the next chunk.
      let render = Task.detached { try ExportAudioRenderer.render(job) }
      return try await withTaskCancellationHandler {
        try await render.value
      } onCancel: {
        render.cancel()
      }
    }
  )
}

extension ExportRenderClient: TestDependencyKey {
  static let testValue = ExportRenderClient(
    renderSlice: { _ in
      reportIssue("ExportRenderClient.renderSlice called without a test override")
      throw EngineClientError.unimplemented("ExportRenderClient.renderSlice")
    }
  )

  /// Used automatically by SwiftUI previews; writes nothing.
  static let previewValue = ExportRenderClient(renderSlice: { _ in })
}

extension DependencyValues {
  var exportRender: ExportRenderClient {
    get { self[ExportRenderClient.self] }
    set { self[ExportRenderClient.self] = newValue }
  }
}

enum ExportRenderError: Error, Equatable, LocalizedError {
  case frameCountMismatch(actual: Int, expected: Int)
  case sampleRateMismatch(actual: Int, expected: Int)
  case shortRender(written: Int, expected: Int)
  case shortRead(requested: Int, got: Int, atFrame: Int)
  case invalidSliceRange(name: String, start: Int, end: Int, duration: Int)
  case bufferAllocationFailed

  var errorDescription: String? {
    switch self {
    case .frameCountMismatch(let actual, let expected):
      return "canonical audio frame count \(actual) != expected \(expected)"
    case .sampleRateMismatch(let actual, let expected):
      return "canonical audio sample rate \(actual) Hz != requested \(expected) Hz"
    case .shortRender(let written, let expected):
      return "rendered \(written) frames but the edited timeline is \(expected) frames"
    case .shortRead(let requested, let got, let atFrame):
      return "read \(got) of \(requested) frames at frame \(atFrame) of the canonical audio"
    case .invalidSliceRange(let name, let start, let end, let duration):
      return
        "\"\(name)\" spans samples \(start)..<\(end), which is not a valid range in a \(duration)-sample recording"
    case .bufferAllocationFailed:
      return "Could not allocate an audio buffer for the export."
    }
  }
}

/// Renders one slice's edited audio straight from the canonical file, using the same
/// `CrossfadeRenderer` blend the live audition path uses — so an exported seam is
/// sample-for-sample what the user heard (locked decision 1).
enum ExportAudioRenderer {
  /// Frames per read/write for kept segments; keeps peak memory flat on long slices.
  private static let chunkFrames = 1 << 16

  static func render(_ job: ExportRenderJob) throws {
    let file = try AVAudioFile(forReading: job.canonicalAudioURL)
    // Fail loud on a stale/swapped/wrong-rate file rather than exporting audio that
    // doesn't match the plan the user edited (mirrors the engine's run_render checks).
    guard Int(file.length) == job.sourceDurationSamples else {
      throw ExportRenderError.frameCountMismatch(
        actual: Int(file.length), expected: job.sourceDurationSamples)
    }
    let actualRate = Int(file.processingFormat.sampleRate.rounded())
    guard actualRate == job.sampleRate else {
      throw ExportRenderError.sampleRateMismatch(actual: actualRate, expected: job.sampleRate)
    }

    // The slice keeps the canonical file's exact format (the analog of the Python
    // slicer reusing the source COMM chunk); buffers move in the processing format.
    let output = try AVAudioFile(forWriting: job.outputURL, settings: file.fileFormat.settings)

    var framesWritten = 0
    for item in job.plan.items {
      try Task.checkCancellation()
      switch item {
      case .segment(let source, _):
        framesWritten += try writeSegment(source, from: file, to: output)
      case .seam(_, let leftTail, let rightHead, _, _, let fadeOffset):
        framesWritten += try writeSeam(
          leftTail: leftTail, rightHead: rightHead, fadeOffset: fadeOffset,
          from: file, to: output)
      }
    }

    guard framesWritten == job.editedDurationSamples else {
      throw ExportRenderError.shortRender(
        written: framesWritten, expected: job.editedDurationSamples)
    }
  }

  private static func writeSegment(
    _ source: Range<Int>, from file: AVAudioFile, to output: AVAudioFile
  ) throws -> Int {
    guard !source.isEmpty else { return 0 }
    let format = file.processingFormat
    let capacity = AVAudioFrameCount(min(source.count, chunkFrames))
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
      throw ExportRenderError.bufferAllocationFailed
    }
    file.framePosition = AVAudioFramePosition(source.lowerBound)
    var remaining = source.count
    var written = 0
    while remaining > 0 {
      try Task.checkCancellation()
      let count = AVAudioFrameCount(min(remaining, chunkFrames))
      try file.read(into: buffer, frameCount: count)
      // Every segment range is in bounds of a file already verified to match the plan's
      // frame count, so a short read means the file changed under us. Fail loud rather
      // than stopping early — a silent break would ship a truncated slice that only the
      // `shortRender` backstop could catch, and only when it changed the total.
      guard buffer.frameLength == count else {
        throw ExportRenderError.shortRead(
          requested: Int(count), got: Int(buffer.frameLength),
          atFrame: source.lowerBound + written)
      }
      try output.write(from: buffer)
      written += Int(buffer.frameLength)
      remaining -= Int(buffer.frameLength)
    }
    return written
  }

  /// Renders one seam's crossfade. The overlap length is `leftTail.count` — the plan's
  /// seam `length` always equals its (possibly trimmed) tail/head range counts, the
  /// same invariant `LivePlayerBox.seamBuffer` relies on.
  ///
  /// Rendered in `chunkFrames` chunks like a kept segment, so a pathological persisted
  /// crossfade length can't allocate the whole overlap (times three: two reads plus the
  /// blend) at once, and a cancel lands within a chunk instead of after the whole fade.
  /// Chunking is sample-identical: `CrossfadeRenderer.gains` positions each chunk inside
  /// the FULL fade via `fadeOffset + chunkStart` against an unchanged `fadeTotal`, which
  /// is the same continuation math a seek into a seam already uses.
  private static func writeSeam(
    leftTail: Range<Int>, rightHead: Range<Int>, fadeOffset: Int,
    from file: AVAudioFile, to output: AVAudioFile
  ) throws -> Int {
    let length = leftTail.count
    guard length > 0 else { return 0 }
    let format = file.processingFormat
    var chunkStart = 0
    while chunkStart < length {
      try Task.checkCancellation()
      let chunkLength = min(chunkFrames, length - chunkStart)
      let out = try readFloats(
        file: file, startFrame: leftTail.lowerBound + chunkStart, frameCount: chunkLength)
      let incoming = try readFloats(
        file: file, startFrame: rightHead.lowerBound + chunkStart, frameCount: chunkLength)
      // Same call shape as `LivePlayerBox.seamBuffer`, so export == audition. The curve
      // is fixed equal-power on both paths until PR5 threads per-seam curves through.
      let blended = CrossfadeRenderer.blend(
        out: out, incoming: incoming, curve: .equalPower,
        fadeOffset: fadeOffset + chunkStart, fadeTotal: fadeOffset + length)
      let count = AVAudioFrameCount(chunkLength)
      guard !blended.isEmpty,
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
        let channels = buffer.floatChannelData
      else { throw ExportRenderError.bufferAllocationFailed }
      buffer.frameLength = count
      for channel in 0..<Int(format.channelCount) {
        let source = blended[min(channel, blended.count - 1)]
        let destination = channels[channel]
        for frame in 0..<chunkLength { destination[frame] = source[frame] }
      }
      try output.write(from: buffer)
      chunkStart += chunkLength
    }
    return length
  }

  /// Reads exactly `frameCount` frames from `startFrame` into per-channel float arrays.
  /// The ratio-1 guarantee plus the plan's in-bounds ranges mean a short read can only
  /// come from a malformed plan or a file that changed under us, so it is a hard error
  /// here — this reader never clamps or zero-pads (unlike the playback path's tolerant
  /// one), because padded silence in an export is indistinguishable from kept audio.
  private static func readFloats(
    file: AVAudioFile, startFrame: Int, frameCount: Int
  ) throws -> [[Float]] {
    let format = file.processingFormat
    let channelCount = Int(format.channelCount)
    var result = Array(
      repeating: [Float](repeating: 0, count: frameCount), count: channelCount)
    guard frameCount > 0 else { return result }
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
      let channels = buffer.floatChannelData
    else { throw ExportRenderError.bufferAllocationFailed }
    file.framePosition = AVAudioFramePosition(startFrame)
    try file.read(into: buffer, frameCount: AVAudioFrameCount(frameCount))
    let read = Int(buffer.frameLength)
    guard read == frameCount else {
      throw ExportRenderError.shortRead(
        requested: frameCount, got: read, atFrame: startFrame)
    }
    for channel in 0..<channelCount {
      let source = channels[channel]
      for frame in 0..<read { result[channel][frame] = source[frame] }
    }
    return result
  }
}
