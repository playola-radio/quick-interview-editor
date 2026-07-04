# Transcript-driven chunking — design

## Goal

Let a user cut a long spoken-word recording into several thematically coherent
audio files by editing its transcript, then drag those files into Logic Pro.
All fine-grained editing happens later in Logic; this tool does coarse,
non-destructive chunking whose cut points never clip a word.

Each output file is ONE contiguous slice of the source. No mid-sentence
splicing (that's a Logic job).

## Front-end (CLI now, SwiftUI later)

Two commands added to the existing `logic-markers` CLI:

- `logic-markers transcript song.m4a` → writes `song.txt`, an editable transcript.
- `logic-markers cut song.m4a song.txt` → writes `song.1.aiff`, `song.2.aiff`, …
  plus `song.edit-plan.json`.

The CLI is the first front-end over a pure engine. A future SwiftUI app
(waveform view, word↔waveform highlighting, zoom, draggable edit points) is a
second front-end over the same engine and the same `edit-plan.json`.

### Transcript file format

One WhisperX segment per line, each with a stable `[n]` id tag:

```
# Delete lines/chunks you don't want. Blank line = split into a new file.
# Keep the [n] tag at the start of each line; edit the words after it freely.

[1] So a young Hayes Carll goes to a Ray Wiley Hubbard concert, and Ray Wiley is
[2] one of the great songwriters of his generation
[3] What I'd like to say is that this is awesome
[4] I really love it
```

Editing semantics:
- Delete a whole line → that segment is excluded.
- Delete words within a line → the segment's span is trimmed (fuzzy match is
  constrained to that segment's known word range, so repeated phrases elsewhere
  never cause ambiguity).
- Blank line → split into a new output file.
- Consecutive kept lines (no blank line between) → merged into one contiguous file.
- If a `[n]` tag is missing/corrupted, fall back to global fuzzy alignment for
  that block and emit a warning.

**Why stable IDs, not pure prose:** the real transcripts repeat phrases ("Ray
Wiley", "concert", "Ray" ×5). Pure `difflib` matching cannot tell which
occurrence a kept line refers to. IDs turn mapping from guesswork into
bookkeeping; fuzzy matching is used only *within* a known word range.

## Engine

Pure, deterministic: `(edit plan input + params) → resolved edit plan → sliced files`.
No undo in the engine (that's GUI state).

### Modules

- `words.py` — `Word(id, text, start, end)` and segment grouping. WhisperX
  already provides per-word start AND end; capture both.
- `silence.py` — silence detection on the FINAL 44.1 kHz AIFF PCM (downmixed to
  mono for analysis). Adaptive threshold: estimate noise floor from a low
  percentile of windowed log-RMS, threshold = floor + 6–12 dB, clamped to
  [-60, -30] dBFS. Window 20–30 ms, hop 5–10 ms, RMS smoothed ~50–100 ms, min
  silence duration ~120 ms. Returns silence regions over the whole file (the GUI
  needs them globally, not just near boundaries).
- `editplan.py` — parse the edited transcript into blocks; resolve each block to
  a word-index range and a content time span; snap boundaries; emit versioned
  `edit-plan.json`.
- `slicer.py` — sample-accurate slice of the AIFF PCM per segment; re-base
  markers to the slice start; write each `.aiff` via the existing
  `aiff_markers` writer.

### Boundary snapping ("nothing gets cut off")

For each block with content span `[first_word_start, last_word_end]`:
- **Start:** search backward from `first_word_start` for the nearest silence
  region; set boundary near that silence's END (e.g. `silence.end - 20 ms`),
  clamped strictly `< first_word_start`. Minimizes dead air.
- **End:** search forward from `last_word_end` for the nearest silence region;
  set boundary near that silence's START (`silence.start + 20 ms`), clamped
  strictly `> last_word_end`.
- **No silence within the search radius (a "tight" join):** don't invent one.
  Pad the start ~100 ms, and give the **end a ~250 ms fade tail** so it doesn't
  sound abruptly cut off. The tail may bleed into the *next kept chunk* (desired
  — it's the material a fade-out is drawn over) but **never into deleted audio**
  (a separate hard limit enforces this). Mark the boundary `padded`.
- **Never** move a boundary inside a kept word's bounds.
- Each boundary's status (`snapped` = natural silence, `padded` = tight join) is
  recorded per segment, so the GUI can **color the words at tight joins** — the
  user's cue that those chunks stick together and need a fade in Logic.

Boundary mode: **independent slices** (default). Adjacent blocks may overlap
slightly in a shared gap — desirable for later editing. Record it, don't force
non-overlap. (A future `partition` mode can pick a single shared boundary.)

### edit-plan.json (versioned)

Records enough to be reproducible and to drive the GUI:
- schema version; source path + sample rate + channels + duration + hash.
- params used (silence threshold, min-silence, search radius, pre/post pad,
  boundary mode, tokenization version).
- full word list: id, text, normalized text, start/end seconds AND samples,
  confidence (if available), segment id.
- global silence regions.
- per segment: word-index range, content span (samples), boundary candidates
  with reason/score, resolved source slice span, boundary status
  (`snapped` | `padded_fallback` | `no_silence_found` | `manual_override`),
  overlaps_previous / overlaps_next, output filename.
- alignment diagnostics: kept/deleted words, unmatched edited text, ambiguities.

## Testing

- `silence.py`: synthetic signals (tone bursts separated by known-length gaps at
  known noise floors) → assert detected regions and adaptive threshold.
- `editplan.py`: transcript with repeated phrases → assert IDs disambiguate;
  deleted lines, blank-line splits, and intra-line word deletions map to correct
  word ranges; missing-tag fallback warns.
- boundary snapping: word spans against synthetic silence maps → assert outward
  snapping, no-clip guarantee, no-silence fallback.
- `slicer.py`: slice a synthetic AIFF → assert sample offsets and re-based marker
  positions.
- integration: run `transcript` then `cut` on the real clip; assert N files,
  valid AIFFs (afinfo), markers present and re-based.

## Out of scope (v1)

Mid-sentence splice removal, partition mode, crossfades, the SwiftUI app,
per-word confidence visualization. The edit-plan schema leaves room for these.
