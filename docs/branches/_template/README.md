# __BRANCH_NAME__ Docs

This directory is the canonical documentation root for branch `__BRANCH_NAME__`.
The Windows-safe folder name for this branch is `__BRANCH_DOC_DIR_NAME__`.

## Reading Order For A New Agent

1. `status/code-map.md`
2. `status/implementation-status.md`
3. `spec/technical-spec.md`
4. `design/current-architecture.md`
5. `design/build-automation-design.md` (only for build or automation work)
6. `plans/next-agent-handoff.md` (when a handoff or follow-up exists)

## Code Lookup Rule

- Before opening guessed source paths or running broad `rg`, use `status/code-map.md` as the first search index.
- Start from the `Search First` rows and symbol/module aliases in the code map.
- If the code map is stale or missing the needed area, update it after the investigation so future sessions do not repeat the same search.

## Current Canonical Conclusions

- Not finalized yet.
- When a new conclusion becomes canonical, update `spec/` or `design/` first and then update this section.

## Folder Roles

- `spec/`
  - Contract documents that the team agrees on.
  - If documents conflict, this folder wins.
- `design/`
  - Documents that describe the current code structure and implementation direction.
- `status/`
  - Current implementation status and file map based on code inspection.
- `plans/`
  - Handoff notes, priorities, and cautions for the next worker.
- `research/`
  - Reference research material. Not a contract document.
- `archive/`
  - Old ideas, session notes, and snapshots.
  - Not part of the current source of truth.
- `backup/`
  - Safe copies kept by the user.
  - Do not edit them or treat them as canonical.

## Document Operating Rules

- When a new rule becomes canonical, update `spec/` first.
- When code changes, update `status/implementation-status.md` and `status/code-map.md` together.
- Put implementation plans in `design/` or `plans/`, then reflect the results in `status/` once implemented.
- Do not mix unimplemented ideas or alternative designs into current-system descriptions.
- All docs in this branch root should be written in English.
