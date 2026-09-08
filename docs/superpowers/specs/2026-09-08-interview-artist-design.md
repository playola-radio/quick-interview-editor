# Interview artist, Intro qualification, and Types menu

Approved by the user on 2026-09-08. This follows the broader Intro change.

## Interview identity

Offer an optional **Interview Artist** text field in the empty import screen, before choosing or dropping audio. Import does not require a name. Persist the trimmed value with the project's undoable document, defaulting to absent for old projects. Preserve it through save/open and re-transcription. Configure Suggestions includes a project-specific **Interview** section with the same editable value and an explicit Save action. This is independent of app-wide rule drafts and does not rename existing clips.

Capture the name in each fresh suggestion-run snapshot and immutable request. Resume uses the captured name even if project settings change. Include it as clearly identified user-provided context for extraction: use the real name only when the passage concerns the interview subject's own music. It is not a blanket default for every speaker or artist mention; other performers still resolve from the text. Never emit the literal placeholder SELF.

## Intro qualification

Fresh searches use configured-v4 and fields-v2. After successful extraction, a built-in Intro with both Song Title and Artist Name explicitly missing is not retained as an Intro. One established field is sufficient: artist-only commentary and known-song/unknown-performer clips remain Intros. Missing fields caused by failed or oversized requests do not trigger reclassification; these remain retryable or explicitly diagnosed.

Preserve useful complete commentary as a Spotlight when the configured Spotlight type exists and the clip fits its established 15–240-second bounds. Prefer a matching candidate from the tuned Spotlight pass over inventing a duplicate. A discovered complete thought that needs conversion uses the configured Spotlight naming rules and fields, with a new stable candidate ID derived from its resulting type and span. If no Spotlight type is configured or the passage fails its bounds, omit the unqualified Intro. Reapply Intro priority only for surviving qualified/pending Intros, so disqualified Intros do not hide useful Spotlights.

Qualification applies when the built-in song-title and artist-name definitions are available. Extract these two fields for v4 Intro qualification even if the user removes them from the naming template; only fields requested by the naming template enter Swift naming records. If the user deletes a default field definition, do not interpret that absent definition as failed evidence. Custom types remain unaffected.

## Filter menu

Keep plural group labels: **Spotlights**, **Song Intros**, **Audio Images**. For a group containing only its conventional built-in type, display one group toggle and omit the redundant child toggle. Retain child choices for imaging subtypes, custom types, renamed types, and multiple types. Filtering still operates on stable type IDs, including historical types. Preserve all/none/partial state and group toggling.

## Compatibility and verification

Optional persisted fields decode old projects and run snapshots unchanged. Old request bytes and identity hashes omit interview_artist when absent; old discovery/extraction versions replay unchanged. New request identity includes a supplied artist so different names cannot share a recovery identity. Validate Swift/Python identity parity, capture/resume behavior, import/settings persistence, default-field null vs failed extraction, fallback naming with custom Spotlight templates, custom type behavior, and filter states. Run Python and Swift suites and formatting/lint, with a single owner for Swift builds. No live provider call is necessary to verify routing; do not claim these tests establish model recall on the user's tape.
