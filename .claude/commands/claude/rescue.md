---
description: Claude sub-agent implementation. Drop-in alternative to /codex:rescue — use when you want Claude to implement instead of Codex.
---

# Claude Rescue

Spawns a `branch-implementer` sub-agent to implement a bounded task. The main session does not read source files — all implementation work happens in the sub-agent.

## Usage

```
/claude:rescue <task description>
```

## Steps

### 1 — Branch Setup

Run `git branch --show-current`. Derive `<branch-doc-dir>` (replace `/` with `~`).

### 2 — Spawn Implementer Sub-Agent

Spawn a sub-agent using the `branch-implementer` agent type with this prompt:

```
Task: $ARGUMENTS

Branch: <branch>
Branch docs root: docs/branches/<branch-doc-dir>/

1. Read AGENTS.md.
2. Read docs/branches/<branch-doc-dir>/README.md.
3. Read docs/branches/<branch-doc-dir>/plans/next-agent-handoff.md if it exists — treat it as the scope contract.
4. Implement the task. Respect the allowed write scope in the branch docs.
5. Update docs/branches/<branch-doc-dir>/status/implementation-status.md and status/code-map.md to reflect what changed.
6. If the implementation contradicts the plan or spec, stop and report the conflict instead of proceeding silently.
7. Report: what was implemented, what was skipped, and any conflicts or open questions.
```

Wait for the sub-agent to complete.

### 3 — Report

Summarize what the sub-agent implemented. Do not re-read the changed source files — trust the sub-agent's report.

If review is needed next, remind the user to run `/codex:review --base <ref>` or `/claude:review --base <ref>`.
