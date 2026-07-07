import Dependencies
import Foundation
import IdentifiedCollections
import IssueReporting
import Observation

@MainActor
@Observable
final class EditorModel: ViewModel {

  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.audioPlayer) var audioPlayer
  @ObservationIgnored @Dependency(\.engine) var engine
  @ObservationIgnored @Dependency(\.workspace) var workspace

  // MARK: - Initialization
  let sourceURL: URL
  let editPlan: EditPlan
  var transcript: TranscriptPageModel

  init(sourceURL: URL, editPlan: EditPlan) {
    self.sourceURL = sourceURL
    self.editPlan = editPlan
    self.transcript = TranscriptPageModel(editPlan: editPlan)
    super.init()
  }

  // MARK: - Export Phase
  enum ExportPhase: Equatable {
    case idle
    case exporting(current: Int, total: Int)
    case done(count: Int)
    case failed(String)
  }

  // MARK: - Properties
  var slices: IdentifiedArrayOf<Slice> = []
  var playingSliceID: Slice.ID?
  var exportPhase: ExportPhase = .idle
  var destinationURL: URL?
  private var nextSliceNumber = 1
  private var lastExportTightNames: [String] = []
  @ObservationIgnored private(set) var exportTask: Task<Void, Never>?

  // MARK: - Display Text
  let addSliceLabel = "Add slice"
  let emptyStateMessage = "Select words in the transcript, then Add slice."
  let playLabel = "Play"
  let stopLabel = "Stop"
  let deleteLabel = "Delete slice"
  let exportLabel = "Export"
  let exportAllLabel = "Export all"
  let cancelExportLabel = "Cancel export"

  // MARK: - View Helpers
  var canAddSlice: Bool { transcript.selectedSampleRange != nil }

  var sliceCountLabel: String {
    "\(slices.count) \(slices.count == 1 ? "clip" : "clips")"
  }

  var isExporting: Bool {
    if case .exporting = exportPhase { return true }
    return false
  }
  var canExportAll: Bool { !slices.isEmpty && !isExporting }
  var canExportSlice: Bool { !isExporting }

  var exportStatusMessage: String {
    switch exportPhase {
    case .idle:
      return ""
    case .exporting(let current, let total):
      return current <= 0 ? "Preparing export…" : "Exporting slice \(current) of \(total)…"
    case .done(let count):
      let clips = count == 1 ? "clip" : "clips"
      let location = destinationURL.map { " to \($0.lastPathComponent)" } ?? ""
      return "Exported \(count) \(clips)\(location)."
    case .failed(let message):
      return message
    }
  }

  /// After a successful export, names the exported slices whose cut points weren't in
  /// silence — the user's cue to add a fade in Logic. Empty otherwise. This carries the
  /// tight-join warning into the summary; it is never written into the AIFF markers.
  var exportTightWarning: String {
    guard case .done = exportPhase, !lastExportTightNames.isEmpty else { return "" }
    let names = lastExportTightNames.joined(separator: ", ")
    let verb = lastExportTightNames.count == 1 ? "has a tight join" : "have tight joins"
    return "\(names) \(verb) — add a fade in Logic."
  }

  var showsExportStatus: Bool { !exportStatusMessage.isEmpty }
  var showsCancelExport: Bool { isExporting }

  var sliceRows: IdentifiedArrayOf<SliceRowState> {
    let sampleRate = editPlan.source.sampleRate
    return IdentifiedArray(
      uniqueElements: slices.map { slice in
        SliceRowState(
          id: slice.id,
          name: slice.name,
          durationLabel: sampleDurationLabel(
            slice.endSample - slice.startSample, sampleRate: sampleRate),
          rangeLabel: "\(sampleTimecodeLabel(slice.startSample, sampleRate: sampleRate)) – "
            + sampleTimecodeLabel(slice.endSample, sampleRate: sampleRate),
          snippet: slice.snippet,
          isTight: !slice.warnings.isEmpty,
          warningLabel: slice.warnings.isEmpty ? "" : "Tight join — add a fade in Logic",
          isPlaying: playingSliceID == slice.id,
          playButtonLabel: playingSliceID == slice.id ? stopLabel : playLabel
        )
      })
  }

  // MARK: - User Actions
  func addSliceTapped() {
    guard let range = transcript.selectedSampleRange else { return }
    let wordIDs = transcript.orderedSelectedWordIDs
    guard !wordIDs.isEmpty else { return }
    let slice = Slice(
      id: UUID(),
      name: "Slice \(nextSliceNumber)",
      startSample: range.lowerBound,
      endSample: range.upperBound,
      wordIDs: wordIDs,
      snippet: displaySnippet(transcript.selectionSnippet),
      warnings: sliceWarnings(
        startSample: range.lowerBound, endSample: range.upperBound,
        durationSamples: editPlan.source.durationSamples, silences: editPlan.silences)
    )
    slices.append(slice)
    nextSliceNumber += 1
    transcript.clearSelectionTapped()
  }

  func renameSlice(_ id: Slice.ID, to name: String) {
    slices[id: id]?.name = name
  }

  func moveSlices(fromOffsets source: IndexSet, toOffset destination: Int) {
    slices.move(fromOffsets: source, toOffset: destination)
  }

  func deleteSlice(_ id: Slice.ID) async {
    let wasPlaying = playingSliceID == id
    slices.remove(id: id)
    if wasPlaying {
      playingSliceID = nil
      await audioPlayer.stop()
    }
  }

  func playSliceTapped(_ id: Slice.ID) async {
    guard let slice = slices[id: id] else { return }
    playingSliceID = id
    do {
      try await audioPlayer.play(
        sourceURL, slice.startSample..<slice.endSample, editPlan.source.sampleRate)
    } catch {
      reportIssue(error)
    }
    if playingSliceID == id { playingSliceID = nil }
  }

  func stopPlaybackTapped() async {
    playingSliceID = nil
    await audioPlayer.stop()
  }

  func playStopTapped(_ id: Slice.ID) async {
    if playingSliceID == id {
      await stopPlaybackTapped()
    } else {
      await playSliceTapped(id)
    }
  }

  // MARK: - Export Actions
  func exportSliceTapped(_ id: Slice.ID) {
    guard !isExporting, let slice = slices[id: id] else { return }
    startExport([slice])
  }

  func exportAllTapped() {
    guard !isExporting, !slices.isEmpty else { return }
    startExport(Array(slices))
  }

  func cancelExportTapped() {
    exportTask?.cancel()
  }

  // MARK: - Private Helpers
  private func displaySnippet(_ text: String) -> String {
    "“\(middleTruncatedSnippet(text, maxLength: 68))”"
  }

  /// Marks the export as running synchronously (so the buttons disable immediately
  /// and a rapid second tap can't start a parallel export) and spawns the worker,
  /// keeping a handle so `cancelExportTapped` can kill the process group.
  private func startExport(_ targets: [Slice]) {
    exportTask?.cancel()
    exportPhase = .exporting(current: 0, total: targets.count)
    exportTask = Task { await performExport(targets) }
  }

  func performExport(_ targets: [Slice]) async {
    guard let destination = await resolvedDestination() else {
      exportPhase = .idle
      return
    }
    exportPhase = .exporting(current: 0, total: targets.count)

    do {
      var rendered: [RenderedSlice] = []
      var workDir: URL?
      for try await event in engine.renderSlices(renderRequest(for: targets)) {
        switch event {
        case .progress(let progress):
          exportPhase = .exporting(
            current: progress.index,
            total: progress.total == 0 ? targets.count : progress.total)
        case .completed(let result):
          rendered = result.slices
          workDir = result.workDir
        }
      }
      if Task.isCancelled {
        await removeWorkDir(workDir)
        exportPhase = .failed(cancelMessage(copied: 0, total: targets.count))
        return
      }
      // Copy off the main actor — copying many/large AIFFs (or to a slow/network
      // folder) must not freeze the UI or block the cancel control.
      let byID = Dictionary(
        rendered.map { ($0.id, $0.url) }, uniquingKeysWith: { first, _ in first })
      let stem = sourceURL.deletingPathExtension().lastPathComponent
      let outcome = await Self.copyRenderedSlices(
        stem: stem, targets: targets, renderedByID: byID, destination: destination)
      await removeWorkDir(workDir)

      if outcome.cancelled {
        exportPhase = .failed(cancelMessage(copied: outcome.copied.count, total: targets.count))
      } else if let message = outcome.errorMessage {
        exportPhase = .failed(message)
      } else if outcome.copied.count != targets.count {
        // A short result means the engine didn't render every requested slice —
        // report it rather than claiming success on a partial reveal.
        exportPhase = .failed(
          "The engine rendered \(outcome.copied.count) of \(targets.count) slices.")
      } else {
        workspace.reveal(outcome.copied)
        lastExportTightNames = targets.filter { !$0.warnings.isEmpty }.map(\.name)
        exportPhase = .done(count: outcome.copied.count)
      }
    } catch is CancellationError {
      // The engine cleans up its own work-dir on a cancelled/failed run.
      exportPhase = .failed(cancelMessage(copied: 0, total: targets.count))
    } catch {
      exportPhase = .failed(error.localizedDescription)
    }
  }

  private func resolvedDestination() async -> URL? {
    if let destinationURL { return destinationURL }
    guard let chosen = await workspace.chooseDirectory() else { return nil }
    destinationURL = chosen
    return chosen
  }

  private func renderRequest(for targets: [Slice]) -> RenderRequest {
    let sampleRate = editPlan.source.sampleRate
    let markers = editPlan.words.map { word in
      RenderMarker(
        position: word.startSample ?? Int(word.start * Double(sampleRate)), name: word.text)
    }
    let specs = targets.map {
      RenderSliceSpec(id: $0.id, startSample: $0.startSample, endSample: $0.endSample)
    }
    return RenderRequest(
      sourceURL: sourceURL, sampleRate: sampleRate, markers: markers, slices: specs)
  }

  /// The result of copying rendered slices to the destination, computed off the main
  /// actor. `cancelled` means the export task was cancelled mid-copy (partial state);
  /// `errorMessage` means a copy failed; otherwise `copied` holds one URL per target.
  struct CopyOutcome: Sendable {
    var copied: [URL]
    var cancelled: Bool
    var errorMessage: String?
  }

  /// Copies each rendered temp AIFF to the destination under a unique, sanitized name.
  /// `nonisolated` so the file IO runs off the main actor. Cancellation is honoured
  /// between files so a mid-copy cancel reports how many actually landed.
  private nonisolated static func copyRenderedSlices(
    stem: String, targets: [Slice], renderedByID: [UUID: URL], destination: URL
  ) async -> CopyOutcome {
    var taken = Set(
      ((try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? [])
        .map { $0.lowercased() })
    var copied: [URL] = []
    for (offset, slice) in targets.enumerated() {
      if Task.isCancelled {
        return CopyOutcome(copied: copied, cancelled: true, errorMessage: nil)
      }
      guard let source = renderedByID[slice.id] else { continue }
      let name = exportFileName(
        sourceStem: stem, sliceName: slice.name, index: offset + 1, taken: &taken)
      let target = destination.appendingPathComponent(name)
      do {
        try FileManager.default.copyItem(at: source, to: target)
        copied.append(target)
      } catch {
        return CopyOutcome(
          copied: copied, cancelled: false, errorMessage: error.localizedDescription)
      }
    }
    return CopyOutcome(copied: copied, cancelled: false, errorMessage: nil)
  }

  private nonisolated func removeWorkDir(_ workDir: URL?) async {
    guard let workDir else { return }
    try? FileManager.default.removeItem(at: workDir)
  }

  private func cancelMessage(copied: Int, total: Int) -> String {
    "Export cancelled — \(copied) of \(total) exported."
  }
}

