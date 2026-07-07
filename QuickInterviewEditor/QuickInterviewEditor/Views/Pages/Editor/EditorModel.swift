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
  private var nextSliceNumber = 1

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

  // MARK: - Private Helpers
  private func displaySnippet(_ text: String) -> String {
    "“\(middleTruncatedSnippet(text, maxLength: 68))”"
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
