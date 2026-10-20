import os

/// Loggers for intentionally best-effort paths (cache reads, pruning, legacy
/// migration, optional metadata) whose failures must not alert the user but
/// should still leave a cause behind. Never log prompts, transcript text,
/// keys, or environment variables.
enum AppLog {
  static let subsystem = "fm.playola.PlayolaInterviewEditor"

  static let project = Logger(subsystem: subsystem, category: "project")
  static let cache = Logger(subsystem: subsystem, category: "cache")
  static let modelDownload = Logger(subsystem: subsystem, category: "model-download")
  // swiftlint:disable:next inclusive_language
  static let mastering = Logger(subsystem: subsystem, category: "mastering")
  static let document = Logger(subsystem: subsystem, category: "document")
  static let suggestions = Logger(subsystem: subsystem, category: "suggestions")
  static let export = Logger(subsystem: subsystem, category: "export")
}
