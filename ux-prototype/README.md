# Handoff: Audio Waveform Editor (macOS app)

## Overview
A desktop (native macOS) audio editor for slicing single-person interview clips into
exportable chunks. The user works top-to-bottom: a **waveform** at the top (zoomable,
scrubbable) and the **transcript** below. The primary way to make a cut is to
**highlight a run of words in the transcript** — this simultaneously highlights the
matching region on the waveform. The user then **fine-tunes the exact in/out cut points**
using two magnified ("zoomed in") views of the waveform boundaries, and saves the
selection as a **slice**. Slices collect in a panel and can be exported individually or
all at once.

The visual style follows the **Playola iOS design system** (dark, black background,
Playola red `#cc6666` accent, Inter for body / Space Grotesk for display).

## About the Design Files
The files in this bundle are **design references created in HTML** (a streaming
"Design Component" prototype) — they demonstrate the intended look and behavior. They are
**not production code to copy directly**. The task is to **recreate this design in the
target codebase's environment**. Because this is a native macOS app, the natural target is
**SwiftUI/AppKit** — recreate the layout, waveform rendering, and interactions using native
patterns and the app's existing design tokens. If the project has no environment yet, pick
the most appropriate framework for a Mac audio app. Do not ship the HTML.

## Fidelity
**High-fidelity.** Final colors, typography, spacing, and interactions are specified below.
Recreate the UI faithfully using the codebase's native components. The waveform amplitude
data in the prototype is synthetic (a procedurally generated speech-like envelope) purely
so the mock looks realistic — in the real app it must be derived from the decoded audio.

## Layout (single window)
Native macOS window with standard traffic-light title bar. Two overall layout variants were
explored (the user can pick either):

- **1a — Sidebar studio** (window ~1160px wide): a left column (waveform on top, transcript
  below) and a **right slices sidebar** (~302px) that can be collapsed via a toolbar toggle.
- **1b — Stacked timeline** (window ~1040px wide): full-width waveform on top, transcript
  below it, and a **horizontal slice tray** running along the bottom.

Shared vertical order in both: **Title bar → Toolbar → Waveform → (Selection / fine-tune
panel, when a selection exists) → Transcript → Slices**.

### Title bar
- Height ~46px; subtle vertical gradient `#1c1c1c → #151515`; bottom border `#242424`.
- Left: three 12px traffic-light dots (`#ff5f57`, `#febc2e`, `#28c840`), 8px gap.
- Center: file name, 13px, `#9a9a9a`, weight 500. Copy: `Interview_047_clip.wav — Waveform Editor`.

### Toolbar (height ~50px, bg `#111`, bottom border `#222`, 9px gap)
Left group:
- **Play/Pause** button: 34×34, radius 9px, bg Playola red `#cc6666`, white SVG icon
  (triangle play / two-bar pause).
- **Time readout**: `M:SS.d / M:SS` (e.g. `0:00.0 / 0:28`), 13px, tabular-nums, current in
  `#d4d4d4`, total in `#565656`.
- **Speed** button: cycles **0.5× → 1× → 1.5× → 2×**. 30px tall, radius 8px, border `#2f2f2f`,
  bg `#191919`, text `#cfcfcf` 12px.

Right group (each button 30px tall, radius 8px, border `#2f2f2f`, bg `#181818`, text
`#cfcfcf` 12px, separated by 1×20px `#2a2a2a` dividers):
- **Undo**, **Redo**
- **+ Marker** (drops a marker at the current playhead)
- **−**  `<zoom%>`  **+**  (zoom out / label / zoom in; label like `100%`)
- **Fit** (fits the current selection into view; if none, resets zoom)
- **Hide slices › / ‹ Slices** toggle (only in the 1a sidebar layout)

### Waveform
- Framed box: bg `#090909`, 1px border `#1d1d1d`, radius 10px, ~12px padding.
- Small caption row above it: label **WAVEFORM** (11px, uppercase, letter-spacing .09em,
  `#6f6f6f`) on the left; hint `click to scrub · amber ticks = silence detected` (`#565656`)
  on the right.
- The wave itself is a **smooth, continuous, filled silhouette mirrored around the vertical
  center** (NOT discrete bars). Base fill `#6f6f6f`. Height ~138px. Horizontally scrollable;
  inner content width = `BASE_W (920px) × zoomLevel`.
