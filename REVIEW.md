# Review Rules

Use this file for local review agents, Codex plugin review prompts, Claude Code subagents, and PR review automation.

## Priorities

Review findings should prioritize:

- Behavioral bugs and regressions.
- Data loss, security, permission, or privacy risks.
- API, schema, serialization, or compatibility contract breaks.
- Threading, lifetime, ownership, caching, or async hazards.
- Missing validation, error handling, rollback, or observability.
- Missing automated or manual verification for the changed behavior.
- Scope creep beyond `plans/next-agent-handoff.md`.
- Generated, temporary, or local-only files accidentally included in diffs.

## Finding Format

Each finding should include:

- Severity: `critical`, `major`, or `minor`.
- Evidence: file path, line number, section, command output, or branch-doc reference.
- Impact: what can fail and who is affected.
- Recommendation: the smallest practical fix or verification step.
- Status: `open`, `accepted`, `rejected`, or `resolved`.

## Review Discipline

- Do not request style-only churn unless it hides a real defect.
- Prefer small, high-confidence fixes over broad rewrites.
- If the implementation contradicts `spec/` or `design/`, call out the contradiction instead of silently changing the contract.
- If the reviewer is not sure, state the uncertainty and the evidence needed.
- Accepted findings should be curated into `docs/branches/<branch-doc-dir>/plans/code-review.md` or `plans/design-review.md`.
