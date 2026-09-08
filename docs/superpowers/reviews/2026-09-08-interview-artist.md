# Interview artist and Intro qualification validation

The approved [spec](../specs/2026-09-08-interview-artist-design.md) and [plan](../plans/2026-09-08-interview-artist.md) cover optional project identity, evidence-based Intro qualification, and redundant filter choices.

## Implemented behavior

- Optional Interview Artist on the import screen and in Configure Suggestions → This project → Interview. Project Save trims or clears the value, participates in Undo/Redo and autosave, and remains independent of rule drafts. Old projects decode without a name; re-transcription preserves saved identity.
- Fresh configured-v4 / fields-v2 searches capture identity in their immutable snapshot/request. Extraction uses it for the subject's own music rather than assigning it to all speakers or songs. Old runs retain their captured versions and settings on Resume.
- Successfully extracted double-null Song Title/Artist Name disqualifies an Intro. Existing matching tuned Spotlights are preferred; other complete 15–240-second thoughts convert to the configured Spotlight with its own ID, naming template and extracted fields. One known field keeps an Intro. Failed or oversized extraction and deleted field definitions are not mistaken for negative evidence.
- Surviving Intros retain duplicate-passage priority. Unaffected tuned Spotlight selections stay intact. A tiny nested Spotlight does not discard a larger useful fallback thought.
- Types shows plural groups once for conventional singleton Intro/Spotlight defaults, retaining imaging, custom, renamed and multiple-type child choices. Underlying group selections still use every stable type ID.

## Verification

Python TDD covered successful/failed/oversized extraction, qualification fields omitted from naming templates, removed definitions, custom fallback fields, stable converted IDs, overlapping candidates, historical versions, request identity and resume. The final full Python run passed **422 tests in 6.12 seconds** (`.context/interview-python-full.log`).

The Spotlight naming implementation retains normal batches. A regression with 41 customized Spotlights requires three naming requests. Exact candidate/field matches from integrity-checked, identity-bound completed journal responses are reused before batching, including responses saved ahead of a checkpoint and candidate sets changed by later qualification. No successful paid request needs repeating in these cases.

Swift recovery RED produced four expected failures showing the old code ignored artist identity. Fresh-capture RED produced four expected failures showing the old version and missing context. UI test declarations initially failed compilation because the new API was absent. Subsequent build fixes added the required actor/await annotations. The first full run exposed two test expectation/setup errors in the menu test (Optional.none versus enum none, and a newly added unselected custom type); production filtering matched the specification.

Final full Swift verification passed **1,538 tests in 124 suites in 28.582 seconds**, with 14 expected known issues and no unexpected failures (`.context/interview-swift-full.log`). Strict formatting passed, and SwiftLint reported **0 violations across 264 files**.

Independent read-only reviews covered Python qualification and cache reuse; Swift snapshot/wire/manifest identity; fresh capture and resumed snapshots; import persistence and all Editor document projections; settings draft isolation; and historical/custom menu behavior. No blocking findings remain.

No live provider calls or interactive native UI harness were used. These tests establish application behavior, prompt contents and recovery, not live model recall on the user's recording. Existing clips/projects were not modified. Rebuild and run a fresh search to use the new context and qualification; Resume uses its original captured request.
