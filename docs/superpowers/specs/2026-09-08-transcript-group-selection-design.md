# Transcript group selection

Date: 2026-09-08
Status: Approved; revised after Claude adversarial review and user decisions.

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

An explicit Delete/Clear of a highlight is the exception: clearing it is undoable
transient state, without modifying the saved document. Ordinary click, drag,
Escape, and background deselection do not add history entries.

| Input | Result |
| --- | --- |
| Single-click a group | Select its identity and full range; reveal its sidebar card |
| Single-click inside the active group or range | Keep the target and range; re-reveal its card if it has one |
| Single-click unmarked text | Select that word |
| Double-click a saved clip | Open the existing clip editor once |
| Double-click a suggestion or freeform range | Open the draft editor described below |
| Drag a transcript group body | Replace object selection with a freeform word range |
| Drag a transcript edge handle | Resize that selection, clip, or suggestion; commit object edits in one undo step |
| Shift-click a word | Extend the range from its existing anchor; transition an object to freeform selection |
| Click true empty transcript background | Clear the selection |
| Escape | Close an open overlap chooser first; otherwise clear the selection |
| Delete with a clip selected | Delete that clip object and clear selection; one undo step |
| Delete with a suggestion selected | Delete that suggestion and clear selection; one undo step |
| Delete with a freeform highlight | Clear the highlight; one undo step; preserve audio |
| Arrow keys with a clip or suggestion selected | Leave the object and its range unchanged |
| Arrow keys with a freeform range | Retain existing start/end boundary nudges |

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

The existing single-word toggle-off behavior is removed. AppKit forwards click
count as well as the hit location and modifiers. A drag begins at 4 points of
movement from mouse-down, using that original position as the selection anchor.
The second click opens the target captured by the first click; deletion or
invalidation of that target cancels Open rather than targeting its replacement.
This gesture policy applies to the main transcript. Transcripts inside editing
sheets do not recursively open further editors or reveal main-window sidebar cards.

## Keyboard and undo contracts

Delete acts on the active selection as specified above. Deleting a suggestion
removes its record from the document and sidebar. The explicit Reject action
retains its existing status-based behavior. Deleting a clip does not change source audio,
timeline removals, or acceptance status of its originating suggestion. Undo
restores the deleted object and selects it again; Redo reapplies the
deletion and clears the selection. Undo of Delete/Clear on a highlight
restores its exact sample range and anchor; Redo clears it again.

The main waveform follows the same active-selection Delete rule. Audio removal
remains available as an explicit "Remove Section" action on a freeform range.
The existing saved-clip editor keeps its scoped audio-removal shortcuts. A
selected crossfade seam keeps its existing Delete-to-restore behavior.

Arrow and Shift-arrow keys do not trim selected objects. Range adjustment first
requires a freeform selection (drag or Shift-click) or opening the editor.
Main waveform edge handles are available for freeform ranges only. Transcript
edge handles remain available for freeform selections, saved clips, and pending
suggestions. They use the full visible word geometry and preview changes during
the drag; Escape cancels and release commits one undoable object edit. At coincident
edges, the freeform selection wins, then the selected foreground object, then the
remaining groups in drawing order. Existing zoom shortcuts and seam-specific
Option-arrow commands retain their meanings.

Editing fields own their usual text deletion, selection, and undo keys. An open
chooser owns its navigation keys and consumes Delete without affecting the
underlying selection. Escape first ends/cancels field editing when the field owns
it, then dismisses the chooser if present, then cancels an editing sheet if one
is open, otherwise clears main selection. A handled Escape never also acts on
the parent window.

One chronological main-editor history contains document actions and explicit
highlight clears. Highlight-only Undo/Redo never restores a document snapshot,
fires document-change callbacks, changes timeline audio, or marks the project
dirty. Document deletion plus its selection change is one entry. Ordinary
document Undo/Redo preserves the current selection unless reconciliation is
required or that entry explicitly restores a deletion's selection. Background
suggestion updates retain the existing history-rebase behavior. Selection
navigation does not add history entries or clear Redo; new undoable actions do.

Unsaved drafts have their own boundary Undo/Redo history. One pointer drag is one
entry, and one nudge press is one entry. Empty draft history consumes Undo/Redo
without falling through to document history. Saving is one document transaction;
cancelling discards the draft and its local history. Saved-clip editor history
retains its current document-edit and unsaved-boundary protections.

## Overlap resolution and presentation

Retain full membership and identity for every saved clip and pending suggestion.
Resolve display precedence separately from candidate discovery. Drawing a group
behind another must not remove it from the overlap chooser.

Specifically, stop subtracting saved-clip words from suggestion bands. Keep typed
object identity on every drawable container. Saved-clip bands, hit candidates,
and selection highlighting all derive from actual source bounds using the
half-open `wordIDs(anyOverlap:)` predicate. Persisted `Slice.wordIDs` and export
behavior are not changed as an incidental part of transcript projection.

The active object wins wherever it covers the clicked text. Otherwise, saved
clips precede suggestions, with stable document order within each type. This
order also determines the visible foreground group, so clicks select what the
user sees. Bringing an object forward does not reorder the sidebar or document.

Fill, outline, text color, hit precedence, and chooser order share this ordering;
draw back-to-front. Stable document order means the current document arrays;
regeneration replaces suggestion ordering. Assign identity colors independently
of selection ordering. Active state adds emphasis to the object's own style
rather than replacing its clip/suggestion kind.

