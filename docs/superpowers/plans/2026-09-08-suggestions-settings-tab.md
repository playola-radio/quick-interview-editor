# Consolidate Suggestion Configuration in Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Remove the Suggestions panel's Configure Suggestions button and keep every rule, field, Interview Artist, and numbering control available in the macOS Settings tab.

**Architecture:** Reuse the app-owned SuggestionSettingsModel already shown in Settings. ProjectHostView publishes project activation, editor replacement, and closure to that shared model. The settings model weakly tracks the last active project and binds its existing CutSuggestionsPageModel callbacks, preserving document Undo/autosave and the global rule draft. Project-specific unsaved drafts live on their project page so focus changes cannot apply one project's input to another.

**Tech Stack:** SwiftUI scenes and EnvironmentValues.appearsActive (available in the installed SDK for the macOS 15 deployment target), Observable models, existing document callbacks, Swift Testing/CustomDump.

## Approved design

- Keep Configure Suggestions as the existing Settings tab (Cmd-,). Remove the duplicate panel button and its sheet presentation.
- The tab contains all current rules, extraction fields, Interview Artist, type starting counts, song/group counts, and group spelling review.
- Show which project Interview/Numbering target. Keep that target when Settings becomes the active window; opening Settings does not clear it. Activate a different project to change the target.
- Preserve unsaved global rule edits across project changes. Preserve unsaved project artist/count drafts on their respective pages. Dismiss any open group review when changing projects so its content never appears under another project's name.
- On closing the target project, clear its settings connection; a later activation selects another project. When there is no project, keep app-wide rules available and explain that opening a project enables Interview/Numbering. Do not retain closed projects through settings references.
- Native Settings uses its normal window close behavior; remove sheet-only Done behavior there. Save Rules/Cancel Rule Edits retain their existing meaning. Saving project settings stays undoable and does not save/discard the rule draft.

## Task 1: Settings context, project drafts, and obsolete panel flow

**Modify:** `Views/Pages/SuggestionSettings/SuggestionSettingsModel.swift`, `SuggestionSettingsView.swift`; `Views/Pages/CutSuggestions/CutSuggestionsPageModel.swift`, `CutSuggestionsPageView.swift`; associated Swift tests.

- [x] Write tests for model-owned project context retaining its target on deactivation, switching/closing/replacing an editor safely, preserving per-project artist/number drafts and the global rule draft, and applying edits through the correct project's Undo/autosave callbacks. Test no-project copy and persistent Settings actions.
- [x] Run tests RED with root as sole xcodebuild owner. Missing new API declarations are an expected initial compile failure; identity/draft/action behavior must pass after implementation.
- [x] Add app-context methods to SuggestionSettingsModel: `projectActivityChanged(_:appearsActive:)`, `projectUpdated(_:)`, and `projectClosed(_:)`. Track the project weakly. Bind numberingPage to its current editor's suggestion page; clear group review on target changes. An initializer flag `isSettingsTab` distinguishes persistent Settings actions from test/preview standalone instances.
- [x] Keep pending artist input on CutSuggestionsPageModel alongside existing futureStartDrafts. The Settings model's artist binding reads/writes the current page's draft and resets only that draft after Save. Existing project callbacks remain the only document mutation path.
- [x] Remove panel configuration button, sheet, and obsolete presentation properties/actions. Update tests that used the old sheet helper to construct SuggestionSettingsModel(numberingPage:) directly, retaining their actual behavior assertions.
- [x] Display active project name or no-project explanation using model-owned text. Preserve all configuration controls and independent rule draft state.

## Task 2: App and project scene integration

**Modify:** `QuickInterviewEditorApp.swift`, `Views/Pages/Project/ProjectHostView.swift`.

- [x] Initialize app-owned SuggestionSettingsModel with `isSettingsTab: true` and inject it into document hosts through the SwiftUI environment.
- [x] Read appearsActive in ProjectHostView and forward activation changes (including initial state) to the model. Forward editor and document URL changes for the currently tracked project, and closure on disappearance. Ignore loss of activation in the settings model so Settings can take focus without losing the document target.
- [x] Keep all activation decisions inside the model. Avoid global NSApplication window enumeration, AppKit event monitors, new package dependencies, or xcodegen regeneration.
- [x] Verify compile plus project-context tests and inspect that the Settings tab uses the same injected model as the hosts.

## Task 3: Review, validation, and documentation

- [x] Independently review weak ownership, multiple-document transitions, draft isolation, callbacks, and removal of all user-facing panel access.
- [x] Run full Swift tests with `make -C QuickInterviewEditor test-fast`, then format-check/lint and git diff --check. Python behavior is untouched; do not run unrelated provider tests.
- [x] Update README to direct users to Settings → Configure Suggestions. Record validation and limitations, then commit locally. No push, release, or changes to existing projects.

## Completion

Implemented and independently reviewed. See [validation evidence](../reviews/2026-09-08-suggestions-settings-tab.md).
