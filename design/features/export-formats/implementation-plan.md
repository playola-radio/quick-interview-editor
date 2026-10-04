# Export formats implementation plan

> Execute inline using superpowers:executing-plans and TDD. User approved the menu scope; no new approval gate for routine implementation.

**Goal:** Export individual/all clips as WAV, M4A or existing AIFF from native menus.
**Architecture:** Extend the existing export job, share bounded edited render/conformance, reuse tagged AAC writer and ordinary no-overwrite copying.
**Tech stack:** Swift 6, AVFoundation, SwiftUI, Dependencies, Swift Testing/CustomDump.

Contracts: [spec](spec.md), [screens](screens.md), [models](models.md). Backend/API: none.

## Execution checklist
- [x] Add renderer WAV/M4A and editor routing/metadata tests; run red.
- [x] Extend format/job/naming, shared conformer and AAC empty tags; run renderer and mastering regressions.
- [x] Thread frozen format/artist/titles through editor; AIFF-only markers; replace buttons with menus and neutral picker text.
- [ ] Run full app tests, build, format and lint; AVFoundation AAC format, duration and metadata readback.
- [ ] Commit; Claude correctness review, then separate challenge/excess concurrently; resolve combined findings and verify.

Review dispositions: keep one client, no extra settings/modal/state, no database fields. Share the existing conformed renderer and PCM settings rather than copying the algorithm. Preserve ordinary naming instead of using masteredM4A naming. Menu format stays selectable even with cached destination. The user's unrelated untracked canvas/docs will not be committed. Screen PNGs exported through Pen; native menu styling remains system-owned.

# Export as WAV / M4A / AIFF: minimal design

## Context
Each clip's Export button and the Export all button become small menus with three items: Export as WAV…, Export as M4A…, Export as AIFF…. AIFF behaves exactly as today. WAV is 24-bit, 44.1 kHz, stereo. M4A is AAC at 256 kbps, 44.1 kHz, stereo, tagged with the clip title, the artist, and LRC lyrics. Both new formats render through the existing edited-render path plus the mastering conformer and AAC helper. They get no gain, joining, parts, or run storage.

## Interface decision: extend `ExportRenderJob` (no new client)
Both new formats go through the same `ExportRenderClient.renderSlice` and `ExportAudioRenderer.render`. The reasons:
- The canonical-file checks (`openCanonical`) are shared.
- The cancellation forwarding into the detached task is shared.
- The test override point (`$0.exportRender`) is shared, and every editor export test already uses it.

A separate client would copy all three, so I'm not adding one.

```swift
// Core/ExportRenderClient.swift
enum ExportAudioFormat: String, CaseIterable, Identifiable, Sendable { case wav, m4a, aiff }  // menu order
struct ExportAudioTags: Equatable, Sendable { var title = ""; var artist = ""; var wordStarts: [RenderMarker] = [] }
struct ExportRenderJob { …existing…; var format: ExportAudioFormat = .aiff; var tags = ExportAudioTags() }
```
- `tags` is only read for `.m4a`. `wordStarts` holds the edited, clip-relative `RenderMarker`s that `renderTargets` already computes for AIFF injection, so they cost nothing extra.
- Defaulting `format` to `.aiff` keeps current job fixtures and AIFF behavior unchanged.

## Renderer (one path)
`Core/ExportRenderClient.swift`:
1. `render` becomes `async throws`. The live value calls `Task.detached { try await ExportAudioRenderer.render(job) }` and keeps the existing `withTaskCancellationHandler`.
2. Move `MasteringAudioClient.render(_:from:sampleRate:to:)` into `ExportAudioRenderer.renderConformed(from:plan:editedDurationSamples:sampleRate:to:settings:) -> Int`. The function body stays the same: `renderEdited` feeds `MasteringConformer` push/finish, then checks the result is within ±1 of `MasteringFrames.conformed`, then reads the file back to check its length. Mastering calls it with the CAF settings, so there is still only one conformed render path.
3. Move `wavSettings` and `cafSettings` onto `MasteringFormat` as `pcm24WAVSettings` and `float32CAFSettings`, so mastering and export share them.
4. `switch job.format`:
   - `.aiff`: today's code, byte for byte.
   - `.wav`: `renderConformed(… to: outputURL, settings: pcm24WAVSettings)`. Done.
   - `.m4a`: render to `outputURL.deletingPathExtension().appendingPathExtension("caf")`, removed by `defer`. Then build the LRC by running `wordStarts.position` through `MasteringFrames.conformed(_, fromRate:)` and keeping positions in `0..<frames`, the same way `MasteringAudioClient` does at lines 224–234. Then call `MasteringAACEncoder.encode(caf, target: MasteredPieceTarget(pieceID: UUID(), startFrame: 0, frameCount: frames, artist:, title:, lrc:), outputURL:)`. The encoder already:
     - checks cancellation,
     - checks the decoded length equals `frameCount`,
     - calls `cancelWriting` and removes the output on any throw.
