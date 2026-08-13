# Transport PR 4 — convenience buttons become transport shortcuts — Plan

**Spec:** `docs/superpowers/specs/2026-08-12-playback-transport-design.md` (rulings D & F, TransportState/TransportContext end state)
**PR 3 plan:** `docs/superpowers/plans/2026-08-13-transport-pr3-working-transport.md`
**Branch:** `briankeane/transport-pr4-transport-shortcuts` (off `main`; PRs 1–3 merged)
**Architect:** Codex consult (session `019ff7ca…`) — rulings Q1–Q5 below.

## Goal

1. Convert the three convenience controls into transport **shortcuts**: saved-slice Play,
   fine-tune Preview toggle, boundary audition (▶In/Out▶, `[`/`]`). Each selects the right
   clip/suggestion, positions the cursor + range, and starts the ONE transport — so global
   Play/Pause/Stop and the single playhead govern them.
2. Remove the per-slice Stop affordance (ruling F). Keep the row "playing" highlight; no local Stop.
3. Collapse the three legacy owners (`playingSliceID`, `isPreviewingDraft`, `audition`) + their
   generation tokens (`previewGeneration`, `auditionGeneration`) into `TransportContext`
   (`.free` / `.slice(id)` / `.draftPreview` / `.audition(mode)`). The five derived display props
   (`sliceRows` isPlaying/playButtonLabel, `previewButtonLabel`, `isAuditioningIn/Out`,
   `auditionStatusText`) now derive from `transportPhase` + `transportContext`.
4. Fix the deferred multi-tab cursor limitation: disambiguate a cross-tab supersede from a genuine
   natural completion so a superseded background tab's cursor doesn't jump to the range end.

## Architect rulings (Codex Q1–Q5)

- **Q1 (state shape):** Codex favored a full `TransportState` struct. **Deviation:** we keep flat
  properties and add `transportContext`, and keep `playheadSample` a **separate** top-level
  observed property. Reason: `@Observable` invalidates on the *whole* struct property, so bundling
  the per-tick `playheadSample` with `phase`/`context` would invalidate every view that reads
  context/phase (slice List, transport panel) at ~30 Hz — regressing the playhead-isolation that
  `WaveformView` + PR 3 deliberately built ("its frequent updates never invalidate the canvas").
  Flat + `transportContext` gets the owner-collapse the spec wants without the observation cost.
- **Q1 (session slot):** Retire `currentPlaybackSession`; derive the owning session from
  `transportPhase.session` (single source of truth; after the collapse every owner plays through
  the transport, so the two are identical).
- **Q2 (toggles):** Slice Play becomes a pure start shortcut (no local Stop). Preview + audition
  **keep** their toggle-to-stop affordance (the button is the mode's status control), but the stop
  routes through the unified `transportStopTapped()`.
- **Q3 (unified helper):** One private `beginTransportPlayback(range:context:originSample:)` that
  every start funnels through (plain Play computes cursor→selection-end then calls it with `.free`).
  Ranges for shortcuts are **explicit** — never recomputed from the selection inside the helper.
  Transcript auto-scroll follow stays slice-only (`isPlaying: transportContext.isSlice`).
- **Q4 (retire generation tokens):** The session guard subsumes them — every start mints a fresh
  session, post-await cleanup guards `transportPhase.session == session`, deferred stops capture the
  session **before** clearing state and let the player actor gate `currentSession == session`.
- **Q5 (multi-tab fix):** `AudioPlayerClient.play` returns `PlaybackEnd { finished, stopped,
  superseded }` — `complete()`→`.finished`, `stop()`→`.stopped`, a superseding `play()`→`.superseded`.
  Post-await moves the cursor to `range.upperBound` only on `.finished`. Same-tab supersede already
  works via the session guard (beginExclusivePlayback replaces the session before the old await
  returns); the return value only matters for the cross-tab fork.
- **Trap:** `beginExclusivePlayback()` must never reset `playheadSample`. Stop → origin; natural
  finish → range end; nothing else moves the resting cursor.

## Stages (each = compile-clean commit, tests green)

### Stage A — engine: `play` returns `PlaybackEnd` + wire transport disambiguation
- `PlaybackEnd` enum; `LivePlayerBox` continuation carries it (`complete`/`stop`/`supersede` reasons).
- Update `testValue`/`previewValue` and all four model call sites + all test `play` overrides.
- Transport natural-end uses `end == .finished` (was `!failed`).
- Tests: `.superseded` return leaves cursor put; a shared-fake-box multi-tab supersede test.

### Stage B — collapse owners into `TransportContext` + shortcuts
- Add `TransportContext` + `transportContext`; remove `currentPlaybackSession`,
  `playingSliceID`, `isPreviewingDraft`, `audition`, `previewGeneration`, `auditionGeneration`.
- `beginTransportPlayback(range:context:originSample:)`; route Play + all three shortcuts through it.
- Derive the five display props from `transportPhase`/`transportContext`.
- Preview + audition tap-while-active → `transportStopTapped()`.
- `observePlayback` derives session from phase; transcript follow via `transportContext.isSlice`.
- Update every test referencing the legacy owners → `transportContext`.

### Stage C — views
- `SlicesPanelView`: slice Play is a start shortcut (no Stop toggle); highlight from `isPlaying`.
- `FineTuneView`: preview button → `previewToggleTapped` (routes stop through transport).
- `WaveformView`: audition buttons → toggle through transport.

Then: Codex review + challenge, `make format-check`/`lint`/`test` green, PR (base `main`), `/fix-review`.
