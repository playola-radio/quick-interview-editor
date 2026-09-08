# Suggestions Settings tab validation

Implemented the approved [plan](../plans/2026-09-08-suggestions-settings-tab.md).

The Suggestions panel's Configure Suggestions button and separate sheet have been removed. The app-owned Configure Suggestions Settings tab now includes all app-wide rule and field editors plus the last active project's Interview Artist, type starting counts, song/group counts, and group spelling review. The tab identifies that project and retains it while Settings has focus.

Project activation and editor/URL changes are forwarded from ProjectHostView through the same SuggestionSettingsModel instance displayed in Settings. Losing activation does not clear the target. Closing a target clears its connection, while unrelated project updates/closures leave it alone. Both project and page references are weak. The installed SwiftUI SDK declares EnvironmentValues.appearsActive available for the macOS 15 deployment target.

Unsaved artist and count drafts stay on their owning project pages. Global rule drafts remain on the persistent Settings model. Context switches dismiss group review and retain each project's draft values. Existing document mutation callbacks preserve Undo and autosave. Persistent Settings uses normal native window closing rather than a sheet-only Done action.

## Evidence

- Added seven model regressions for focus loss, project switching, separate project/global drafts, Save and Undo routing, review dismissal, editor replacement, closure, weak lifetime, and project filename updates. Root observed the expected missing-API RED before implementation.
- Existing configuration tests were adapted from the removed sheet helper to direct Settings model construction, preserving their actual rule/field/numbering assertions.
- Full Swift suite: **1,545 tests in 124 suites passed in 29.233 seconds**, with 14 expected known issues and no unexpected failures (`.context/settings-tab-swift.log`).
- Strict formatting passed. SwiftLint reported **0 violations across 264 files** (`.context/settings-tab-format.log`, `.context/settings-tab-lint.log`).
- Independent spec/quality review found no concrete defects in context handling, ownership, draft isolation, controls, callback routing, or panel removal.
- `git diff --check` passed. No Python or provider behavior changed.

Verification covered models and compilation of native scene wiring. No interactive native window-focus smoke test was run; no user's open project or saved clip was modified.
