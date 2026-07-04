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
    guard let range = selectedIDRange else { return "No selection" }
    let n = range.count
    return "\(n) word\(n == 1 ? "" : "s") selected"
  }
  var selectedSampleRange: Range<Int>? {
    guard let range = selectedIDRange, let plan = editPlan,
          let first = plan.words.first(where: { $0.id == range.lowerBound }),
          let last = plan.words.first(where: { $0.id == range.upperBound })
    else { return nil }
    let sr = Double(plan.source.sampleRate)
    let s = first.startSample ?? Int(first.start * sr)
    let e = last.endSample ?? Int((last.end ?? last.start) * sr)
    return s..<e
  }

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

  // MARK: - Private Helpers
  func recomputeWords() {
    guard let plan = editPlan else { words = []; return }
    let red = runTogetherWordIDs(plan.words, maxGapMs: runTogetherMaxGapMs)
    words = IdentifiedArrayOf(uniqueElements: plan.words.map { w in
      WordViewState(
        id: w.id, text: w.text,
        startSample: w.startSample, endSample: w.endSample,
        isSelected: selectedIDRange?.contains(w.id) ?? false,
        isRunTogether: red.contains(w.id)
      )
    })
  }

  private var selectedIDRange: ClosedRange<Word.ID>? {
    guard let a = selectionAnchorID, let f = selectionFocusID else { return nil }
    return min(a, f)...max(a, f)
  }
}
