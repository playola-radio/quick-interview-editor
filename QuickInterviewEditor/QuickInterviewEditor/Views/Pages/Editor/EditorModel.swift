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

  // MARK: - Properties
  var slices: IdentifiedArrayOf<Slice> = []
  var playingSliceID: Slice.ID?

  // MARK: - Display Text
  let addSliceLabel = "Add slice"
  let emptyStateMessage = "Select words in the transcript, then Add slice."
  let playLabel = "Play"
  let stopLabel = "Stop"
  let deleteLabel = "Delete slice"

  // MARK: - View Helpers
  var canAddSlice: Bool { transcript.selectedSampleRange != nil }

  var sliceCountLabel: String {
    "\(slices.count) \(slices.count == 1 ? "clip" : "clips")"
  }

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
      name: "Slice \(slices.count + 1)",
      startSample: range.lowerBound,
      endSample: range.upperBound,
      wordIDs: wordIDs,
      snippet: displaySnippet(transcript.selectionSnippet),
      warnings: sliceWarnings(
        startSample: range.lowerBound, endSample: range.upperBound,
        durationSamples: editPlan.source.durationSamples, silences: editPlan.silences)
    )
    slices.append(slice)
    transcript.clearSelectionTapped()
  }

  func renameSlice(_ id: Slice.ID, to name: String) {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    slices[id: id]?.name = name
  }

  func moveSlices(fromOffsets source: IndexSet, toOffset destination: Int) {
    slices.move(fromOffsets: source, toOffset: destination)
  }

  func deleteSlice(_ id: Slice.ID) async {
    if playingSliceID == id {
      playingSliceID = nil
      await audioPlayer.stop()
    }
    slices.remove(id: id)
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

  // MARK: - Private Helpers
  private func displaySnippet(_ text: String) -> String {
    let quoted = text.count > 68 ? String(text.prefix(68)) + "…" : text
    return "“\(quoted)”"
  }
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
