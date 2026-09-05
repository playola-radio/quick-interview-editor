import Foundation

/// The seam between a `ProjectModel` and whatever owns persistence. In PR 4 this is backed by
/// the `ReferenceFileDocument` (commit writes the package values back; `registerChange`
/// registers one `UndoManager` action so the document goes dirty and autosaves). Keeping the
/// model behind two `@MainActor` closures means every phase/commit/dirtiness path is tested with
/// a recorder and never touches a document type (spec A2).
struct ProjectDocumentSink: Sendable {
  /// Writes new project values into the document. `plan`/`audio` are `nil` when unchanged (an
  /// editor content edit rewrites only `file`), non-nil on transcription/import/re-transcribe.
  var commit: @MainActor @Sendable (ProjectFile, EditPlan?, CanonicalAudioSource?) -> Void
  /// Marks the document dirty for the current change so NSDocument autosaves it (spec A7).
  var registerChange: @MainActor @Sendable () -> Void
}
