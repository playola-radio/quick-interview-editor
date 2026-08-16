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

/// An explicit "scroll this word into view" request, distinct from the playhead-follow
/// `scrollTargetWordID` (which the view suppresses once the user scrolls by hand). The
/// `token` bumps on every request so re-revealing the same word still re-scrolls.
struct TranscriptReveal: Equatable {
  var wordID: Word.ID
  var token: Int
}

@MainActor
@Observable
class TranscriptPageModel: ViewModel {

  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.engine) var engine

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
  /// Words with almost no gap before/after them ("run-together"), computed at load and
  /// retained for future features (e.g. revealing them while dragging a clip boundary).
  /// No longer rendered — the transcript/waveform stopped drawing the red marking — but
  /// kept as stored analysis so it can be surfaced again without re-deriving.
  var runTogetherWordIDSet: Set<Word.ID> = []
  let runTogetherMaxGapMs: Double = 30
  @ObservationIgnored private var gaps: [WordGap] = []
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
  /// The clip containers to draw, derived by `EditorModel` from slices + pending suggestions
  /// and pushed in by the view. Kept here (not recomputed from slices) so the transcript stays
  /// layout-local — it knows nothing about slices or the sidecar, only which words are clips.
  /// Assigning it recomputes the cached `clipContainers` so the O(n) derivation runs only on a
  /// real change, not on every body evaluation (the view reads `clipContainers` each playback tick).
  var clipBands: [TranscriptClipBand] = [] {
    didSet { recomputeClipContainers() }
  }
  /// The latest explicit reveal request (from clicking a suggestion or clip). The view scrolls
  /// to it regardless of `followMode`; nil until the first reveal.
  var reveal: TranscriptReveal?
  @ObservationIgnored private var revealToken = 0
  @ObservationIgnored private var wasPlaying = false

  // MARK: - Display Text
  let transcriptCaption = "TRANSCRIPT"
  let emptyStateMessage = "No transcript loaded."
  let clearButtonLabel = "Clear"
  /// Vertical spacing (points) between lines. The same value is used within a paragraph
  /// (`lineSpacing`) and after each pause-paragraph (`paragraphSpacing`) so the gap is uniform
  /// everywhere — just enough that a clip container clears the next line without touching it. A
  /// display decision, so it lives on the model rather than being hardcoded in the view.
  let lineSpacing = 8.0
  let paragraphSpacing = 8.0

  // MARK: - View Helpers
  var hasSelection: Bool { !selectedWords.isEmpty }
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

  /// The clip bands mapped to drawable UTF-16 runs, in transcript order. Walks
  /// `document.wordRanges` (position order, so it's correct even for non-monotonic word IDs)
  /// and merges each maximal stretch of consecutive words belonging to the SAME band into ONE
  /// range that spans their interior separators — that's the continuous tinted container the
  /// renderer strokes. Splitting by band identity (not just kind) keeps two back-to-back clips
  /// of the same state as separate containers, each with its own caps; a non-clip word, a
  /// green-over-amber precedence hole, or a paragraph break (the separator is a newline, and a
  /// container can't span the vertical gap between paragraphs) also breaks the run. The range
  /// ends at the last word (its trailing space is left untinted, so the fill caps at the words,
  /// not the gap after them).
  ///
  /// A word ID maps to whichever band lists it first; a *duplicate* ID (the document allows
  /// non-unique IDs) tints every occurrence, matching the transcript's existing tolerance for
  /// duplicates elsewhere. Real aligner output uses unique IDs, so this is a theoretical edge.
  ///
  /// Cached: recomputed only when `clipBands` or `document` changes (see `recomputeClipContainers`),
  /// never on the getter, so a playback tick that re-evaluates the view doesn't re-derive it.
  private(set) var clipContainers: [TranscriptClipContainer] = []

  private func recomputeClipContainers() {
    clipContainers = Self.clipContainers(bands: clipBands, document: document)
  }

  private static func clipContainers(
    bands: [TranscriptClipBand], document: TranscriptDocument
  ) -> [TranscriptClipContainer] {
    guard !bands.isEmpty else { return [] }
    var bandByWord: [Word.ID: (band: UUID, kind: TranscriptClipKind)] = [:]
    for band in bands {
      for id in band.wordIDs where bandByWord[id] == nil {
        bandByWord[id] = (band.id, band.kind)
      }
    }
    let text = document.text as NSString
    var containers: [TranscriptClipContainer] = []
    var runStart: Int?
    var runEnd = 0
    var runBand: UUID?
    var runKind: TranscriptClipKind?
    func closeRun() {
      defer {
        runStart = nil
        runBand = nil
        runKind = nil
      }
      guard let start = runStart, let kind = runKind else { return }
      containers.append(
        TranscriptClipContainer(
          range: NSRange(location: start, length: runEnd - start), kind: kind))
    }
    for wordRange in document.wordRanges {
      let entry = bandByWord[wordRange.wordID]
      // The separator between the run's last word and this one is the char at `runEnd`; a
      // newline there is a paragraph break, which always ends the run.
      let paragraphBreak =
        runStart != nil && runEnd < text.length
        && text.character(at: runEnd) == 0x0A
      if let entry, entry.band == runBand, !paragraphBreak {
        runEnd = NSMaxRange(wordRange.range)
      } else {
        closeRun()
        if let entry {
          runStart = wordRange.range.location
          runEnd = NSMaxRange(wordRange.range)
          runBand = entry.band
          runKind = entry.kind
        }
      }
    }
    closeRun()
    return containers
  }
  var canZoomIn: Bool { fontSize < maxFontSize }
  var canZoomOut: Bool { fontSize > minFontSize }

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

  /// Selects the contiguous run between two words (a suggestion's or clip's endpoints).
  /// Both IDs must resolve in the loaded plan; otherwise the selection is left untouched and
  /// `false` is returned so callers don't act on a selection that didn't change.
  @discardableResult
  func selectWords(anchorID: Word.ID, focusID: Word.ID) -> Bool {
    guard let plan = editPlan,
      plan.words.contains(where: { $0.id == anchorID }),
      plan.words.contains(where: { $0.id == focusID })
    else { return false }
    selectionAnchorID = anchorID
    selectionFocusID = focusID
    return true
  }

  /// Requests a scroll to the first selected word — an explicit reveal that isn't gated by
  /// `followMode`, so it works even after the user has scrolled away. No-op with no selection.
  func revealSelection() {
    guard let first = selectedWords.first else { return }
    revealToken += 1
    reveal = TranscriptReveal(wordID: first.id, token: revealToken)
  }

  func transcriptClicked(atUTF16Offset offset: Int, extending: Bool = false) {
    guard let id = document.wordID(atUTF16Offset: offset) else { return }
    wordClicked(id, extending: extending)
  }

  /// The single selection entry point for both the transcript and the waveform.
  /// `extending` = Shift held: keep the anchor and move the focus (contiguous run).
  func wordClicked(_ id: Word.ID, extending: Bool) {
    guard let plan = editPlan, plan.words.contains(where: { $0.id == id }) else { return }
    let anchorIsValid =
      selectionAnchorID.map { anchor in plan.words.contains { $0.id == anchor } } ?? false
    if extending, anchorIsValid {
      selectionFocusID = id  // keep anchor, move focus
    } else if extending {
      selectWord(id)  // no valid anchor -> plain select
    } else if selectionAnchorID == id, selectionFocusID == id {
      clearSelectionTapped()  // plain re-click of the sole selected word clears
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
  /// Rebuilds everything derived from the plan's words: the document (space-joined
  /// text + UTF-16 range map), the adjacent-gap cache, and the run-together set. This
  /// is the single place the plan is materialized, so it runs only when the plan is
  /// set (convenience init + `viewAppeared`), never on the selection/drag path.
  private func rebuildForLoadedPlan() {
    guard let plan = editPlan else { return }
    paragraphs = PauseParagraphBuilder.paragraphs(
      words: plan.words, transcriptSegments: plan.transcriptSegments)
    document = TranscriptDocument(words: plan.words, paragraphs: paragraphs)
    gaps = wordGaps(plan.words)
    recomputeRunTogether()
    // The word→range map just changed, so re-derive the cached containers against it (bands may
    // already be set — e.g. a reload — so this keeps them from pointing at stale ranges).
    recomputeClipContainers()
  }
  /// Recomputes the run-together set from the cached gaps at the fixed default threshold.
  /// Runs once at plan load; the result is stored analysis, not currently rendered.
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
