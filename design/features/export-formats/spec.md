# Export audio formats

## Scope
User approved on 2026-10-04: use the existing Export controls as small menus rather than a modal format chooser. Implement Export as WAV…, Export as M4A…, and preserve Export as AIFF… for both one clip and all clips. One file per clip; preserve edited boundaries, removals and fades. No normalization or concatenation. Destination selection and its existing session cache remain. Existing collision review, cancellation and progress remain. Generated titles and artist tags use the current frozen editor values; blank artist does not block ordinary export.

WAV is 24-bit PCM, 44.1 kHz stereo; M4A is AAC 256 kbps, 44.1 kHz stereo with Artist, Title and edited-local word-start LRC. AIFF retains source-format output and Logic marker injection. WAV does not promise word markers. These fixed output settings reuse the retained mastering audio primitives, without invoking preparation gain or creating a mastering run.

## Non-goals
No WAV + M4A batch option in this pass (the user described it as optional). No mastering sheet, upload, bitrate/sample-rate/options modal, new persisted format preference, project schema or backend change. Keep original export filename policy, changing only the extension for the selected format.

## Base commits and surface
Native macOS editor; base 8e2665e3af06e38eecc67b053e1471824df79bac. Remote primary main at 771fa6f33920fdf7e1e3a0e0bdfd96c8bcd3af50. Backend inspected path /Users/brian/playola/playola, develop 70c0e08873d5b8a88d20e2e0a06dd115cf0a7fc0; no server calls or model changes for local export. Preserve the existing workspace branch and user's unrelated untracked design documents/canvas.

## Design deliverables
- Screens: [screens.md](screens.md)
- Endpoints: none — export is entirely local, no network or API contracts
- Models: [models.md](models.md)

## Approval record
The user approved the menu approach and requested implementation in this conversation on 2026-10-04. The attached screen states document that exact native-menu behavior; they do not introduce a new layout direction. Existing export busy/empty/invalid-timeline/fully-removed gates remain.

## Acceptance
Both export menus expose the same three choices. WAV/M4A do not invoke Python marker injection. Source-rate edited markers become piece-local output timestamps; no priming offset. Every output goes through existing no-overwrite collision handling with the correct extension. Format/artist/title are frozen before opening the destination picker. Cancel/failure removes temporary audio; successfully copied outputs remain. AIFF regressions and all mastering plumbing tests remain green.

## Open questions
None required for this pass. Combined WAV + M4A output is deferred.
