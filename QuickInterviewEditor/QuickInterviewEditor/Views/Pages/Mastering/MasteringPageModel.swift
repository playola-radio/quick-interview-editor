import AVFoundation
import AppKit
import AudioToolbox
import Dependencies
import Foundation
import Observation
import UniformTypeIdentifiers

// swiftlint:disable inclusive_language

struct MasteringArtifactValidationClient: Sendable {
  var validate: @Sendable (URL, String, Int) throws -> Void
}

enum MasteringArtifactError: Error { case corrupt, unavailable }

extension MasteringArtifactValidationClient: DependencyKey {
  static var liveValue: Self {
    Self(validate: { url, ext, frames in
      guard let file = try? AVAudioFile(forReading: url), Int(file.length) == frames,
        Int(file.fileFormat.sampleRate) == MasteringFormat.sampleRate,
        Int(file.fileFormat.channelCount) == MasteringFormat.channels
      else {
        throw MasteringArtifactError.corrupt
      }
      var audioFile: AudioFileID?
      guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFile) == noErr,
        let audioFile
      else { throw MasteringArtifactError.corrupt }
      defer { AudioFileClose(audioFile) }
      var format = AudioStreamBasicDescription()
      var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
      guard AudioFileGetProperty(audioFile, kAudioFilePropertyDataFormat, &size, &format) == noErr,
        (ext == "wav" && format.mFormatID == kAudioFormatLinearPCM && format.mBitsPerChannel == 24)
          || (ext == "m4a" && format.mFormatID == kAudioFormatMPEG4AAC)
      else {
        throw MasteringArtifactError.corrupt
      }
    })
  }
  static var testValue: Self { Self(validate: { _, _, _ in }) }
}

extension DependencyValues {
  var masteringArtifactValidation: MasteringArtifactValidationClient {
    get { self[MasteringArtifactValidationClient.self] }
    set { self[MasteringArtifactValidationClient.self] = newValue }
  }
}

@MainActor
@Observable
final class MasteringPageModel: ViewModel {
  struct Host {
    var finishTitleEdit: @MainActor () -> Void
    var inputs: @MainActor () -> Result<MasteringSnapshot, MasteringBlocker>
    var eligibility: @MainActor () -> MasteringEligibility?
    var run: @MainActor () -> MasteringRun?
    var packageURL: @MainActor () -> URL?
    var artifact: @MainActor (MasteringArtifactRef) -> StagedMasteringArtifact?
    var commit: @MainActor (MasteringRun, [String: StagedMasteringArtifact], UUID?) -> Bool
    var stagingError: @MainActor () -> String? = { nil }
    var dismiss: @MainActor () -> Void = {}
  }
  enum Activity: Equatable {
    case idle
    case preparing(completed: Int, total: Int)
    case inspecting(fileName: String)
    case returning(partID: UUID)
    case copying
  }
  struct AmbiguousReturn: Equatable {
    var candidatePartIDs: [UUID]
  }
  struct DestinationPrompt: Equatable {
    var suggested: URL
    var message: String
  }
  struct PartRow: Identifiable {
    var id: UUID
    var title: String
    var status: String
    var canDrag: Bool
    var canReplace: Bool
  }
  struct AmbiguityChoice: Identifiable {
    var id: UUID
    var title: String
  }

