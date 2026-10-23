# Changelog

Notable changes to Playola Interview Editor are documented here. Release notes
focus on changes that affect editing work rather than internal implementation.

## [Unreleased]

## [2.6.0] - 2026-10-22

- Word edges now line up with the audio in newly transcribed interviews:
  deleting a single word no longer leaves part of it behind or clips the start
  of the next word. Projects you already edited keep their existing word edges.
- When a suggestion search stops, the app now says why (a bad API key, no
  credits, a rate limit, a network problem) and what to do next.
- When transcription or a suggestion search fails, the message names the real
  cause and the step that failed, and points to a diagnostic log you can copy
  and send along with a bug report.
- Opening an audio file, saving or reading your API key, playing audio,
  drawing the waveform, and moving the app into Applications now tell you what
  went wrong and what to try next instead of failing silently. A locked
  Keychain is no longer mistaken for a missing API key.
- Errors from exporting, Prepare for Mastering, model downloads, damaged
  project files, and saved suggestions now say which clip, file, or step failed
  and why.

## [2.5.0] - 2026-10-16

- Delete several words at once: Cmd-click words, or Cmd-drag across a run of
  words, to add them to the selection, then press Delete to remove every piece
  in one undoable step, each with its own crossfade. Every selected piece is
  highlighted in both the transcript and the waveform, and playback keeps going
  while you build the selection.
- Removed words are now faded in the transcript so cut text stands apart from
  the words you kept.
- Clips you mark by hand are now named the same way as accepted suggestions
  (for example "Whiskey Rain 1, Hayes Carll" or "Spotlight 5") instead of
  staying "Slice N". A hand-marked Song Intro can now be used with Prepare for
  Mastering.
- Cmd-Down / Cmd-Up make the waveform taller or shorter, like Logic Pro's
  vertical zoom, and Cmd-Right / Cmd-Left keyboard zoom now keeps the playhead
  centered.

## [2.4.1] - 2026-10-14

- Fixed transcription failing as soon as it started, with a "Symbol not found"
  error, on Macs running anything older than macOS 26.4.

## [2.4.0] - 2026-10-04

- Choose an audio format when exporting: the Export and Export All buttons now
  offer AIFF (with Logic word markers, as before), WAV (24-bit, 44.1 kHz
  stereo), or M4A (AAC, tagged with artist, title, and word-timed lyrics).
- The export review now lists the exact filenames that would collide with files
  already in the destination folder, so you can see which clip names to fix.

## [2.3.0] - 2026-09-14

- New Playback Latency settings: correct the audio delay you hear on Bluetooth
  headphones and speakers so the playhead lines up with the sound. The app
  estimates the offset automatically and remembers a per-device adjustment you
  can fine tune, and it now stops playback cleanly when the audio output changes.
- Rejected cut suggestions now stay gone — dismissing a suggestion removes it
  from the list instead of leaving it behind.
- Accepted clips now move to the top of the slices panel and are revealed as
  soon as you accept them.
- The suggestions panel now remembers its scroll position.

## [2.2.0] - 2026-09-10

- Edit words directly inside a clip: select and delete words from the transcript
  in the Edit Slice sheet with an equal-power crossfade, fully undoable and
  blocked while an export is running.
- Simpler transcript editing: a single click and drag always selects words, and
  double-click opens the clip or suggestion under the pointer. Selected text now
  renders as a continuous rounded highlight.
- Cut suggestions are shown in one list ordered by their position in the audio,
  each labeled with its product type.
- Fixed a hang when saving with ⌘S.
- Fixed the Space bar and ⌘Z no longer working after editing a slice or
  suggestion name: clicking away from a rename field now reliably commits the
  edit and restores playback and undo.
- Renaming a slice is smoother on long interviews and now reverts as a single
  undo step.

## [2.0.0] - 2026-09-08

- Save an entire editing session as a `.pie` project and reopen it later with
  its audio, transcript, clips, edits, and suggestions intact. Multiple projects
  can be open in separate windows.
- Find and review configurable AI cut suggestions for Spotlights, Song Intros,
  and Audio Images. Customize suggestion rules, extracted fields, clip naming,
  numbering, and interview context.
- Edit directly from the transcript and waveform: select and resize clips, fine
  tune boundaries, audition edits, remove sections with crossfades, and undo
  document changes.
- Export Logic-ready AIFF clips with embedded word markers, editable clip names,
  and a review step for filename collisions.
- Improved the reliability of transcription, saved-project recovery, suggestion
  searches, playback, and export.
