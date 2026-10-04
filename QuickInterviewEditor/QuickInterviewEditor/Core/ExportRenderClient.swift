import AVFoundation
import Dependencies
import Foundation
import IssueReporting

struct ExportAudioTags: Equatable, Sendable {
  var title = ""
  var artist = ""
  var wordStarts: [RenderMarker] = []
}

/// One slice to render: the plan's source ranges are ABSOLUTE canonical-file
/// coordinates, its edited axis is slice-local, and `outputURL` receives an audio
/// file in the selected export format (AIFF defaults to the canonical format).
///
/// `sampleRate` and `sourceDurationSamples` are the plan's own values, and the
/// renderer requires the file to match both EXACTLY. That makes the file-to-plan
/// sample ratio exactly 1, so every plan coordinate is a native frame coordinate and
/// edits are rendered before any conversion to the selected output sample rate.
struct ExportRenderJob: Equatable, Sendable {
  var canonicalAudioURL: URL
  var plan: AudioEditRenderPlan
  var editedDurationSamples: Int
  var sampleRate: Int
  var sourceDurationSamples: Int
  var outputURL: URL
  var format: ExportAudioFormat = .aiff
  var tags = ExportAudioTags()
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
      let render = Task.detached { try await ExportAudioRenderer.render(job) }
      return try await withTaskCancellationHandler {
        do {
          try await render.value
          try Task.checkCancellation()
        } catch {
          try? FileManager.default.removeItem(at: job.outputURL)
          throw error
        }
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
  case invalidWordStart

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
    case .invalidWordStart:
      return "A transcript word has an invalid start time."
    }
  }
}

/// Renders one slice's edited audio straight from the canonical file, using the same
/// `CrossfadeRenderer` blend the live audition path uses — so an exported seam is
/// sample-for-sample what the user heard (locked decision 1).
enum ExportAudioRenderer {
  /// Frames per read/write for kept segments; keeps peak memory flat on long slices.
  private static let chunkFrames = 1 << 16

  static func render(_ job: ExportRenderJob) async throws {
    try Task.checkCancellation()
    let file = try openCanonical(
      job.canonicalAudioURL, sampleRate: job.sampleRate,
      sourceDurationSamples: job.sourceDurationSamples)
    switch job.format {
    case .aiff:
      let output = try AVAudioFile(forWriting: job.outputURL, settings: file.fileFormat.settings)
      _ = try renderEdited(
        from: file, plan: job.plan, editedDurationSamples: job.editedDurationSamples,
        sampleRate: job.sampleRate, emit: { try output.write(from: $0) })
    case .wav:
      _ = try renderConformed(
        from: file, plan: job.plan, editedDurationSamples: job.editedDurationSamples,
        sampleRate: job.sampleRate, to: job.outputURL, settings: MasteringFormat.pcm24WAVSettings)
    case .m4a:
      try await renderM4A(job, from: file)
    }
  }

  private static func renderM4A(_ job: ExportRenderJob, from file: AVAudioFile) async throws {
    let caf = job.outputURL.deletingPathExtension().appendingPathExtension("caf")
    defer { try? FileManager.default.removeItem(at: caf) }
    let frames = try renderConformed(
      from: file, plan: job.plan, editedDurationSamples: job.editedDurationSamples,
      sampleRate: job.sampleRate, to: caf, settings: MasteringFormat.float32CAFSettings)
    let words = job.tags.wordStarts.compactMap { marker -> (frame: Int, text: String)? in
      guard marker.position >= 0 else { return nil }
      let frame = MasteringFrames.conformed(marker.position, fromRate: job.sampleRate)
      return frame < frames ? (frame, marker.name) : nil
    }
    _ = try await MasteringAACEncoder.encode(
      caf,
      target: .init(
        pieceID: UUID(), startFrame: 0, frameCount: frames,
        artist: job.tags.artist, title: job.tags.title, lrc: MasteringLRC.text(wordStarts: words)),
      outputURL: job.outputURL)
  }

  // swiftlint:disable:next function_parameter_count
  static func renderConformed(
    from source: AVAudioFile, plan: AudioEditRenderPlan, editedDurationSamples: Int,
    sampleRate: Int, to url: URL, settings: [String: Any]
  ) throws -> Int {
    var frames = 0
    do {
      let conformer = try MasteringConformer(inputFormat: source.processingFormat)
      let writer = try AVAudioFile(forWriting: url, settings: settings)
      _ = try renderEdited(
        from: source, plan: plan, editedDurationSamples: editedDurationSamples,
        sampleRate: sampleRate
      ) { input in
        try conformer.push(input) { output in
          try writer.write(from: output)
          frames += Int(output.frameLength)
        }
      }
      try conformer.finish { output in
        try writer.write(from: output)
        frames += Int(output.frameLength)
      }
    }
    let expected = MasteringFrames.conformed(editedDurationSamples, fromRate: sampleRate)
    guard abs(frames - expected) <= 1 else {
      throw MasteringPreparationError.conversionFailed(
        "Conformed audio length \(frames) differs from expected \(expected)")
    }
    let readback = try AVAudioFile(forReading: url)
    guard Int(readback.length) == frames else {
      throw ExportRenderError.shortRender(written: Int(readback.length), expected: frames)
    }
    return frames
  }

