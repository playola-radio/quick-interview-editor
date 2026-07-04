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

  // MARK: - Display Text
  let transcriptCaption = "TRANSCRIPT"
  let runTogetherLegend = "red = words that run together (hard to cut between)"
  let emptyStateMessage = "No transcript loaded."
  let sensitivityLabel = "Run-together sensitivity"
  let sensitivityMinMs = 10.0
  let sensitivityMaxMs = 80.0

  // MARK: - User Actions
  func viewAppeared() async {
    guard editPlan == nil, let planURL else { return }
    isLoading = true
    defer { isLoading = false }
    editPlan = try? await engine.loadPlan(planURL)
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
        isSelected: false,
        isRunTogether: red.contains(w.id)
      )
    })
  }
}
