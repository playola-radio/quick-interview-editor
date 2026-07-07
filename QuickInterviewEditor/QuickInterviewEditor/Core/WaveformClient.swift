import AVFoundation
import Accelerate
import Dependencies
import Foundation
import IssueReporting

// MARK: - Waveform

/// A multi-resolution min/max peak pyramid for one audio file, keyed in PLAN samples
/// (`editPlan.source.sampleRate`). Level 0 is the finest; each higher level halves the
/// resolution (doubles `bucketSize`). The whole app works in plan samples, so the
/// native→plan sample-rate conversion happens once, inside ``WaveformClient`` — nothing
/// here or above ever sees the source file's native frame coordinates.
struct Waveform: Sendable, Equatable {
  /// Plan sample rate — the coordinate system every bucket is keyed in.
  var sampleRate: Int
  /// Authoritative total length in plan samples (`editPlan.source.durationSamples`).
  var totalSamples: Int
  /// Finest first. Level 0's `bucketSize` is the base; each subsequent level doubles it.
  var levels: [Level]

  struct Level: Sendable, Equatable {
    /// Plan samples per bucket. Doubles from one level to the next.
    var bucketSize: Int
    /// Per-bucket minimum sample amplitude, normalized to -1...1.
    var mins: [Float]
    /// Per-bucket maximum sample amplitude, normalized to -1...1.
    var maxs: [Float]
  }

  /// The finest level, or `nil` for an empty waveform.
  var baseLevel: Level? { levels.first }
}

extension Waveform {
  /// Plan samples per bucket at the finest level. 256 (not 512) so the waveform keeps
  /// useful detail when the user zooms near a word boundary; memory stays trivial
  /// (~10 MB of Float32 min/max for a 90-minute mono interview).
  static let baseBucketSize = 256

  /// Builds the full pyramid from a finest-level min/max pair. Pure and deterministic —
  /// the one place the level structure is defined, shared by the live decoder and tests.
  /// Higher levels pairwise-reduce the level below until a single bucket remains.
  static func pyramid(
    baseMins: [Float], baseMaxs: [Float], sampleRate: Int, totalSamples: Int,
    baseBucketSize: Int = Waveform.baseBucketSize
  ) -> Waveform {
    precondition(baseMins.count == baseMaxs.count, "mins/maxs must be parallel")
    guard !baseMins.isEmpty else {
      return Waveform(sampleRate: sampleRate, totalSamples: totalSamples, levels: [])
    }
    var levels = [Level(bucketSize: baseBucketSize, mins: baseMins, maxs: baseMaxs)]
    while let finest = levels.last, finest.mins.count > 1 {
      levels.append(reduce(finest))
    }
    return Waveform(sampleRate: sampleRate, totalSamples: totalSamples, levels: levels)
  }

  /// Halves a level: bucket `k` of the result covers buckets `2k` and `2k+1` below (a
  /// trailing odd bucket carries through unpaired). `bucketSize` doubles.
  private static func reduce(_ level: Level) -> Level {
    let outCount = (level.mins.count + 1) / 2
    var mins = [Float](repeating: 0, count: outCount)
    var maxs = [Float](repeating: 0, count: outCount)
    for index in 0..<outCount {
      let lo = index * 2
      let hi = min(lo + 1, level.mins.count - 1)
      mins[index] = Swift.min(level.mins[lo], level.mins[hi])
      maxs[index] = Swift.max(level.maxs[lo], level.maxs[hi])
    }
    return Level(bucketSize: level.bucketSize * 2, mins: mins, maxs: maxs)
  }

  /// Buckets a mono buffer into finest-level min/max arrays. Pure; used for fixtures and
  /// small inputs (the live decoder accumulates the same values incrementally while
  /// streaming so it never holds the whole file in memory). Every bucket is
  /// `bucketSize` samples except a possible shorter final bucket, which is preserved.
  static func baseLevel(mono: [Float], bucketSize: Int = Waveform.baseBucketSize)
    -> (mins: [Float], maxs: [Float])
  {
    guard bucketSize > 0, !mono.isEmpty else { return ([], []) }
    let count = (mono.count + bucketSize - 1) / bucketSize
    var mins = [Float](repeating: 0, count: count)
    var maxs = [Float](repeating: 0, count: count)
    for bucket in 0..<count {
      let start = bucket * bucketSize
      let end = Swift.min(start + bucketSize, mono.count)
      var low: Float = mono[start]
      var high: Float = mono[start]
      for index in start..<end {
        low = Swift.min(low, mono[index])
        high = Swift.max(high, mono[index])
      }
      mins[bucket] = low
      maxs[bucket] = high
    }
    return (mins, maxs)
  }
}

// MARK: - WaveformClient

