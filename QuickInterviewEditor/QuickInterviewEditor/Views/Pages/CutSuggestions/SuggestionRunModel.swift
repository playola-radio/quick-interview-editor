import Dependencies
import Foundation
import Observation

@MainActor
@Observable
final class SuggestionRunModel: ViewModel {
  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.cutSuggest) var cutSuggest
  @ObservationIgnored @Dependency(\.suggestionRecovery) var recovery
  @ObservationIgnored @Dependency(\.suggestionConfiguration) var configuration
  @ObservationIgnored @Dependency(\.uuid) var uuid

  // MARK: - Initialization
  init(editPlan: EditPlan, sourceFingerprint: String, options: CutSuggestOptions = .init()) {
    self.editPlan = editPlan
    self.sourceFingerprint = sourceFingerprint
    self.options = options
    makeRequest = { snapshot, mode, directory in
      CutSuggestRequest(
        transcriptUnits: editPlan.transcriptUnits, diarization: nil,
        productSpecs: ProductSpec.defaults,
        options: CutSuggestOptions(
          model: snapshot.model, promptVersion: snapshot.discoveryPromptVersion,
          productSpecVersion: snapshot.productSpecVersion, stage1Window: snapshot.stage1Window,
          stage1Step: snapshot.stage1Step),
        transcriptHash: snapshot.transcriptHash, sourceFingerprint: snapshot.sourceFingerprint,
        sampleRate: snapshot.sampleRate, snapshot: snapshot, mode: mode, journalDirectory: directory
      )
    }
    super.init()
  }

  // MARK: - Properties
  let editPlan: EditPlan
  let sourceFingerprint: String
  let options: CutSuggestOptions
  var phase: SuggestionRunPhase = .idle
  private(set) var activeRunID: UUID?
  private(set) var activeAttemptID: UUID?
  var diagnostic: String?
  var ownershipBlocked = false
  var staleDiscardAvailable = false
  var automaticEnabled = true
  var numberingEntries: [SuggestionNumberingEntry] = []
  @ObservationIgnored var currentDocument: @MainActor () -> EditorDocumentState = { .init() }
  @ObservationIgnored var currentOwner: @MainActor () -> SuggestionRecoveryOwner? = { nil }
  @ObservationIgnored var makeRequest:
    @MainActor (SuggestionRunSnapshot, SuggestionSearchMode, URL?) -> CutSuggestRequest
  @ObservationIgnored var prepare: @MainActor (SuggestionRecoveryPreparation) async throws -> URL =
    { _ in
      throw SuggestionRecoveryError.missingRun
    }
  @ObservationIgnored var onCheckpoint: @MainActor (SuggestionRecoveryCapture) throws -> Void = {
    _ in
    throw SuggestionRecoveryError.missingRun
  }
  @ObservationIgnored var onApply: @MainActor ([CutSuggestion], SuggestionBatch) throws -> Void = {
    _, _ in
    throw SuggestionRecoveryError.missingRun
  }
  @ObservationIgnored var onDiscard: @MainActor () async throws -> Void = {
    throw SuggestionRecoveryError.missingRun
  }
  @ObservationIgnored var resolveAPIKey: @MainActor () -> String? = { nil }
  @ObservationIgnored var onMissingAPIKey: @MainActor () -> Void = {}
  @ObservationIgnored var onExplicitStart: @MainActor () -> Void = {}
  @ObservationIgnored private var attemptTask: Task<Void, Never>?
  @ObservationIgnored private var stopTask: Task<Void, Never>?
  @ObservationIgnored private var attemptOwner: SuggestionRecoveryOwner?
  @ObservationIgnored private var acceptingConfirmation = false
  @ObservationIgnored private var confirmation: Confirmation?
  private enum Confirmation {
    case fresh
    case resume(UUID, SuggestionRunPhase)
  }

  // MARK: - View Helpers
  let replaceTitle = "Replace existing suggestions?"
  let replaceMessage =
    "This will run a new search and replace the current suggestions. Your saved clips will not be changed."
  let replaceButtonTitle = "Replace Suggestions"
  let cancelButtonTitle = "Cancel"
  let resumeButtonTitle = "Resume Search"
  let discardButtonTitle = "Discard Search"
  let applyNumberingTitle = "Apply Numbering"
  let numberingTitle = "Choose starting numbers"
  let noResultsMessage = "The search completed with no suggestions."
  var isRunning: Bool { activeAttemptID != nil }
  var candidatesLocked: Bool {
    if case .needsNumbering = phase { return true }
    return isRunning || stopTask != nil || ownershipBlocked
  }
  var canStart: Bool {
    !ownershipBlocked && !isRunning && stopTask == nil
      && currentDocument().unfinishedSuggestionRun == nil
      && confirmation == nil
  }
  var canResume: Bool {
    !ownershipBlocked && !isRunning && stopTask == nil
      && currentDocument().unfinishedSuggestionRun != nil
      && confirmation == nil
  }
  var canDiscard: Bool {
    !isRunning && stopTask == nil && (canResume || staleDiscardAvailable)
  }
  var showsNumbering: Bool {
    if case .needsNumbering = phase { return true }
    return false
  }
  var isConfirmingReplacement: Bool {
    get {
      if case .confirmingReplacement = phase { return true }
      return false
    }
    set { if !newValue, confirmation != nil, !acceptingConfirmation { cancelReplacementTapped() } }
  }
  var message: String? {
    switch phase {
    case .idle, .confirmingReplacement: nil
    case .running(_, let message), .paused(_, let message), .needsRetry(_, let message),
      .needsNumbering(_, let message), .failed(let message):
      message
    }
  }

  // MARK: - User Actions
  func suggestTapped() async {
    guard canStart else { return }
    guard resolveAPIKey() != nil else {
      onMissingAPIKey()
      return
    }
    if !currentDocument().cutSuggestions.isEmpty {
      let runID = uuid()
      await perform(runID: runID) { attemptID in
        _ = try await self.validConfiguration()
        try self.check(runID, attemptID)
        self.confirmation = .fresh
        self.phase = .confirmingReplacement
      }
      return
    }
    await startFresh(mode: .fresh)
  }

  func automaticSearchIfNeeded() async {
    guard canStart, automaticEnabled, currentDocument().cutSuggestions.isEmpty,
      resolveAPIKey() != nil
    else { return }
    await startFresh(mode: .automatic)
  }

  func replacementButtonTapped() {
    acceptingConfirmation = true
    Task { await replaceConfirmed() }
  }

  func replaceConfirmed() async {
    acceptingConfirmation = false
    guard let target = confirmation, !ownershipBlocked else { return }
    confirmation = nil
    switch target {
    case .fresh: await startFresh(mode: .fresh)
    case .resume(let runID, _): await startResume(runID: runID, replaceBaseline: true)
    }
  }

  func cancelReplacementTapped() {
    if case .resume(_, let previous) = confirmation { phase = previous } else { phase = .idle }
    confirmation = nil
  }

  func cancelSearchTapped() {
    invalidateAttempt()
    beginStop(publish: true)
  }

  func invalidateAttempt() {
    activeAttemptID = nil
    attemptTask?.cancel()
  }

  func stopForOwnershipTransition() async {
    invalidateAttempt()
    beginStop(publish: false)
    await stopTask?.value
  }

  func waitUntilStopped() async { await stopTask?.value }

  func resumeTapped() async {
    guard canResume, let checkpoint = currentDocument().unfinishedSuggestionRun else { return }
    await startResume(runID: checkpoint.snapshot.runID, replaceBaseline: false)
  }

  func discardSearchTapped() async {
    cancelSearchTapped()
    await stopTask?.value
    activeRunID = nil
    confirmation = nil
    do {
      try await onDiscard()
      guard !Task.isCancelled, activeRunID == nil else { return }
      synchronizeDocument()
    } catch { phase = .failed(message: error.localizedDescription) }
  }

  func applyNumberingTapped(_ starts: SuggestionStarts) async {
    guard canResume, showsNumbering, let checkpoint = currentDocument().unfinishedSuggestionRun
    else { return }
    let runID = checkpoint.snapshot.runID
    await perform(runID: runID) { attemptID in
      let capture = try await self.readCapture(runID, attemptID: attemptID)
      _ = try self.number(capture.checkpoint, starts: starts)
      let updated = try await self.writeControl(
        capture, attemptID: attemptID, starts: starts, paused: false)
      try self.apply(updated.checkpoint, attemptID: attemptID, automatic: false)
    }
  }

  func numberingApplyTapped() async {
    var starts = currentDocument().unfinishedSuggestionRun?.proposedStarts ?? .init()
    starts.groups = []
    for entry in numberingEntries {
      starts.types[entry.id] = .init(number: entry.number, isExplicit: true)
    }
    await applyNumberingTapped(starts)
  }

  func synchronizeDocument() {
    guard !isRunning, stopTask == nil, confirmation == nil else { return }
    guard let checkpoint = currentDocument().unfinishedSuggestionRun else {
      activeRunID = nil
      phase = .idle
      return
    }
    if activeRunID == checkpoint.snapshot.runID {
      switch phase {
      case .needsNumbering, .needsRetry, .paused: return
      default: break
      }
    }
    activeRunID = checkpoint.snapshot.runID
    present(checkpoint)
  }

  // MARK: - Private Helpers
  private func validConfiguration() async throws -> SuggestionConfiguration {
    let value = try await configuration.load()
    let messages = value.validationMessages()
    guard messages.isEmpty else {
      throw SuggestionRecoveryError.invalid(messages.joined(separator: "\n"))
    }
    return value
  }

  private func startFresh(mode: SuggestionSearchMode) async {
    guard !isRunning, currentDocument().unfinishedSuggestionRun == nil else { return }
    let runID = uuid()
    await perform(runID: runID) { attemptID in
      let configuration = try await self.validConfiguration()
      try self.check(runID, attemptID)
      guard let key = self.resolveAPIKey() else {
        if mode == .fresh { self.onMissingAPIKey() }
        throw CutSuggestClientError.authMissing("Add an API key to resume this search.")
      }
      let document = self.currentDocument()
      guard document.unfinishedSuggestionRun == nil,
        mode != .automatic || (self.automaticEnabled && document.cutSuggestions.isEmpty)
      else { throw CancellationError() }
      let snapshot = SuggestionRunSnapshot(
        runID: runID, configuration: configuration,
        configurationHash: try SuggestionRecoveryArchive.configurationHash(configuration),
        model: self.options.model, discoveryPromptVersion: "configured-v1",
        extractionPromptVersion: "fields-v1", productSpecVersion: "configured-v1",
        transcriptHash: self.editPlan.transcriptHash, sourceFingerprint: self.sourceFingerprint,
        sampleRate: self.editPlan.source.sampleRate,
        stage1Window: self.options.stage1Window, stage1Step: self.options.stage1Step)
      let original = self.makeRequest(snapshot, mode, nil)
      let preparation = SuggestionRecoveryPreparation(
        snapshot: snapshot, originalRequest: try LiveCutSuggester.encodedRequest(original),
        control: .init(
          revision: 0, proposedStarts: document.suggestionStarts,
          originalBatchFingerprint: try suggestionBatchFingerprint(document), isPaused: false),
        lastAppliedRunID: document.lastAppliedSuggestionRunID)
      if mode == .fresh { self.onExplicitStart() }
      let preparationTask = Task { try await self.prepare(preparation) }
      let directory = try await preparationTask.value
      try self.check(runID, attemptID)
      self.attemptOwner = self.currentOwner()
      try await self.consume(
        self.makeRequest(snapshot, mode, directory), key: key, attemptID: attemptID)
    }
  }

  private func startResume(runID: UUID, replaceBaseline: Bool) async {
    let previous = phase
    await perform(runID: runID) { attemptID in
      var capture = try await self.readCapture(runID, attemptID: attemptID)
      try self.validateSource(capture.checkpoint.snapshot)
      if !replaceBaseline, try self.baselineChanged(capture.checkpoint) {
        self.confirmation = .resume(runID, previous)
        self.phase = .confirmingReplacement
        return
      }
      if replaceBaseline || capture.checkpoint.phase == .paused {
        capture = try await self.writeControl(
          capture, attemptID: attemptID, paused: false, replaceBaseline: replaceBaseline)
      }
      if capture.checkpoint.phase == .ready || capture.checkpoint.phase == .needsNumbering {
        try self.apply(capture.checkpoint, attemptID: attemptID, automatic: false)
        return
      }
      guard let key = self.resolveAPIKey() else {
        self.onMissingAPIKey()
        throw CutSuggestClientError.authMissing("Add an API key to resume this search.")
      }
      try await self.consume(
        self.makeRequest(capture.checkpoint.snapshot, .resume, capture.journalDirectory),
        key: key, attemptID: attemptID)
    }
  }

  private func perform(
    runID: UUID, operation: @escaping @MainActor (UUID) async throws -> Void
  ) async {
    guard !ownershipBlocked, !isRunning, stopTask == nil else { return }
    let attemptID = uuid()
    activeRunID = runID
    activeAttemptID = attemptID
    attemptOwner = currentOwner()
    phase = .running(runID: runID, message: "Analyzing transcript…")
    diagnostic = nil
    let task = Task { [weak self] in
      guard let self else { return }
      do { try await operation(attemptID) } catch {
        guard self.isCurrent(runID, attemptID) else { return }
        self.presentFailure(error, runID: runID)
      }
      guard self.isCurrent(runID, attemptID) else { return }
      self.activeAttemptID = nil
      self.attemptTask = nil
      self.attemptOwner = nil
      if self.currentDocument().unfinishedSuggestionRun == nil { self.activeRunID = nil }
    }
    attemptTask = task
    await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
    if task.isCancelled, activeRunID == runID, activeAttemptID == attemptID {
      cancelSearchTapped()
      await stopTask?.value
    }
  }

  private func consume(_ request: CutSuggestRequest, key: String, attemptID: UUID) async throws {
    guard let snapshot = request.snapshot else { throw SuggestionRecoveryError.missingRun }
    let runID = snapshot.runID
    for try await event in cutSuggest.suggestCuts(request, key) {
      try check(runID, attemptID)
      switch event {
      case .progress(let message): phase = .running(runID: runID, message: message)
      case .diagnostic(let message): diagnostic = message
      case .checkpoint(let eventRunID, let revision):
        guard eventRunID == runID else { continue }
        _ = try await readCapture(runID, attemptID: attemptID, minimumRevision: revision)
      case .recoverableFailure(let eventRunID, _, let message):
        guard eventRunID == runID else { continue }
        let capture = try await readCapture(runID, attemptID: attemptID)
        phase = .needsRetry(runID: runID, message: capture.checkpoint.failureMessage ?? message)
        return
      case .completed:
        let capture = try await readCapture(runID, attemptID: attemptID)
        guard capture.checkpoint.phase == .ready else {
          throw SuggestionRecoveryError.invalid(
            "The helper finished without a complete saved checkpoint.")
        }
        try apply(capture.checkpoint, attemptID: attemptID, automatic: request.mode == .automatic)
        return
      }
    }
    try check(runID, attemptID)
    throw CutSuggestClientError.suggestFailed("The cut-suggester stopped before returning results.")
  }

  private func readCapture(
    _ runID: UUID, attemptID: UUID, minimumRevision: Int? = nil
  ) async throws -> SuggestionRecoveryCapture {
    try check(runID, attemptID)
    guard let owner = attemptOwner ?? currentOwner() else {
      throw SuggestionRecoveryError.missingRun
    }
    let capture = try await recovery.capture(owner, runID, minimumRevision)
    try check(runID, attemptID)
    guard capture.checkpoint.snapshot.runID == runID else { throw CancellationError() }
    try validateSource(capture.checkpoint.snapshot)
    try onCheckpoint(capture)
    try check(runID, attemptID)
    return capture
  }

  private func writeControl(
    _ capture: SuggestionRecoveryCapture, attemptID: UUID, starts: SuggestionStarts? = nil,
    paused: Bool, replaceBaseline: Bool = false
  ) async throws -> SuggestionRecoveryCapture {
    let checkpoint = capture.checkpoint
    let runID = checkpoint.snapshot.runID
    try check(runID, attemptID)
    guard let owner = attemptOwner ?? currentOwner() else {
      throw SuggestionRecoveryError.missingRun
    }
    let next = checkpoint.controlRevision.addingReportingOverflow(1)
    guard !next.overflow else { throw SuggestionRecoveryError.revisionOverflow }
    let control = SuggestionRecoveryControl(
      revision: next.partialValue, proposedStarts: starts ?? checkpoint.proposedStarts,
      originalBatchFingerprint: replaceBaseline
        ? try suggestionBatchFingerprint(currentDocument()) : checkpoint.originalBatchFingerprint,
      isPaused: paused)
    try await recovery.updateControl(owner, runID, control, checkpoint.controlRevision)
    try check(runID, attemptID)
    return try await readCapture(runID, attemptID: attemptID)
  }

  private func number(_ checkpoint: SuggestionRunCheckpoint, starts: SuggestionStarts) throws
    -> (candidates: [CutSuggestion], batch: SuggestionBatch)
  {
    try validateSource(checkpoint.snapshot)
    guard checkpoint.phase == .ready || checkpoint.phase == .needsNumbering else {
      throw SuggestionRecoveryError.invalid("The search has not finished extracting names.")
    }
    return try numberSuggestions(
      checkpoint.candidates, snapshot: checkpoint.snapshot, starts: starts,
      issued: currentDocument().issuedSuggestionNumbers, retained: [])
  }

  private func apply(_ checkpoint: SuggestionRunCheckpoint, attemptID: UUID, automatic: Bool) throws
  {
    try check(checkpoint.snapshot.runID, attemptID)
    guard !automatic || currentDocument().cutSuggestions.isEmpty else {
      throw SuggestionRecoveryError.conflict(
        "Suggestions changed while the search was running. Resume to replace them.")
    }
    guard try !baselineChanged(checkpoint) else {
      throw SuggestionRecoveryError.conflict(
        "Suggestions changed while the search was running. Resume to replace them.")
    }
    let result = try number(checkpoint, starts: checkpoint.proposedStarts)
    try onApply(result.candidates, result.batch)
    phase = .idle
    activeRunID = nil
    activeAttemptID = nil
    attemptOwner = nil
    attemptTask = nil
    if result.candidates.isEmpty, diagnostic == nil { diagnostic = noResultsMessage }
  }

  private func baselineChanged(_ checkpoint: SuggestionRunCheckpoint) throws -> Bool {
    try !suggestionBaselineMatches(checkpoint, document: currentDocument())
  }

  private func validateSource(_ snapshot: SuggestionRunSnapshot) throws {
    guard snapshot.sourceFingerprint == sourceFingerprint,
      snapshot.transcriptHash == editPlan.transcriptHash,
      snapshot.sampleRate == editPlan.source.sampleRate
    else {
      throw SuggestionRecoveryError.invalid(
        "The source or transcript changed. Discard this search.")
    }
  }

  private func isCurrent(_ runID: UUID, _ attemptID: UUID) -> Bool {
    activeRunID == runID && activeAttemptID == attemptID && !Task.isCancelled
  }

  private func check(_ runID: UUID, _ attemptID: UUID) throws {
    guard isCurrent(runID, attemptID), !ownershipBlocked else { throw CancellationError() }
  }

  private func presentFailure(_ error: any Error, runID: UUID) {
    if let numberingError = error as? SuggestionNumberingError {
      switch numberingError {
      case .minimumSafeStart(let minimum):
        phase = .needsNumbering(
          runID: runID, message: "Choose a starting number of at least \(minimum).")
        seedNumbering(minimum: minimum)
      case .invalidStart:
        phase = .needsNumbering(
          runID: runID, message: "Starting numbers must be positive whole numbers.")
      case .exhausted:
        phase = .needsNumbering(
          runID: runID, message: "There are no safe numbers left for this group.")
      }
    } else if currentDocument().unfinishedSuggestionRun != nil {
      phase = .needsRetry(runID: runID, message: error.localizedDescription)
    } else {
      phase = .failed(message: error.localizedDescription)
    }
  }

  private func present(_ checkpoint: SuggestionRunCheckpoint) {
    let runID = checkpoint.snapshot.runID
    switch checkpoint.phase {
    case .paused:
      phase = .paused(runID: runID, message: checkpoint.failureMessage ?? "Search paused.")
    case .needsNumbering:
      phase = .needsNumbering(
        runID: runID, message: "Choose starting numbers to finish this search.")
      seedNumbering(minimum: 1)
    case .ready:
      phase = .paused(runID: runID, message: "Search complete. Resume to apply its suggestions.")
    case .discovering, .extracting, .needsRetry:
      phase = .needsRetry(
        runID: runID, message: checkpoint.failureMessage ?? "Resume the unfinished search.")
    }
  }

  private func seedNumbering(minimum: Int) {
    guard let checkpoint = currentDocument().unfinishedSuggestionRun else { return }
    numberingEntries = checkpoint.snapshot.configuration.types.filter { type in
      type.template.contains { $0.kind == .sequence }
    }.map { type in
      .init(
        id: type.id, title: type.name,
        number: max(minimum, checkpoint.proposedStarts.types[type.id]?.number ?? 1))
    }
  }

  private func beginStop(publish: Bool) {
    guard stopTask == nil, let runID = activeRunID else { return }
    let oldTask = attemptTask
    let oldOwner = attemptOwner
    phase = .paused(runID: runID, message: "Search paused.")
    stopTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.attemptOwner = nil
        self.attemptTask = nil
        self.stopTask = nil
      }
      await oldTask?.value
      guard self.isStoppedRun(runID) else { return }
      guard let owner = oldOwner ?? self.currentOwner(),
        self.currentDocument().unfinishedSuggestionRun?.snapshot.runID == runID
      else {
        self.activeRunID = nil
        self.phase = .idle
        return
      }
      do { try await self.persistPause(owner: owner, runID: runID, publish: publish) } catch {
        if publish, self.isStoppedRun(runID) {
          self.phase = .failed(message: error.localizedDescription)
        }
      }
    }
  }

  private func isStoppedRun(_ runID: UUID) -> Bool {
    activeRunID == runID && activeAttemptID == nil && !Task.isCancelled
  }

  private func persistPause(owner: SuggestionRecoveryOwner, runID: UUID, publish: Bool) async throws
  {
    let capture = try await recovery.capture(owner, runID, nil)
    guard isStoppedRun(runID) else { return }
    let checkpoint = capture.checkpoint
    let next = checkpoint.controlRevision.addingReportingOverflow(1)
    guard !next.overflow else { throw SuggestionRecoveryError.revisionOverflow }
    try await recovery.updateControl(
      owner, runID,
      .init(
        revision: next.partialValue, proposedStarts: checkpoint.proposedStarts,
        originalBatchFingerprint: checkpoint.originalBatchFingerprint, isPaused: true),
      checkpoint.controlRevision)
    guard isStoppedRun(runID) else { return }
    let paused = try await recovery.capture(owner, runID, nil)
    guard isStoppedRun(runID) else { return }
    if publish { try onCheckpoint(paused) }
  }

}

enum SuggestionRunPhase: Equatable {
  case idle
  case confirmingReplacement
  case running(runID: UUID, message: String)
  case paused(runID: UUID, message: String)
  case needsRetry(runID: UUID, message: String)
  case needsNumbering(runID: UUID, message: String)
  case failed(message: String)
}

struct SuggestionNumberingEntry: Identifiable {
  var id: String
  var title: String
  var number: Int
}

func suggestionBatchFingerprint(_ document: EditorDocumentState) throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  return SuggestionRecoveryArchive.sha256(try encoder.encode(document.cutSuggestions.elements))
}

func suggestionBaselineMatches(
  _ checkpoint: SuggestionRunCheckpoint, document: EditorDocumentState
) throws -> Bool {
  guard let baseline = checkpoint.originalBatchFingerprint else {
    return document.cutSuggestions.isEmpty
  }
  return try baseline == suggestionBatchFingerprint(document)
}
