import Dependencies
import Foundation
import IdentifiedCollections
import IssueReporting
import Observation

@MainActor
@Observable
class TranscriptPageModel: ViewModel {

  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.engine) var engine

  // MARK: - Initialization
  let planURL: URL?
  init(planURL: URL? = Bundle.main.url(forResource: "edit-plan", withExtension: "json")) {
    self.planURL = planURL
    super.init()
  }

  convenience init(editPlan: EditPlan) {
    self.init(planURL: nil)
    self.editPlan = editPlan
    recomputeWords()
  }

  // MARK: - Properties
  var editPlan: EditPlan?
  var words: IdentifiedArrayOf<WordViewState> = []
  var runTogetherMaxGapMs: Double = 30
  var isLoading = false
  var selectionAnchorID: Word.ID?
  var selectionFocusID: Word.ID?

  // MARK: - Display Text
  let transcriptCaption = "TRANSCRIPT"
  let runTogetherLegend = "red = words that run together (hard to cut between)"
  let emptyStateMessage = "No transcript loaded."
  let sensitivityLabel = "Run-together sensitivity"
  let sensitivityMinMs = 10.0
  let sensitivityMaxMs = 80.0
  let clearButtonLabel = "Clear"

  // MARK: - View Helpers
  var hasSelection: Bool { selectionAnchorID != nil }
  var selectionSummary: String {
    let count = selectedWords.count
    guard count > 0 else { return "No selection" }
    return "\(count) word\(count == 1 ? "" : "s") selected"
  }
  var selectedSampleRange: Range<Int>? {
    guard let plan = editPlan, let first = selectedWords.first, let last = selectedWords.last
    else { return nil }
    let sr = Double(plan.source.sampleRate)
    let lower = first.startSample ?? Int(first.start * sr)
    let upper = last.endSample ?? Int((last.end ?? last.start) * sr)
    // non-monotonic samples must not build an inverted Range
    guard lower < upper else { return nil }
    return lower..<upper
  }
  var runTogetherCount: Int { words.filter(\.isRunTogether).count }
  var runTogetherCountLabel: String { "\(runTogetherCount) run-together" }
  var orderedSelectedWordIDs: [Word.ID] { selectedWords.map(\.id) }
  var selectionSnippet: String {
    selectedWords.map(\.text).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
  }

  // MARK: - User Actions
  func viewAppeared() async {
    guard editPlan == nil, let planURL else { return }
    isLoading = true
    defer { isLoading = false }
    // Surface load failures (dev/test) instead of silently swallowing them; on a
    // failure editPlan stays nil and the view shows the empty state.
    await withErrorReporting {
      editPlan = try await engine.loadPlan(planURL)
    }
    recomputeWords()
  }

  func wordTapped(_ id: Word.ID) {
    if selectionAnchorID == nil {
      selectionAnchorID = id
      selectionFocusID = id  // first click
    } else if selectionAnchorID == selectionFocusID {
      selectionFocusID = id  // second click extends
    } else {
      selectionAnchorID = id
      selectionFocusID = id  // third click resets
    }
    recomputeWords()
  }

  func clearSelectionTapped() {
    selectionAnchorID = nil
    selectionFocusID = nil
    recomputeWords()
  }

  /// Selects exactly one word (anchor == focus). Used by the waveform→transcript sync
  /// when the user clicks a point in the audio.
  func selectWord(_ id: Word.ID) {
    selectionAnchorID = id
    selectionFocusID = id
    recomputeWords()
  }

  func sensitivityChanged(_ ms: Double) {
    runTogetherMaxGapMs = ms
    recomputeWords()
  }

  // MARK: - Private Helpers
  private func recomputeWords() {
    guard let plan = editPlan else {
      words = []
      return
    }
    let red = runTogetherWordIDs(plan.words, maxGapMs: runTogetherMaxGapMs)
    let selected = selectedWordIDs
    let states = plan.words.map { word in
      WordViewState(
        id: word.id, text: word.text,
        startSample: word.startSample, endSample: word.endSample,
        isSelected: selected.contains(word.id),
        isRunTogether: red.contains(word.id)
      )
    }
    // A malformed plan with duplicate word IDs must not trap the app on load.
    words = IdentifiedArray(states, uniquingIDsWith: { first, _ in first })
  }

  /// The contiguous run of words between anchor and focus, by POSITION in the
  /// transcript — not by ID arithmetic. Word IDs are not guaranteed dense,
  /// unique, or monotonic with visual order, so `min(id)...max(id)` would
  /// over-count and could invert; positions are the source of truth.
  private var selectedWords: ArraySlice<Word> {
    guard let anchorID = selectionAnchorID, let focusID = selectionFocusID, let plan = editPlan,
      let anchorIndex = plan.words.firstIndex(where: { $0.id == anchorID }),
      let focusIndex = plan.words.firstIndex(where: { $0.id == focusID })
    else { return [] }
    return plan.words[min(anchorIndex, focusIndex)...max(anchorIndex, focusIndex)]
  }

  private var selectedWordIDs: Set<Word.ID> { Set(selectedWords.map(\.id)) }
}
