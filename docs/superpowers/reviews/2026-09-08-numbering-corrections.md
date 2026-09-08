# Numbering corrections validation

This change follows the user’s two corrections: move Starting Counts and Song/Group Counts into Configure Suggestions, and assign numbers only when a suggestion is accepted as a clip.

## Behavior

Configure Suggestions now includes Numbering under This project. Project Save/Reset actions remain independent of app-wide rule drafts; rule drafts survive navigation and cancelling them does not revert saved project counts. Closing configuration discards unsaved starting-count text. Group review belongs to the configuration sheet and closes without dismissing it. Numbering actions remain locked during search/export ownership transitions, with validation messages visible inside configuration.

Pending suggestions use descriptive labels. Acceptance applies the captured naming template and assigns the next number within the type/song group. Rejected suggestions consume nothing. A configured starting count is a minimum, so subsequent accepted clips continue after previously issued numbers. Saved clip names and permanent number identities remain stable through deletion, Undo/reaccept, and reopening older projects.

## Verification record

Initial UI-focused run: 18 SuggestionSettingsTests passed, including project scoping, rule-draft preservation, nested review ownership, invalid starts, locks, and weak ownership. Independent UI review found no actionable issues. A further load/navigation regression is included in final integration checks.

The new Editor acceptance-order regression passed after first reproducing the old behavior: start at 7, reject first, accept later candidates as 7/8, Undo/reaccept 8, delete 7, then accept another as 9. Independent design review identified existing-document normalization as necessary; that compatibility case is part of the implementation.

The final affected-suite run passed 145 tests in seven suites. Review also verified filtered canonical spelling fields, precedence of previously issued spelling, and Apply → Undo with a clean or partly edited group review. The first full-suite run found two obsolete document-mutation expectations; those were corrected in `6657863`, and all 10 document-mutation tests passed. Final full-suite verification: `make -C QuickInterviewEditor test-fast` passed **1,521 tests in 124 suites**, 31.453 seconds, with **14 expected known issues and no unexpected failures**. Strict formatting, SwiftLint, and diff checks passed. These were model/integration checks; interactive native UI actions were not repeated for this revision. No live provider request was needed for these Swift-only changes.

## Investigation: only Spotlights detected

The user additionally requested checking whether other suggestion types were blocked or removed. Read-only inspection of the latest available saved run found all six default types enabled, `configured-v2`, model `claude-sonnet-5`, and 939 transcript units. Its validated request records contain nine partition responses, classification with 55 Spotlights and one proposed Intro, refinement returning no complete takes for that Intro, and nine imaging responses each returning an empty clips list. The ready checkpoint contains all 55 Spotlights and no failed batches.

The excluded Intro passage discusses a song's award and performance history; rejecting it as a performance handoff appears reasonable. No imaging answers were removed downstream: the model had returned none. Replaying a temporary copy of this journal using the real CLI with `--cached`, without provider credentials, exactly reproduced the 55 saved suggestions. The original journal was unchanged and temporary copies were removed.

Independent code review confirmed the imaging pass runs separately from Spotlight/Intro discovery; local UI filters do not narrow searches; Spotlight cannot deduplicate an Intro or image; missing fields retain candidates; and Swift maps all requested types into the results. Duration, duplicate, subtype-overlap, and Intro-refinement guards remain intentional. They do not explain this run's empty imaging results. No routing/filter bug was found, and no prompt was changed to force additional types. This establishes which searches ran and what their recorded answers were, rather than guaranteeing the model found every usable passage.
