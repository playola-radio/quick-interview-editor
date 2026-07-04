import Dependencies
import Foundation
import IdentifiedCollections
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
    let n = selectedWords.count
    guard n > 0 else { return "No selection" }
    return "\(n) word\(n == 1 ? "" : "s") selected"
  }
  var selectedSampleRange: Range<Int>? {
    guard let plan = editPlan, let first = selectedWords.first, let last = selectedWords.last
    else { return nil }
    let sr = Double(plan.source.sampleRate)
    let s = first.startSample ?? Int(first.start * sr)
    let e = last.endSample ?? Int((last.end ?? last.start) * sr)
    guard s < e else { return nil }  // non-monotonic samples must not build an inverted Range
    return s..<e
  }
  var runTogetherCount: Int { words.filter(\.isRunTogether).count }
  var runTogetherCountLabel: String { "\(runTogetherCount) run-together" }

  // MARK: - User Actions
  func viewAppeared() async {
    guard editPlan == nil, let planURL else { return }
    isLoading = true
    defer { isLoading = false }
    editPlan = try? await engine.loadPlan(planURL)
    recomputeWords()
  }

  func wordTapped(_ id: Word.ID) {
    if selectionAnchorID == nil {
      selectionAnchorID = id; selectionFocusID = id            // first click
    } else if selectionAnchorID == selectionFocusID {
      selectionFocusID = id                                     // second click extends
    } else {
      selectionAnchorID = id; selectionFocusID = id             // third click resets
    }
    recomputeWords()
  }

  func clearSelectionTapped() {
    selectionAnchorID = nil; selectionFocusID = nil
    recomputeWords()
  }

  func sensitivityChanged(_ ms: Double) {
    runTogetherMaxGapMs = ms
    recomputeWords()
  }

  // MARK: - Private Helpers
  func recomputeWords() {
    guard let plan = editPlan else { words = []; return }
    let red = runTogetherWordIDs(plan.words, maxGapMs: runTogetherMaxGapMs)
    let selected = selectedWordIDs
    let states = plan.words.map { w in
      WordViewState(
        id: w.id, text: w.text,
        startSample: w.startSample, endSample: w.endSample,
        isSelected: selected.contains(w.id),
        isRunTogether: red.contains(w.id)
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
    guard let a = selectionAnchorID, let f = selectionFocusID, let plan = editPlan,
          let anchorIndex = plan.words.firstIndex(where: { $0.id == a }),
          let focusIndex = plan.words.firstIndex(where: { $0.id == f })
    else { return [] }
    return plan.words[min(anchorIndex, focusIndex)...max(anchorIndex, focusIndex)]
  }

  private var selectedWordIDs: Set<Word.ID> { Set(selectedWords.map(\.id)) }
}
