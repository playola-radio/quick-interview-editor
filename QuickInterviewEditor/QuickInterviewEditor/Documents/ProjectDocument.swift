import AppKit
import Foundation
import IssueReporting
import SwiftUI
import Synchronization
import UniformTypeIdentifiers

extension UTType {
  /// The `.pie` project package, exported from Info.plist (spec A2).
  static let pieProject = UTType(exportedAs: "fm.playola.interview-editor.project")
}

enum ProjectDocumentError: Error, Equatable, LocalizedError {
  case nothingToSave
  case missingPackageAudio

  var errorDescription: String? {
    switch self {
    case .nothingToSave: return "Import an audio file before saving the project."
    case .missingPackageAudio:
      return "The project's audio could not be found. Reopen the project and try again."
    }
  }
}

/// The `ReferenceFileDocument` behind every `.pie` window (spec A2/A3). Deliberately thin: it
/// holds the decoded values, hands them to a `ProjectModel` through a `ProjectDocumentSink`, and
/// turns the model's commits back into a package on save. The document system calls
/// `init(configuration:)`, `snapshot(contentType:)` and `fileWrapper(snapshot:configuration:)`
/// off the main thread (NSDocument saves asynchronously), so the saved values live behind a
/// lock rather than on the main actor.
@MainActor
final class ProjectDocument: ReferenceFileDocument {

  /// Everything a save needs, captured on the main actor and handed to the background write.
  struct Content: Equatable, Sendable {
    var file: ProjectFile
    var plan: EditPlan
    var audio: CanonicalAudioSource
    var recoveryArchive: Data?
  }

  /// The value `snapshot` hands to `fileWrapper`: the content to write plus the edit
  /// generation it reflects. Carrying the generation on the snapshot (rather than through
  /// shared document state) keeps overlapping save pipelines honest — a completing save can
  /// only ever clear the indicator up to the generation it actually wrote.
  struct Snapshot: Sendable {
    var content: Content
    var editGeneration: Int
  }

  nonisolated static var readableContentTypes: [UTType] { [.pieProject] }

  /// `nil` for an untitled window until its first transcription commits. Written by main-actor
  /// commits, read by the document system's background save; the lock keeps both honest.
  nonisolated var content: Content? {
    get { latest.withLock { $0 } }
    set { latest.withLock { $0 = newValue } }
  }
  private nonisolated let latest = Mutex<Content?>(nil)
  /// The window's undo manager, supplied by `ProjectHostView` from the SwiftUI environment. It is
  /// the document system's own manager, so one registered action marks the document edited and
  /// schedules autosave (spec A7).
  weak var undoManager: UndoManager?

  /// The window's autosave indicator, supplied by `ProjectHostView`. `registerChange` marks it
  /// edited and the completed save pipeline clears it; `nil` outside a live window (e.g. codec
  /// tests) leaves the seams as no-ops.
  weak var saveStatus: SaveStatus?
  /// Bumped on the main actor for every dirtying change and read off the main actor by the save
  /// pipeline, so the generation a save captures is comparable to the latest edit.
  private nonisolated let editGeneration = Mutex(0)

  nonisolated init() {}

  nonisolated convenience init(configuration: ReadConfiguration) throws {
    try self.init(reading: configuration.file)
  }

  /// Decodes a package tree and checks the bundled audio's byte count against `project.json`
  /// (spec A4). A mismatch fails the open with the document system's alert (spec A9).
  nonisolated init(reading root: FileWrapper) throws {
    let decoded = try ProjectPackage.decode(root)
    try ProjectPackage.verifyAudio(decoded.audioWrapper, against: decoded.file.source)
    content = Content(
      file: decoded.file, plan: decoded.plan, audio: .packageChild(sessionCopy: nil),
      recoveryArchive: decoded.recoveryArchive)
  }

  nonisolated func snapshot(contentType: UTType) throws -> Snapshot {
    // Read the generation BEFORE the content (they live behind separate locks). This keeps the
    // captured generation older-or-equal to the content actually written, so a completing save
    // can never report a generation newer than what it wrote — the indicator errs toward
    // "Saving…" and never falsely clears to "Saved" if an edit lands mid-snapshot.
    let generation = editGeneration.withLock { $0 }
    guard let content else { throw ProjectDocumentError.nothingToSave }
    return Snapshot(content: content, editGeneration: generation)
  }