/// Reads the interview audio and produces its peak pyramid. A `Sendable` dependency so
/// models are tested against synthetic ``Waveform`` fixtures with no audio decode.
struct WaveformClient: Sendable {
  /// Reads native PCM from `url`, downmixes to mono, resamples to `planSampleRate`, and
  /// builds a min/max pyramid keyed in plan samples spanning `[0, durationSamples)`.
  /// The read is streamed so peak memory stays bounded regardless of file length.
  var loadWaveform:
    @Sendable (_ url: URL, _ planSampleRate: Int, _ durationSamples: Int) async throws -> Waveform
}

enum WaveformClientError: Error, Equatable {
  case unimplemented(String)
  case noAudioTrack
  case readFailed(String)
}

extension WaveformClient: DependencyKey {
  static let liveValue = WaveformClient(
    loadWaveform: { url, planSampleRate, durationSamples in
      try await WaveformDecoder.decode(
        url: url, planSampleRate: planSampleRate, durationSamples: durationSamples)
    }
  )
}

extension WaveformClient: TestDependencyKey {
  static let testValue = WaveformClient(
    loadWaveform: { _, _, _ in
      reportIssue("WaveformClient.loadWaveform called without a test override")
      throw WaveformClientError.unimplemented("loadWaveform")
    }
  )

  /// Synthetic pyramid for SwiftUI previews — a slow sine sweep, never real audio.
  static let previewValue = WaveformClient(
    loadWaveform: { _, planSampleRate, durationSamples in
      let total = max(planSampleRate, durationSamples)
      var mono = [Float](repeating: 0, count: total)
      for index in 0..<total {
        let phase = Double(index) / Double(total)
        mono[index] = Float(sin(phase * .pi * 12) * (0.3 + 0.6 * phase))
      }
      let base = Waveform.baseLevel(mono: mono)
      return Waveform.pyramid(
        baseMins: base.mins, baseMaxs: base.maxs, sampleRate: planSampleRate,
        totalSamples: total)
    }
  )
}

extension DependencyValues {
  var waveform: WaveformClient {
    get { self[WaveformClient.self] }
    set { self[WaveformClient.self] = newValue }
  }
}

// MARK: - Live decoder

/// Streams PCM out of the source file and folds it into the finest pyramid level with
/// `vDSP`, one bounded chunk at a time. All AVFoundation objects stay local to
/// `decode(...)` — none are captured into another closure — so nothing crosses a
/// concurrency-isolation boundary (Swift 6 `sending`). Not unit-tested (real audio
/// decode); the model is covered against synthetic ``Waveform`` fixtures instead.
private enum WaveformDecoder {

  static func decode(url: URL, planSampleRate: Int, durationSamples: Int) async throws -> Waveform {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    guard let track = tracks.first else { throw WaveformClientError.noAudioTrack }

    let reader = try AVAssetReader(asset: asset)
    let output = makeOutput(track: track, planSampleRate: planSampleRate)
    guard reader.canAdd(output) else {
      throw WaveformClientError.readFailed("cannot add track output")
    }
    reader.add(output)
    guard reader.startReading() else {
      throw WaveformClientError.readFailed(reader.error?.localizedDescription ?? "startReading")
    }

    let base = try accumulate(
      output: output, reader: reader, planSampleRate: planSampleRate,
      durationSamples: durationSamples)
    // The plan's duration is authoritative (roadmap decision 4): the pyramid always spans
    // exactly [0, durationSamples), so its coverage and the x-axis can't disagree.
    return Waveform.pyramid(
      baseMins: base.mins, baseMaxs: base.maxs, sampleRate: planSampleRate,
      totalSamples: durationSamples)
  }

