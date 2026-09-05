import Dependencies
import Foundation
import Observation
import Sharing

/// The document-level model for one `.pie` project window (spec A2/A3). It owns the phase state
/// machine, drives transcription through the shared `TranscriptionQueueClient`, builds the
/// `EditorModel` on completion, and pushes every document change into a `ProjectDocumentSink`.
/// It is the successor to `SongTabModel`: the phase logic, `withDependencies(from:)` editor
/// construction, and teardown sequence are ported from it. Until PR 4 hosts this in a
/// `DocumentGroup`, the app still runs under `RootModel`/`SongTabModel` — this model is wired and
/// tested but not yet on screen.
@MainActor
@Observable
final class ProjectModel: ViewModel {

  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.transcriptionQueue) var transcriptionQueue
  @ObservationIgnored @Dependency(\.engineFingerprint) var engineFingerprint
  @ObservationIgnored @Dependency(\.date) var date

  // MARK: - Initialization
  @ObservationIgnored private let sink: ProjectDocumentSink
  /// The project's serialized values. `nil` for a fresh untitled window (import fills it); a
  /// decoded package supplies it and `viewAppeared` builds the editor from `content`.
  @ObservationIgnored private var file: ProjectFile?
  @ObservationIgnored private var loadedPlan: EditPlan?
  @ObservationIgnored private var loadedAudio: CanonicalAudioSource?

  init(
    file: ProjectFile?, plan: EditPlan?, audio: CanonicalAudioSource?, sink: ProjectDocumentSink
  ) {
    self.sink = sink
    self.file = file
    self.loadedPlan = plan
    self.loadedAudio = audio
    self.phase = file == nil ? .empty : .queued
    super.init()
  }

  // MARK: - Phase
  enum Phase: Equatable {
    case empty  // untitled, no audio imported yet
    case queued  // a decoded package waiting for `viewAppeared` to build its editor
    case transcribing(Double)  // fraction of the current engine phase (0 when indeterminate)
    case loaded
    case failed(String)
  }

  // MARK: - Properties
  var phase: Phase
  var editor: EditorModel?

  // MARK: - User Actions
  /// Imports a source audio file into a fresh window: tears down any prior editor, seeds from the
  /// legacy sidecar once (migration), enqueues transcription behind the shared cap, drives the
  /// phase, and on completion builds the editor and commits the new package values.
  func importAudioTapped(_ url: URL) async {
    await tearDownEditor()
    phase = .queued
    let fingerprint = await SourceFingerprint.make(for: url)
    let seed = migrationSeed(fingerprint: fingerprint)
    phase = .transcribing(0)
    let job = TranscriptionJob(source: url, sourceFingerprint: fingerprint, policy: .useCache)
    do {
      for try await event in await transcriptionQueue.enqueue(job) {
        switch event {
        case .progress(let progress):
          if let fraction = progress.fraction { phase = .transcribing(fraction) }
        case .completed(let result):
          loadCompletedTranscription(result, url: url, fingerprint: fingerprint, seed: seed)
        }
      }
    } catch is CancellationError {
      return
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  /// For a window opened from a decoded package: builds the editor from the stored content. Real
  /// audio hydration (cloning `audio/canonical.aiff` into a session store) lands in PR 5; here it
  /// builds against the committed session source, so a `.packageChild` project waits for PR 5.
  func viewAppeared() async {
    guard case .queued = phase, let file, let plan = loadedPlan,
      case .sessionFile(let url)? = loadedAudio
    else { return }
    let editor = buildEditor(
      sourceURL: URL(fileURLWithPath: file.source.originalFileName),
      canonicalAudioURL: url, editPlan: plan,
      fingerprint: file.source.originalFingerprint, seed: file.content)
    self.editor = editor
    wireEditor(editor)
    phase = .loaded
  }

  // MARK: - Private Helpers
  private func loadCompletedTranscription(
    _ result: TranscriptionResult, url: URL, fingerprint: String, seed: EditorDocumentState
  ) {
    let editor = buildEditor(
      sourceURL: url, canonicalAudioURL: result.canonicalAudioURL, editPlan: result.editPlan,
      fingerprint: fingerprint, seed: seed)
    let newFile = makeProjectFile(
      url: url, fingerprint: fingerprint, editPlan: result.editPlan, content: editor.documentState)
    self.editor = editor
    file = newFile
    wireEditor(editor)
    phase = .loaded
    sink.commit(newFile, result.editPlan, .sessionFile(result.canonicalAudioURL))
  }

  /// Seeds the editor's document from the legacy per-file `.projectState` sidecar, once, on import
  /// (spec A8 migration). A pure read: the sidecar is never written or deleted from here.
  private func migrationSeed(fingerprint: String) -> EditorDocumentState {
    @Shared(.projectState(fingerprint: fingerprint)) var projectState = ProjectState()
    return EditorDocumentState(
      slices: [],
      timelineRemovals: projectState.timelineRemovals,
      cutSuggestions: projectState.cutSuggestions,
      speakerCountOverride: projectState.speakerCountOverride,
      speakerDisplayNames: projectState.speakerDisplayNames)
  }

  private func buildEditor(
    sourceURL: URL, canonicalAudioURL: URL, editPlan: EditPlan, fingerprint: String,
    seed: EditorDocumentState
  ) -> EditorModel {
    withDependencies(from: self) {
      EditorModel(
        sourceURL: sourceURL, canonicalAudioURL: canonicalAudioURL, editPlan: editPlan,
        sourceFingerprint: fingerprint, initialDocument: seed)
    }
  }

  /// Every document change the editor funnels through `mutateDocument` rewrites the project file's
  /// content and commits it, then registers dirtiness — the one signal PR 4's document autosaves
  /// on. The commit carries `nil` plan/audio because a content edit never touches those. Diffing
  /// discipline is the editor's: it only fires this callback for a real post-init change.
  private func wireEditor(_ editor: EditorModel) {
    editor.onDocumentStateChanged = { [weak self] state in
      guard let self, var file = self.file else { return }
      file.content = state
      self.file = file
      self.sink.commit(file, nil, nil)
      self.sink.registerChange()
    }
  }

  private func makeProjectFile(
    url: URL, fingerprint: String, editPlan: EditPlan, content: EditorDocumentState
  ) -> ProjectFile {
    ProjectFile(
      schemaVersion: ProjectFile.currentSchemaVersion,
      source: ProjectSource(
        originalFileName: url.lastPathComponent,
        originalPath: url.path,
        originalFingerprint: fingerprint,
        // canonicalFingerprint / canonicalByteCount are computed on the bundled AIFF in PR 5
        // (Task 5.1), where they key the re-transcribe cache; empty until then.
        canonicalFingerprint: "",
        canonicalByteCount: 0,
        importedAt: date.now,
        sampleRate: editPlan.source.sampleRate,
        channels: editPlan.source.channels,
        durationSamples: editPlan.source.durationSamples),
      engine: ProjectEngineInfo(engineFingerprint: engineFingerprint.current()),
      content: content)
  }

  /// Teardown copied verbatim from `SongTabModel`: cancel export, stop playback, let the cancelled
  /// render unwind, then release the canonical AIFF — so a re-import never leaves stale playback or
  /// export work running, or an orphaned canonical file.
  private func tearDownEditor() async {
    if let previous = editor {
      previous.cancelExportTapped()
      await previous.stopPlaybackTapped()
      await previous.awaitExportTeardown()
      previous.discardCanonicalAudio()
    }
    editor = nil
  }
}
