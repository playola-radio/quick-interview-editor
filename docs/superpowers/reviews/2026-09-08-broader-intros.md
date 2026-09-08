# Broader Intro validation

The approved [plan](../plans/2026-09-08-broader-intros.md) is implemented. Fresh app searches use `configured-v3`: Intro discovery now accepts complete song or artist commentary without requiring a handoff, and suppresses a duplicate Spotlight when the Intro covers at least 80% of its span. Longer independently useful stories with partial overlap remain. Unestablished naming fields retain the existing editable descriptive-name fallback.

Exact legacy built-in Intro guidance and Song Title/Artist Name instructions migrate in app-wide storage with an atomic write and one checked revision increment. Edited properties, templates, removed defaults, project snapshots, and historical run versions remain intact.

## Evidence

- Python RED: 12 new behavior/prompt failures, 49 passing focused tests before implementation.
- Python GREEN: 61 focused tests; independently rerun full suite **386 passed in 7.12 seconds** (`.context/broader-intros-python.log`). Coverage includes no-handoff song and artist commentary, missing fields, adjacent takes, 80-second commentary, overlap boundaries, unrelated Spotlights, immutable requests, checkpoint interruption, and cached resume.
- Swift RED: store migration/fresh-version assertions failed on the old implementation. The initial compilation-only failure from awaiting inside a synchronous assertion was corrected before observing behavior failures.
- Swift focused GREEN: **16 tests passed**, including migration idempotence, independent property edits, absent defaults, stale drafts, failed writes, overflow, and fresh version selection.
- Swift full GREEN: **1,528 tests in 124 suites passed in 30.670 seconds**, with 14 expected known issues (`.context/broader-intros-swift-full.log`). Historical transport/recovery fixture setup now decodes its captured configuration instead of mixing old JSON with current defaults; historical JSON and production recovery validation are unchanged.
- After splitting the longer default-text assertion into two tests for lint, the focused defaults suite passed **22 tests** (`.context/broader-intros-defaults-final.log`).
- Formatting passed; SwiftLint reported **0 violations across 264 files**.
- Independent Swift spec/quality review found no blocking issues, including a follow-up review of the historical fixture corrections.
- Independent Python spec/quality review found no issues; it ran **84 tests** and compared **40 historical v1/v2 prompts byte-for-byte** against the prior implementation.

The provider decisions in new tests are scripted. These tests establish routing, retention, priority, and recovery; they do not measure live model recall on the user's tape. Existing historical cached editorial evaluations pass. No new provider request was made and no existing project was modified. Rebuild the app and start a fresh search to use the broader definition; Resume deliberately retains the previous run's captured rules and prompt version.