5. `MasteringAACEncoder`: only add the artist and title metadata items when they are non-empty, the same way `lrc` is already handled. This is what lets a blank artist through. Mastering always passes non-empty values, so its behavior does not change.

## Model (`EditorModel` export section)
- New API: `exportSliceTapped(_ id:, format:)`, `exportAllTapped(format:)`, `let exportFormats = ExportAudioFormat.allCases`, `func exportFormatLabel(_:) -> String` ("Export as WAV…" and so on). `exportLabel` and `exportAllLabel` stay as the menu titles. The format parameter defaults to .aiff for source compatibility; both actual menus pass their chosen format explicitly.
- **Settings are captured before the first await.** In the synchronous `startExport(targets, format:)`, next to the existing `removals` snapshot, I capture:
  - `format`,
  - `artist = interviewArtist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""`.

  Titles are already captured because `targets` is a value copy taken after `finishSliceNameEdit()`. All three are threaded into `performExport` and `renderTargets`.
- **Channel guard, checked synchronously before the folder picker.** If `format != .aiff` and `editPlan.source.channels ∉ 1...2`, set `.failed("WAV and M4A export support mono or stereo recordings. Export as AIFF instead.")` and stop. The conformer still throws at render time as a backstop. AIFF keeps full support for every channel count it handles now.
  - Recommendation: reject rather than keep the source layout. A 4-channel WAV would break the settled 44.1 kHz stereo convention, and the conformer can't do it anyway.
- `renderTargets`: the scratch filename is `"\(id).\(format.fileKind.fileExtension)"`. The job gets `format` plus `tags(title: slice.name, artist:, wordStarts: markers)`. `injectionFiles` is only built and `engine.injectMarkers` only called when the format is `.aiff`. WAV makes no promise about markers.
- `finishExport`: pass `kind: format.fileKind` into `ExportCopyRequest`. This is a real gap today: the request uses the default `.logicAIFF`, so without this fix a `.wav` file would be copied under a `.aiff` name.
- Folder memory stays as it is: `resolvedDestination` remembers the folder per editor, whatever the format. I'm adding no "always choose".
- Status text stays the same ("Exporting slice x of y…", "Exported N clips").

## Naming (`Models/ExportNaming.swift`)
- Add `static let wav = Self(fileExtension: "wav", forcesExactNames: false)` and `static let m4a = Self(fileExtension: "m4a", forcesExactNames: false)`. Add `ExportAudioFormat.fileKind`, which maps `.aiff` to `.logicAIFF`.
- Clips keep the normal per-clip rule: "Stem - Clip.ext", and the exact name for clips named from a suggestion.
- `.m4a != .masteredM4A` because `forcesExactNames` differs. So `ExportReviewModel` keeps the "Export" wording and never switches to the mastered "Save" wording. A test pins this.

## View (`SlicesPanelView.swift`)
Both buttons become `Menu(model.exportLabel)` / `Menu(model.exportAllLabel)` built from `ForEach(model.exportFormats) { Button(model.exportFormatLabel($0)) { model.exportSliceTapped(row.id, format: $0) } }`. The existing `.disabled(…)` conditions stay. `.menuStyle(.button)` and `.fixedSize()` are visual only, so the view has no logic.