- **Selection region**: the portion of the silhouette inside the selected time range is
  filled Playola red `#cc6666` (via a clip rect over the same path), plus a translucent
  marquee overlay `rgba(204,102,102,.10)` with 2px red left/right edges.
- **Playhead**: 2px white vertical line with a 10px white dot at top; soft dark shadow.
- **Markers**: 2px `#febc2e` vertical lines at 85% opacity.
- **Scrub**: mousedown anywhere on the wave sets the playhead to that time (and pauses).

### Selection / fine-tune panel (visible only when words are selected)
Card: bg `#131313`, 1px border `#262626`, radius 12px, ~12px padding.
- Header row: left column shows `SELECTION · <dur>s` (11px uppercase `#7a7a7a`) and the
  quoted transcript snippet (13px `#cfcfcf`, truncated). Right side: **Clear** button
  (outline) and **＋ Add slice** button (solid red `#cc6666`, white text, weight 600).
- Helper line: `Fine-tune the cut points — drag the red line or nudge in 10 ms steps` (11px `#6f6f6f`).
- **Two magnified boundary insets side by side** — this is the key feature. Each is a
  **zoomed-in view of the waveform** around one boundary (a ±0.5s window, `INSET_SPAN = 1.0s`):
  - Box: 252×86, bg `#080808`, 1px border `#1c1c1c`, radius 7px, overflow hidden.
  - Same smooth mirrored silhouette style; base fill `#4d4d4d`.
  - The **kept side** of the cut is filled red `#cc6666` (left inset = "Cut in ▸", keeps the
    right side; right inset = "◂ Cut out", keeps the left side). The discarded side is dimmed
    and covered by a `rgba(0,0,0,.45)` shade.
  - A **draggable white cut line** (2px, `ew-resize`, white dot handle ringed in red) sits at
    the boundary. Dragging it, or the **−10ms / +10ms** nudge buttons below, adjusts the fine
    offset (clamped to ±0.6s). A thin center line `#262626` runs through the middle.
  - Header of each inset: label (`Cut in ▸` / `◂ Cut out`, 10.5px uppercase `#7a7a7a`) and the
    resulting boundary time in red (e.g. `0:05.9`).

### Transcript
- Caption row: label **TRANSCRIPT** (same style as WAVEFORM) on the left; a legend on the
  right — a 9px red square + `words that run together` (11px `#7a7a7a`).
- Reading box: bg `#0e0e0e`, 1px border `#1d1d1d`, radius 10px, ~16–18px padding; font-size
  17px (1a) / 18px (1b); line-height ~2.05; default text color `#8f8f8f`. Shows ~a paragraph
  at a time (scrolls).
- **Words are individually clickable spans.** Selection is two-click: click the first word,
  then the last word, to select the inclusive range (a third click starts a new selection).
- **Selected words**: background `rgba(204,102,102,.30)`, text `#fff` (contiguous highlight;
  first/last word get rounded outer corners).
- **"Words that run together"** (no clear gap between them — hard to slice cleanly): these
  specific words are always tinted red `#e39393` even when unselected (→ `#ffdada` when
  selected). In the sample copy these are the phrases: *kind of*, *you know*, *a lot of*,
  *wanted to*, *sort of*.

Sample transcript copy (single-person interview):
> So when I first started out, I honestly had no idea what I was doing. I kind of just
> followed my gut, you know, and hoped that things would work out. There were a lot of late
> nights, a ton of second-guessing, and I wanted to quit more times than I can count. But
> looking back, I think that struggle is sort of the whole point. You have to want it.

### Slices panel
Sidebar (1a) = vertical list; tray (1b) = horizontal scrolling row. Header: **SLICES** label
+ count (`N clips`). Each slice card (bg `#151515`, 1px border `#232323`, radius 11px):
- Name (`Slice N`, 14px weight 600 `#eee`) + duration (right, 11px `#8a8a8a`).
- Time range `M:SS.d – M:SS.d` (11px `#6f6f6f`, tabular-nums).
- Quoted transcript snippet (12.5px `#9a9a9a`).
- Buttons row: **Play** (outline), **Export** (bg `#2a2020`, text `#e39393`), **✕** delete.
- Footer / header CTA: **Export all slices** (Playola primary Button).

