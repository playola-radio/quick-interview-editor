import Foundation

/// The serialized payload of a `.pie` project package: everything JSON-encodable
/// about a project except the audio and the engine's own `plan.json` (spec A2/A4).
struct ProjectFile: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 2
  static let maximumReadableSchemaVersion = 3

  var schemaVersion: Int
  var source: ProjectSource
  var engine: ProjectEngineInfo
  var content: EditorDocumentState
  // swiftlint:disable:next inclusive_language
  var masteringRun: MasteringRun?

  static func writtenSchemaVersion(for file: ProjectFile) -> Int {
    file.masteringRun == nil ? currentSchemaVersion : maximumReadableSchemaVersion
  }
}

extension ProjectFile {
  enum CodingKeys: String, CodingKey {
    // swiftlint:disable:next inclusive_language
    case schemaVersion, source, engine, content, masteringRun
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    source = try container.decode(ProjectSource.self, forKey: .source)
    engine = try container.decode(ProjectEngineInfo.self, forKey: .engine)
    content = try container.decode(EditorDocumentState.self, forKey: .content)
    masteringRun = (try? container.decodeIfPresent(MasteringRun.self, forKey: .masteringRun)) ?? nil
  }
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
  /// Unchanged since the package was read. `sessionCopy` is the clone hydration made for the
  /// editor (nil until then); a save that has no on-disk package child to reuse — Save As or
  /// Duplicate of an unsaved copy — writes the audio from it instead.
  case packageChild(sessionCopy: URL?)
  case sessionFile(URL)

  /// The session-owned copy the editor reads from, if one exists yet.
  var sessionURL: URL? {
    switch self {
    case .packageChild(let sessionCopy): return sessionCopy
    case .sessionFile(let url): return url
    }
  }
}
