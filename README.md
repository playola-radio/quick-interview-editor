# logic-markers (POC)

Transcribe an audio file with OpenAI Whisper and embed the words as marker
chunks in an AIFF, so Apple Logic Pro can import them and you can navigate the
track word-by-word.

**Status:** proof-of-concept CLI. Its one job is to prove Logic actually
ingests our marker chunks. Once validated, the plan is a SwiftUI Mac app built
on the same marker layout.

## How it works

1. Send the original file to Whisper (`whisper-1`, word-level timestamps).
2. Convert the source to linear PCM AIFF with `afconvert`.
3. Map each word's start time to a sample-frame position.
4. Write a `MARK` chunk and rewrite the `FORM` size.
5. Emit `<name>.markers.aiff` next to the source (original untouched).

## Requirements

- macOS (uses the built-in `afconvert`)
- Python 3 with `requests`
- An OpenAI API key

## Usage

The tool uses local WhisperX (forced alignment) by default; the venv it needs is
built in `.venv` (see `logic-markers-env-setup` notes). Run via `.venv/bin/python`.

### Embed markers into one file

```bash
.venv/bin/python -m logic_markers.cli markers "song.m4a"
```

Then in Logic: **Navigate > Other > Import Markers from Audio File**, and pick
the generated `.markers.aiff`.

### Chunk a recording by editing its transcript

```bash
# 1. write an editable transcript (one [n]-tagged segment per line)
.venv/bin/python -m logic_markers.cli transcript "talk.m4a"

# 2. edit talk.txt: delete chunks you don't want; blank line = split into a file

# 3. cut into per-chunk AIFFs (each with re-based word markers)
.venv/bin/python -m logic_markers.cli cut "talk.m4a" "talk.txt"
```

Produces `talk.1.aiff`, `talk.2.aiff`, … plus `talk.m4a.edit-plan.json`. Cut
points snap to the nearest silence so no word is clipped; adjacent chunks meet
in their gap. Drag the AIFFs into Logic — markers travel with each file.

## Tests

```bash
python3 -m pytest -q
```