  /// Mono Float32 at the plan sample rate: AVAssetReader downmixes channels and resamples,
  /// so each frame the loop sees IS one plan sample (frame index == plan sample). This is
  /// the entire native→plan conversion, confined here.
  private static func makeOutput(track: AVAssetTrack, planSampleRate: Int)
    -> AVAssetReaderTrackOutput
  {
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
        AVSampleRateKey: planSampleRate,
        AVNumberOfChannelsKey: 1,
      ])
    output.alwaysCopiesSampleData = false
    return output
  }

  /// Streams the reader's PCM into finest-level min/max buckets, honoring cancellation and
  /// stopping once every plan-duration bucket is filled.
  private static func accumulate(
    output: AVAssetReaderTrackOutput, reader: AVAssetReader, planSampleRate: Int,
    durationSamples: Int
  ) throws -> (mins: [Float], maxs: [Float]) {
    var accumulator = BaseAccumulator(
      bucketSize: Waveform.baseBucketSize, durationSamples: durationSamples)
    var verifiedFormat = false

    while let sampleBuffer = output.copyNextSampleBuffer() {
      if Task.isCancelled {
        reader.cancelReading()
        throw CancellationError()
      }
      // Verify AVAssetReader actually delivered mono Float32 at the plan rate. If a codec
      // path ever ignores the output settings, fail loud rather than silently treat
      // native-rate PCM as plan samples (which would drift the waveform).
      if !verifiedFormat {
        try verifyFormat(sampleBuffer, planSampleRate: planSampleRate)
        verifiedFormat = true
      }
      guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
      let length = CMBlockBufferGetDataLength(blockBuffer)
      var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
      let status = samples.withUnsafeMutableBytes { raw -> OSStatus in
        CMBlockBufferCopyDataBytes(
          blockBuffer, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
      }
      guard status == kCMBlockBufferNoErr else { continue }
      accumulator.fold(samples: samples)
      // Every plan-duration bucket is filled; extra decoder tail (codec padding beyond the
      // plan's timeline) isn't part of our coordinate space, so stop early.
      if accumulator.position >= durationSamples {
        reader.cancelReading()
        break
      }
    }

    if reader.status == .failed {
      throw WaveformClientError.readFailed(reader.error?.localizedDescription ?? "read failed")
    }
    return accumulator.finish()
  }

  /// Throws if the sample buffer isn't the mono 32-bit float PCM at `planSampleRate` we
  /// asked for — the guarantee the whole "frame index == plan sample" mapping rests on.
  private static func verifyFormat(_ sampleBuffer: CMSampleBuffer, planSampleRate: Int) throws {
    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
    else {
      throw WaveformClientError.readFailed("missing PCM format description")
    }
    let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
    guard Int(asbd.mSampleRate.rounded()) == planSampleRate, asbd.mChannelsPerFrame == 1,
      isFloat, asbd.mBitsPerChannel == 32
    else {
      throw WaveformClientError.readFailed(
        "unexpected PCM format: \(asbd.mSampleRate) Hz, \(asbd.mChannelsPerFrame) ch, "
          + "\(asbd.mBitsPerChannel)-bit")
    }
  }

  /// Accumulates streamed mono samples into finest-level min/max buckets without ever
  /// holding the whole file. Buckets are pre-sized from the plan's duration; a running
  /// `position` (absolute plan-sample index) places each chunk. Buckets the reader
  /// never reaches finish as silence rather than ±infinity.
  private struct BaseAccumulator {
    let bucketSize: Int
    private let durationSamples: Int
    private(set) var position = 0
    private var mins: [Float]
    private var maxs: [Float]
    private var touched: [Bool]

    init(bucketSize: Int, durationSamples: Int) {
      self.bucketSize = bucketSize
      self.durationSamples = max(0, durationSamples)
      let count = max(1, (self.durationSamples + bucketSize - 1) / bucketSize)
      mins = [Float](repeating: .greatestFiniteMagnitude, count: count)
      maxs = [Float](repeating: -.greatestFiniteMagnitude, count: count)
      touched = [Bool](repeating: false, count: count)
    }

    /// Folds one chunk, walking it bucket-aligned slice by slice with `vDSP` per slice.
    /// Never folds a sample at or beyond `durationSamples` (codec padding past the plan's
    /// timeline), so the final partial bucket stays inside `[0, durationSamples)`.
    mutating func fold(samples: [Float]) {
      defer { position += samples.count }
      guard !samples.isEmpty else { return }
      samples.withUnsafeBufferPointer { buffer in
        var offset = 0
        while offset < buffer.count {
          let globalPosition = position + offset
          guard globalPosition < durationSamples else { break }
          let bucket = globalPosition / bucketSize
          guard bucket >= 0, bucket < mins.count else { break }
          let sliceEnd = Swift.min((bucket + 1) * bucketSize, durationSamples)
          let sliceLen = Swift.min(sliceEnd - globalPosition, buffer.count - offset)
          guard sliceLen > 0 else { break }
          var low: Float = 0
          var high: Float = 0
          vDSP_minv(buffer.baseAddress! + offset, 1, &low, vDSP_Length(sliceLen))
          vDSP_maxv(buffer.baseAddress! + offset, 1, &high, vDSP_Length(sliceLen))
          mins[bucket] = Swift.min(mins[bucket], low)
          maxs[bucket] = Swift.max(maxs[bucket], high)
          touched[bucket] = true
          offset += sliceLen
        }
      }
    }

    func finish() -> (mins: [Float], maxs: [Float]) {
      var mins = mins
      var maxs = maxs
      for index in mins.indices where !touched[index] {
        mins[index] = 0
        maxs[index] = 0
      }
      return (mins, maxs)
    }
  }
}
