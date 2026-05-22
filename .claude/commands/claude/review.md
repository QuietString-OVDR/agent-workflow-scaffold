---
description: Claude sub-agent code review. Drop-in alternative to /codex:review — use when you want Claude to review instead of Codex, or when Codex review is unavailable.
---

# Claude Review

Spawns a `code-reviewer` sub-agent to review code changes. The main session does not read source files — all review work happens in the sub-agent.

## Usage

```
/claude:review [--base <ref>]
```

Default base ref: `main`. Override with `--base <ref>` (e.g. `--base develop`).

## Steps

### 1 — Branch Setup

Run `git branch --show-current`. Derive `<branch-doc-dir>` (replace `/` with `~`).

Parse `--base <ref>` from `$ARGUMENTS` if present; otherwise use `main`.

### 2 — Spawn Reviewer Sub-Agent

Spawn a sub-agent using the `code-reviewer` agent type with this prompt:

```
Branch: <branch>
Base ref: <ref>
Branch docs root: docs/branches/<branch-doc-dir>/

1. Read docs/branches/<branch-doc-dir>/README.md for task context.
2. Read docs/branches/<branch-doc-dir>/plans/technical-plan.md if it exists — use it as the scope contract.
3. Run `git diff <ref>` to see all changes on this branch.
4. Review for: correctness, regressions, unsafe assumptions, scope creep, missing error handling, missing verification steps.
5. Ground every finding in file path and line number where possible.
6. Write findings to docs/branches/<branch-doc-dir>/plans/code-review-claude.md using this format:

---
## Claude Review — <ISO date>
### Base ref: <ref>

### Summary
<One or two sentence verdict.>

### Findings

| Severity | Location | Finding | Recommendation |
|----------|----------|---------|----------------|
| CRITICAL / WARNING / INFO | file:line | description | fix |

### Doc Accuracy
Does implementation-status.md accurately reflect what was changed? Note gaps.

### Verdict
PASS | PASS WITH NOTES | NEEDS WORK
---

7. Report your verdict and the finding count by severity.
```

Wait for the sub-agent to complete.

### 3 — Report

Report the verdict and critical/warning findings from the sub-agent. Do not re-read the source files.

If Codex review is also needed for a second opinion, remind the user to run `/codex:review --base <ref>`.