  @ObservationIgnored @Dependency(\.masteringAudio) private var audio
  @ObservationIgnored @Dependency(\.masteringReturn) private var returned
  @ObservationIgnored @Dependency(\.masteringStaging) private var staging
  @ObservationIgnored @Dependency(\.masteringArtifactValidation) private var validation
  @ObservationIgnored @Dependency(\.workspace) private var workspace
  @ObservationIgnored @Dependency(\.uuid) private var uuid
  @ObservationIgnored private let host: Host
  @ObservationIgnored private var worker: Task<Void, Never>?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var pendingMasters: [StagedMasteringArtifact] = []
  @ObservationIgnored private var ambiguousOwner: StagedMasteringArtifact?
  private var dragOwners: [UUID: StagedMasteringArtifact] = [:]
  private var dragRevision = 0
  @ObservationIgnored private var saveOwners: [StagedMasteringArtifact] = []
  @ObservationIgnored private var copied: [ExportCopiedFile] = []
  @ObservationIgnored private var destination: URL?
  @ObservationIgnored private var batchBusy = false
  private(set) var activity: Activity = .idle
  var confirmingPrepareAgain = false
  var ambiguousReturn: AmbiguousReturn?
  @ObservationIgnored private var replaceTargetPartID: UUID?
  var destinationPrompt: DestinationPrompt?
  var exportReview: ExportReviewModel?
  private(set) var savedFiles: [URL] = []
  private(set) var message: String?
  private(set) var warningMessages: [String] = []

  init(host: Host) {
    self.host = host
    super.init()
  }

  let title = "Prepare for Mastering"
  let prepareLabel = "Prepare for Mastering"
  let prepareAgainLabel = "Prepare Again"
  let cancelLabel = "Cancel"
  let openSiteLabel = "Open Masterchannel Studio"
  let saveLabel = "Save Finished Files"
  let chooseOtherLabel = "Choose Other…"
  let showInFinderLabel = "Show in Finder"
  let dragLabel = "Drag WAV"
  let replaceLabel = "Replace"
  let doneLabel = "Done"
  let dropHelp = "Drop lossless mastered audio here"
  let noRunMessage = "Prepare intro clips to start a mastering run."
  let staleMessage =
    "The interview has changed since these files were prepared. Prepare again to use the current edits."
  let confirmAgainMessage =
    "Prepare again? Your current files stay until the new preparation succeeds."
  var unavailableMessage: String {
    let detail = host.stagingError().map { " \($0)" } ?? ""
    return
      "A saved mastering file is unavailable. Reopen the project or prepare that part again.\(detail)"
  }
  let corruptMessage =
    "A saved mastering file is damaged or has the wrong audio format. Prepare or return that part again."

  var run: MasteringRun? { host.run() }
  var dragReloadKey: String { "\(run?.id.uuidString ?? "none"):\(dragRevision)" }
  var hasRun: Bool { run != nil }
  var eligibilitySummary: String {
    guard let eligibility = host.eligibility() else { return "" }
    let included = eligibility.intros.count
    let other = eligibility.excluded.filter { $0.reason == .notIntro }.count
    let removed = eligibility.excluded.filter { $0.reason == .fullyRemoved }.count
    let includedText = "\(included) intro\(included == 1 ? "" : "s") included"
    let otherText = "\(other) other clip\(other == 1 ? "" : "s") excluded"
    let removedText = "\(removed) fully removed intro\(removed == 1 ? "" : "s") excluded"
    return [includedText, otherText, removedText].joined(separator: " · ")
  }
  var showsEligibilitySummary: Bool { host.eligibility() != nil }
  var showsActivity: Bool { activity != .idle }
  var activityLabel: String {
    switch activity {
    case .idle: return ""
    case .preparing(let completed, let total): return "Preparing intro \(completed) of \(total)…"
    case .inspecting(let fileName): return "Inspecting \(fileName)…"
    case .returning(let id):
      let number = (run?.parts.firstIndex(where: { $0.id == id }) ?? 0) + 1
      return "Encoding returned Part \(number)…"
    case .copying: return "Saving mastered files…"
    }
  }
  var isBusy: Bool {
    activity != .idle || batchBusy || exportReview != nil || destinationPrompt != nil
  }
  var canCancel: Bool { isBusy || replaceTargetPartID != nil }
  var canSave: Bool {
    run?.parts.allSatisfy { part in
      part.isReturned
        && part.pieces.allSatisfy { piece in
          piece.finished.flatMap(host.artifact) != nil
        }
    } == true && !isBusy
  }
  var ambiguityChoices: [AmbiguityChoice] {
    guard let ambiguousReturn, let run else { return [] }
    return ambiguousReturn.candidatePartIDs.compactMap { id in
      guard let index = run.parts.firstIndex(where: { $0.id == id }) else { return nil }
      let part = run.parts[index]
      let seconds = part.frameCount / MasteringFormat.sampleRate
      let duration = String(format: "%d:%02d", seconds / 60, seconds % 60)
      return AmbiguityChoice(id: id, title: "Part \(index + 1) (\(duration))")
    }
  }
  let ambiguityMessage = "Which part is this master for?"
  var destinationMessage: String { destinationPrompt?.message ?? "" }
  var showsAmbiguityPrompt: Bool { ambiguousReturn != nil }
  var showsDestinationPrompt: Bool { destinationPrompt != nil }
  var showsStaleNotice: Bool {
    guard let run else { return false }
    guard case .success(let snapshot) = host.inputs() else { return true }
    return snapshot.inputsDigest != run.inputsDigest
  }
  var rows: [PartRow] {
    guard let run else { return [] }
    return run.parts.enumerated().map { index, part in
      let seconds = part.frameCount / MasteringFormat.sampleRate
      let duration = String(format: "%d:%02d", seconds / 60, seconds % 60)
      let missing =
        part.isReturned
        ? part.pieces.contains { $0.finished.flatMap(host.artifact) == nil }
        : part.prepared.flatMap(host.artifact) == nil
      return PartRow(
        id: part.id, title: "Part \(index + 1) of \(run.parts.count)",
        status:
          "\(duration) · \(missing ? "unavailable" : (part.isReturned ? "returned" : "needed"))",
        canDrag: !missing && part.prepared != nil && dragOwners[part.id] != nil && !isBusy,
        canReplace: part.isReturned && !isBusy)
    }
  }

