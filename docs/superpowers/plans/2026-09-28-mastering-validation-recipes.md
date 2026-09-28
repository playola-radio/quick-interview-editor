# Portable mastering validation recipes

These recipes carry the disposable spike's evidence into fresh implementation workspaces. They are validation instructions, not a production audio implementation. The approved contract is in `../specs/2026-09-28-prepare-for-mastering-design.md`.

## Metadata transport

Generate stereo 44,100 Hz PCM and write an m4a using the production AAC encoder. Configure 256,000 bps. Write these AVFoundation metadata identifiers with UTF-8 string values:

```swift
.iTunesMetadataArtist // "Test Artist"
.iTunesMetadataSongName // "Generated Title"
.iTunesMetadataLyrics // payload below
```

Use both 5 and 5,000 entries:

```swift
let payload = (0..<count).map { index in
  let centiseconds = 10 + index * 20
  return String(
    format: "[%02d:%02d.%02d]", centiseconds / 6000,
    (centiseconds / 100) % 60, centiseconds % 100
  ) + "café—word-\(index)"
}.joined(separator: "\n") + "\n"
```

Read the exact Artist, Title and lyrics strings through AVFoundation. Independently inspect the file:

```sh
ffprobe -v error -show_entries format_tags -of json lyrics-5000.m4a
```

Use a scratch directory with `npm install --save-exact music-metadata@11.16.1` (the version used in the spike). Run an `.mjs` script importing `parseFile` from `music-metadata` and `assert` from `node:assert/strict`:

```js
const metadata = await parseFile(process.argv[2]);
const count = Number(process.argv[3]);
assert.equal(metadata.common.artist, 'Test Artist');
assert.equal(metadata.common.title, 'Generated Title');
const words = metadata.common.lyrics[0].syncText;
assert.equal(words.length, count);
for (let index = 0; index < count; index++) {
  assert.deepEqual(words[index], {
    timestamp: 100 + index * 200,
    text: `café—word-${index}`,
  });
}
```

Keep Node/ffprobe as independent development checks; neither belongs in the app's runtime. The 5,000-entry fixture deliberately tests metadata capacity, not alignment: its lyrics outlast a short audio fixture. Also test actual-duration words, punctuation, newlines normalized to spaces, and distinct words rounding to the same centisecond. Preserve order and do not add AAC priming to their times. Minutes must not wrap at 100; document that parsers accepting exactly two minute digits cannot parse such unusually long pieces.

## Conversion, encoder delay and trailing padding

Make a two-second stereo 48,000 Hz input with impulses in both channels at frames `[480, 12000, 36000, 60000, 94560]`. The expected 44,100 Hz positions are `[441, 11025, 33075, 55125, 86877]`.

1. Convert using `AVAudioConverter` from the file's actual processing format to 44,100 Hz floating-point stereo. Supply each input buffer once. After input is exhausted, return `.endOfStream` and continue until the converter reports `.endOfStream`. Count actual output frames.
2. Finalize the output writer before opening the file for another pass. An `AVAudioFile` retained in a top-level variable was not finalized in the initial spike; a scoped writer fixed this. Expect exactly 88,200 frames for this fixture.
3. Encode already-conformed PCM, starting the writer session at zero. End its session explicitly at `CMTime(value: 88200, timescale: 44100)` before marking input finished and awaiting `finishWriting`. Check reader and writer final status; a file's existence alone is not success.
4. Check AVURLAsset's intended presentation duration (2 seconds) and AVAudioFile's playback frame count (88,200 for this fixture). Decode to PCM and search a narrow neighborhood around each expected impulse; the spike's five peak positions matched exactly.
5. Independently decode with `ffmpeg -i final.m4a -f f32le -acodec pcm_f32le -ac 1 decoded.f32`. Verify impulse positions separately from total raw decode length. The spike produced 89,024 raw frames and an encoded duration around 2.0666 seconds in ffprobe/music-metadata, while the five positions still matched. Do not shift lyrics or reject the file solely because this decoder exposes trailing padding.

Production tests must extend this beyond the two-second fixture: vary PCM lengths around AAC frame boundaries; test mono duplication, stereo, 44.1/48 kHz sources, 44.1→48→44.1 returns, short clips and cancellation. Test a one-frame return shortfall explicitly: it must fail range validation rather than pad or shorten a slice. Keep a real-speech manual fixture outside the repository unless its redistribution is authorized.

## Loudness reference and dependency provenance

Vendor libebur128 v1.2.6 at commit `67b33abe1558160ed76ada1322329b0e9e058b02`, verified from the upstream tag during planning. Include upstream's licence and required source/header dependencies. Record the SHA and source URL with the vendored files. Do not add an unpinned latest download to the build.

Measure the conformed stereo signal with integrated-loudness and true-peak modes enabled. Compare deterministic tone and speech fixtures with an independent meter, such as FFmpeg's ebur128 filter, using documented measurement tolerances. Record the reference tool version and fixture generation parameters with the tests.

Assert the gain policy separately from meter calibration: `min(-16 - L, -1.5 - P)` dB for valid measurements; silence/undefined integrated loudness never triggers amplification. Recheck the joined, quantized prepared output for true peaks, including piece boundaries. A ceiling failure must not silently invoke a limiter or alter duration.

## Manual release checks

These checks remain outstanding until the implemented workflow exists:

- Drag a prepared WAV into an actual Masterchannel browser tab; verify a project autosave does not invalidate the file while the browser reads it.
- Complete a real intro round trip and listen at two joins. Verify the saved sample boundaries and word starts still match.
- Close/reopen a partially completed multi-part project, then finish its remaining return.
- Exercise Save As and Duplicate before ever opening the mastering sheet, during staged work, and after a completed return. Check that the copied project contains its media and survives moving the original.
- Use a large prepared WAV to check save duration, memory use and disk behavior. Confirm ordinary metadata saves reuse unchanged wrappers.
- Cancel the output chooser, reopen the project and save again to the suggested sibling `mastered/` folder. Exercise duplicate titles, an existing destination file and a copy failure partway through.
- Export a spotlight through the existing AIFF/Logic-marker workflow.

Do not report these checks as passed based on synthetic fixtures. Do not upload audio or incur mastering charges without the user's authorization.
