import Foundation

// MARK: - ModelFile

/// One downloadable model artifact: where to fetch it, where it lands under the
/// models root, and how to verify it. The SHA-256 makes a partial/corrupt file
/// detectable so it can be re-fetched, and keeps the download tamper-evident
/// (weights are untrusted input to the model loaders).
struct ModelFile: Equatable, Sendable {
  /// Remote source (HuggingFace `resolve/<revision>` or download.pytorch.org).
  var remoteURL: URL
  /// Destination relative to the models root, e.g.
  /// `faster-whisper-large-v2/model.bin`.
  var relativePath: String
  /// Lowercase hex SHA-256 of the file's content.
  var sha256: String
  /// Expected size in bytes (drives progress + a cheap pre-checksum sanity check).
  var byteCount: Int64
}

// MARK: - ModelManifest

/// The complete set of model files the engine needs, pinned to exact revisions.
///
/// These are **data**, downloaded on first launch into Application Support and
/// loaded by faster-whisper / torchaudio — never executable code shipped or
/// fetched post-notarization (roadmap decision 6). Bumping a model is a data
/// change here.
struct ModelManifest: Equatable, Sendable {
  var version: Int
  var files: [ModelFile]

  var totalByteCount: Int64 { files.reduce(0) { $0 + $1.byteCount } }

  /// faster-whisper `large-v2` (CTranslate2, MIT) pinned to a HuggingFace commit,
  /// plus the torchaudio `WAV2VEC2_ASR_BASE_960H` English alignment model (MIT).
  static let current = ModelManifest(
    version: 1,
    files: {
      let whisperRevision = "f0fe81560cb8b68660e564f55dd99207059c092e"
      func whisper(_ name: String, _ sha: String, _ size: Int64) -> ModelFile {
        ModelFile(
          remoteURL: URL(
            string:
              "https://huggingface.co/Systran/faster-whisper-large-v2/resolve/\(whisperRevision)/\(name)"
          )!,
          relativePath: "faster-whisper-large-v2/\(name)",
          sha256: sha,
          byteCount: size
        )
      }
      return [
        whisper(
          "config.json",
          "d86b7a7664a12559d644aa210a32ce9a7e03913e794b7ea4fb7182de69e273a7", 2796),
        whisper(
          "model.bin",
          "bf2a9746382e1aa7ffff6b3a0d137ed9edbd9670c3b87e5d35f5e85e70d0333a", 3_086_912_962),
        whisper(
          "tokenizer.json",
          "fb7b63191e9bb045082c79fd742a3106a12c99513ab30df4a0d47fa6cb6fd0ab", 2_203_239),
        whisper(
          "vocabulary.txt",
          "34ce3fe1c5041027b3f8d42912270993f986dbc4bb34cf27f951e34a1e453913", 459_861),
        ModelFile(
          remoteURL: URL(
            string:
              "https://download.pytorch.org/torchaudio/models/wav2vec2_fairseq_base_ls960_asr_ls960.pth"
          )!,
          relativePath: "align/wav2vec2_fairseq_base_ls960_asr_ls960.pth",
          sha256: "488fd4f16de84438ffc945334278c1b9fb9b7159a806c1080b16111a958c945d",
          byteCount: 377_664_473),
      ]
    }()
  )
}

// MARK: - ModelLocations

/// Single source of truth for where models install on disk. Shared by the
/// downloader (writes here) and the engine launch (points `QIE_*` env here), so
/// they can never disagree.
enum ModelLocations {
  private static let appFolder = "Quick Interview Editor"

  /// `~/Library/Application Support/Quick Interview Editor/Models`.
  static func modelsRoot(
    fileManager: FileManager = .default
  ) throws -> URL {
    try fileManager.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    )
    .appendingPathComponent(appFolder)
    .appendingPathComponent("Models")
  }

  static func installation(fileManager: FileManager = .default) throws -> ModelInstallation {
    let root = try modelsRoot(fileManager: fileManager)
    return ModelInstallation(
      whisperModelDir: root.appendingPathComponent("faster-whisper-large-v2"),
      alignModelDir: root.appendingPathComponent("align")
    )
  }
}

// MARK: - ModelInstallation

/// Absolute model directories handed to the engine as `QIE_*` env when running
/// the packaged helper.
struct ModelInstallation: Equatable, Sendable {
  var whisperModelDir: URL
  var alignModelDir: URL

  /// Env overrides that make the engine load these dirs offline.
  var engineEnvironment: [String: String] {
    [
      "QIE_WHISPER_MODEL_DIR": whisperModelDir.path,
      "QIE_ALIGN_MODEL_DIR": alignModelDir.path,
      "QIE_OFFLINE": "1",
    ]
  }
}