A freeform selection takes precedence inside its highlighted range. Groups
underneath remain accessible through the chooser or sidebar. Selecting one
replaces the freeform range with that object.

Inside a freeform highlight, that entire freeform range is the click/double-click
target even when it covers several clips. Only the chooser or sidebar switches
to an underlying object.

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
Duration uses the resolved range divided by the source sample rate. Hover is
draw-only and must not alter text metrics, hit precedence, or selection identity.

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

An accepted suggestion whose clip has been deleted and a rejected suggestion
remain historical sidebar rows. Their reveal actions may select their resolvable
word span as a freeform range, but never recreate or reopen a missing clip.

## Sidebar and waveform synchronization

A transcript click highlights and reveals the matching sidebar card. Switch to
Clips or Suggestions if needed; preserve Both when both panels are already shown.
If a clip filter excludes the target, switch to All so the target can be revealed.
Use repeatable reveal requests so clicking the same object after manually
scrolling its card away reveals it again.

Both panels use identity-plus-token reveal requests. Transcript-initiated reveal
never enters or leaves Both mode, so it never changes sidebar width. Replace the
existing whole-card double-tap with a gesture on the card's selection surface.

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

Double-click opens the selection for all three selection kinds.

- A saved clip opens its existing editor and saves changes to that clip.
- A pending suggestion opens a draft based on that suggestion. "Accept as Clip"
  validates freshness, creates the edited clip, and marks the suggestion accepted
  in one document undo step. Opening or cancelling does not accept it.
- A freeform range opens a draft. "Create Clip" saves one new clip in one undo
  step. Opening or cancelling does not create a clip.
- A double-click on previously unselected plain text opens the word range
  selected by its first click. A double-click within an existing freeform range
  opens that entire range.

The editing session has an explicit saved-clip, suggestion-draft, or freeform-draft
target. Valid draft commit is enabled even when boundaries are unchanged. Failed
commit keeps the sheet open, preserves its range and local history, and shows an
actionable error in the sheet. A successful commit selects the resulting clip.

Apply configured new-clip boundary offsets once when initializing a draft. Show
and preview those adjusted bounds; save the final previewed bounds exactly without
applying offsets again. Immediate Mark/Accept actions retain their existing offset
behavior. Validate the original suggestion's freshness and identity at commit,
then build the resulting clip from the edited range, deriving membership and
snippet from that range. Do not require the edited range's words to equal the
original suggestion's words. Invalid, empty, out-of-file, or wordless ranges
cannot commit. Boundary adjustment retains existing minimum-duration constraints.

Draft editing initially supports boundary adjustment and preview/audition using
the existing editor controls. Global audio-removal, crossfade-editing, and
editing-complete controls are omitted from unsaved drafts: those controls
currently mutate the document immediately, which would violate draft cancellation.
Saved clips retain their existing editor capabilities and mutation semantics.
The source document is unchanged by opening, previewing, or cancelling a draft.

Draft playback reads the current edited timeline, including already-removed audio,
without changing it. If the suggestion disappears, is completed elsewhere, or no
longer matches its opening identity/provenance, keep the draft visible with commit
disabled and a reason; do not discard adjustments or bind to a replacement. The
same applies if the source changes. Saved-clip editor reconciliation retains its
existing behavior. A new editor session cannot be opened over an unsaved saved-clip
edit; show "Save or cancel the current edit before opening another clip."

The bottom bar exposes actions for the selected kind: Edit/Play for a clip,
Accept/Reject for a suggestion, Mark as Clip for a freeform range, and Clear.
Explicit actions remain available as keyboard-accessible alternatives to
double-click. There is no sidebar card to reveal for an unsaved freeform range.
Provide Open/Edit on all three kinds, and Remove Section on freeform ranges.

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

An object selection alone has no fine-tune editing target. Only a freeform range
may drive the existing pending-selection session; opening a sheet explicitly
creates that sheet's editing target. The old activeSliceID editing state must not
compete with selected object identity. Type-tag clip and suggestion IDs because
accepted suggestions and their resulting clips intentionally share the same UUID.

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
11. Delete removes only the selected object/highlight, is undoable and redoable,
    and does not remove timeline audio. Seam and saved-editor deletion retain
    their scoped behavior. Object arrow keys and edge drags do not trim objects.
12. Highlight-clear Undo/Redo creates no document callback and interleaves in
    chronological order with document edits, preserving background history rebases.
13. Draft Undo/Redo coalesces pointer drags, preserves nudge granularity, and never
    reaches the parent document, even when local history is empty.
14. Unchanged drafts can commit; failures preserve the sheet; final saved samples
    exactly match previewed bounds with nonzero configured offsets.

Manual macOS verification must cover click/double-click timing, pointer jitter,
dragging through overlaps, wrapped text, spaces, paragraph gaps, text zoom,
sidebar panel switching, inline title editing, chooser positioning, keyboard
activation, VoiceOver labels, and playback during selection. In particular,
switching sidebar modes must not move the text under an in-progress double-click.

Run focused transcript, reveal, selection, suggestion, edit-sheet, and transport
tests during implementation; run the full app suite plus formatting and lint
checks before delivery. This document introduces no executable changes.
