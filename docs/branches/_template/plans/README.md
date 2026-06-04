# Plans

This folder stores active implementation planning for branch `__BRANCH_NAME__`.

## Default Files

- `active.md`
  - The default current implementation plan.
- `next-agent-handoff.md`
  - Short handoff for the next worker.

## Plan Lifecycle

Use one of these lifecycle values near the top of every plan:

- `active`
- `parked`
- `implemented`
- `superseded`
- `archived`

## Operating Rules

- Before creating a new plan file, update `active.md` or an existing topic plan unless the work is a distinct new workstream.
- When a plan is implemented or superseded, update its lifecycle value and summarize the final result in `../status/implementation-status.md`.
- Move old plan files to `../archive/plans/` when they are no longer useful as active context.
- Keep this folder small enough that a new agent can identify the current plan quickly.
