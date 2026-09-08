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

- macOS (uses the built-in `afconvert`; no ffmpeg needed)
- Python 3.12, **built with `lzma`** (a Homebrew or python.org build — some
  `pyenv` builds omit it, which breaks `transformers`/WhisperX)

## Setup

```bash
git clone git@github.com:playola-radio/quick-interview-editor.git
cd quick-interview-editor
python3.12 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

The first WhisperX run downloads the transcription + alignment models
(~hundreds of MB); after that it's cached and fast. Run everything through
`.venv/bin/python`.

For Xcode development, the shared scheme sets `QIE_ENGINE_REPO` to the current
checkout so the app and Python helpers use the same branch. Each worktree needs
a `.venv`; you can reuse an existing environment with
`ln -s /absolute/path/to/existing/.venv .venv`. This shares installed dependencies
while loading the helper source from the current worktree. After changing the
scheme's environment, stop and run the app again in Xcode.

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

## Configurable Suggestions

Suggestions finds three groups of material in your transcript:

| Group | Default types | Default naming |
| --- | --- | --- |
| Spotlights | Spotlight | `Spotlight 1`, `Spotlight 2`, … |
| Song Intros | Song Intro | `Song Title 1, Artist Name` |
| Audio Images | ID, Pre-commercial, Post-commercial, Promo | `ID 1`, `Pre-Com 1`, `Post-Com 1`, `Promo 1`, … |

Song Intros include complete commentary about a song or artist, even without a lead-in
to music. When the same passage also fits Spotlight, Intro takes priority for naming.
Names remain editable; an Intro with an unknown song title keeps a descriptive name
when its artist is established. If both song and artist are missing after successful
extraction, useful complete commentary is kept as a Spotlight when that type is configured;
otherwise the unqualified Intro is omitted. Failed extraction stays available to retry.

Enter an optional **Interview Artist** before importing audio, or edit it later under
**Settings (⌘,) → Configure Suggestions → This project → Interview** and click **Save**. The name belongs
to this project and helps resolve references to the subject’s own music. Other artists
still come from the transcript. Each search captures the name it started with; changes
apply to future searches.

The Settings tab shows the last active project’s name. Activate another project window
to edit its Interview and Numbering settings. Unsaved project drafts remain separate,
and opening Settings keeps the last active project selected. App-wide rules remain
available when no project is open.

Use **Types** to show any combination of groups or individual types. The menu shows
**Spotlights**, **Song Intros**, and **Audio Images**, with distinct subtype or custom
choices where useful. Filtering changes what you see; it does not delete suggestions or change saved clip names. Saved clips remain
available independently of this filter.

Open **Settings (⌘,) → Configure Suggestions** to edit the app-wide rules. Each type has discovery
guidelines and a naming template built from text, extracted fields, and an optional
sequence number. You can add types and fields, with instructions explaining how to
extract each field from the transcript. The default Intro fields identify the song and
its performing artist, or the artist being discussed when no specific song is established.
They do not substitute the station DJ. Saving rules affects future searches;
existing suggestions keep the rules captured when they were found. Cancel leaves the
saved rules unchanged. A stale settings draft must reload before it can replace newer
saved rules.

Review extracted fields before accepting a suggestion. Missing values are identified for
correction. Pending suggestions retain their descriptive labels; the captured naming
template is applied when you accept a clip. Field corrections and canonical group
spelling affect that accepted name without renaming clips you already accepted.

Open **Settings (⌘,) → Configure Suggestions → Numbering**, under **This project**, for starting counts
and song/group overrides. Leave a count Automatic, or enter a starting number when
continuing across source tapes or `.pie` files. Each Save/Reset applies directly to the
project and can be undone in the editor. These counters are independent of app-wide
rule drafts and of other projects.

Numbers are assigned in acceptance order within each type or song group. Starting at 7,
rejecting a suggestion, accepting two clips, and rejecting another yields clips 7 and 8.
The next accepted clip gets 9. A starting count is a minimum; allocation continues after
previously issued numbers in the same group.

Accepting a suggestion permanently reserves its sequence number in that project.
Deleting a clip, undoing acceptance, or running a new search does not release an issued
number. This prevents later clips from accidentally reusing it.

Running a new search asks before replacing existing suggestions and explains that saved
clips are safe. **Resume** continues an unfinished search using its captured rules and
saved successful responses. **Discard** removes that unfinished search. These differ
from starting a fresh search under the current rules.

New suggestion-derived clips export using their current clip names, such as `ID 7.aiff`,
without a source-tape prefix. If a filename is already present or duplicated within the
export, review the proposed filenames before allowing suffixes. Export suffixes do not
change clip names or editorial sequence numbers. A new collision during copying pauses
for another review, retaining the remaining rendered clips and identifying files already
exported. Older and manually created clips retain their existing source-prefixed export
naming.

## Cut Suggestions — API key setup

The macOS app finds suggestions by sending the transcript to a hosted Claude model. This
is **bring-your-own-key**: usage is billed to your own Anthropic account.

1. Get an Anthropic API key at
   <https://console.anthropic.com/settings/keys>.
2. In the app, open **Settings** (⌘,) — or tap **Suggest Cuts** with no key set,
   which opens the same key entry — and paste the key into **Anthropic API Key**.
3. The key is stored in your **macOS Keychain** under a stable, machine-wide
   service id (`fm.playola.PlayolaInterviewEditor.anthropicAPIKey`), so you set it
   **once per machine** and it's shared across every build/workspace. It is never
   written to `UserDefaults`, a plist, the on-disk request, or the process
   arguments, and is never logged.

**Env-var fallback (dev convenience):** if no Keychain key is set, the app falls
back to the `ANTHROPIC_API_KEY` environment variable. Resolution order is
Keychain first, then `ANTHROPIC_API_KEY`; if neither is present the feature shows
an onboarding state and never calls the model. The resolved key is injected only
into the cut-suggester subprocess's environment.

The provider/model stays a config knob (defaults to `claude-sonnet-5`). A hosted
Playola gateway is a possible future option; today it's your own key.
