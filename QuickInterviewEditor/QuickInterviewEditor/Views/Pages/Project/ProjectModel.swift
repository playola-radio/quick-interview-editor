import Dependencies
import Foundation
import IssueReporting
import Observation
import Sharing
import UniformTypeIdentifiers

/// The document-level model for one `.pie` project window (spec A2/A3). It owns the phase state
/// machine, drives transcription through the shared `TranscriptionQueueClient`, builds the
/// `EditorModel` on completion or on open (hydrating the package's audio into a session copy),
/// and pushes every document change into a `ProjectDocumentSink`.
@MainActor
@Observable
final class ProjectModel: ViewModel {

  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.transcriptionQueue) var transcriptionQueue
  @ObservationIgnored @Dependency(\.canonicalAudioStore) var canonicalAudioStore
  @ObservationIgnored @Dependency(\.engineFingerprint) var engineFingerprint
  @ObservationIgnored @Dependency(\.continuousClock) var clock
  @ObservationIgnored @Dependency(\.date) var date

  // MARK: - Initialization
  @ObservationIgnored private let sink: ProjectDocumentSink
  /// The project's serialized values. `nil` for a fresh untitled window (import fills it); a
  /// decoded package supplies it and `viewAppeared` builds the editor from `content`.
  @ObservationIgnored private var file: ProjectFile?
  @ObservationIgnored private var loadedPlan: EditPlan?
  @ObservationIgnored private var loadedAudio: CanonicalAudioSource?
  /// Where the opened package lives on disk; hydration reads `audio/canonical.aiff` from it.
  /// `nil` for an untitled window.
  @ObservationIgnored private let packageURL: URL?

  init(
    file: ProjectFile?, plan: EditPlan?, audio: CanonicalAudioSource?, packageURL: URL? = nil,
    sink: ProjectDocumentSink
  ) {
    self.sink = sink
    self.file = file
    self.loadedPlan = plan
    self.loadedAudio = audio
    self.packageURL = packageURL
    self.phase = file == nil ? .empty : .queued
    super.init()
  }

  // MARK: - Phase
  enum Phase: Equatable {
    case empty  // untitled, no audio imported yet
    case queued  // waiting for a transcription slot, or a decoded package waiting to hydrate
    case transcribing(EngineProgress?)  // nil until the engine reports its first phase
    case loaded
    case failed(String)
  }

  // MARK: - Properties
  var phase: Phase
  var editor: EditorModel?
  var isImporterPresented = false
  private var maxFraction: Double?
  private var elapsedSeconds: Double = 0
  /// The engine phase identity currently on screen — index plus raw name. A change in either
  /// resets the monotonic clamp (a new phase starts its own 0–100%); the index alone also lets
  /// us ignore a late event from an earlier phase.
  private var currentPhaseIndex: Int?
  private var currentPhaseName: String?
  /// `elapsedSeconds` at the moment the current phase began, so the ETA measures time spent in
  /// THIS phase (transcribe and align run at very different rates).
  private var phaseStartElapsed: Double = 0
  /// The source audio imported in this window during this session; re-import and retry re-run
  /// it. A project opened from disk has none until PR 5 re-transcribes from the bundled AIFF.
  @ObservationIgnored private(set) var sourceURL: URL?
  @ObservationIgnored private(set) var transcriptionTask: Task<Void, Never>?
  @ObservationIgnored private var tickTask: Task<Void, Never>?

  // MARK: - Display Text
  let emptyStateTitle = "Drop an audio clip to transcribe"
  let emptyStateSubtitle = "Drag a file here, or choose one to open."
  let importButtonLabel = "Open Audio File…"
  let reimportMenuLabel = "Re-import (Ignore Cache)"
  let cancelButtonLabel = "Cancel"
  let retryButtonLabel = "Retry"
  let startingMessage = "Starting…"
  let queuedMessage = "Waiting to transcribe…"
  let progressNote = "This can take several minutes — longer files take longer."
  let missingCanonicalAudioMessage =
    "Transcription finished but its audio file is missing. Try importing again."
  let missingPackageMessage =
    "This project has no saved location to load its audio from. Reopen it from its .pie file."

  // MARK: - View Helpers
  var showsEmptyState: Bool { phase == .empty }
  var showsProgress: Bool {
    switch phase {
    case .queued, .transcribing: return true
    case .empty, .loaded, .failed: return false
    }
  }
  var showsEditor: Bool { phase == .loaded }
  var showsError: Bool { errorMessage != nil }
  /// Only a run started in this window can be cancelled; hydrating an opened package can't.
  var showsCancel: Bool {
    guard showsProgress, let transcriptionTask else { return false }
    return !transcriptionTask.isCancelled
  }
  var isLoaded: Bool { phase == .loaded }
  /// Only a source imported in this session can be re-transcribed; a project opened from disk
  /// re-transcribes from its bundled AIFF in PR 5.
  var canReimport: Bool { isLoaded && sourceURL != nil }
  /// A drop or open replaces nothing: only an empty or failed window takes new audio.
  var acceptsImport: Bool {
    switch phase {
    case .empty, .failed: return true
    case .queued, .transcribing, .loaded: return false
    }
  }
  var errorMessage: String? {
    if case .failed(let message) = phase { return message }
    return nil
  }
  /// The one-line progress headline: "Phase X of N · <label> · NN%". The phase-of-N prefix
  /// appears only when the engine declared it; the percent only when the phase is determinate.
  var progressHeadline: String {
    switch phase {
    case .queued: return queuedMessage
    case .transcribing(let progress):
      guard let progress else { return startingMessage }
      return Self.headline(for: progress, fraction: progressFraction)
    case .empty, .loaded, .failed: return ""
    }
  }
  static func headline(for progress: EngineProgress, fraction: Double?) -> String {
    var parts: [String] = []
    if let phaseOfN = progress.phaseOfNText { parts.append(phaseOfN) }
    parts.append(progress.displayText)
    if let fraction { parts.append("\(Int(fraction * 100))%") }
    return parts.joined(separator: " · ")
  }
  var progressFraction: Double? {
    guard case .transcribing = phase else { return nil }
    return maxFraction  // nil for an indeterminate phase (e.g. Finalizing)
  }
  var isProgressDeterminate: Bool { progressFraction != nil }
  var determinateValue: Double { maxFraction ?? 0 }
  /// A per-phase estimate: time remaining *in this phase*, from time already spent in it and
  /// the phase fraction. Held back until the phase has run a bit so it doesn't jump around.
  static func phaseETAText(phaseElapsedSeconds: Double, fraction: Double) -> String? {
    guard phaseElapsedSeconds >= 30, fraction >= 0.05 else { return nil }
    let remaining = phaseElapsedSeconds * (1 - fraction) / fraction
    if remaining < 60 { return "Less than a minute left in this phase" }
    let minutes = Int((remaining / 60).rounded())
    return "About \(max(minutes, 1)) min left in this phase"
  }
  var etaMessage: String? {
    guard let fraction = progressFraction else { return nil }
    return Self.phaseETAText(
      phaseElapsedSeconds: elapsedSeconds - phaseStartElapsed, fraction: fraction)
  }

  // MARK: - User Actions
  func importButtonTapped() { isImporterPresented = true }

  func filePicked(_ url: URL) {
    guard acceptsImport else { return }
    beginTranscription(of: url, policy: .useCache)
  }

  /// Surface (don't swallow) an open-panel failure.
  func filePickFailed(_ error: Error) {
    reportIssue("Audio import failed: \(error.localizedDescription)")
  }

  /// A drop can carry anything; the first audio file wins (one project per window). Returns
  /// whether the drop was taken so the view can report it to the drag session.
  func fileDropped(_ urls: [URL]) -> Bool {
    guard acceptsImport, let url = urls.first(where: Self.isAudioFile) else { return false }
    beginTranscription(of: url, policy: .useCache)
    return true
  }

  /// Imports a source audio file and waits for the run to finish (the view-facing entry points
  /// above start the same run without waiting).
  func importAudioTapped(_ url: URL) async {
    await beginTranscription(of: url, policy: .useCache).value
  }

  /// Abandons the running transcription. An untitled window returns to its empty state; a
  /// window that already had a project keeps it and offers Retry.
  func cancelTranscriptionTapped() {
    // The task reference is kept so the next import awaits its unwinding (see
    // `beginTranscription`); only the cancelled flag changes.
    transcriptionTask?.cancel()
    stopTicking()
    phase = file == nil ? .empty : .failed("Transcription cancelled.")
  }

  /// Re-runs whatever failed: the last import in this session, or the hydration of an opened
  /// package.
  func retryTapped() async {
    if let sourceURL {
      await beginTranscription(of: sourceURL, policy: .useCache).value
    } else if file != nil {
      phase = .queued
      await hydrate()
    }
  }

  /// Re-transcribes this session's source ignoring any cached result, overwriting the entry.
  func reimportIgnoringCacheTapped() async {
    guard canReimport, let sourceURL else { return }
    await beginTranscription(of: sourceURL, policy: .forceFresh).value
  }

  /// For a window opened from a decoded package: hydrates the audio and builds the editor.
  func viewAppeared() async {
    guard case .queued = phase, file != nil else { return }
    await hydrate()
  }

  /// The window is closing: stop any transcription and release the editor's playback, export,
  /// and session audio.
  func viewDisappeared() async {
    transcriptionTask?.cancel()
    stopTicking()
    await transcriptionTask?.value
    await tearDownEditor()
    releaseSessionAudio(loadedAudio)
  }

  // MARK: - Private Helpers
  private static func isAudioFile(_ url: URL) -> Bool {
    guard url.isFileURL else { return false }
    return UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) ?? false
  }

  /// Starts one transcription run as a stored task so Cancel and window close can stop it. A
  /// run already in flight is cancelled and allowed to unwind first, so teardown never races.
  @discardableResult
  private func beginTranscription(of url: URL, policy: CachePolicy) -> Task<Void, Never> {
    let previous = transcriptionTask
    previous?.cancel()
    let task = Task { [weak self] in
      await previous?.value
      await self?.transcribe(url, policy: policy)
    }
    transcriptionTask = task
    return task
  }

  private func transcribe(_ url: URL, policy: CachePolicy) async {
    await tearDownEditor()
    guard !Task.isCancelled else { return }
    sourceURL = url
    resetProgress()
    phase = .queued
    // Content-hash the source once (off-main) BEFORE the engine reads it, so the cache keys to
    // the bytes we're actually transcribing. Falls back to the path if unreadable.
    let fingerprint = await SourceFingerprint.make(for: url)
    guard !Task.isCancelled else { return }
    let seed = documentSeed(fingerprint: fingerprint)
    let job = TranscriptionJob(source: url, sourceFingerprint: fingerprint, policy: policy)
    let events = await transcriptionQueue.enqueue(job)
    guard !Task.isCancelled else { return }
    phase = .transcribing(nil)
    startTicking()
    defer { stopTicking() }
    do {
      for try await event in events {
        switch event {
        case .progress(let progress):
          applyProgress(progress)
        case .completed(let result):
          loadCompletedTranscription(result, url: url, fingerprint: fingerprint, seed: seed)
        }
      }
    } catch is CancellationError {
      return  // cancel/close already decided the phase; leave the last progress alone
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  private func loadCompletedTranscription(
    _ result: TranscriptionResult, url: URL, fingerprint: String, seed: EditorDocumentState
  ) {
    // The package records the canonical AIFF's size so a later open can refuse audio that was
    // truncated or swapped (ProjectPackage.verifyAudio). Read it from the file system, never by
    // loading the (potentially multi-GB) file.
    guard
      let byteCount = try? result.canonicalAudioURL.resourceValues(forKeys: [.fileSizeKey])
        .fileSize
    else {
      phase = .failed(missingCanonicalAudioMessage)
      return
    }
    let editor = buildEditor(
      sourceURL: url, canonicalAudioURL: result.canonicalAudioURL, editPlan: result.editPlan,
      fingerprint: fingerprint, seed: seed)
    let newFile = makeProjectFile(
      url: url, fingerprint: fingerprint, editPlan: result.editPlan,
      canonicalByteCount: byteCount, content: editor.documentState)
    let replacedAudio = loadedAudio
    self.editor = editor
    file = newFile
    loadedPlan = result.editPlan
    loadedAudio = .sessionFile(result.canonicalAudioURL)
    wireEditor(editor)
    phase = .loaded
    sink.commit(newFile, result.editPlan, .sessionFile(result.canonicalAudioURL))
    // A completed transcription is the first thing worth keeping (spec A7): an untitled window
    // must go dirty here so closing it asks to save and autosave arms.
    sink.registerChange()
    // Only now is the previous session audio unreferenced by the document (spec A5: re-transcribe
    // replaces plan + audio in one commit). Releasing it any earlier would leave a failed or
    // cancelled run pointing a save at a deleted file.
    if replacedAudio?.sessionURL != result.canonicalAudioURL {
      releaseSessionAudio(replacedAudio)
    }
  }

  /// Builds the editor for an opened package. Audio still inside the package is first cloned
  /// into a session dir (the one place the package is read by URL, spec A5) and the clone is
  /// committed so a later Save As can bundle it; a session copy that already exists (retry, or
  /// an import earlier this session) is used as is. Hydration never marks the document dirty.
  private func hydrate() async {
    guard let file, let plan = loadedPlan, let loadedAudio else { return }
    let canonicalAudioURL: URL
    switch loadedAudio {
    case .sessionFile(let url), .packageChild(sessionCopy: let url?):
      canonicalAudioURL = url
    case .packageChild(sessionCopy: nil):
      guard let packageURL else {
        phase = .failed(missingPackageMessage)
        return
      }
      do {
        let clone = try await canonicalAudioStore.clone(
          packageURL.appendingPathComponent("audio/\(CanonicalAudioStore.fileName)"))
        // The window may have closed while the copy ran; the clone is derived data, so drop it
        // rather than leave a multi-GB orphan in the session store.
        guard !Task.isCancelled else {
          canonicalAudioStore.remove(clone)
          return
        }
        // The package was verified at open, but it is read again by path here; refuse a copy
        // whose size no longer matches `project.json` (the package changed in between).
        guard
          try clone.resourceValues(forKeys: [.fileSizeKey]).fileSize
            == file.source.canonicalByteCount
        else {
          canonicalAudioStore.remove(clone)
          throw ProjectPackageError.audioMismatch
        }
        canonicalAudioURL = clone
        self.loadedAudio = .packageChild(sessionCopy: clone)
        sink.commit(file, nil, .packageChild(sessionCopy: clone))
      } catch {
        phase = .failed("Couldn't load the project's audio: \(error.localizedDescription)")
        return
      }
    }
    let editor = buildEditor(
      sourceURL: URL(fileURLWithPath: file.source.originalFileName),
      canonicalAudioURL: canonicalAudioURL, editPlan: plan,
      fingerprint: file.source.originalFingerprint, seed: file.content)
    self.editor = editor
    wireEditor(editor)
    phase = .loaded
  }

  /// The document a new editor starts from. Re-running the same source (retry, re-import) keeps
  /// the project's current content — the sidecar is stale the moment the document diverges from
  /// it. Only a source this window has never held is seeded from the sidecar.
  private func documentSeed(fingerprint: String) -> EditorDocumentState {
    if let file, file.source.originalFingerprint == fingerprint {
      return file.content
    }
    return migrationSeed(fingerprint: fingerprint)
  }

  /// Seeds the editor's document from the legacy per-file `.projectState` sidecar, once, on
  /// import (spec A8 migration). A pure read: the sidecar is never written or deleted from here.
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

  /// Every document change the editor funnels through `mutateDocument` rewrites the project
  /// file's content and commits it, then registers dirtiness — the one signal the document
  /// autosaves on. The commit carries `nil` plan/audio because a content edit never touches
  /// those. Diffing discipline is the editor's: it only fires for a real post-init change.
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
    url: URL, fingerprint: String, editPlan: EditPlan, canonicalByteCount: Int,
    content: EditorDocumentState
  ) -> ProjectFile {
    ProjectFile(
      schemaVersion: ProjectFile.currentSchemaVersion,
      source: ProjectSource(
        originalFileName: url.lastPathComponent,
        originalPath: url.path,
        originalFingerprint: fingerprint,
        // canonicalFingerprint is computed on the bundled AIFF in PR 5 (Task 5.1), where it
        // keys the re-transcribe cache; empty until then.
        canonicalFingerprint: "",
        canonicalByteCount: canonicalByteCount,
        // The `.pie` package stores whole seconds only; floor here so the committed
        // in-memory `ProjectFile` matches what reopening the saved package yields
        // (ProjectPackage precision contract).
        importedAt: Date(timeIntervalSince1970: date.now.timeIntervalSince1970.rounded(.down)),
        sampleRate: editPlan.source.sampleRate,
        channels: editPlan.source.channels,
        durationSamples: editPlan.source.durationSamples),
      engine: ProjectEngineInfo(engineFingerprint: engineFingerprint.current()),
      content: content)
  }

  /// Applies one engine progress event to the on-screen state. Resets the monotonic clamp and
  /// the per-phase timer when the phase moves forward, ignores a late event from an earlier
  /// phase, and clamps the fraction so the bar never jumps backward within a phase.
  private func applyProgress(_ progress: EngineProgress) {
    // Normalize first: a malformed index (e.g. 999-of-3) becomes nil so it can never pin the
    // phase high and make every real later phase look stale.
    let incomingIndex = progress.validPhaseIndex
    if let incoming = incomingIndex, let current = currentPhaseIndex, incoming < current {
      return  // stale event from an earlier phase — keep the newer phase on screen
    }
    if incomingIndex != currentPhaseIndex || progress.phase != currentPhaseName {
      currentPhaseIndex = incomingIndex
      currentPhaseName = progress.phase
      maxFraction = nil
      phaseStartElapsed = elapsedSeconds
    }
    if let fraction = progress.fraction {
      maxFraction = max(maxFraction ?? 0, fraction)
    }
    phase = .transcribing(progress)
  }

  private func resetProgress() {
    maxFraction = nil
    currentPhaseIndex = nil
    currentPhaseName = nil
    phaseStartElapsed = 0
    elapsedSeconds = 0
  }

  private func startTicking() {
    tickTask?.cancel()
    tickTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        try? await self.clock.sleep(for: .seconds(1))
        guard !Task.isCancelled else { return }
        self.elapsedSeconds += 1
      }
    }
  }

  private func stopTicking() {
    tickTask?.cancel()
    tickTask = nil
  }

  /// Cancel export, stop playback, and let the cancelled render unwind — so a re-import or window
  /// close never leaves stale playback or export work running. The session audio is deliberately
  /// not released here: the document keeps referencing it until a replacement is committed
  /// (`loadCompletedTranscription`) or the window closes (`viewDisappeared`).
  private func tearDownEditor() async {
    if let previous = editor {
      previous.cancelExportTapped()
      await previous.stopPlaybackTapped()
      await previous.awaitExportTeardown()
    }
    editor = nil
  }

  /// Deletes a session copy of the canonical AIFF (derived data, rebuildable by re-transcribing).
  /// Only safe once no editor is playing or rendering from it (`tearDownEditor`) and the document
  /// no longer points a save at it.
  private func releaseSessionAudio(_ source: CanonicalAudioSource?) {
    guard let url = source?.sessionURL else { return }
    canonicalAudioStore.remove(url)
  }
}
