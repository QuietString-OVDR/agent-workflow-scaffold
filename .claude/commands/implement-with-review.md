# Implement With Review

Orchestrate a full implementation cycle: Codex implements, then Codex and a Claude sub-agent review in parallel, findings are synthesized and documented. End the turn so the user decides next steps.

## Usage

```
/implement-with-review <task description>
```

Optionally append `--base <ref>` to override the review base ref (default: `main`).

---

## Step 1 — Branch and Docs Setup

1. Run `git branch --show-current` to get the current branch name.
2. Derive `<branch-doc-dir>` by replacing every `/` with `~` in the branch name.
3. If `docs/branches/<branch-doc-dir>/` does not exist, initialize it:
   `bash ./tools/agent/init-branch-docs.sh`
4. Read `docs/branches/<branch-doc-dir>/README.md` and
   `docs/branches/<branch-doc-dir>/plans/next-agent-handoff.md` for context.

---

## Step 2 — Codex Implementation (Foreground)

Run `/codex:rescue --write` (foreground, no `--background`) so Codex can write files
directly and this turn waits for completion.

Use this prompt template:

```
Implement: $ARGUMENTS

Branch: <branch>. Branch docs root: docs/branches/<branch-doc-dir>/.

Before coding:
- Read AGENTS.md.
- Read docs/branches/<branch-doc-dir>/README.md.

After coding:
- Update docs/branches/<branch-doc-dir>/status/implementation-status.md
  to reflect what was implemented, what was skipped, and current status.
- Update docs/branches/<branch-doc-dir>/status/code-map.md if the file
  structure changed.

Scope constraints:
- Do not modify files outside the implementation scope.
- The only docs/ files you may write are the two status files above.
```

Do not proceed to Step 3 until Codex finishes.

---

## Step 3 — Parallel Review

Start both reviewers before waiting for either to finish.

### A. Codex Review (background)

Run `/codex:review --base main --background`
(substitute `--base <ref>` if the user specified an override).

### B. Claude Sub-Agent Review (parallel)

Immediately after starting Codex review, spawn a sub-agent via the Agent tool.

Sub-agent prompt:

```
You are performing a standalone code review. Do not ask for clarification — work
from the information given and the files you can read.

Task that was implemented: $ARGUMENTS
Branch: <branch>
Branch docs root: docs/branches/<branch-doc-dir>/

Read for context:
- docs/branches/<branch-doc-dir>/README.md
- docs/branches/<branch-doc-dir>/status/implementation-status.md
- docs/branches/<branch-doc-dir>/status/code-map.md

Review the changes:
  git diff main   (or git diff <base-ref> if overridden)

Assess the following and write your findings to
docs/branches/<branch-doc-dir>/plans/code-review-claude.md:

---
## Claude Review — <ISO date>

### Summary
<One or two sentence verdict.>

### Findings

| Severity | Location | Finding |
|----------|----------|---------|
| CRITICAL / WARNING / INFO | file:line | description |

### Doc Accuracy
Does implementation-status.md accurately reflect what was changed? Note any gaps.

### Verdict
PASS | PASS WITH NOTES | NEEDS WORK
---

Do not modify any source files. Only write to plans/code-review-claude.md.
```

---

## Step 4 — Collect Codex Review

After the sub-agent finishes:

1. Poll `/codex:status` until the review job is complete.
2. Run `/codex:result` to retrieve the output.
3. Write the raw output to
   `docs/branches/<branch-doc-dir>/plans/code-review-codex.md`.

---

## Step 5 — Synthesize

Write `docs/branches/<branch-doc-dir>/plans/code-review.md`:

```markdown
## Combined Review — <ISO date>

### Task
<task description>

### Codex Review — Verdict: <verdict from code-review-codex.md>
<2-3 sentence summary of Codex findings>

### Claude Review — Verdict: <verdict from code-review-claude.md>
<2-3 sentence summary of Claude findings>

### Combined Verdict
PASS | PASS WITH NOTES | NEEDS WORK

### Action Items
<!-- List only items that block the next step. Leave empty if none. -->
- [ ] <item>
```

Report the combined verdict to the user in one short paragraph and end the turn.
Do not attempt to fix issues — the user decides next steps.
