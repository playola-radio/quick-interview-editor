# Numbering in Configure Suggestions Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans for this focused change; review the final diff independently. Steps use checkbox syntax for tracking.

**Goal:** Remove Future Search Starts and Song Starts from the Suggestions panel and place both under Numbering — This project in Configure Suggestions.

**Architecture:** Keep existing project-owned numbering actions and Undo transactions on CutSuggestionsPageModel. SuggestionSettingsModel holds a weak reference to that page and owns selection/presentation inside the configuration sheet. Rule drafts remain app-wide; numbered-start Save/Reset actions remain immediate project edits. No persistence, discovery, or allocation changes.

**Tech Stack:** SwiftUI, Observation, Swift Testing, Dependencies, Sharing, CustomDump.

## Approved design

The user approved moving the two controls into Configure Suggestions and asked to implement this change first. Add a Numbering sidebar choice beneath the existing Types and Fields choices. Selecting it shows a scrollable project numbering panel with the existing type-start and song/group-start actions. Label its scope “This project” and explain that each Save/Reset applies to this project and can be undone in the editor. Keep rule save/cancel behavior explicit with “Save Rules” and “Cancel Rule Edits”; when viewing numbering with no changed rule draft, show Done instead. Rule drafts survive navigation between the sections. Saved project numbering is unaffected by cancelling a rule draft.

Group review opens as a child sheet of configuration. Field review from the main Suggestions list keeps its existing presentation. Error messages and search/export locks remain visible/effective in the new location. A settings instance without a project context does not offer numbering. Use a weak page reference to avoid a settings/page retention cycle.

## Task 1: Settings navigation and regression coverage

Files: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/SuggestionSettings/SuggestionSettingsModel.swift`, `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/SuggestionSettings/SuggestionSettingsTests.swift`, `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/CutSuggestions/CutSuggestionsPageModel.swift`.

- [x] Add tests for project-aware numbering selection, preservation of a changed rules draft across navigation, project save surviving Cancel Rule Edits, and absence of numbering in standalone settings. Use existing editor fixtures and `expectDifference` / `expectNoDifference`.
- [x] Run `make -C QuickInterviewEditor test-fast ONLY=PlayolaInterviewEditorTests/SuggestionSettingsTests` and observe missing selection/context API failures.
- [x] Add `weak var numberingPage: CutSuggestionsPageModel?`, `private(set) var isNumberingSelected = false`, `var numberingReview: SuggestionReviewModel?`, and a default-nil `numberingPage` initializer argument. Derive `showsNumbering`, `showsNumberingOption`, `showsRuleActions`, and `showsDone` in the model. Numbering selection changes only navigation; type/field selection exits numbering.
- [x] Pass `numberingPage: self` from `configureSuggestionsTapped()`. Route group reviews to `suggestionSettings.numberingReview` while settings is present, with a dismissal callback that clears that child only. Keep field reviews on the page.
- [x] Verify project start changes use the existing `applyTypeStartTapped`, `resetTypeStartTapped`, `resetSongStartTapped`, and `reviewGroupTapped` actions with their existing lock/error handling.

## Task 2: Move the controls

Files: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/CutSuggestions/CutSuggestionsPageView.swift`, `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/SuggestionSettings/SuggestionSettingsView.swift`.

- [x] Remove both DisclosureGroups from CutSuggestionsPageView.
- [x] Add the Numbering sidebar choice to SuggestionSettingsView. Display a local `SuggestionNumberingView` (same Swift file, no project registration changes) bound to the original page model when selected.
- [x] Move the existing control content into two sections in the configuration content ScrollView, removing their nested 220-point scroll limits. Display project scope/help and the page action error inside the panel. Disable its actions using `candidateActionsDisabled`.
- [x] Add the settings-owned `.sheet(item: $model.numberingReview)` for SuggestionReviewView. Keep the settings sheet open when that review closes.
- [x] Use model-derived footer visibility and copy so Done is available for numbering-only visits and rule Save/Cancel remains scoped to rule drafts.

## Task 3: Verify and document

Files: the preceding tests plus `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/CutSuggestions/SuggestionReviewTests.swift`, `README.md`, this plan.

- [x] Add a regression opening Configure Suggestions → Numbering → Review Group, saving a song start, resetting the override, and closing only the review. Verify locks and surfaced invalid starting-number errors through the moved controls; preserve existing number/Undo tests.
- [x] Run affected suites: SuggestionSettingsTests, CutSuggestionsPageTests, SuggestionReviewTests, and EditorSuggestionFlowTests (one xcodebuild invocation with four suite filters).
- [x] Run scoped `xcrun swift-format lint --strict`, `swiftlint lint --strict --path` if supported (otherwise the existing full `make lint`), and `git diff --check`. Fix only relevant formatting.
- [x] Inspect the final model/view wiring for nested sheet ownership, retained rule drafts, and weak ownership. Record actual test results here, update README location instructions, and commit locally. Do not restart the user's app or touch its project data.

## Acceptance-numbering correction during execution

The user subsequently required numbering only when clips are accepted, so rejected suggestions leave no gaps. The companion [acceptance-numbering plan](2026-09-08-acceptance-numbering.md) implements that behavior. This supersedes pending-renumber controls and search-start wording in the original task: the new panel uses Starting Counts, Start numbering at, and Song and Group Counts. Group review no longer offers pending renumbering. Previously issued clip identities remain stable.

Initial location verification: 18 SuggestionSettingsTests passed, including navigation/draft preservation, independent project saves, nested review ownership, invalid input and lock protection, and weak ownership. Independent UI review found no actionable issues. Final integrated checks follow acceptance-numbering changes.

Final integration: 1,521 Swift tests in 124 suites passed (14 expected known issues), including 145 focused tests across seven feature suites and 10 document-mutation tests. Independent UI, acceptance, and canonical Undo reviews passed. The pure legacy allocation helpers retain separate compatibility tests; normal search/review paths no longer allocate pending numbers.
