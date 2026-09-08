# Transcript group selection

Date: 2026-09-08
Status: Agreed interaction model, with supporting details proposed for review.

## Purpose

Make the transcript's visible clips, suggestions, and freeform selections behave
as selectable groups. A click selects; a double-click opens; a drag selects words.
Overlapping groups remain independently accessible without cycling click targets.

## Agreed behavior

- Clicking a clip selects the whole clip and scrolls the right panel to its card.
- Double-clicking a clip opens its editor.
- Clicking inside an existing selection preserves it.
- Dragging selects words, including when the drag begins inside a selected group.
  There is no move gesture in the transcript.
- A selected clip comes to the front across its entire extent and remains there
  while selected.
- An overlap control lets the user explicitly choose a lower group. Choosing it
  brings it forward and reveals its sidebar card. A subsequent double-click in
  its text opens that chosen group.
- Selecting a lower clip through its sidebar card also brings it forward.
- Repeated clicks never cycle through overlapping groups.

## Existing implementation

The transcript's `HitTestingTextView` distinguishes clicks from drags but forwards
clicks only as a UTF-16 offset and Shift flag. `TranscriptPageModel` resolves a
word and emits a word-selection intent. Neither path selects a clip identity.

`EditorModel.audioSelection` owns the source-sample range. Sidebar reveal actions
also select a range derived from words, which can differ from a saved clip's
actual padded or finely adjusted audio boundaries. The existing `activeSliceID`
belongs to fine-tune editing and must not become a second, competing selection.

`EditorModel.clipBands` removes words claimed by saved clips from suggestions.
`TranscriptPageModel` then gives each word to the first remaining band. Drawable
containers retain style and range, but lose the owning band's identity. This
makes an overlapping group appear fragmented or disappear entirely.

Saved clips already have an editor sheet. Suggestions and freeform ranges do not
currently have a corresponding draft sheet.

## Selection and gestures

Maintain one active selection: a saved clip, a pending suggestion, a freeform
audio range, a crossfade seam, or none. Object identity and range must stay in
agreement. Selecting an object is transient UI state and does not edit the
document or add an undo entry.

| Input | Result |
| --- | --- |
| Single-click a group | Select its identity and full range; reveal its sidebar card |
| Single-click inside the active group or range | Keep the target and range; re-reveal its card if it has one |
| Single-click unmarked text | Select that word |
| Double-click a saved clip | Open the existing clip editor once |
| Double-click a suggestion or freeform range | Open the draft editor described below |
| Drag from any transcript word | Replace object selection with a freeform word range |
| Shift-click a word | Extend the range from its existing anchor; transition an object to freeform selection |
| Click true empty transcript background | Clear the selection |
| Escape | Close an open overlap chooser first; otherwise clear the selection |

When an object becomes a freeform range, edits to that range do not change the
saved clip or suggestion. A plain group selection seeds the range anchor at its
start; subsequent range gestures retain the established anchor semantics.

Inter-word spaces within a visible group belong to that group for clicking.
Empty margins, trailing line whitespace outside a container, and paragraph gaps
must not resolve to the nearest word accidentally. Drags retain normal word
selection behavior and do not open editors on release.

Use a small movement tolerance to distinguish an intentional drag from pointer
jitter. Use the system double-click count. The first click may select and reveal
immediately; the second opens the same target. Sidebar reveal must not reflow or
scroll the transcript underneath the pointer during this sequence. Modified
range gestures do not also open an editor.

## Overlap resolution and presentation

Retain full membership and identity for every saved clip and pending suggestion.
Resolve display precedence separately from candidate discovery. Drawing a group
behind another must not remove it from the overlap chooser.

The active object wins wherever it covers the clicked text. Otherwise, saved
clips precede suggestions, with stable document order within each type. This
order also determines the visible foreground group, so clicks select what the
user sees. Bringing an object forward does not reorder the sidebar or document.

A freeform selection takes precedence inside its highlighted range. Groups
underneath remain accessible through the chooser or sidebar. Selecting one
replaces the freeform range with that object.

Expose an overlap control beside the clicked line when multiple objects cover
that word, including when covered by a freeform selection. Label it with the
number and kind of candidates: "2 clips", "2 suggestions", or "3 items".
It must be an overlay that does not alter text wrapping or layout.

The chooser lists all objects covering the clicked word, including fully hidden
and identical-range objects. Each row shows the name, clip/suggestion type,
duration, and selected state. Hover previews the candidate's full extent without
changing selection, playback, or scroll. Clicking commits the choice and closes
the chooser. Escape dismisses the preview and preserves the existing selection.
Keyboard focus and activation offer the same choice without requiring hover.

Selecting B under A makes B's entire range visible in front, including across
wrapped lines and paragraph breaks. A and other groups are subdued. Repeated
clicks inside B preserve B. Double-clicking there opens B, including when their
ranges are identical. Clicking A's exposed text or choosing A explicitly selects A.

Use one clear active outline. Preserve the distinction between a saved clip's
solid outline and a suggestion's dashed outline; color alone must not encode
type or active state. Preserve group color identity when changing foreground
order. The playback word indicator remains distinguishable from selection.

When suggestion overlays are hidden, they are excluded from transcript click
targets and the chooser. Explicitly selecting a pending suggestion in the
sidebar turns the overlay on and reveals its full selected range. Accepted
suggestions resolve to their saved clip when that clip exists; they are not a
second overlapping transcript object. Rejected suggestions are not active
transcript groups.