  func prepareTapped() async {
    guard !isBusy else {
      busyMessage()
      return
    }
    host.finishTitleEdit()
    switch host.inputs() {
    case .failure(let blocker): message = Self.text(for: blocker)
    case .success(let snapshot):
      if run != nil {
        confirmingPrepareAgain = true
        return
      }
      await launchPrepare(snapshot, expectedID: nil)
    }
  }
  func prepareAgainConfirmed() async {
    guard !isBusy else { return }
    confirmingPrepareAgain = false
    host.finishTitleEdit()
    switch host.inputs() {
    case .failure(let blocker): message = Self.text(for: blocker)
    case .success(let snapshot): await launchPrepare(snapshot, expectedID: run?.id)
    }
  }
  func prepareAgainCancelled() { confirmingPrepareAgain = false }
  func doneTapped() {
    guard !isBusy else { return }
    confirmingPrepareAgain = false
    host.dismiss()
  }

  private func launchPrepare(_ snapshot: MasteringSnapshot, expectedID: UUID?) async {
    generation += 1
    let token = generation
    activity = .preparing(completed: 0, total: snapshot.pieces.count)
    message = nil
    let task = Task { [weak self] in
      guard let self else { return }
      await performPrepare(snapshot, expectedID: expectedID, token: token)
    }
    worker = task
    await task.value
    if generation == token { worker = nil }
  }
  private func performPrepare(_ snapshot: MasteringSnapshot, expectedID: UUID?, token: Int) async {
    do {
      let work = try staging.makeWorkDirectory()
      defer { staging.removeDirectory(work) }
      let result = try await audio.prepare(.init(snapshot: snapshot, workDirectory: work)) {
        [weak self] progress in
        Task { @MainActor [weak self] in
          guard let self, self.generation == token,
            case .preparing = self.activity
          else { return }
          self.activity = .preparing(
            completed: progress.completedPieces, total: progress.totalPieces)
        }
      }
      try current(token, runID: expectedID)
      var staged: [String: StagedMasteringArtifact] = [:]
      let parts = try result.parts.map { part -> MasteringPart in
        try current(token, runID: expectedID)
        let name = uuid().uuidString.lowercased() + ".wav"
        staged[name] = try staging.adopt(part.wavURL, name)
        return MasteringPart(
          id: uuid(), frameCount: part.frameCount,
          prepared: .init(fileName: name, byteCount: part.byteCount),
          pieces: part.pieces.map {
            MasteringPiece(
              id: uuid(), sliceID: $0.sliceID, title: $0.title,
              startFrame: $0.startFrame, frameCount: $0.frameCount, lrc: $0.lrc, finished: nil)
          })
      }
      let newRun = MasteringRun(
        id: uuid(), artist: snapshot.artist, inputsDigest: result.inputsDigest, parts: parts)
      try current(token, runID: expectedID)
      guard host.commit(newRun, staged, expectedID) else {
        message = "The project changed while preparing; prepare again."
        return
      }
      dragOwners = [:]
      warningMessages = result.warnings.map(Self.warningText)
      message = "Prepared \(parts.count) part\(parts.count == 1 ? "" : "s") for mastering."
    } catch is CancellationError {
      message = "Preparation cancelled. Your previous prepared run is unchanged."
    } catch MasteringPreparationError.truePeakCeilingExceeded(let part, let measured) {
      message = String(
        format: "Part %d peaks at %.1f dBTP, above the −1.5 dBTP ceiling. Nothing was changed.",
        part, measured)
    } catch { message = error.localizedDescription }
    if generation == token {
      activity = .idle
      dragRevision += 1
    }
  }
  func cancelTapped() async {
    generation += 1
    worker?.cancel()
    await worker?.value
    worker = nil
    activity = .idle
    dragRevision += 1
    batchBusy = false
    ambiguousReturn = nil
    ambiguousOwner = nil
    pendingMasters = []
    replaceTargetPartID = nil
    destinationPrompt = nil
    confirmingPrepareAgain = false
  }
  func openMasterchannelTapped() {
    workspace.open(URL(string: "https://masterchannel.ai/studio")!)
  }
  func dragURL(for partID: UUID) async -> URL? {
    let token = generation
    guard let part = run?.parts.first(where: { $0.id == partID }), let ref = part.prepared else {
      return nil
    }
    guard let source = host.artifact(ref) else {
      message = unavailableMessage
      return nil
    }
    do {
      try validation.validate(source.url, "wav", part.frameCount)
      let partName = rows.first(where: { $0.id == partID })?.title ?? "Part"
      let projectName = host.packageURL()?.deletingPathExtension().lastPathComponent ?? "Interview"
      let copy = try await staging.sessionCopy(source.url, "\(projectName) – \(partName).wav")
      guard !Task.isCancelled, generation == token,
        run?.parts.contains(where: { $0.id == partID && $0.prepared == ref }) == true
      else {
        return nil
      }
      dragOwners[partID] = copy
      return copy.url
    } catch MasteringArtifactError.corrupt { message = corruptMessage } catch {
      message = "Could not stage the prepared file: \(error.localizedDescription)"
    }
    return nil
  }
  func dragURLSync(for partID: UUID) -> URL? { dragOwners[partID]?.url }
  func preloadDragSources() async {
    for part in run?.parts ?? [] where part.prepared != nil && dragOwners[part.id] == nil {
      _ = await dragURL(for: part.id)
    }
  }
  @discardableResult
  func providersDropped(_ providers: [NSItemProvider]) -> Task<Void, Never>? {
    guard !isBusy, !providers.isEmpty else {
      busyMessage()
      return nil
    }
    batchBusy = true
    let token = generation
    let task = Task { [weak self] in
      guard let self else { return }
      do {
        for provider in providers {
          let owner = try await Self.retainProvider(
            provider, copy: staging.retainTemporaryFile)
          try Task.checkCancellation()
          guard generation == token else { throw CancellationError() }
          pendingMasters.append(owner)
        }
        await continueDropBatch()
      } catch is CancellationError {
        pendingMasters = []
        batchBusy = false
        message = "Drop cancelled."
      } catch {
        pendingMasters = []
        batchBusy = false
        message = "Could not retain the dropped audio: \(error.localizedDescription)"
      }
      worker = nil
    }
    worker = task
    return task
  }
  private static func retainProvider(
    _ provider: NSItemProvider,
    copy: @escaping @Sendable (URL, String) throws -> StagedMasteringArtifact
  ) async throws
    -> StagedMasteringArtifact
  {
    try await withCheckedThrowingContinuation { continuation in
      provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
        do {
          if let error { throw error }
          let url =
            (item as? URL)
            ?? (item as? Data).flatMap {
              URL(dataRepresentation: $0, relativeTo: nil)
            }
          guard let url, url.isFileURL else { throw CocoaError(.fileReadNoSuchFile) }
          continuation.resume(returning: try copy(url, url.lastPathComponent))
        } catch { continuation.resume(throwing: error) }
      }
    }
  }
  private func continueDropBatch() async {
    let token = generation
    while !pendingMasters.isEmpty {
      let owner = pendingMasters.removeFirst()
      guard let currentRun = run else {
        message = noRunMessage
        break
      }
      activity = .inspecting(fileName: owner.url.lastPathComponent)
      do {
        let inspection = try await returned.inspect(owner.url)
        try current(token, runID: currentRun.id)
        let choices = currentRun.parts.filter {
          replaceTargetPartID == $0.id || (replaceTargetPartID == nil && !$0.isReturned)
        }
        let matches = MasterReturnMatching.candidates(
          durationSeconds: inspection.durationSeconds,
          parts: choices.map { ($0.id, $0.frameCount) })
        if matches.isEmpty {
          message = "\(inspection.fileName) does not match any part still needed."
          continue
        }
        if matches.count > 1 {
          ambiguousOwner = owner
          ambiguousReturn = .init(candidatePartIDs: matches)
          activity = .idle
          return
        }
        await encode(owner, partID: matches[0], token: token)
      } catch is CancellationError { break } catch { message = error.localizedDescription }
    }
    pendingMasters = []
    activity = .idle
    batchBusy = false
    replaceTargetPartID = nil
  }
  func ambiguousChoiceTapped(_ partID: UUID) async {
    guard let ambiguousReturn, ambiguousReturn.candidatePartIDs.contains(partID),
      let owner = ambiguousOwner
    else { return }
    self.ambiguousReturn = nil
    ambiguousOwner = nil
    let token = generation
    let task = Task { [weak self] in
      guard let self else { return }
      await encode(owner, partID: partID, token: token)
      await continueDropBatch()
      worker = nil
    }
    worker = task
    await task.value
  }
  func ambiguousReturnCancelled() {
    guard ambiguousReturn != nil else { return }
    ambiguousReturn = nil
    ambiguousOwner = nil
    worker = Task { [weak self] in
      await self?.continueDropBatch()
      self?.worker = nil
    }
  }
  func replacePartTapped(_ partID: UUID) {
    guard !isBusy, run?.parts.contains(where: { $0.id == partID && $0.isReturned }) == true else {
      return
    }
    replaceTargetPartID = partID
    message = "Drop a new master for the selected part."
  }
  private func encode(_ owner: StagedMasteringArtifact, partID: UUID, token: Int) async {
    guard let currentRun = run,
      let partIndex = currentRun.parts.firstIndex(where: { $0.id == partID })
    else { return }
    defer { if replaceTargetPartID == partID { replaceTargetPartID = nil } }
    let part = currentRun.parts[partIndex]
    guard !part.isReturned || replaceTargetPartID == partID else {
      message = "That part has already been returned. Choose Replace to change it."
      return
    }
    activity = .returning(partID: partID)
    do {
      let work = try staging.makeWorkDirectory()
      defer { staging.removeDirectory(work) }
      let target = MasteredPartTarget(
        partFrameCount: part.frameCount,
        pieces: part.pieces.map {
          MasteredPieceTarget(
            pieceID: $0.id, startFrame: $0.startFrame,
            frameCount: $0.frameCount, artist: currentRun.artist, title: $0.title, lrc: $0.lrc)
        })
      let encoded = try await returned.encodePart(owner.url, target, work)
      try current(token, runID: currentRun.id)
      guard encoded.count == part.pieces.count,
        Set(encoded.map(\.pieceID)) == Set(part.pieces.map(\.id))
      else {
        throw MasteringReturnError.encodeFailed(title: "part", reason: "Missing encoded pieces")
      }
      var staged: [String: StagedMasteringArtifact] = [:]
      var updated = currentRun
      for piece in encoded {
        try current(token, runID: currentRun.id)
        let name = uuid().uuidString.lowercased() + ".m4a"
        staged[name] = try staging.adopt(piece.url, name)
        let index = updated.parts[partIndex].pieces.firstIndex(where: { $0.id == piece.pieceID })!
        updated.parts[partIndex].pieces[index].finished = .init(
          fileName: name, byteCount: piece.byteCount)
      }
      try current(token, runID: currentRun.id)
      guard host.commit(updated, staged, currentRun.id) else {
        message = "The project changed while returning this master. Drop it again."
        return
      }
      copied = []
      savedFiles = []
      destination = nil
      saveOwners = []
      message = "Part \(partIndex + 1) returned."
    } catch is CancellationError {
      message = "Return cancelled. Completed parts are unchanged."
    } catch { message = error.localizedDescription }
  }

  func saveFinalsTapped() {
    guard canSave else {
      if run?.parts.allSatisfy(\.isReturned) == true { message = unavailableMessage }
      return
    }
    guard let package = host.packageURL() else { return }
    let suggested = package.deletingLastPathComponent().appendingPathComponent("mastered")
    destinationPrompt = .init(
      suggested: suggested,
      message: "Save to “mastered” next to “\(package.lastPathComponent)”?")
  }
  func destinationCancelTapped() { destinationPrompt = nil }
  func destinationSaveSelected() async {
    guard let prompt = destinationPrompt else { return }
    destinationPrompt = nil
    activity = .copying
    let task = Task { [weak self] in
      guard let self else { return }
      do {
        try workspace.createDirectory(prompt.suggested)
        await copyFinals(to: prompt.suggested)
      } catch {
        message = "Could not create the destination: \(error.localizedDescription)"
        activity = .idle
      }
      worker = nil
    }
    worker = task
    await task.value
  }
  func destinationChooseOtherSelected() async {
    guard let prompt = destinationPrompt else { return }
    destinationPrompt = nil
    let token = generation
    let runID = run?.id
    activity = .copying
    let task = Task { [weak self] in
      guard let self else { return }
      if let url = await workspace.chooseDirectoryNear(
        prompt.suggested, "Save Here", "Choose a folder for the mastered m4a files")
      {
        if generation == token, run?.id == runID, !Task.isCancelled {
          await copyFinals(to: url)
        } else {
          activity = .idle
        }
      } else {
        activity = .idle
      }
      worker = nil
    }
    worker = task
    await task.value
  }
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func copyFinals(to url: URL) async {
    guard let run, run.parts.allSatisfy(\.isReturned) else {
      activity = .idle
      return
    }
    let token = generation
    activity = .copying
    do {
      if destination?.standardizedFileURL.path != url.standardizedFileURL.path {
        copied = []
        savedFiles = []
        destination = url
      }
      saveOwners = []
      let alreadyCopied = Set(copied.map(\.id))
      var rendered: [UUID: URL] = [:]
      var targets: [Slice] = []
      for part in run.parts {
        for piece in part.pieces {
          guard let ref = piece.finished else { throw MasteringArtifactError.corrupt }
          if !alreadyCopied.contains(piece.id) {
            guard let owner = host.artifact(ref) else { throw MasteringArtifactError.unavailable }
            try validation.validate(owner.url, "m4a", piece.frameCount)
            let copy = try await staging.sessionCopy(owner.url, ref.fileName)
            try current(token, runID: run.id)
            saveOwners.append(copy)
            rendered[piece.id] = copy.url
          }
          targets.append(
            Slice(
              id: piece.id, name: piece.title, startSample: 0,
              endSample: 0, wordIDs: [], snippet: ""))
        }
      }
      let review = withDependencies(from: self) {
        ExportReviewModel(
          request: .init(
            targets: targets, sourceStem: "",
            renderedByID: rendered, destination: url, kind: .masteredM4A, copied: copied),
          scratchDirectory: nil)
      }
      review.onExport = { [weak self, weak review] approved in
        guard let self, let review else { return }
        self.activity = .copying
        self.worker = Task { [weak self] in
          await self?.finishCopy(review, approved: approved, token: token, runID: run.id)
          self?.worker = nil
        }
      }
      review.onReviewNames = { [weak self] in
        Task {
          await self?.cancelTapped()
          self?.exportReview = nil
          self?.saveOwners = []
          self?.copied = []
          self?.savedFiles = []
          self?.destination = nil
        }
      }
      await finishCopy(review, approved: nil, token: token, runID: run.id)
    } catch MasteringArtifactError.corrupt { message = corruptMessage } catch MasteringArtifactError
      .unavailable
    { message = unavailableMessage } catch is CancellationError {
      message = "Save cancelled. Files already copied remain."
    } catch { message = "Could not stage the final files: \(error.localizedDescription)" }
    if exportReview == nil { saveOwners = [] }
    activity = .idle
  }
  private func finishCopy(
    _ review: ExportReviewModel, approved: [ExportNameMapping]?,
    token: Int, runID: UUID
  ) async {
    let outcome = await review.copy(approved: approved)
    guard run?.id == runID else { return }
    copied = outcome.copied
    savedFiles = copied.map(\.url)
    if generation != token {
      if outcome.cancelled { message = "Save cancelled. Files already copied remain." }
      exportReview = nil
      saveOwners = []
      activity = .idle
      return
    }
    if let error = outcome.errorMessage {
      message = error
      exportReview = nil
      saveOwners = []
    } else if outcome.reviewMappings != nil {
      exportReview = review
    } else if !outcome.cancelled {
      exportReview = nil
      message = "Saved \(savedFiles.count) mastered files."
      copied = []
      saveOwners = []
    } else {
      exportReview = nil
      saveOwners = []
    }
    activity = .idle
  }
  func showInFinderTapped() { workspace.reveal(savedFiles) }
  func teardown() async {
    await cancelTapped()
    dragOwners = [:]
    dragRevision += 1
    saveOwners = []
    exportReview = nil
    savedFiles = []
    copied = []
    destination = nil
    warningMessages = []
    message = nil
  }
  private func current(_ token: Int, runID: UUID?) throws {
    try Task.checkCancellation()
    guard generation == token, host.run()?.id == runID else { throw CancellationError() }
  }
  private func busyMessage() { message = "Wait for the current step to finish." }
  private static func warningText(_ warning: MasteringPreparationWarning) -> String {
    switch warning {
    case .overlongPiece(let title, let seconds):
      return String(format: "%@ lasts %.0f seconds and has its own part.", title, seconds)
    case .peakLimitedGain(let title, _, _):
      return "\(title) remains below the loudness target to preserve the −1.5 dBTP ceiling."
    }
  }
  private static func text(for blocker: MasteringBlocker) -> String {
    switch blocker {
    case .unsaved: "Save the project before preparing for mastering."
    case .missingArtist: "Enter the interview artist first."
    case .noIntros: "No intro clips to prepare. Only clips typed as Intro are included."
    case .blankTitles: "Name every intro before preparing."
    case .pendingEdit: "Finish the pending clip edit before preparing."
    case .invalidTimeline: "The edited timeline is invalid. Undo the last change before preparing."
    case .notLoaded: "Load the interview before preparing."
    }
  }
}

// swiftlint:enable inclusive_language
