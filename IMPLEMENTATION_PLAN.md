# Edit / delete words inside clips from the transcript text view

Single PR on `briankeane/edit-words-in-clips`. Restore word-level deletion from the
transcript text (crossfade removal, struck through) even where a clip covers the
words, in BOTH the main window and the Edit-Slice sheet, kept in sync across the
main transcript, the main audio, and the clip audio via the shared document.

Design locked with Codex (Option A). Word selection INSIDE a clip is a **drag**
gesture (Logic marquee semantics); single-click and double-click keep their current
region select / open behavior untouched (avoids the double-click-to-open collision).
This diverges from the literal "click and drag" wording — single-click on a clipped
word still selects the whole clip; you drag inside the engaged clip to pick words.

## Stage 1: Drag two-step routing (main window)
**Goal**: A drag over a clip the user has not engaged first selects the clip; a drag
inside the engaged clip (or over unclipped words) paints a freeform word range.
**Where**: `EditorModel.onSelectionIntent` `.word` handler → new
`selectWordOrEngageClip` + `clipToEngage` + `isEditingWords(inside:)` in
`EditorModel+TranscriptSelection.swift`. `selectTranscriptObject` already invalidates
the transcript anchor, so the in-flight drag stops painting.
**Tests** (`EditorGroupSelectionTests` / new suite):
- drag-begin on a word in an unselected clip → `.object(.clip)` (not `.range`)
- drag-begin + drag over an unselected clip → stays `.object(.clip)` (no paint)
- drag-begin on a word in the engaged clip → `.range` (that word)
- drag across the engaged clip → `.range` spanning the words
- drag-begin on an unclipped word → `.range` (regression guard)
**Status**: Complete

## Stage 2: Delete on a freeform range removes audio (main window)
**Goal**: ⌫ / Delete on a `.range` selection performs the existing crossfade removal
(`removeSelectedSectionTapped` → `removeSourceRange`, appends a `TimelineRemoval`),
strikes the words through, clears the selection; undo restores.
**Where**: `EditorModel+SelectionHistory.swift` `deleteSelectionTapped()` `.range`
case → `await removeSelectedSectionTapped()` (was `clearSelectionTapped()`).
**Tests**: rewrite `deleteRangeOnlyClearsHighlightAndIsUndoable` →
removes audio + strikethrough + undoable; export stays blocked.
**Status**: Complete

## Stage 3: Edit-Slice sheet transcript select + delete
**Goal**: The sheet's transcript can select words (drag) and delete them; removals
funnel through the parent `EditorModel.removeSourceRange` so all surfaces stay in
sync. Selection clamped to the sheet's live draft/playback range.
**Where**: `EditSliceModel` (`transcript.onSelectionIntent` → `waveformSelection`,
`highlightedWordIDs`, `removedWordIDs`), `EditSliceView` (push highlight/strikethrough).
**Tests**: EditSlice suite — drag selects within clamp; Delete → parent removal;
out-of-clamp word rejected.
**Status**: Not Started

## Gates
`make test-fast`, `make format-check`, `make lint`; Codex adversarial review
(review + challenge) before PR; delegate PR-create to `codex exec`.
