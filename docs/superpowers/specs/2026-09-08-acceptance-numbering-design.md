# Assign suggestion numbers when accepting clips

User correction on 2026-09-08: assigning numbers to discovered suggestions leaves gaps when some suggestions are rejected. Numbers must instead be assigned when a suggestion is accepted as a saved clip.

## Required behavior

- Discovery and rejection do not consume a sequence number. Pending suggestions use their descriptive discovery label until acceptance; extraction and field correction remain available before acceptance.
- Accepting clips assigns consecutive numbers in acceptance order within the captured type/song grouping. Starting at 7 yields 7, 8, 9 for the first three accepted clips even when other suggestions are rejected between them.
- Types using fields still render their captured naming template on acceptance. Song Intro counters remain independent per normalized song/performer group.
- Number allocation, clip creation, status change, and permanent issued-number recording form one validated document transaction. Failed acceptance consumes nothing.
- Already issued numbers and existing saved clip names remain stable. Deletion and Undo retain the existing permanent reservation behavior; reaccepting the same owner preserves its identity.
- Previously numbered but never accepted suggestions must not reserve numbers against newly accepted clips. Older saved clips retain their issued identities.
- Starting-count controls move into Configure Suggestions as already requested. Their wording must describe acceptance-time counts. Search completion must no longer require resolving collisions caused solely by pending suggested numbers.

This correction supersedes the original design's discovery-time numbering and pending-renumber behavior. Discovery prompts, recovery of paid provider work, app-wide rules, captured naming templates, and exact export names remain in scope of the original design.
