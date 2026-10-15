import Dependencies
import Foundation
import IdentifiedCollections

struct ManualClipNamingJob: Sendable {
  var clipID: Slice.ID
  var originalName: String
  var startSample: Int
  var endSample: Int
  var wordIDs: [Word.ID]
  var removedRanges: [Range<Int>]
  var interviewArtist: String?
  var clipText: String
  var apiKey: String

  func matches(_ state: EditorDocumentState) -> Bool {
    guard let slice = state.slices[id: clipID] else { return false }
    return slice.name == originalName && slice.startSample == startSample
      && slice.endSample == endSample && slice.wordIDs == wordIDs
      && slice.suggestionNaming == nil && slice.suggestionTypeID == nil
      && state.interviewArtist == interviewArtist
      && Self.intersectingRemovals(in: state.timelineRemovals, start: startSample, end: endSample)
        == removedRanges
  }

  static func intersectingRemovals(
    in removals: IdentifiedArrayOf<TimelineRemoval>, start: Int, end: Int
  ) -> [Range<Int>] {
    removals.map(\.removedRange).filter { $0.overlaps(start..<end) }
      .sorted { $0.lowerBound < $1.lowerBound }
  }
}

struct DeferredClipNaming {
  var job: ManualClipNamingJob
  var result: ClipNamingResult
  var configuration: SuggestionConfiguration
}

struct ManualClipName: Equatable, Sendable {
  var name: String
  var naming: SuggestionNamingRecord
}

func manualClipName(
  for job: ManualClipNamingJob, result: ClipNamingResult, snapshot: SuggestionRunSnapshot,
  starts: SuggestionStarts, issued: [SequenceReservation]
) throws -> ManualClipName {
  guard let type = snapshot.configuration.types.first(where: { $0.id == result.typeID }),
    let productType = ProductType(rawValue: type.id)
  else { throw SuggestionBatchNumberingError.unknownType(result.typeID) }
  let required = Set(type.sequenceFieldIDs).union(
    type.template.compactMap { $0.kind == .field ? $0.value : nil })
  let extracted = required.reduce(into: [String: String]()) { values, fieldID in
    if let value = result.fields[fieldID] ?? nil { values[fieldID] = value }
  }
  let sampleRate = Double(snapshot.sampleRate)
  let candidate = CutSuggestion(
    id: job.clipID, productType: productType, title: job.originalName, song: nil,
    songVerified: false, wordIDs: job.wordIDs, startSample: job.startSample,
    endSample: job.endSample, startSec: Double(job.startSample) / sampleRate,
    endSec: Double(job.endSample) / sampleRate,
    durationSec: Double(job.endSample - job.startSample) / sampleRate, rank: 0, score: 0,
    status: .pending,
    provenance: .init(
      model: snapshot.model, promptVersion: snapshot.discoveryPromptVersion,
      productSpecVersion: snapshot.productSpecVersion, transcriptHash: snapshot.transcriptHash,
      sourceFingerprint: snapshot.sourceFingerprint, diarizationHash: nil),
    naming: SuggestionNamingRecord(
      runID: snapshot.runID, typeID: type.id, typeName: type.name, typeGroup: type.group,
      discoveryLabel: job.originalName, extractedValues: extracted,
      missingFieldIDs: required.filter { extracted[$0] == nil }.sorted(), correctedValues: [:],
      reservation: nil))
  let numbered = try numberSuggestions(
    [candidate], snapshot: snapshot, starts: starts.withoutExplicitFlags, issued: issued,
    retained: [])
  guard let named = numbered.candidates.first, let naming = named.naming else {
    throw SuggestionBatchNumberingError.invalidNaming(candidateID: job.clipID)
  }
  return ManualClipName(name: named.title, naming: naming)
}

