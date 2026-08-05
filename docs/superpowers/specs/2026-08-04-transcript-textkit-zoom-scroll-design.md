# Transcript: TextKit rendering + text zoom + scroll — Design

**Date:** 2026-08-04
**Status:** Approved (brainstorming complete; architecture consulted with Codex)
**Area:** `QuickInterviewEditor` — `Views/Pages/TranscriptPage`, with touch-points in `Views/Pages/Editor`

## Problem

Loading a large interview (e.g. a ~15.6 min, 90 MB mono WAV) makes the whole app
sluggish, and the transcript has no way to zoom the text or scroll.

Root cause is **not** the `.wav` format. WAV is uncompressed, so the file is large
and costs a bit of one-time decode, but the audio pipeline is already well
optimized (streamed decode, multi-resolution peak pyramid, per-pixel waveform
columns). The lag is the **transcript rendering**:

- `TranscriptPageView.swift` renders **every word** as its own SwiftUI `Text`
  view (padding, background, clipShape, `onTapGesture`) inside a **custom
  `FlowLayout`** that is **not lazy**. A long interview is 10k+ word views, all
  materialized and measured twice per layout pass. There is **no `ScrollView`
  anywhere in the app**.
- `TranscriptPageModel.recomputeWords()` rebuilds the entire `words` array — and
  re-runs run-together detection over all words — on **every tap** and on **every
  continuous sensitivity-slider tick**, with no throttling.

## Goals

1. Fix large-file sluggishness in the transcript.
2. Add text zoom in/out on the transcript (font-size scaling).
3. Add vertical scrolling to the transcript.

## Non-goals (YAGNI)

- **Drag-to-copy transcript text** is deferred. The word→range map added here
  makes it easy to add later (plain drag = OS text selection + ⌘C), but it is not
  built in this pass.
- **No waveform changes.** The waveform already has zoom + pan; the requested
  zoom is on the *text*, which lives entirely in the transcript.

## Approach

Replace the `FlowLayout`-of-`Text`-views transcript with a single TextKit-backed
`NSTextView` rendered as one attributed string. Word state (selected, run-together)
is applied as **text attributes** and mutated **incrementally**. All logic stays
in the `@Observable` model; the `NSViewRepresentable` is a dumb renderer.

### Selection semantics (contiguous, unchanged invariant)

The existing selection is contiguous by design: `selectionAnchorID` /
`selectionFocusID` project to a single `selectedSampleRange`
(`first.startSample ..< last.endSample`) because a slice is one continuous audio
range and cannot have holes. This is preserved.

- **Single-click** selects one word (anchor == focus).
- **Click-drag** extends the focus contiguously to paint a run of words.
- **Clicking the sole selected word** clears the selection.
- No non-contiguous multi-word selection is introduced.

### Rendering — `TranscriptTextView: NSViewRepresentable` (TextKit 1)

- Wraps `NSTextView` + `NSScrollView` + `NSTextStorage`, using **TextKit 1**
  (`NSLayoutManager` / `NSTextContainer`). Chosen over TextKit 2 for stable,
  predictable character-index hit testing
  (`characterIndex(for:in:fractionOfDistanceBetweenInsertionPoints:)`),
  `glyphRange(forCharacterRange:)`, and `scrollRangeToVisible(_:)`.
- The transcript is one attributed string. Word attributes:
  - **Selected:** the existing red-ish selection background over the word range.
  - **Run-together:** the existing red foreground styling over the word range.
- `NSTextView` is read-only (not user-editable) and non-selectable for OS text
  selection in this pass (slice-selection owns click/drag).
- Native vertical scrolling via the enclosing `NSScrollView`.

### Model / renderer boundary

**`TranscriptPageModel` owns (all logic, fully testable):**

- `plainTranscriptText: String` — the joined transcript.
- An **ordered word → UTF-16 `NSRange` map** built when the plan / font / config
  changes (not rebuilt per observation pass).
- `selectionAnchorID` / `selectionFocusID` (contiguous selection; unchanged).
- `runTogetherWordIDs: Set<Word.ID>`.
- `fontSize: Double`, persisted app-wide.
- `followMode` and `scrollTargetWordID`.
- Intent methods driven by the renderer:
  - `transcriptClicked(atUTF16Offset:)`
  - `transcriptDragBegan(atUTF16Offset:)` / `transcriptDragged(toUTF16Offset:)` /
    `transcriptDragEnded()`
  - `transcriptUserScrolled()`
  - `zoomInTapped()` / `zoomOutTapped()` / `zoomResetTapped()` / `zoomChanged(_:)`
