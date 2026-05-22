# Plan With Codex

Orchestrate a planning cycle: a context-gatherer sub-agent reads all relevant files and writes a summary, Codex investigates further and drafts the plan directly to disk, Claude reviews and finalizes into branch docs. End the turn so the user decides next steps.

## Usage

```
/plan-with-codex <planning request>
```

Optionally append `--base <ref>` to override the review base ref (default: `main`).

---

## Step 1 — Branch and Docs Setup

1. Run `git branch --show-current` to get the current branch name.
2. Derive `<branch-doc-dir>` by replacing every `/` with `~` in the branch name.
3. If `docs/branches/<branch-doc-dir>/` does not exist, initialize it:
   `bash ./tools/agent/init-branch-docs.sh`
4. Read `docs/branches/<branch-doc-dir>/README.md` and
   `docs/branches/<branch-doc-dir>/plans/next-agent-handoff.md` if they exist.
   Keep this reading minimal — detailed source investigation is the sub-agent's job.

---

## Step 2 — Context Gathering (Sub-Agent)

Spawn a `context-gatherer` sub-agent via the Agent tool. Do NOT read source files or
query external APIs yourself — delegate all of that to the sub-agent to keep the main
session context clean.

Sub-agent prompt:

```
Branch: <branch>
Branch docs root: docs/branches/<branch-doc-dir>/
Task: $ARGUMENTS

Files and sources to investigate (derived from the user request):
<list every ticket path, source file, and external system the user mentioned>

Steps:
1. Read all referenced ticket and spec files.
2. Identify and read the key source files involved in this task.
3. If external APIs (TeamCity, S3, etc.) are referenced, query them using available skills.
4. Write a structured context summary to .agent-work/context-<branch>.md following your
   output format instructions.

Do not modify any source files.
```

Wait for the sub-agent to complete, then read `.agent-work/context-<branch>.md`.

---

## Step 3 — Codex Investigation and Draft (Foreground, with write)

Run `/codex:rescue --write` (foreground, no `--background`) so Codex can write files
directly and this turn waits for completion.

Use this prompt template, embedding the full content of `.agent-work/context-<branch>.md`:

```
Plan: $ARGUMENTS

Branch: <branch>. Branch docs root: docs/branches/<branch-doc-dir>/.

== Context Summary (gathered by pre-analysis) ==
<paste full content of .agent-work/context-<branch>.md here>
== End Context Summary ==

Tasks:
1. Read AGENTS.md.
2. Investigate any open questions listed in the Context Summary. Focus on resolving
   ambiguities that would block the plan — do not re-read files already covered above.
3. Write a technical plan to docs/branches/<branch-doc-dir>/plans/technical-plan.md
   using this structure:

---
## Technical Plan — <ISO date>

### Goal
<What this work achieves and why.>

### Current State
<How the relevant system works today. Key files, entry points, data flow.>

### Proposed Approach
<Step-by-step description of what will change and how.>

### Affected Files
| File | Change type | Notes |
|------|-------------|-------|
| path/to/file | add / modify / delete | reason |

### Open Questions
<Anything that needs a decision before implementation can start.>

### Risks
<What could go wrong. Missing edge cases, integration risks, rollback difficulty.>
---
```

Do not proceed to Step 4 until Codex finishes.

---

## Step 4 — Claude Review and Finalize

Read `docs/branches/<branch-doc-dir>/plans/technical-plan.md` written by Codex.

Assess:
- Does the proposed approach match the user's request?
- Are there gaps in the affected files list?
- Are the open questions and risks complete?

Make targeted corrections directly in `technical-plan.md` if needed. Do not rewrite the
whole document — only fix what is wrong or missing.

---

## Step 5 — Update Branch README

Update `docs/branches/<branch-doc-dir>/README.md` to reference the new plan:

```markdown
## Active Plans
- [Technical Plan](plans/technical-plan.md) — <one-line summary>
```

---

## Step 6 — Report and End Turn

Report to the user:
- Where the plan is saved.
- Any open questions that need a decision before implementation.
- Whether the plan is ready for `/implement-with-review` or needs more discussion.

End the turn. Do not begin implementation.
