import Foundation

enum EngineEvent: Equatable, Sendable {
  case progress(EngineProgress)
  case completed(TranscriptionResult)
}

/// A finished transcription: the decoded plan plus the canonical PCM AIFF the engine
/// produced (copied into an app-owned cache). Every downstream coordinate — waveform,
/// playhead, cut — is a sample of this one file, so nothing drifts through a second
/// native→plan resample (roadmap decision 4).
struct TranscriptionResult: Equatable, Sendable {
  var editPlan: EditPlan
  var canonicalAudioURL: URL
}

/// One engine-declared progress update. The engine owns the pipeline shape and
/// tells the app which ordered phase this is (`phaseIndex` of `phaseCount`), so the
/// app renders "Phase X of N · … · NN%" without hard-coding the stages. `phase` is
/// kept as the raw string (for logs); display is driven by the metadata + fraction,
/// never by matching a known phase name — an unknown/renamed phase still renders.
struct EngineProgress: Equatable, Sendable {
  var phase: String
  var phaseIndex: Int?
  var phaseCount: Int?
  var label: String?
  var message: String
  var fraction: Double?

  init(
    phase: String,
    phaseIndex: Int? = nil,
    phaseCount: Int? = nil,
    label: String? = nil,
    message: String,
    fraction: Double? = nil
  ) {
    self.phase = phase
    self.phaseIndex = phaseIndex
    self.phaseCount = phaseCount
    self.label = label
    self.message = message
    self.fraction = fraction
  }

  /// The phase index, but only when it forms sane 1-based metadata (`1...phaseCount`).
  /// Old-format events (no index) and malformed metadata (e.g. `index 999, count 3`)
  /// normalize to nil, so a bogus index is never used for ordering or the "Phase X of
  /// N" prefix — otherwise it would pin `currentPhaseIndex` high and make every real
  /// later phase look stale.
  var validPhaseIndex: Int? {
    guard let index = phaseIndex, let count = phaseCount,
      count >= 1, index >= 1, index <= count
    else { return nil }
    return index
  }

  /// "Phase X of N", shown only when the engine sent sane 1-based metadata. Old-format
  /// events (or malformed index/count) return nil, so the app just drops the prefix.
  var phaseOfNText: String? {
    guard let index = validPhaseIndex, let count = phaseCount else { return nil }
    return "Phase \(index) of \(count)"
  }

  /// The human text for this phase: the live sub-status (`message`) when present —
  /// which is what keeps the indeterminate Finalizing phase from reading as a dead
  /// spinner — falling back to `label`, then the raw phase, then a generic word.
  var displayText: String {
    if !message.isEmpty { return message }
    if let label, !label.isEmpty { return label }
    if !phase.isEmpty { return phase }
    return "Working"
  }
}

enum EngineClientError: Error, Equatable, LocalizedError {
  case unimplemented(String)
  case engineNotFound(String)
  case engineFailed(String)
  case decodeFailed(String)
  case injectFailed(String)
  case injectDecodeFailed(String)

  var errorDescription: String? {
    switch self {
    case .unimplemented(let name): return "EngineClient.\(name) was called without a test override."
    case .engineNotFound(let path): return "Transcription engine not found at \(path)."
    case .engineFailed(let message): return "Transcription failed: \(message)"
    case .decodeFailed(let message): return "Could not read the transcription result: \(message)"
    case .injectFailed(let message): return "Marker injection failed: \(message)"
    case .injectDecodeFailed(let message):
      return "Could not read the marker injection result: \(message)"
    }
  }
}