## Errors, late cancel, cleanup
- Cancel during render, conform, or encode: the encoder's sleep/check throws, its `catch` removes the m4a, `defer` removes the CAF, and `performExport` catches `CancellationError` and calls `removeWorkDir`. This is the same path as today.
- Cancel after `finishWriting`: the encoder's `checkCancellation` after finishing throws, and the output is removed.
- Cancel after render but before copy: the existing `Task.isCancelled` check handles it. Cancel during copy or review: existing behavior, unchanged.
- WAV/M4A failures are written to scratch only, so a partial file can never reach the destination folder.
- `encodeFailed` reads "Could not encode <title>: …". It doesn't mention mastering, so it's fine for plain exports.

## Design deliverables (write first)
The untracked `design/features/export-formats/exports/*.png` files already exist. I'll add the following and leave everything else untouched:
- `screens.md`: the clip menu open, the Export all menu open, the disabled state, and the folder picker and progress/cancel reused from today. The route is the editor window's Slices panel.
- `endpoints.md`: `none — local-only export; no backend`.
- `models.md`: the new `ExportAudioFormat`, `ExportAudioTags`, the two new `ExportRenderJob` fields, and `ExportFileKind.wav`/`.m4a`. Project/document schema: `none — format is not persisted`.

## Tests
**`Core/ExportAudioRendererTests`**
- WAV from a 48 kHz mono fixture with a removal and crossfade comes out 44.1 kHz / 2 ch / 24-bit, its length equals `conformed(edited)`, and L equals R.
- WAV from a 44.1 kHz stereo float source matches the AIFF render within 24-bit quantization.
- M4A has AAC 44.1 kHz stereo, decoded length equal to the conformed frames, and title, artist, and lyrics metadata. The LRC timestamp of a 48 kHz marker is converted to 44.1 kHz correctly.
- M4A with a blank artist succeeds and has no artist item.
- WAV and M4A on 3+ channels throw `unsupportedChannelCount` and leave no output and no CAF. AIFF on the same file still renders.
- Cancelling mid-M4A throws `CancellationError` and leaves neither the m4a nor the CAF behind.

**`MasteringAACEncoderTests`**
- Empty artist and empty title are left out of the metadata.

**`ExportNaming` tests**
- `.wav` and `.m4a` names follow source-prefixed naming, suggestion-named clips keep their exact names, and collision suffixes work.
- `ExportReviewModel` titles for `.m4a` read "Review Export Filenames".

**Editor tests**
- Per format, check `job.format`, the scratch extension, whether `injectMarkers` is called (`.aiff` only), and the copied filename "Stem - Slice 1.wav" / ".m4a".
- Artist and rename are captured: change `interviewArtist` and rename the clip while a suspended `chooseDirectory` is pending, and the job still carries the original values.
- The trimmed artist is used, and a blank artist still exports.
- A 3-channel source with WAV fails immediately without opening the folder picker. With AIFF it proceeds.
- A second export in a different format reuses the remembered folder.
- `exportFormatLabel` strings and their order.

**Regression**
- The full `MasteringPreparationTests`, `MasteringConformerTests`, `MasteringAACEncoderTests`, `EditorExportRemovalTests`, and `EditorTests` suites, since `render` and the settings were moved out of the mastering client.

## Sequencing (one PR, base `main`)
1. Design markdown files.
2. Move `renderConformed` and the settings out of mastering, and run the mastering tests (no behavior change).
3. Change the encoder to skip blank metadata.
4. Add the job, format, and renderer branches with their tests.
5. Add the naming kinds.
6. Update the model, its tests, and the view menus.
7. Run `make test-fast`, `make format-check`, and `make lint`.

Keep the user's untracked files and the current branch.

## Verification
- Run `make test-fast ONLY=…` for each suite above, then the full `make test-fast`, then `make format-check` and `make lint`.
- Manual check: export one clip in each format. WAV and M4A should open in QuickTime at 44.1 kHz stereo, the M4A should show its title, artist, and lyrics in Music/afinfo, and the AIFF should still show markers in Logic.

## Validation record

The full app suite passed with 1,989 tests and 15 existing known issues. Formatting and lint passed. New renderer tests cover WAV conformance and unchanged interior level, tagged AAC readback (including blank artist and Unicode), and cancellation cleanup. Editor tests cover all three formats for single/bulk exports, frozen metadata, folder reuse, unsupported channels, and collision approval. Existing mastering suites passed after sharing the renderer. The proposed independent decoder and manual QuickTime/Logic listening checks have not been rerun for this change.