## Interactions & Behavior
- **Play/pause**: animates the playhead across the wave via requestAnimationFrame at the
  current speed; stops at the end. Scrubbing or clicking the wave repositions it and pauses.
- **Speed**: cycles 0.5× / 1× / 1.5× / 2× and scales playback rate.
- **Zoom**: integer levels 1–6; inner wave width = 920px × level. **Fit** computes a level so
  the current selection fills ~⅓ of the view and scrolls it to center.
- **Word selection** (primary slicing method): first click sets an anchor (start = end),
  second click sets the other end; drives both the transcript highlight and the waveform
  region. Selecting resets the fine offsets to 0.
- **Fine-tune**: drag the white cut line or use ±10ms nudges on each inset to move the in/out
  boundary within ±0.6s of the word boundary.
- **Add slice**: creates a slice `{name, start, end, startWord, endWord, snippet}` from the
  current (fine-tuned) selection; pushes an undo entry.
- **Markers**: drop at playhead; render as amber lines.
- **Undo/redo**: history of the slices array (snapshots; ~30 deep).
- **Delete slice / Play slice**: remove; or re-select that slice's words + move playhead to
  its start.
- **Export** / **Export all**: hooks for the real export pipeline (no-ops in the prototype).

## State Management
Per-editor state:
- `selStart`, `selEnd` — word indices of the transcript selection (null when none).
- `startFine`, `endFine` — seconds offset applied to the in/out boundaries (±0.6 clamp).
- `playing`, `playhead` (0–1 of total), `zoom` (1–6), `speed` (0.5/1/1.5/2).
- `slices[]`, `markers[]`, `sidebarOpen`.
- Undo/redo: two stacks of JSON snapshots of `slices`.
Derived: word→time map (each word has `t` start + `dur`); selection region in seconds =
`words[a].t + startFine … words[b].t + words[b].dur + endFine`; waveform region highlight and
inset windows are computed from that.

## Real-audio notes (replace the synthetic signal)
- The prototype generates a smoothed **speech envelope**: rounded syllable bumps grouped into
  phrases with quiet gaps, then normalized and lightly averaged. In production, compute
  peak/RMS amplitude buckets from the decoded PCM and render the mirrored filled silhouette
  from those, at a resolution that scales with zoom.
- Transcript word timings must come from the real forced-alignment / ASR output. The
  "run together" flag should come from the aligner (words with ~no inter-word gap), not be
  hard-coded.

## Design Tokens
- Colors — background `#000`/`#090909`/`#0a0a0a`/`#0e0e0e`; cards `#131313`/`#151515`/`#181818`;
  borders `#1c1c1c`/`#1d1d1d`/`#232323`/`#262626`/`#2f2f2f`; text `#fff`/`#cfcfcf`/`#9a9a9a`/
  `#8f8f8f`/`#6f6f6f`/`#565656`.
- Accent (Playola red) `#cc6666`; run-together word `#e39393`; export tint `#e39393` on `#2a2020`;
  marker/warn amber `#febc2e`; waveform base `#6f6f6f`, inset base `#4d4d4d`.
- Traffic lights `#ff5f57` / `#febc2e` / `#28c840`.
- Radius — buttons 8–9px, cards/insets 7–12px, window 14px.
- Type — Inter (body), Space Grotesk (display/headers). Numeric readouts use tabular-nums.
- Spacing — 8/10/12/14/16/18/20px rhythm; toolbar 9px gaps.
- Wave geometry — `BASE_W` 920px, wave height 138px, inset 252×86, inset window `INSET_SPAN` 1.0s,
  fine-tune clamp ±0.6s, zoom levels 1–6.

## Assets
No external image/icon assets. Icons are inline SVG (play/pause). Everything else is CSS.
Fonts (Inter, Space Grotesk) ship with the Playola design system — use the app's existing
font setup.

## Files
- `Waveform Editor.dc.html` — entry/options file; presents both layout variants (1a sidebar,
  1b stacked) side by side. Mounts `Editor` twice with `layout="sidebar"` / `layout="stacked"`.
- `Editor.dc.html` — the actual editor: all layout, waveform/inset rendering, transcript,
  slicing logic, transport, and state.
- `support.js` — runtime for the HTML prototype (reference only; not needed in the real app).
- The prototype also loads the Playola design-system bundle for fonts/Button styling; in the
  real app use the codebase's own design system instead.