  nonisolated func fileWrapper(snapshot: Snapshot, configuration: WriteConfiguration) throws
    -> FileWrapper
  {
    let wrapper = try Self.makeFileWrapper(
      snapshot: snapshot.content, existingFile: configuration.existingFile)
    // Only a successfully built package clears the indicator, and only up to the generation
    // this save actually wrote; a throw leaves it "Saving…".
    let saved = snapshot.editGeneration
    Task { @MainActor [weak self] in self?.saveStatus?.markSaved(upToGeneration: saved) }
    return wrapper
  }

  /// Builds the package to write. Audio unchanged since the read reuses the on-disk package's
  /// own child wrapper so the AIFF is never re-serialized (spec A5); a save with nothing to reuse
  /// (Save As / Duplicate) falls back to the hydrated session copy, and freshly transcribed audio
  /// is wrapped lazily from the session store. Every path is refused when the audio's size no
  /// longer matches the recorded byte count, so a package can never be written whose
  /// `project.json` disagrees with its audio.
  nonisolated static func makeFileWrapper(snapshot: Content, existingFile: FileWrapper?) throws
    -> FileWrapper
  {
    var snapshot = snapshot
    snapshot.file.schemaVersion = ProjectFile.currentSchemaVersion
    let audio: FileWrapper
    switch snapshot.audio {
    case .packageChild(let sessionCopy):
      if let existingFile,
        let existing = existingFile.fileWrappers?["audio"]?.fileWrappers?["canonical.aiff"],
        existing.isRegularFile
      {
        try ProjectPackage.verifyAudio(existing, against: snapshot.file.source)
        return try ProjectPackage.rewriteMetadata(
          in: existingFile, file: snapshot.file, plan: snapshot.plan,
          recoveryArchive: snapshot.recoveryArchive)
      }
      guard let sessionCopy else { throw ProjectDocumentError.missingPackageAudio }
      audio = try sessionAudioWrapper(at: sessionCopy, source: snapshot.file.source)
    case .sessionFile(let url):
      audio = try sessionAudioWrapper(at: url, source: snapshot.file.source)
    }
    return try ProjectPackage.encode(
      file: snapshot.file, plan: snapshot.plan, audio: audio,
      recoveryArchive: snapshot.recoveryArchive)
  }

  private nonisolated static func sessionAudioWrapper(at url: URL, source: ProjectSource) throws
    -> FileWrapper
  {
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size == source.canonicalByteCount
    else {
      throw ProjectPackageError.audioMismatch
    }
    return try FileWrapper(url: url, options: [])
  }

  // MARK: - Model seam

  /// The sink a `ProjectModel` writes through: commits update the stored values; a registered
  /// change becomes one `UndoManager` action so NSDocument goes dirty and autosaves. The editor's
  /// own value-snapshot `UndoStack` stays the real undo history; this action is only the
  /// dirtiness signal (spec A7).
  var sink: ProjectDocumentSink {
    ProjectDocumentSink(
      commit: { [weak self] file, plan, audio in self?.commit(file, plan: plan, audio: audio) },
      commitRecovery: { [weak self] file, archive in self?.commitRecovery(file, archive: archive) },
      registerChange: { [weak self] in self?.registerChange() })
  }

  func registerChange() {
    let generation = editGeneration.withLock {
      $0 += 1
      return $0
    }
    saveStatus?.markEdited(generation: generation)
    guard let undoManager else { return }
    undoManager.levelsOfUndo = 1
    undoManager.registerUndo(withTarget: self) { _ in }
    // NSUndoManager closes the implicit per-event group (which is what marks the document
    // edited) only when AppKit finishes dispatching an event. A change committed from a task
    // continuation would otherwise stay in an open group, and the window clean, until the next
    // mouse or key event; a no-op event closes it now.
    if let nudge = NSEvent.otherEvent(
      with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
      context: nil, subtype: 0, data1: 0, data2: 0)
    {
      NSApp?.postEvent(nudge, atStart: false)
    }
  }

  private func commitRecovery(_ file: ProjectFile, archive: Data?) {
    latest.withLock { content in
      guard content != nil else { return }
      content?.file = file
      content?.recoveryArchive = archive
    }
  }

  private func commit(_ file: ProjectFile, plan: EditPlan?, audio: CanonicalAudioSource?) {
    if var content {
      content.file = file
      if let plan { content.plan = plan }
      if let audio { content.audio = audio }
      self.content = content
    } else {
      guard let plan, let audio else {
        reportIssue("First commit to an empty project must carry a plan and audio")
        return
      }
      content = Content(file: file, plan: plan, audio: audio)
    }
  }
}
