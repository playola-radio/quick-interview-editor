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

```bash
export OPENAI_API_KEY=sk-...
python3 -m logic_markers.cli "song.m4a"
# or
python3 -m logic_markers.cli "song.m4a" --api-key sk-... --sample-rate 44100
```

Then in Logic: **Navigate > Other > Import Markers from Audio File**, and pick
the generated `.markers.aiff`.

## Tests

```bash
python3 -m pytest -q
```