## Sidebar and waveform synchronization

A transcript click highlights and reveals the matching sidebar card. Switch to
Clips or Suggestions if needed; preserve Both when both panels are already shown.
If a clip filter excludes the target, switch to All so the target can be revealed.
Use repeatable reveal requests so clicking the same object after manually
scrolling its card away reveals it again.

A sidebar card's selection surface selects the same object and reveals its text
and waveform. Title fields and action buttons retain their own gestures; their
clicks and double-clicks must not accidentally open the editor.

Saved-clip selection uses its actual source-sample boundaries. Transcript
highlighting derives the overlapping words from that range. Selecting a
suggestion resolves its full valid word range. Selecting within the transcript
keeps its current scroll position and waveform zoom; pan the waveform only as
needed to reveal the selection's start. Explicit sidebar reveal retains the
existing behavior of framing the target in the transcript and waveform.

Selection keeps the existing playhead placement policy and does not start
playback. Re-clicking an unchanged selection does not restart or interrupt audio.
Opening the editor retains the existing transport handoff to its scoped player.

## Opening suggestions and freeform selections

This section is a proposed completion of the user's request that double-click
opens the selection, extending the agreed saved-clip interaction consistently.

- A saved clip opens its existing editor and saves changes to that clip.
- A pending suggestion opens a draft based on that suggestion. "Accept as Clip"
  validates freshness, creates the edited clip, and marks the suggestion accepted
  in one document undo step. Opening or cancelling does not accept it.
- A freeform range opens a draft. "Create Clip" saves one new clip in one undo
  step. Opening or cancelling does not create a clip.
- A double-click on previously unselected plain text opens the word range
  selected by its first click. A double-click within an existing freeform range
  opens that entire range.

Draft editing initially supports boundary adjustment and preview/audition using
the existing editor controls. Global audio-removal, crossfade-editing, and
editing-complete controls are omitted from unsaved drafts: those controls
currently mutate the document immediately, which would violate draft cancellation.
Saved clips retain their existing editor capabilities and mutation semantics.
The source document is unchanged by opening, previewing, or cancelling a draft.

The bottom bar exposes actions for the selected kind: Edit/Play for a clip,
Accept/Reject for a suggestion, Mark as Clip for a freeform range, and Clear.
Explicit actions remain available as keyboard-accessible alternatives to
double-click. There is no sidebar card to reveal for an unsaved freeform range.

## State ownership and failure behavior

Keep interaction policy in observable models, following the repository's MV
architecture. The editor owns the selected identity and authoritative audio
range, routes sidebar requests, and opens/commits editing sessions. Transcript
models resolve word hits and derive drawing and overlap presentation data.
AppKit supplies geometry, modifier flags, click counts, and drag events; SwiftUI
renders model-derived state and forwards actions.

Use a focused selection/overlap unit rather than adding every new rule to the
large `EditorModel.swift`. The renderer and hit resolver consume the same
foreground ordering and stable typed object identities. Fine-tune session
reconciliation must not silently turn an object click into a new-clip draft.

Retain the current document format. Selection, foreground state, hover preview,
chooser presentation, and reveal tokens are local to each document window.

Deletion, undo/redo, regeneration, rejection, and acceptance reconcile the active
identity and open chooser against the current document. Clear missing targets;
transition an accepted suggestion to its resulting clip. Update the selected
range when an existing selected clip changes. Never fall through to a different
overlapping object when the intended editor target disappears.

Stale or invalid suggestions retain the existing actionable error messages and
cannot be accepted through the draft path. Validate again at commit. Reuse
existing unsaved-edit protection for saved clips and existing export constraints.

## Verification criteria

Model tests must establish:

1. Whole-object selection retains identity and exact saved audio boundaries.
2. Clicking inside an active range preserves it; dragging and Shift-click make
   freeform selections without mutating objects.
3. Saved/saved, saved/suggested, suggested/suggested, nested, identical-range,
   and three-way overlaps all expose their complete candidate sets.
4. Choosing a hidden object brings its full range forward; clicking and
   double-clicking it keep the same identity.
5. Selecting the same object issues a fresh sidebar reveal without restarting
   playback; filters, hidden panels, and Both resolve as specified.
6. Sidebar and transcript selection agree, including hidden suggestion overlays.
7. Opening/cancelling drafts leaves the document unchanged; committing creates
   or accepts exactly once and is undone as one action.
8. Staleness, deletion, undo/redo, and regeneration cannot open or commit the
   wrong object or retain invalid chooser rows.
9. Drag completion never opens an editor, and blank background does not select
   a nearby word.
10. Selection is isolated between document windows and survives view updates
    without becoming an unintended fine-tune edit target.

Manual macOS verification must cover click/double-click timing, pointer jitter,
dragging through overlaps, wrapped text, spaces, paragraph gaps, text zoom,
sidebar panel switching, inline title editing, chooser positioning, keyboard
activation, VoiceOver labels, and playback during selection. In particular,
switching sidebar modes must not move the text under an in-progress double-click.

Run focused transcript, reveal, selection, suggestion, edit-sheet, and transport
tests during implementation; run the full app suite plus formatting and lint
checks before delivery. This document introduces no executable changes.
