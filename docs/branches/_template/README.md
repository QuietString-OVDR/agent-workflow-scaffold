# __BRANCH_NAME__ Docs

This directory is the canonical documentation root for branch `__BRANCH_NAME__`.
The Windows-safe folder name for this branch is `__BRANCH_DOC_DIR_NAME__`.

## Reading Order For A New Agent

1. `status/code-map.md`
2. `status/implementation-status.md`
3. `status/decisions.md`
4. `spec/technical-spec.md`
5. `architecture/current-architecture.md`
6. `plans/README.md`
7. `plans/active.md` (when implementation planning exists)
8. `plans/next-agent-handoff.md` (when a handoff or follow-up exists)

## Code Lookup Rule

- Before opening guessed source paths or running broad `rg`, use `status/code-map.md` as the first search index.
- Start from the `Search First` rows and symbol/module aliases in the code map.
- If the code map is stale or missing the needed area, update it after the investigation so future sessions do not repeat the same search.

## Current Canonical Conclusions

- Not finalized yet.
- When a new conclusion becomes canonical, update `spec/` or `architecture/current-architecture.md` first and then update this section.

## Folder Roles

- `spec/`
  - Contract documents that the team agrees on.
  - If documents conflict, this folder wins.
- `architecture/`
  - Current code structure and implementation direction.
  - Default canonical file: `current-architecture.md`.
  - Do not create additional architecture files unless this README declares them canonical.
- `status/`
  - Current implementation status, accepted decisions, and file map based on code inspection.
- `plans/`
  - Active implementation plan and handoff notes.
  - Read `plans/README.md` before creating or replacing plan files.
- `share/`
  - Polished teammate-facing documents grouped by document type, such as `guides/` and `specs/`.
  - Use this for Confluence-ready, review-ready, or cross-team documents.
  - Documents in this folder must be written in Korean.
- `research/`
  - Reference research material. Not a contract document.
- `archive/`
  - Old ideas, session notes, and snapshots.
  - Old plans should go under `archive/plans/`.
  - Not part of the current source of truth.
- `backup/`
  - Safe copies kept by the user.
  - Do not edit them or treat them as canonical.

## Document Operating Rules

- When a new rule becomes canonical, update `spec/` first.
- When a decision affects future work, update `status/decisions.md`.
- When code changes, update `status/implementation-status.md` and `status/code-map.md` together.
- Put implementation plans in `plans/`, then reflect the results in `status/` once implemented.
- Update `architecture/current-architecture.md` instead of creating new architecture drafts.
- Put polished teammate-facing documents in `share/<doc-type>/`, not in `plans/` or `architecture/`.
- Keep `plans/active.md` or the relevant existing topic plan current; do not create near-duplicate plan files for the same workstream.
- Do not mix unimplemented ideas or alternative designs into current-system descriptions.
- Internal branch memory should be written in English.
- Share docs under `share/` must be written in Korean.
