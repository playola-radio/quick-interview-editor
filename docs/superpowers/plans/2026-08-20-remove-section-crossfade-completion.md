# Remove Section + Crossfade — Completion Plan (PRs 2–6)

**Status:** Plan approved-pending-user-review
**Date:** 2026-08-20
**Supersedes:** §6 "PR sequence" of
`docs/superpowers/specs/2026-08-18-remove-section-crossfade-design.md` (PR 1 of
that sequence shipped; this plan replaces its PRs 2–4 with a 5-PR completion
sequence). Architecture consult: Codex session `01a01f7d-6aa3-7fe1-86ef-d1cf777e9434`.

---

## Where we are

Shipped (spec PR 1 + freeform selection #54): `TimelineRemoval`/`Crossfade`
data model with normalization + per-seam clamping; `EditedTimeline`
source↔edited mapping including crossfade overlap; `EditedWaveformAdapter`
collapsed edited-axis rendering with a static bowtie X per seam; ⌫ delete
gesture from `audioSelection` with cross-seam rejection and pre-commit nudge;
`mutateDocument` snapshot undo (`EditorDocumentState`); sidecar persistence;
removed-word strikethrough.

Missing: all crossfade DSP; blended playback (transport plays the original
contiguous audio; `removalPlaybackNote` admits it); export is hard-blocked
whenever removals exist; no seam selection; no fade editing (length, curve,
center, ⌃⌥X, inspector); no way to delete a removal except whole-document undo.

## User requirements → PRs

1. Hear the edit + crossfade during normal playback → **PR 2 + PR 3**
2. Crossfades visible and editable exactly like Logic (curve shape + spread) → **PR 5**
3. A deletion is removable (restore original audio) → **PR 4**
4. Everything undoable → every PR routes document changes through `mutateDocument`

## Locked decisions

1. **Swift owns all sample construction — no parallel Python/Swift audio paths.**
   One `CrossfadeRenderer` (equal-power, linear, continuous `curveAmount`,
   per-frame across all channels) feeds both live audition and export. The
   failure mode of parallel paths — preview sounds different from export — is
   unacceptable. Python is demoted to marker injection only (see decision 5).
2. **Transport is ALWAYS in edited coordinates** in the main editor —
   `playheadEditedSample`, never a runtime branch on whether removals exist.
   With zero removals `EditedTimeline` is the identity map, so behavior is
   unchanged but the type meaning is stable. Convert to source only at
   boundaries that need source data (transcript word lookup, slice ranges,
   slice-edit modal, which stays source-coordinate internally).
   `PlaybackPosition` carries `editedSample` explicitly. Also rename
   `TimelineSeam.editedCenter` → `editedCrossfadeStart` (it is the overlap
   start, not the visual center); derive `editedCrossfadeCenter`.
3. **Playlist scheduler on the existing single `AVAudioPlayerNode` + TimePitch
   chain**, implemented inside `LivePlayerBox` as a new
   `playEdited(plan:rate:session:)` — NOT repeated public `play()` calls.
   Kept-segment interiors via `scheduleSegment` from the source file; each seam
   via a pre-rendered `AVAudioPCMBuffer` (`scheduleBuffer`). Schedule near-term
   items up front (small lookahead); completion callbacks are bookkeeping only,
   never gap-sensitive chaining. Contract:
   - `pause()` → `node.pause()`, freeze cursor from playlist frame timeline;
     schedule stays intact. `resume()` → `node.play()`, no reschedule.
   - `seek(editedSample:)` → stop, invalidate generation, rebuild playlist from
     that edited sample. Seeking into a seam renders a **partial seam buffer
     from the offset inside the crossfade** (never schedule the whole buffer
     and fake the cursor).
   - Rate rides `AVAudioUnitTimePitch`; node `sampleTime` advances in input
     frames, so rate changes need no position-math adjustment.
   - Cursor is computed from node time against the playlist frame timeline,
     never trusted from callback timing.
4. **`Crossfade` grows Logic-parity fields**, leniently decoded:
   ```swift
   struct Crossfade: Equatable, Codable, Sendable {
     var lengthSamples: Int
     var curve: CrossfadeCurve        // equalPower | linear (unknown → .equalPower)
     var curveAmount: Double          // -1.0…1.0 (UI shows -99…+99); missing → 0
     var centerOffsetSamples: Int     // shifts the fade center; missing → 0
   }
   ```
   One curve amount applied complementarily to out/in gains (no independent
   fade-in/fade-out shapes in v1).
5. **Export split = option (b):** Swift renders markerless AIFF PCM through the
   same renderer; Python injects/rebases MARK chunks via an explicit
   marker-injection API (the tested `aiff_markers` path stays; no Swift AIFF
   metadata writer, no new PyInstaller risk). Markers map source → edited with
   `.nilInsideRemoval` (drop markers inside removals), rebase slice-relative,
   enforce monotonic nudge-forward-one-frame.
6. **Seam selection is a peer of `audioSelection`, mutually exclusive.**
   `selectedSeamID: TimelineRemoval.ID?` (or an `EditorSelection` enum if the
   refactor is cheap): selecting a seam clears `audioSelection` and vice versa;
   Escape clears. Delete-key arbitration: seam selected → restore removal;
   source range selected → remove section; else existing fallback.
7. **Fade drags are draft-then-commit** (visual draft during drag, one
   `mutateDocument` commit on mouse-up — the established pattern; never mutate
   `@Observable` state per drag tick). No continuous audition per drag tick:
   audition on release + an explicit seam-audition command (~500 ms before →
   ~500 ms after the seam, edited coordinates).

## PR sequence

### PR 2 — Swift crossfade DSP + edited render plan (foundation)
- `CrossfadeRenderer`: equal-power/linear gain curves with `curveAmount`,
  per-frame, multi-channel; one shared endpoint/rounding convention.
- `AudioEditRenderPlan` / playlist builder from `EditedTimeline`: kept-segment
  interiors, per-seam overlap tails, partial-seam-from-offset support.
- Rename `editedCenter` → `editedCrossfadeStart` (+ derived center).
- Marker source→edited mapping helpers (used by PR 6).
- Tests: gain sums, channel correctness, determinism, overlap lengths,
  clamping, partial-seam offsets, the two-seams-sharing-a-short-island clamp
  case, marker mapping.
- No user-visible change. **May merge with PR 3 into one PR if the playlist
  prototype lands cleanly** — do not fold in export or fade-edit UI.
- Prototype first (riskiest): sample-accurate seam-buffer generation from
  `AVAudioFile` in the canonical AIFF format.

### PR 3 — Live edited transport (HEAR IT — earliest user value)
- `AudioPlayerClient.playEdited(plan:rate:session:)`; playlist scheduler in
  `LivePlayerBox` per decision 3.
- Main transport migrates to edited coordinates everywhere (decision 2);
  cross-tab cursor (`TransportContext`) carries edited samples.
- Boundary conversions: transcript current-word highlight, waveform playhead,
  slice-edit modal (stays source inside).
- Remove `removalPlaybackNote`.
- Keep the old `play(url:range:)` path for the slice-edit modal until
  deliberately migrated.
- Manual verify: play across a seam at 1x and at altered rates; pause/resume
  mid-crossfade; seek into a seam; ruler/playhead agree with the ear.

### PR 4 — Seam selection + Restore Removed Audio (small, ships fast)
- `selectedSeamID` + mutual exclusion with `audioSelection` (decision 6);
  bowtie hit-testing + selected visual state.
- `selectSeam(_:)`, `deleteRemoval(id:)`, `deleteSelectedRemoval()`,
  `updateCrossfade(id:_:)` — all through `mutateDocument` (undoable), with
  playback reconciliation + sidecar persistence.
- Interactions: click bowtie selects; ⌫ restores original audio; context menu
  + inspector "Restore Removed Audio"; Escape deselects.

### PR 5 — Logic-style crossfade editing
- Edge drag → `lengthSamples` (clamped to available handles); middle drag →
  `centerOffsetSamples`; vertical drag → `curveAmount`; `⌃⌥X` resets the
  selected seam to the equal-power default; numeric inspector (length, center,
  curve).
- All clamping through one model API so drag, keyboard, inspector, and undo
  share behavior; draft-during-drag, commit on mouse-up (decision 7).
- Audition on release + explicit seam-audition command using the PR 2 renderer.
- Bowtie visuals upgraded to Logic-style fade curves (curve shape reflects
  `curveAmount`).
- Verify Logic's actual defaults before implementing gestures (repo rule:
  interface parity — check, don't guess).

### PR 6 — Export with removals
- Swift renders each slice's PCM through the shared renderer; Python injects
  markers only (decision 5); explicit marker-injection API on the engine
  boundary.
- Markers in edited coordinates, slice-relative, monotonic.
- Remove the export hard-block; a removal consuming a whole slice marks it
  unexportable.
- Tight-join warning copy becomes crossfade-aware.
- Integration tests: rendered sample counts, marker positions, audition ==
  export determinism.

Deferred (unchanged from spec): slice-local removals (old spec PR 4 scope),
cut-suggester warning reconciliation beyond copy changes.

## Riskiest pieces — prototype before committing to the PR boundary

1. Gapless `scheduleSegment` + `scheduleBuffer` playlist on one node.
2. Edited-position reporting across pause/resume and rate changes.
3. Crossfade clamp semantics when two seams share a short kept island.
4. Marker rebasing for slices that partially overlap removals.