- Mapping a UTF-16 offset → `Word.ID` uses the model's own range table.

**The representable is dumb — owns only AppKit plumbing:**

- The `NSTextView` / `NSScrollView` / `NSTextStorage` lifetimes.
- Converting a mouse point → UTF-16 offset (rendering plumbing), then calling the
  model with that offset. It never decides which *word* an offset is.
- Applying model-provided attribute diffs to `NSTextStorage`.
- Reporting scroll events back to the model.

**Tests never construct the representable.** Behavior is tested on the model.

### Efficient re-render (incremental attribute mutation)

The model holds `selectedWordIDs` (derived from anchor/focus) as source of truth.
On change, the renderer diffs the previously-rendered set vs the new set:

```swift
let removed = lastRenderedSelectedWordIDs.subtracting(model.selectedWordIDs)
let added   = model.selectedWordIDs.subtracting(lastRenderedSelectedWordIDs)
```

and calls `textStorage.addAttribute` / `removeAttribute` for **only** those word
ranges. Same diff strategy for run-together styling. Deciding a word is selected
is model logic; applying a background color to an `NSRange` is renderer work.

- **Selection changes** never touch the font attribute.
- **Zoom changes** update the font attribute across the whole string (rare event).

### Zoom

- Controls: `[−] [slider] [+]` in the transcript header **plus** ⌘+ / ⌘− / ⌘0
  keyboard shortcuts. All drive a single `fontSize` on the model.
- Bounds: ~11pt–36pt. Default stays at the current 17pt.
- Persistence: **app-wide across launches** via `@Shared(.appStorage(...))` (not
  raw `UserDefaults`).

### Auto-scroll follow (with manual override)

- Model owns `followMode` (`.following` / `.userPaused`).
- The representable sets an `isProgrammaticScroll` flag around
  `scrollRangeToVisible`. A scroll notification that is **not** programmatic calls
  `model.transcriptUserScrolled()`, which flips `followMode` to `.userPaused`.
- While `.following`, the model derives the current playhead word from the
  playback position and updates `scrollTargetWordID`; the renderer scrolls to it.
- **Re-enable rule:** follow resumes when playback (re)starts. (Single explicit
  rule, tested. Not "user scrolled back near playhead" — that ambiguity is
  avoided.)
- The renderer never decides "near the playhead"; the model owns that decision.

### Slider throttle

- Split the sensitivity value into:
  - `draftGapMs` — updates the label only, live during drag.
  - `runTogetherMaxGapMs` — effective value, committed on a debounce.
- Debounce uses an injected `@Dependency(\.continuousClock)`; tests use an
  immediate/test clock. No `Task.sleep` in tests.
- Precompute per-adjacent-word **gap records** once (leftID, rightID, gapMs) so a
  sensitivity change filters gaps instead of re-walking every word's timestamps.

### Cleanup this touches

`EditorModel.redRanges` currently derives from `transcript.words`. Once the
per-word `words` array is removed, `TranscriptPageModel` exposes run-together
ranges directly and `EditorModel` reads those.

## Testing

- All new behavior is tested on `TranscriptPageModel` with Swift Testing and
  `expectNoDifference` / `expectDifference` (per `pfw-testing`, `pfw-custom-dump`).
- Covered: click selects one word; drag extends contiguously; click sole selected
  word clears; UTF-16 offset → word ID mapping (incl. boundaries); zoom
  in/out/reset bounds + clamping; zoom persistence via `@Shared`; follow-mode
  transitions (playback advances target; user scroll pauses; playback restart
  resumes); slider draft-vs-effective debounce with an immediate clock;
  run-together gap-record filtering.
- The `NSViewRepresentable` is never instantiated in tests.

## Risks / things to get right

- Keep selection **contiguous**; do not let click/drag create holes.
- Do **not** rebuild the attributed string inside `updateNSView`; build the
  document/range map in the model on config change, apply incremental diffs in the
  renderer.
- Do **not** let the coordinator own word mapping — the model owns it.
- Use a stable UTF-16 `NSRange` map for hit testing, not Swift `String.Index`.
- Zoom = full font update; selection = incremental only.
- Guard against `scrollRangeToVisible` disabling auto-follow (programmatic flag).
- Persist zoom via `@Shared(.appStorage(...))`, not raw `UserDefaults`.
- Re-point `EditorModel.redRanges` off the removed `words` array.
