import Foundation

/// The serialized payload of a `.pie` project package: everything JSON-encodable
/// about a project except the audio and the engine's own `plan.json` (spec A2/A4).
struct ProjectFile: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  var schemaVersion: Int
  var source: ProjectSource
  var engine: ProjectEngineInfo
  var content: EditorDocumentState
}

/// Where the imported audio came from and how the bundled canonical AIFF is
/// identified, so a re-transcribe or an integrity check never has to touch the
/// original file (spec A4/A8).
struct ProjectSource: Codable, Equatable, Sendable {
  var originalFileName: String
  var originalPath: String?
  var originalFingerprint: String
  var canonicalFingerprint: String
  var canonicalByteCount: Int
  var importedAt: Date
  var sampleRate: Int
  var channels: Int
  var durationSamples: Int
}

/// Provenance of the engine that produced `plan.json`, recorded for future
/// "produced by an older engine" affordances. Does not gate opening (spec A8).
struct ProjectEngineInfo: Codable, Equatable, Sendable {
  var engineFingerprint: String
}

/// Where the canonical AIFF's bytes currently live: unchanged since the package
/// was read (reuse the existing wrapper on save) or freshly imported/re-transcribed
/// this session (read from the session store on save). Never persisted itself —
/// it is process state, not project content (spec A5).
enum CanonicalAudioSource: Equatable, Sendable {
  case packageChild
  case sessionFile(URL)
}