  static func openCanonical(
    _ url: URL, sampleRate: Int, sourceDurationSamples: Int
  ) throws -> AVAudioFile {
    let file = try AVAudioFile(forReading: url)
    // Fail loud on a stale/swapped/wrong-rate file rather than exporting audio that
    // doesn't match the plan the user edited (mirrors the engine's run_render checks).
    guard Int(file.length) == sourceDurationSamples else {
      throw ExportRenderError.frameCountMismatch(
        actual: Int(file.length), expected: sourceDurationSamples)
    }
    let actualRate = Int(file.processingFormat.sampleRate.rounded())
    guard actualRate == sampleRate else {
      throw ExportRenderError.sampleRateMismatch(actual: actualRate, expected: sampleRate)
    }
    return file
  }

  static func renderEdited(
    from file: AVAudioFile, plan: AudioEditRenderPlan, editedDurationSamples: Int,
    sampleRate: Int, emit: (AVAudioPCMBuffer) throws -> Void
  ) throws -> Int {
    // A short declick ramp at the clip's own outer start/end — never at an internal seam,
    // which already gets its own crossfade. Same envelope live audition applies (locked
    // decision 1: one shared render path), so a hard cut at a clip boundary never clicks
    // whichever path the user hears it through.
    let declickCount = DeclickFade.frameCount(
      totalFrames: editedDurationSamples, sampleRate: sampleRate)

    var framesWritten = 0
    for item in plan.items {
      try Task.checkCancellation()
      switch item {
      case .segment(let source, _):
        framesWritten += try writeSegment(
          source, from: file, emit: emit, globalStart: framesWritten,
          totalFrames: editedDurationSamples, fadeInCount: declickCount,
          fadeOutCount: declickCount)
      case .seam(_, let leftTail, let rightHead, _, _, let fadeOffset):
        framesWritten += try writeSeam(
          leftTail: leftTail, rightHead: rightHead, fadeOffset: fadeOffset,
          from: file, emit: emit, globalStart: framesWritten,
          totalFrames: editedDurationSamples, fadeInCount: declickCount,
          fadeOutCount: declickCount)
      }
    }

    guard framesWritten == editedDurationSamples else {
      throw ExportRenderError.shortRender(
        written: framesWritten, expected: editedDurationSamples)
    }
    return framesWritten
  }

  // swiftlint:disable:next function_parameter_count
  private static func writeSegment(
    _ source: Range<Int>, from file: AVAudioFile,
    emit: (AVAudioPCMBuffer) throws -> Void,
    globalStart: Int, totalFrames: Int, fadeInCount: Int, fadeOutCount: Int
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
      applyDeclick(
        to: buffer, chunkStart: globalStart + written, totalFrames: totalFrames,
        fadeInCount: fadeInCount, fadeOutCount: fadeOutCount)
      try emit(buffer)
      written += Int(buffer.frameLength)
      remaining -= Int(buffer.frameLength)
    }
    return written
  }

  /// Applies `DeclickFade` in place to a just-read chunk, where `chunkStart` is the chunk's
  /// position in the WHOLE rendered clip (not the source file). Skips entirely when the chunk
  /// doesn't touch either fade window — true for the overwhelming majority of chunks in a long
  /// clip, so this never costs a full per-sample pass on interior audio.
  private static func applyDeclick(
    to buffer: AVAudioPCMBuffer, chunkStart: Int, totalFrames: Int,
    fadeInCount: Int, fadeOutCount: Int
  ) {
    guard fadeInCount > 0 || fadeOutCount > 0 else { return }
    let count = Int(buffer.frameLength)
    guard count > 0, let channels = buffer.floatChannelData else { return }
    let chunkEnd = chunkStart + count
    let touchesFadeIn = fadeInCount > 0 && chunkStart < fadeInCount
    let touchesFadeOut = fadeOutCount > 0 && chunkEnd > totalFrames - fadeOutCount
    guard touchesFadeIn || touchesFadeOut else { return }
    let channelCount = Int(buffer.format.channelCount)
    for frame in 0..<count {
      let gain = DeclickFade.gain(
        atFrame: chunkStart + frame, totalFrames: totalFrames, fadeInCount: fadeInCount,
        fadeOutCount: fadeOutCount)
      guard gain != 1 else { continue }
      for channel in 0..<channelCount {
        channels[channel][frame] *= gain
      }
    }
  }

  // swiftlint:disable function_parameter_count
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
    from file: AVAudioFile, emit: (AVAudioPCMBuffer) throws -> Void,
    globalStart: Int, totalFrames: Int, fadeInCount: Int, fadeOutCount: Int
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
      var blended = CrossfadeRenderer.blend(
        out: out, incoming: incoming, curve: .equalPower,
        fadeOffset: fadeOffset + chunkStart, fadeTotal: fadeOffset + length)
      // A seam can itself sit at the clip's outer edge (e.g. a removal starting at sample 0),
      // so the boundary declick applies here exactly like an ordinary segment chunk.
      for channel in blended.indices {
        DeclickFade.apply(
          to: &blended[channel], chunkStart: globalStart + chunkStart, totalFrames: totalFrames,
          fadeInCount: fadeInCount, fadeOutCount: fadeOutCount)
      }
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
      try emit(buffer)
      chunkStart += chunkLength
    }
    return length
  }
  // swiftlint:enable function_parameter_count

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