/// Middle-truncate a transcript snippet to at most `maxLength` characters, always
/// keeping the first and last words and filling in as many middle words as fit —
/// e.g. "So a young … think is great" rather than "So a young Hayes Carl…". Short
/// snippets, and those with fewer than three words, pass through unchanged.
func middleTruncatedSnippet(_ text: String, maxLength: Int) -> String {
  let trimmed = text.trimmingCharacters(in: .whitespaces)
  guard trimmed.count > maxLength else { return trimmed }
  let words = trimmed.split(separator: " ").map(String.init)
  guard words.count >= 3 else { return trimmed }

  func rendered(head: Int, tail: Int) -> String {
    words.prefix(head).joined(separator: " ") + " … "
      + words.suffix(tail).joined(separator: " ")
  }
  // Always show the first and last word, then greedily add words toward the
  // middle from alternating ends while they still fit the budget.
  var head = 1
  var tail = 1
  var growTail = true
  // If even the minimal first-word … last-word window overflows (e.g. a single
  // run-on word or a long URL), fall back to a hard character truncation so the
  // maxLength guarantee always holds.
  guard rendered(head: head, tail: tail).count <= maxLength else {
    return String(trimmed.prefix(max(0, maxLength - 1))) + "…"
  }
  while head + tail < words.count {
    let headFits = rendered(head: head + 1, tail: tail).count <= maxLength
    let tailFits = rendered(head: head, tail: tail + 1).count <= maxLength
    if !headFits, !tailFits { break }
    if growTail, tailFits {
      tail += 1
    } else if headFits {
      head += 1
    } else {
      tail += 1
    }
    growTail.toggle()
  }
  // If the head and tail met, nothing is actually elided — show the whole thing.
  return head + tail >= words.count ? trimmed : rendered(head: head, tail: tail)
}

struct SliceRowState: Identifiable, Equatable {
  var id: Slice.ID
  var name: String
  var durationLabel: String
  var rangeLabel: String
  var snippet: String
  var isTight: Bool
  var warningLabel: String
  var isPlaying: Bool
  var playButtonLabel: String
}