extension EditorModel {
  func queueManualClipNaming(for slice: Slice) {
    guard slices[id: slice.id] != nil, let apiKey = resolvedClipNamingAPIKey() else { return }
    let removed = removedWordIDs
    clipNamingQueue.append(
      ManualClipNamingJob(
        clipID: slice.id, originalName: slice.name, startSample: slice.startSample,
        endSample: slice.endSample, wordIDs: slice.wordIDs,
        removedRanges: ManualClipNamingJob.intersectingRemovals(
          in: timelineRemovals, start: slice.startSample, end: slice.endSample),
        interviewArtist: interviewArtist,
        clipText: sliceSnippet(
          for: slice.wordIDs.filter { !removed.contains($0) }, words: editPlan.words),
        apiKey: apiKey))
    startClipNamingWorker()
  }

  func cancelClipNaming() {
    clipNamingTask?.cancel()
    clipNamingQueue.removeAll()
    deferredClipNamings.removeAll()
  }

  /// Applies results that arrived while export was open, once it closes.
  func applyDeferredClipNamings() {
    guard !isExporting else { return }
    let deferred = deferredClipNamings
    deferredClipNamings.removeAll()
    for item in deferred {
      applyClipNaming(item.result, configuration: item.configuration, to: item.job)
    }
  }

  func awaitClipNaming() async {
    await clipNamingTask?.value
  }

  private func resolvedClipNamingAPIKey() -> String? {
    resolveAnthropicAPIKey(
      keychain: (try? keychain.load()) ?? nil, env: environment.value(anthropicAPIKeyEnvVar))
  }

  private func startClipNamingWorker() {
    guard clipNamingTask?.isCancelled ?? true else { return }
    clipNamingTask = Task { [weak self] in
      while let job = self?.nextClipNamingJob() {
        await self?.performClipNaming(job)
      }
    }
  }

  private func nextClipNamingJob() -> ManualClipNamingJob? {
    guard !Task.isCancelled else { return nil }
    guard !clipNamingQueue.isEmpty else {
      clipNamingTask = nil
      return nil
    }
    return clipNamingQueue.removeFirst()
  }

  private func performClipNaming(_ job: ManualClipNamingJob) async {
    guard let configuration = try? await suggestionConfiguration.load(),
      configuration.validationMessages().isEmpty
    else { return }
    let request = ClipNamingRequest(
      configuration: configuration, model: CutSuggestOptions.freshConfigured.model,
      clipText: job.clipText, clipStartSample: job.startSample, clipEndSample: job.endSample,
      transcriptUnits: editPlan.transcriptUnits, interviewArtist: job.interviewArtist)
    guard let result = try? await cutSuggest.nameClip(request, job.apiKey), !Task.isCancelled
    else { return }
    applyClipNaming(result, configuration: configuration, to: job)
  }

  private func applyClipNaming(
    _ result: ClipNamingResult, configuration: SuggestionConfiguration, to job: ManualClipNamingJob
  ) {
    guard !isExporting else {
      deferredClipNamings.append(.init(job: job, result: result, configuration: configuration))
      return
    }
    guard !isEditingName(of: job.clipID), job.matches(documentState),
      let named = try? manualClipName(
        for: job, result: result, snapshot: clipNamingSnapshot(configuration),
        starts: suggestionStarts, issued: issuedSuggestionNumbers)
    else { return }
    let reservations = named.naming.reservation.map { [$0] } ?? []
    mutateDocument(recordUndo: false, recordingPermanentReservations: reservations) { state in
      guard job.matches(state) else { return }
      state.slices[id: job.clipID]?.name = named.name
      state.slices[id: job.clipID]?.suggestionNaming = named.naming
      state.slices[id: job.clipID]?.suggestionTypeID = named.naming.typeID
    }
  }

  private func clipNamingSnapshot(_ configuration: SuggestionConfiguration) throws
    -> SuggestionRunSnapshot
  {
    let options = CutSuggestOptions.freshConfigured
    return SuggestionRunSnapshot(
      runID: uuid(), configuration: configuration,
      configurationHash: try SuggestionRecoveryArchive.configurationHash(configuration),
      model: options.model, discoveryPromptVersion: options.promptVersion,
      extractionPromptVersion: "fields-v3", productSpecVersion: "configured-v1",
      transcriptHash: editPlan.transcriptHash, sourceFingerprint: sourceFingerprint,
      sampleRate: editPlan.source.sampleRate, interviewArtist: interviewArtist)
  }
}
