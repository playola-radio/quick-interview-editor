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

/// Normal-speed playback rate, shared by the `@Shared(.playbackRate)` key default and the
/// model's `defaultPlaybackRate`.
private let defaultPlaybackRate = 1.0

extension SharedKey where Self == AppStorageKey<Double>.Default {
  static var playbackRate: Self {
    Self[.appStorage("playbackRate"), default: defaultPlaybackRate]
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
  /// Pitch-preserving playback speed, persisted and shared across tabs (global appStorage). The
  /// speed control lives in this panel next to the font size, so this model owns the value and its
  /// actions; `EditorModel` applies it to the audio via `onPlaybackRateChanged`.
  @ObservationIgnored @Shared(.playbackRate) var playbackRate: Double

  /// Called with the clamped rate whenever the user changes speed, so `EditorModel` (the transport
  /// owner) can apply it to the shared player — live if playing, and for the next play otherwise.
  @ObservationIgnored var onPlaybackRateChanged: ((Double) -> Void)?

  /// A text-selection gesture, expressed as which words it hit. The transcript no longer owns the
  /// selection: it resolves the gesture to word IDs and hands this intent to `EditorModel`, which
  /// writes the authoritative freeform `audioSelection`. One-directional — nothing writes back
  /// through here. Lives on the model (not a view `.onChange`) so headless tests apply intents.
  @ObservationIgnored var onSelectionIntent: ((SelectionIntent) -> Void)?

  /// What a transcript selection gesture resolved to, in transcript terms (word IDs). `EditorModel`
  /// turns each into a source-sample range on the authoritative `audioSelection`.
  enum SelectionIntent: Equatable, Sendable {
    /// A span from an anchor word to a focus word (drag, or a resolved multi-word selection).
    case words(anchor: Word.ID, focus: Word.ID)
    /// A single word; `extending` (Shift) stretches the current selection to it.
    case word(Word.ID, extending: Bool)
    /// Clear the selection entirely.
    case clear
  }

  // MARK: - Initialization
  let planURL: URL?
  init(planURL: URL? = Bundle.main.url(forResource: "edit-plan", withExtension: "json")) {
    self.planURL = planURL
    super.init()
    // A persisted speed from a build with a different range would show a bogus label with no preset
    // checked while the player silently clamps it — snap it back into range once at load.
    let clampedRate = min(max(playbackRate, minRate), maxRate)
    if clampedRate != playbackRate { $playbackRate.withLock { $0 = clampedRate } }
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
  /// Transcript-local selection endpoints, kept only to render the text highlight while later tasks
  /// migrate the transcript to derive its highlight from the authoritative `audioSelection`. No
  /// longer the selection's source of truth — the gesture handlers emit `onSelectionIntent` and
  /// `EditorModel.audioSelection` is authoritative. Retired in a later task.
  var selectionAnchorID: Word.ID?
  var selectionFocusID: Word.ID?
  var document = TranscriptDocument(words: [])
  var plainTranscriptText: String { document.text }
  let minFontSize = 11.0
  let maxFontSize = 36.0
  let fontStep = 2.0
  let defaultFontSize = defaultTranscriptFontSize
  /// Selectable speeds shown in the menu, ascending. `<`/`>` nudge to the neighbouring preset.
  let speedPresets: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0]
  let minRate = 0.5
  let maxRate = 3.0
  var followMode: TranscriptFollowMode = .following
  var scrollTargetWordID: Word.ID?
  /// The word under the playhead while listening — the renderer gives it a light "current word"
  /// highlight. Tracks what's being SAID regardless of scroll-follow, and persists on the last
  /// word when the playhead sits in a gap or playback pauses, so you never lose your place.
  var currentWordID: Word.ID?
  /// The clip containers to draw, derived by `EditorModel` from slices + pending suggestions
  /// and pushed in by the view. Kept here (not recomputed from slices) so the transcript stays
  /// layout-local — it knows nothing about slices or the sidecar, only which words are clips.
  /// Assigning it recomputes the cached `clipContainers` so the O(n) derivation runs only on a
  /// real change, not on every body evaluation (the view reads `clipContainers` each playback tick).
  var clipBands: [TranscriptClipBand] = [] {
    didSet { recomputeClipContainers() }
  }
  /// Words struck through because they fall inside a removed section, derived by `EditorModel`
  /// from `timelineRemovals` and pushed in by the view — mirrors `clipBands`. The transcript
  /// stays layout-local and only renders what it's handed.
  var removedWordIDs: Set<Word.ID> = []
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
    // A stable colour index per clip (band), assigned in first-appearance order, so every run of
    // one clip shares a colour and clips that appear next to each other get different colours.
    var colorIndexByBand: [UUID: Int] = [:]
    func closeRun() {
      defer {
        runStart = nil
        runBand = nil
        runKind = nil
      }
      guard let start = runStart, let kind = runKind, let band = runBand else { return }
      let colorIndex = colorIndexByBand[band] ?? colorIndexByBand.count
      colorIndexByBand[band] = colorIndex
      containers.append(
        TranscriptClipContainer(
          range: NSRange(location: start, length: runEnd - start), kind: kind,
          colorIndex: colorIndex))
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

  /// One row in the speed menu — its rate, the display label, and whether it's the active speed
  /// (so the view can show a checkmark without deciding anything itself).
  struct SpeedOption: Identifiable, Equatable {
    let rate: Double
    let label: String
    let isCurrent: Bool
    var id: Double { rate }
  }
  /// The current speed formatted for the button, e.g. `1.0×`, `0.75×`, `1.5×`.
  var speedLabel: String { Self.speedLabel(playbackRate) }
  /// The menu rows, one per preset, each flagged if it's the current speed.
  var speedMenuOptions: [SpeedOption] {
    speedPresets.map {
      SpeedOption(rate: $0, label: Self.speedLabel($0), isCurrent: isCurrentSpeed($0))
    }
  }
  func isCurrentSpeed(_ rate: Double) -> Bool { abs(rate - playbackRate) < 1e-6 }
  var canSpeedUp: Bool { playbackRate < maxRate }
  var canSpeedDown: Bool { playbackRate > minRate }

  /// Formats a rate as `1.0×` / `0.75×`: two decimals, then one trailing zero trimmed so whole
  /// and half steps read as `1.0×`/`1.5×` while quarter steps keep both digits (`1.25×`).
  static func speedLabel(_ rate: Double) -> String {
    var text = String(format: "%.2f", rate)
    if text.hasSuffix("0") { text.removeLast() }
    return text + "×"
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
    rebuildForLoadedPlan()
  }

  func clearSelectionTapped() {
    selectionAnchorID = nil
    selectionFocusID = nil
    onSelectionIntent?(.clear)
  }

  /// Selects exactly one word (anchor == focus). Used by the waveform→transcript sync
  /// when the user clicks a point in the audio.
  func selectWord(_ id: Word.ID) {
    selectionAnchorID = id
    selectionFocusID = id
    onSelectionIntent?(.word(id, extending: false))
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
    onSelectionIntent?(.words(anchor: anchorID, focus: focusID))
    return true
  }

  /// Requests a scroll to the first selected word — an explicit reveal that isn't gated by
  /// `followMode`, so it works even after the user has scrolled away. No-op with no selection.
  func revealSelection() {
    guard let first = selectedWords.first else { return }
    revealToken += 1
    reveal = TranscriptReveal(wordID: first.id, token: revealToken)
  }

  /// Requests a scroll to a specific word, token-bumped so the renderer re-scrolls even to the same
  /// word. Used when the waveform owns the selection (freeform `audioSelection`) and drives the
  /// transcript scroll by the range's first overlapping word, rather than the transcript's own
  /// selection (which the waveform no longer sets).
  func revealWord(_ id: Word.ID) {
    revealToken += 1
    reveal = TranscriptReveal(wordID: id, token: revealToken)
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
    if extending, anchorIsValid, let anchor = selectionAnchorID {
      selectionFocusID = id  // keep anchor, move focus
      onSelectionIntent?(.words(anchor: anchor, focus: id))
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
    onSelectionIntent?(.word(id, extending: false))
  }

  func transcriptDragged(toUTF16Offset offset: Int) {
    guard let id = document.wordID(atUTF16Offset: offset), let anchor = selectionAnchorID else {
      return
    }
    selectionFocusID = id
    onSelectionIntent?(.words(anchor: anchor, focus: id))
  }

  func transcriptDragEnded() {}

  func zoomInTapped() { setFontSize(fontSize + fontStep) }
  func zoomOutTapped() { setFontSize(fontSize - fontStep) }
  func zoomResetTapped() { setFontSize(defaultFontSize) }
  func zoomChanged(_ size: Double) { setFontSize(size) }

  /// Picks an exact speed (a menu row).
  func speedSelected(_ rate: Double) { setPlaybackRate(rate) }
  /// `>` — steps up to the next preset above the current speed, clamped at the fastest.
  func speedUpTapped() {
    setPlaybackRate(speedPresets.first { $0 > playbackRate + 1e-6 } ?? maxRate)
  }
  /// `<` — steps down to the next preset below the current speed, clamped at the slowest.
  func speedDownTapped() {
    setPlaybackRate(speedPresets.last { $0 < playbackRate - 1e-6 } ?? minRate)
  }

  /// Derives the auto-scroll target from the playhead. A playback rising edge (false→true)
  /// always resumes following, even if the user had scrolled away. While following and playing,
  /// the target becomes the word containing `sample` (kept unchanged in a gap). The current-word
  /// HIGHLIGHT is separate — `EditorModel` drives `currentWordID` from the persistent cursor so
  /// it tracks where you are whether playing, paused, or scrubbed.
  func playheadChanged(sample: Int?, isPlaying: Bool) {
    if isPlaying, !wasPlaying { followMode = .following }
    wasPlaying = isPlaying
    guard isPlaying, followMode == .following, let sample, let word = wordID(atSample: sample)
    else { return }
    if word != scrollTargetWordID { scrollTargetWordID = word }
  }

  /// Sets the current-word HIGHLIGHT to the word under `sample`, mirroring how `EditorModel`
  /// drives the main editor's `currentWordID` from its persistent cursor — used by a scoped
  /// transcript (the slice-detail modal) that has no `EditorModel` to do it for them. Keeps the
  /// last word in a gap (never clears on a nil lookup) and only writes on a real change so a
  /// fast-ticking playhead doesn't churn the transcript view.
  func currentWordChanged(toSample sample: Int?) {
    guard let sample, let word = wordID(atSample: sample), word != currentWordID else { return }
    currentWordID = word
  }

  /// The word whose audio contains `sample`, or nil when it lands in a gap / past the end.
  private func wordID(atSample sample: Int) -> Word.ID? {
    editPlan?.words.first { word in
      guard let start = word.startSample, let end = word.endSample else { return false }
      return sample >= start && sample < end
    }?.id
  }

  /// Whether the "scroll to current word" control has somewhere to go.
  var canScrollToCurrentWord: Bool { currentWordID != nil }

  /// Re-reveals the word under the playhead and resumes follow — the "scroll to current word"
  /// button that gets you back after scrolling away by hand. A no-op before playback has placed
  /// a current word.
  func scrollToCurrentWordTapped() {
    guard let id = currentWordID else { return }
    followMode = .following
    revealToken += 1
    reveal = TranscriptReveal(wordID: id, token: revealToken)
  }

  /// The renderer calls this when the user scrolls the transcript by hand, so
  /// subsequent playhead ticks stop moving the scroll target until playback restarts.
  func transcriptUserScrolled() { followMode = .userPaused }

  // MARK: - Private Helpers
  private func setFontSize(_ size: Double) {
    $fontSize.withLock { $0 = min(max(size, minFontSize), maxFontSize) }
  }
  /// Clamps to the supported range, persists, and notifies `EditorModel` so the audio speed
  /// follows. Only fires the callback on a real change, so re-selecting the current speed is inert.
  private func setPlaybackRate(_ rate: Double) {
    let clamped = min(max(rate, minRate), maxRate)
    guard clamped != playbackRate else { return }
    $playbackRate.withLock { $0 = clamped }
    onPlaybackRateChanged?(clamped)
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
    currentWordID = nil
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
