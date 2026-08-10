import Dependencies
import Foundation
import IssueReporting
import Observation
import Sharing

/// Single source of truth for the default transcript font size, shared by the
/// `@Shared(.transcriptFontSize)` key default and the model's `defaultFontSize`.
private let defaultTranscriptFontSize = 17.0

extension SharedKey where Self == AppStorageKey<Double>.Default {
  static var transcriptFontSize: Self {
    Self[.appStorage("transcriptFontSize"), default: defaultTranscriptFontSize]
  }
}

enum TranscriptFollowMode: Equatable {
  case following
  case userPaused
}

@MainActor
@Observable
class TranscriptPageModel: ViewModel {

  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.engine) var engine
  @ObservationIgnored @Dependency(\.continuousClock) var clock

  // MARK: - Shared State
  @ObservationIgnored @Shared(.transcriptFontSize) var fontSize: Double

  // MARK: - Initialization
  let planURL: URL?
  init(planURL: URL? = Bundle.main.url(forResource: "edit-plan", withExtension: "json")) {
    self.planURL = planURL
    super.init()
  }

  convenience init(editPlan: EditPlan) {
    self.init(planURL: nil)
    self.editPlan = editPlan
    rebuildForLoadedPlan()
  }

  // MARK: - Properties
  /// Set only through the two load paths (convenience init + `viewAppeared`), each of
  /// which calls `rebuildForLoadedPlan()`. `private(set)` keeps `document`, `gaps`, and
  /// `runTogetherWordIDSet` from ever going stale behind an external plan assignment.
  private(set) var editPlan: EditPlan?
  /// Pause-grouped paragraphs (solo interviews) the renderer can lay out. Derived
  /// purely from the decoded plan's words + `transcript_segments`; no Python re-run.
  var paragraphs: [TranscriptParagraph] = []
  /// Public run-together set for the renderer to diff.
  var runTogetherWordIDSet: Set<Word.ID> = []
  var runTogetherMaxGapMs: Double = 30
  var draftGapMs: Double = 30
  @ObservationIgnored private var gaps: [WordGap] = []
  @ObservationIgnored private var sensitivityCommitTask: Task<Void, Never>?
  var isLoading = false
  var selectionAnchorID: Word.ID?
  var selectionFocusID: Word.ID?
  var document = TranscriptDocument(words: [])
  var plainTranscriptText: String { document.text }
  let minFontSize = 11.0
  let maxFontSize = 36.0
  let fontStep = 2.0
  let defaultFontSize = defaultTranscriptFontSize
  var followMode: TranscriptFollowMode = .following
  var scrollTargetWordID: Word.ID?
  @ObservationIgnored private var wasPlaying = false

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
  var runTogetherCount: Int { runTogetherWordIDSet.count }
  var runTogetherCountLabel: String { "\(runTogetherCount) run-together" }
  /// Sample ranges of the run-together words, ordered by transcript position. Words
  /// missing sample bounds (or with inverted/zero-width bounds) are excluded. A duplicate
  /// word ID emits only its first occurrence's range, matching the dedup semantics of the
  /// `words` array this replaces (`uniquingIDsWith: { first, _ in first }`).
  var runTogetherSampleRanges: [Range<Int>] {
    guard let plan = editPlan else { return [] }
    var seenIDs: Set<Word.ID> = []
    var ranges: [Range<Int>] = []
    for word in plan.words {
      guard runTogetherWordIDSet.contains(word.id), seenIDs.insert(word.id).inserted,
        let start = word.startSample, let end = word.endSample, start < end
      else { continue }
      ranges.append(start..<end)
    }
    return ranges
  }
  var orderedSelectedWordIDs: [Word.ID] { selectedWords.map(\.id) }
  var selectionSnippet: String {
    selectedWords.map(\.text).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
  }
  /// Public selection set for the renderer to diff (the private `selectedWordIDs` stays internal).
  var selectedWordIDSet: Set<Word.ID> { selectedWordIDs }
  var canZoomIn: Bool { fontSize < maxFontSize }
  var canZoomOut: Bool { fontSize > minFontSize }
  var sensitivityValueLabel: String { "\(Int(draftGapMs)) ms" }

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
    rebuildForLoadedPlan()
  }

  func clearSelectionTapped() {
    selectionAnchorID = nil
    selectionFocusID = nil
  }

  /// Selects exactly one word (anchor == focus). Used by the waveform→transcript sync
  /// when the user clicks a point in the audio.
  func selectWord(_ id: Word.ID) {
    selectionAnchorID = id
    selectionFocusID = id
  }

  func sensitivityChanged(_ ms: Double) {
    sensitivityCommitTask?.cancel()
    runTogetherMaxGapMs = ms
    recomputeRunTogether()
  }

  /// Live slider drag: update the label immediately, debounce the expensive recompute.
  func sensitivityDragChanged(_ ms: Double) {
    draftGapMs = ms
    sensitivityCommitTask?.cancel()
    sensitivityCommitTask = Task { [weak self] in
      guard let self else { return }
      try? await self.clock.sleep(for: .milliseconds(150))
      guard !Task.isCancelled else { return }
      self.commitSensitivity(ms)
    }
  }

  func transcriptClicked(atUTF16Offset offset: Int) {
    guard let id = document.wordID(atUTF16Offset: offset) else { return }
    if selectionAnchorID == id, selectionFocusID == id {
      clearSelectionTapped()
    } else {
      selectWord(id)
    }
  }

  func transcriptDragBegan(atUTF16Offset offset: Int) {
    guard let id = document.wordID(atUTF16Offset: offset) else { return }
    selectionAnchorID = id
    selectionFocusID = id
  }

  func transcriptDragged(toUTF16Offset offset: Int) {
    guard let id = document.wordID(atUTF16Offset: offset) else { return }
    selectionFocusID = id
  }

  func transcriptDragEnded() {}

  func zoomInTapped() { setFontSize(fontSize + fontStep) }
  func zoomOutTapped() { setFontSize(fontSize - fontStep) }
  func zoomResetTapped() { setFontSize(defaultFontSize) }
  func zoomChanged(_ size: Double) { setFontSize(size) }

  /// Derives the auto-scroll target from the playhead. A playback rising edge
  /// (false→true) always resumes following, even if the user had scrolled away.
  /// While following and playing, the target becomes the word containing `sample`
  /// (kept unchanged if the playhead sits in a gap between words).
  func playheadChanged(sample: Int?, isPlaying: Bool) {
    if isPlaying, !wasPlaying { followMode = .following }
    wasPlaying = isPlaying
    guard isPlaying, followMode == .following, let sample, let plan = editPlan else { return }
    scrollTargetWordID =
      plan.words.first { word in
        guard let start = word.startSample, let end = word.endSample else { return false }
        return sample >= start && sample < end
      }?.id ?? scrollTargetWordID
  }

  /// The renderer calls this when the user scrolls the transcript by hand, so
  /// subsequent playhead ticks stop moving the scroll target until playback restarts.
  func transcriptUserScrolled() { followMode = .userPaused }

  // MARK: - Private Helpers
  private func setFontSize(_ size: Double) {
    $fontSize.withLock { $0 = min(max(size, minFontSize), maxFontSize) }
  }
  private func commitSensitivity(_ ms: Double) {
    runTogetherMaxGapMs = ms
    recomputeRunTogether()
  }
  /// Rebuilds everything derived from the plan's words: the document (space-joined
  /// text + UTF-16 range map), the adjacent-gap cache, and the run-together set. This
  /// is the single place the plan is materialized, so it runs only when the plan is
  /// set (convenience init + `viewAppeared`), never on the selection/drag path.
  private func rebuildForLoadedPlan() {
    guard let plan = editPlan else { return }
    document = TranscriptDocument(words: plan.words)
    gaps = wordGaps(plan.words)
    paragraphs = PauseParagraphBuilder.paragraphs(
      words: plan.words, transcriptSegments: plan.transcriptSegments)
    recomputeRunTogether()
  }
  /// Recomputes only the run-together set from the cached gaps. Cheap relative to
  /// rebuilding the document; runs at plan load and on sensitivity commit.
  private func recomputeRunTogether() {
    runTogetherWordIDSet = runTogetherWordIDs(gaps: gaps, maxGapMs: runTogetherMaxGapMs)
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
