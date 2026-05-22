# __BRANCH_NAME__ Next Agent Handoff

## Task

Implement `<specific behavior>` from `spec/technical-spec.md`.

## Read First

- `README.md`
- `spec/technical-spec.md`
- `design/<design-doc>.md`
- `plans/design-review.md`
- Relevant source paths:
  - `<path>`

## Allowed Write Scope

- `<path-or-module>`
- `status/implementation-status.md`
- `status/code-map.md`

## Do Not Modify

- `<path-or-module>`

## Constraints

- Do not refactor unrelated systems.
- Keep public contracts backward-compatible unless the spec explicitly says otherwise.
- Follow repository language and comment policy from `AGENTS.md`.
- Do not apply Codex rescue changes unless explicitly accepted by the human owner or Claude coordinator.

## Required Verification

- Run `<targeted command>` if available.
- If a manual test is required, write exact steps and expected result.

## Codex Review Gate

- Run `/codex:review --background` after implementation.
- Run `/codex:adversarial-review --background <focus>` for high-risk architecture or integration work.
- Curate accepted findings into `plans/code-review.md`.

## Output

- Summary of code changes.
- Verification evidence.
- Updated status docs.
- Accepted or rejected Codex findings.
- Open risks or follow-up items.
