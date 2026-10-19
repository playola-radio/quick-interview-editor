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
  init(editPlan: EditPlan, sourceFingerprint: String, options: CutSuggestOptions = .freshConfigured)
  {
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
  /// Copyable detail under a hard failure (the helper's diagnostic log), kept out of the
  /// primary sentence.
  var failureDetail: String?
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
  @ObservationIgnored var onReplacementConfirmed: @MainActor () throws -> Void = {
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
    "This will immediately remove the current suggestions and search for replacements. "
    + "Your saved clips will not be changed."
  let replaceButtonTitle = "Replace Suggestions"
  let cancelButtonTitle = "Cancel"
  let resumeButtonTitle = "Resume Search"
  let discardButtonTitle = "Discard Search"
  let applyNumberingTitle = "Apply Numbering"
  let numberingTitle = "Choose starting numbers"
  let noResultsMessage = "The search completed with no suggestions."
  static let genericRetryMessage = "Some requests failed. Resume to retry the unfinished requests."
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
    hasActionableUnfinishedRun && !resumeCannotSucceed
  }
  var canDiscard: Bool {
    !isRunning && stopTask == nil && (hasActionableUnfinishedRun || staleDiscardAvailable)
  }
  private var hasActionableUnfinishedRun: Bool {
    !ownershipBlocked && !isRunning && stopTask == nil
      && currentDocument().unfinishedSuggestionRun != nil
      && confirmation == nil
  }
  private var resumeCannotSucceed: Bool {
    guard let failures = currentDocument().unfinishedSuggestionRun?.failures,
      let primary = Self.primaryFailure(failures)
    else { return false }
    switch primary.category {
    case .badRequest, .inputSize: return true
    case .unknown: return !primary.retryable
    default: return false
    }
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
      currentDocument().suggestionBatch == nil, resolveAPIKey() != nil
    else { return }
    await startFresh(mode: .automatic)
  }

  func replacementButtonTapped() {
    acceptingConfirmation = true
    Task { await replaceConfirmed() }
  }

  func replaceConfirmed() async {
    acceptingConfirmation = false
    guard let target = confirmation, !ownershipBlocked, !isRunning, stopTask == nil else { return }
    confirmation = nil
    do {
      try onReplacementConfirmed()
    } catch {
      phase = .failed(message: error.localizedDescription)
      return
    }
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
    guard canResume, showsNumbering, let checkpoint = currentDocument().unfinishedSuggestionRun
    else { return }
    do {
      var starts = checkpoint.proposedStarts
      starts.groups = []
      for entry in numberingEntries {
        starts.types[entry.id] = .init(
          number: try parseSuggestionStartingNumber(entry.numberText), isExplicit: true)
      }
      await applyNumberingTapped(starts)
    } catch {
      presentFailure(error, runID: checkpoint.snapshot.runID)
    }
  }

  func synchronizeDocument() {
    guard !isRunning, stopTask == nil, confirmation == nil else { return }
    guard let checkpoint = currentDocument().unfinishedSuggestionRun else {
      activeRunID = nil
      phase = .idle
      failureDetail = nil
      return
    }
    if activeRunID == checkpoint.snapshot.runID {
      switch phase {
      case .needsNumbering, .needsRetry, .paused: return
      default: break
      }
    }
    activeRunID = checkpoint.snapshot.runID
    failureDetail = nil
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
        mode != .automatic
          || (self.automaticEnabled && document.cutSuggestions.isEmpty
            && document.suggestionBatch == nil)
      else { throw CancellationError() }
      let extractionPromptVersion =
        switch self.options.promptVersion {
        case "configured-v5": "fields-v3"
        case "configured-v4": "fields-v2"
        default: "fields-v1"
        }
      let snapshot = SuggestionRunSnapshot(
        runID: runID, configuration: configuration,
        configurationHash: try SuggestionRecoveryArchive.configurationHash(configuration),
        model: self.options.model, discoveryPromptVersion: self.options.promptVersion,
        extractionPromptVersion: extractionPromptVersion,
        productSpecVersion: "configured-v1",
        transcriptHash: self.editPlan.transcriptHash, sourceFingerprint: self.sourceFingerprint,
        sampleRate: self.editPlan.source.sampleRate,
        stage1Window: self.options.stage1Window, stage1Step: self.options.stage1Step,
        interviewArtist: document.interviewArtist)
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
    failureDetail = nil
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
    let startRevision = currentDocument().unfinishedSuggestionRun?.pythonRevision
    var events = cutSuggest.suggestCuts(request, key).makeAsyncIterator()
    while true {
      let next: CutSuggestEvent?
      do {
        next = try await events.next()
      } catch {
        try await presentRecordedFailureOrRethrow(
          error, runID: runID, attemptID: attemptID, startRevision: startRevision)
        return
      }
      guard let event = next else { break }
      try check(runID, attemptID)
      switch event {
      case .progress(let message): phase = .running(runID: runID, message: message)
      case .diagnostic(let message): diagnostic = message
      case .checkpoint(let eventRunID, let revision):
        try await captureCheckpointEvent(
          eventRunID: eventRunID, runID: runID, attemptID: attemptID, revision: revision)
      case .recoverableFailure(let eventRunID, _, let eventFailures):
        guard eventRunID == runID else { continue }
        try await presentRecoverableFailure(
          runID: runID, attemptID: attemptID, failures: eventFailures)
        return
      case .completed:
        try await applyCompletedRun(
          runID: runID, attemptID: attemptID, automatic: request.mode == .automatic)
        return
      }
    }
    try check(runID, attemptID)
    throw CutSuggestClientError.endedWithoutResult
  }

  private func captureCheckpointEvent(
    eventRunID: UUID, runID: UUID, attemptID: UUID, revision: Int
  ) async throws {
    guard eventRunID == runID else { return }
    _ = try await readCapture(runID, attemptID: attemptID, minimumRevision: revision)
  }

  private func applyCompletedRun(runID: UUID, attemptID: UUID, automatic: Bool) async throws {
    let capture = try await readCapture(runID, attemptID: attemptID)
    guard capture.checkpoint.phase == .ready else {
      throw SuggestionRecoveryError.invalid(
        "The helper finished without a complete saved checkpoint.")
    }
    try apply(capture.checkpoint, attemptID: attemptID, automatic: automatic)
  }

  private func presentRecoverableFailure(
    runID: UUID, attemptID: UUID, failures: [SuggestionRunFailure]
  ) async throws {
    let capture = try await readCapture(runID, attemptID: attemptID)
    phase = .needsRetry(
      runID: runID,
      message: recoveryMessage(capture.checkpoint, fallbackFailures: failures)
        ?? capture.checkpoint.failureMessage ?? Self.genericRetryMessage)
  }

  private func presentRecordedFailureOrRethrow(
    _ streamError: any Error, runID: UUID, attemptID: UUID, startRevision: Int?
  ) async throws {
    guard !(streamError is CancellationError), !Self.isUnexpectedExit(streamError),
      let capture = try? await readCapture(runID, attemptID: attemptID),
      capture.checkpoint.pythonRevision > (startRevision ?? -1),
      let message = recoveryMessage(capture.checkpoint)
    else { throw streamError }
    phase = .needsRetry(runID: runID, message: message)
    failureDetail = Self.failureDetail(streamError)
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
    return try preparePendingSuggestions(
      checkpoint.candidates, snapshot: checkpoint.snapshot, starts: starts,
      issued: currentDocument().issuedSuggestionNumbers)
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
    } else {
      let message = Self.hardFailureMessage(error, model: options.model)
      if currentDocument().unfinishedSuggestionRun != nil {
        phase = .needsRetry(runID: runID, message: message)
      } else {
        phase = .failed(message: message)
      }
      failureDetail = Self.failureDetail(error)
    }
  }

  private func present(_ checkpoint: SuggestionRunCheckpoint) {
    let runID = checkpoint.snapshot.runID
    switch checkpoint.phase {
    case .paused:
      phase = .paused(
        runID: runID,
        message: recoveryMessage(checkpoint) ?? checkpoint.failureMessage ?? "Search paused.")
    case .ready, .needsNumbering:
      phase = .paused(runID: runID, message: "Search complete. Resume to apply its suggestions.")
    case .discovering, .extracting, .needsRetry:
      phase = .needsRetry(
        runID: runID,
        message: recoveryMessage(checkpoint) ?? checkpoint.failureMessage
          ?? "Resume the unfinished search.")
    }
  }

  private func recoveryMessage(
    _ checkpoint: SuggestionRunCheckpoint, fallbackFailures: [SuggestionRunFailure] = []
  ) -> String? {
    let recorded = checkpoint.failures ?? []
    return Self.recoveryMessage(
      failures: recorded.isEmpty ? fallbackFailures : recorded, model: checkpoint.snapshot.model)
  }

  private func seedNumbering(minimum: Int) {
    guard let checkpoint = currentDocument().unfinishedSuggestionRun else { return }
    numberingEntries = checkpoint.snapshot.configuration.types.filter { type in
      type.template.contains { $0.kind == .sequence }
    }.map { type in
      .init(
        id: type.id, title: type.name,
        numberText: String(max(minimum, checkpoint.proposedStarts.types[type.id]?.number ?? 1)))
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
  var numberText: String
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

extension SuggestionRunModel {
  static func primaryFailure(_ failures: [SuggestionRunFailure]) -> SuggestionRunFailure? {
    failures.min { priority($0.category) < priority($1.category) }
  }

  static func providerName(model: String) -> String {
    let name = model.lowercased()
    return ["gpt-", "o1", "o3", "o4"].contains(where: name.hasPrefix) ? "OpenAI" : "Anthropic"
  }

  static func recoveryMessage(failures: [SuggestionRunFailure], model: String) -> String? {
    guard let primary = primaryFailure(failures) else { return nil }
    let provider = providerName(model: model)
    var text = primaryText(primary, provider: provider)
    if failures.count > 1 { text += " \(failures.count) requests failed." }
    text += providerDetail(primary)
    return text
  }

  /// The sentence for a search that stopped without a recorded per-request failure. A
  /// helper's structured provider error reuses the per-request wording; nothing raw from the
  /// helper's output is shown.
  static func hardFailureMessage(_ error: any Error, model: String) -> String {
    switch error as? CutSuggestClientError {
    case .helperFailed(let failure):
      let kind = helperKind(failure.phase)
      if let provider = failure.report?.providerError,
        let message = recoveryMessage(
          failures: [
            SuggestionRunFailure(
              kind: kind, category: provider.category, message: provider.message,
              statusCode: provider.statusCode, requestID: provider.requestID,
              retryAfter: provider.retryAfter, retryable: provider.retryable,
              errorType: failure.report?.errorType)
          ], model: model)
      {
        return message
      }
      return "The suggestion search stopped while \(unknownPhase(kind)): \(failure.cause)."
    case .exitMismatch(_, let failure):
      return "The suggestion search ended unexpectedly: \(failure.exitSummary)."
    case .unreadableOutput:
      return "The suggestion search returned a result the app could not read."
    case .endedWithoutResult:
      return "The suggestion search stopped without returning results or saying why."
    default:
      return error.localizedDescription
    }
  }

  /// A helper killed by a signal, or whose result disagrees with its exit code, is shown as
  /// that, not as whatever its last checkpoint recorded.
  private static func isUnexpectedExit(_ error: any Error) -> Bool {
    guard let error = error as? CutSuggestClientError else { return false }
    if case .exitMismatch = error { return true }
    return error.helperFailure?.signal != nil
  }

  private static func failureDetail(_ error: any Error) -> String? {
    (error as? CutSuggestClientError)?.helperFailure?.logURL.map { "Diagnostic log: \($0.path)" }
  }

  private static func helperKind(_ phase: String?) -> String {
    switch phase {
    case "discovering": "discovery"
    case "extracting": "extraction"
    default: "search"
    }
  }

  private static let priorityOrder = [
    "auth", "credits", "bad_request", "input_size", "rate_limit", "overloaded", "timeout",
    "network", "server", "bad_response",
  ]

  private static func priority(_ category: SuggestionFailureCategory) -> Int {
    priorityOrder.firstIndex(of: category.wireName) ?? priorityOrder.count
  }

  // swiftlint:disable:next cyclomatic_complexity
  private static func primaryText(_ failure: SuggestionRunFailure, provider: String) -> String {
    switch failure.category {
    case .auth:
      return "\(provider) rejected your API key. Check or replace the key in Settings, then Resume."
    case .credits:
      let billing =
        provider == "OpenAI"
        ? "platform.openai.com/settings/organization/billing"
        : "console.anthropic.com/settings/billing"
      return "Your \(provider) account is out of credits. Add credits at \(billing), then Resume."
    case .rateLimit:
      return
        "\(provider)'s rate limit was reached. Wait \(retryWait(failure.retryAfter)), then Resume."
    case .overloaded:
      return "\(provider) is temporarily overloaded. Wait a few minutes, then Resume."
    case .network:
      return
        "The app could not reach \(provider). Check your internet connection, VPN, or firewall, then Resume."
    case .timeout:
      return "\(provider) did not respond in time. Check your connection, then Resume."
    case .server:
      return "\(provider) returned a server error. Wait a few minutes, then Resume."
    case .badRequest:
      return "\(provider) rejected the suggestion request. Discard this search and start a new one."
    case .badResponse:
      return
        "\(provider) returned a response the app could not read. Resume to try that request again."
    case .inputSize:
      return
        "Some suggestion evidence is too large to send to \(provider). "
        + "Discard this search and shorten the transcript or naming instructions."
    case .unknown:
      return
        "The suggestion search failed while \(unknownPhase(failure.kind)): \(unknownDetail(failure))."
    }
  }

  private static func retryWait(_ retryAfter: Double?) -> String {
    guard let retryAfter, retryAfter > 0 else { return "a few minutes" }
    let seconds = Int(min(retryAfter, 31_536_000).rounded(.up))
    guard seconds >= 60 else { return unit(seconds, "second") }
    return unit((seconds + 59) / 60, "minute")
  }

  private static func unit(_ count: Int, _ name: String) -> String {
    count == 1 ? "1 \(name)" : "\(count) \(name)s"
  }

  private static func unknownPhase(_ kind: String) -> String {
    switch kind {
    case "discovery": "finding suggestions"
    case "extraction": "reading suggestion details"
    default: "searching"
    }
  }

  private static func unknownDetail(_ failure: SuggestionRunFailure) -> String {
    var detail = nonEmpty(failure.message) ?? nonEmpty(failure.errorType) ?? "unknown error"
    if detail.hasSuffix(".") { detail.removeLast() }
    return detail
  }

  private static func providerDetail(_ failure: SuggestionRunFailure) -> String {
    switch failure.category {
    case .inputSize, .unknown: return ""
    default: break
    }
    guard let message = nonEmpty(failure.message) else { return "" }
    var parts: [String] = []
    if let status = failure.statusCode { parts.append("HTTP \(status)") }
    if let id = nonEmpty(failure.requestID) { parts.append("request \(id)") }
    let reference = parts.isEmpty ? "" : " (\(parts.joined(separator: "; ")))"
    return " Provider message: \"\(message)\"\(reference)."
  }

  private static func nonEmpty(_ text: String?) -> String? {
    guard let text, !text.isEmpty else { return nil }
    return text
  }
}
