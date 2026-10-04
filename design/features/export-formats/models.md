# Export formats — Model changes

All models are in-memory Swift values. No database table, endpoint, persisted preference, migration or project schema change.

| Change | Model | Table | Summary |
|---|---|---|---|
| New | ExportAudioFormat | none | wav, m4a, aiff; menu order and mapping to export file kind |
| New | ExportAudioTags | none | Frozen title, artist and edited-local word starts for M4A |
| Changed | ExportRenderJob | none | Defaulted format (.aiff) and tags, consumed by renderer |
| Changed | ExportFileKind | none | wav and m4a kinds with existing ordinary naming policy |

## ExportAudioFormat — New
Transient value selected from the export menu and carried through rendering and copy. No remembered-format setting. Cases wav/m4a/aiff; fileKind maps to wav/m4a/logicAIFF respectively. Identifiable by rawValue. The model supplies menu labels.

## ExportAudioTags — New
Title and artist are strings; wordStarts are [RenderMarker] in edited-local source-rate frames. Frozen before asynchronous rendering, with title/artist captured before the destination picker. Not persisted or recomputed against later editor edits. Blank tags omitted from AAC metadata, never block export.

## ExportRenderJob — Changed
Adds format defaulting to .aiff and tags defaulting to empty. Existing callers remain AIFF-compatible. Renderer converts markers to output-rate positions and clips at exclusive rendered end before LRC serialization. Invalid negative positions are omitted as in existing mastering behavior.

## ExportFileKind — Changed
Adds wav and m4a values, each forcesExactNames=false. Both retain existing generated-name collision review and source-prefixed manual names; .masteredM4A remains separate and unchanged. No speculative format options.
