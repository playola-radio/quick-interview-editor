# Changelog

Notable changes to Playola Interview Editor are documented here. Release notes
focus on changes that affect editing work rather than internal implementation.

## [Unreleased]

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
