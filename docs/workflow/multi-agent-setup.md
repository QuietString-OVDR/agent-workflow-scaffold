# Multi-Agent Development Workflow

Codex + Claude pipeline running from a single Claude Code session via the `openai/codex-plugin-cc` plugin. Codex handles design review and investigation; Claude handles implementation and file edits. Branch documentation remains the source of truth.

---

## Environment

| Layer | Tool | Role |
|---|---|---|
| Primary session | **Claude Code CLI** | Single shell window for the entire pipeline |
| Second-opinion agent | **Codex** (via `codex-plugin-cc` plugin) | Review, adversarial challenge, bounded investigation |
| Terminal (optional) | **Warp** | Visual status badges and system notifications for background Codex jobs |

Everything runs from one Claude Code session. No separate Codex terminal needed.

---

## Responsibilities

### Claude Code
- Read the branch README before starting branch work.
- Create or update branch docs when coordinating work locally.
- Implement from `plans/next-agent-handoff.md`, not from an unbounded chat request.
- Stay within the assigned file/module scope.
- Update `status/implementation-status.md` and `status/code-map.md` when source code changes.
- Stop and report if implementation invalidates the spec or design.
- Call Codex plugin commands when a review, challenge, or investigation is needed.

### Codex (via plugin)
- Review uncommitted changes or branch diffs with `/codex:review`.
- Challenge design or implementation assumptions with `/codex:adversarial-review`.
- Investigate bugs, build failures, or risky design areas with `/codex:rescue`.
- Run in the background for long review or investigation work.
- Return findings for Claude or the human owner to curate into branch docs.
- Avoid being the default write-enabled implementation worker unless explicitly delegated and monitored.

### Human Owner
- Start Codex reviews intentionally rather than relying on hidden automatic hooks.
- Read and accept or reject review findings.
- Decide whether Codex rescue output should be applied, ignored, or turned into a handoff packet.
- Keep review gate automation disabled until the workflow and cost profile are understood.

---

## Setup

### Prerequisites

- Node.js 18.18+ and npm in PATH
- OpenAI account with API key or ChatGPT subscription
- Claude Code CLI installed and authenticated

Install Codex CLI manually if needed:
```bash
npm install -g @openai/codex
```

Authenticate Codex inside Claude Code:
```
!codex login
```

### Install the Codex plugin

```
/plugin marketplace add openai/codex-plugin-cc
/plugin install codex@openai-codex
/reload-plugins
/codex:setup
```

### Disable the review gate immediately

The plugin's automatic review gate uses a Stop hook and can create expensive Claude/Codex loops. Keep it off until the workflow is stable:

```
/codex:setup --disable-review-gate
```

Enable it only after validating the review signal and cost profile over several real branches.

### Optional: Warp terminal

Run Claude Code inside [Warp](https://warp.dev) for visual status badges on background Codex jobs and system notifications when they complete. Warp detects Claude Code automatically — no additional configuration.

---

## Plugin Commands

| Command | Use for | Stance |
|---|---|---|
| `/codex:setup` | Verify plugin, Codex install, and auth | Setup only |
| `/codex:review` | Normal review of uncommitted changes or branch diff | Read-only |
| `/codex:adversarial-review` | Challenge design choices, hidden assumptions, risk areas | Read-only |
| `/codex:rescue` | Background investigation or bounded delegated task | Potentially write-capable — monitor carefully |
| `/codex:status` | Check running and recent Codex jobs | Read-only |
| `/codex:result` | Read final Codex output | Read-only |
| `/codex:cancel` | Stop active background Codex work | Control only |

Prefer `--background` for multi-file reviews and investigations. Use `--base <ref>` when reviewing a whole branch:

```
/codex:review --base main --background
/codex:adversarial-review --base main --background challenge whether this implementation is too broad and whether rollback/manual verification is sufficient.
```

---

## Role Assignment

| Task | Agent | How to invoke |
|---|---|---|
| Branch setup & docs | **Claude** | `"Read branch README and init missing docs"` |
| Architecture & design | **Claude** | `"Write design doc to docs/branches/{branch}/design/X.md"` |
| Design challenge | **Codex** | `/codex:adversarial-review --background <focus>` |
| Handoff packet | **Claude** | `"Write handoff packet to plans/next-agent-handoff.md"` |
| Implementation | **Claude** | `"Read plans/next-agent-handoff.md and implement"` |
| Code review | **Codex** | `/codex:review --background` |
| High-risk review | **Codex** | `/codex:adversarial-review --base main --background <focus>` |
| Bug investigation | **Codex** | `/codex:rescue --background investigate why X is failing` |
| Final diff before PR | **Codex** | `/codex:review --base main --background` |

---

## Directory Layout

```
docs/
├── workflow/                          ← Project-wide workflow docs (this file)
└── branches/{branch}/
    ├── README.md                      ← Reading order and current conclusions (Claude owns)
    ├── spec/
    │   └── technical-spec.md          ← Accepted requirements and behavior contract
    ├── design/                        ← Architecture and implementation direction
    ├── plans/
    │   ├── next-agent-handoff.md      ← Task packet for implementation (Claude writes)
    │   ├── design-review.md           ← Design review findings (Codex writes, Claude curates)
    │   └── code-review.md             ← Code review findings before PR (Codex writes, Claude curates)
    ├── status/
    │   ├── implementation-status.md   ← Done / partial / blocked / verified (Claude writes)
    │   └── code-map.md                ← Files touched and why (Claude writes)
    └── research/                      ← Reference material

.claude/
├── settings.json                      ← Hook configuration (Level 3 guardrails)
├── hooks/
│   └── post-write-review.sh           ← Experimental; prefer explicit /codex:* commands
├── agents/
│   ├── design-reviewer.md             ← Claude-native design reviewer (Codex plugin fallback)
│   ├── code-reviewer.md               ← Claude-native code reviewer (Codex plugin fallback)
│   └── branch-implementer.md          ← Write-enabled implementation worker
└── commands/
    ├── review-with-codex.md           ← Deterministic prompt: run Codex review + curate findings
    └── prepare-handoff.md             ← Deterministic prompt: build handoff packet from branch docs

.agent-work/                           ← Raw agent logs, temporary outputs, scratch files (gitignored)
.agents/
└── skills/                            ← Codex repo skills (after workflow stabilizes)
```

---

## Shared Instruction Files

| File | Purpose |
|---|---|
| `AGENTS.md` | Canonical repo instructions — read by Codex and all Claude agents |
| `CLAUDE.md` | Claude Code entrypoint (`@AGENTS.md`) |
| `REVIEW.md` | Review-only rules: Unreal conventions, API contracts, test requirements |

Recommended root `CLAUDE.md`:

```md
@AGENTS.md
```

Review-specific guidance that would be noisy during implementation sessions belongs in `REVIEW.md`, not `CLAUDE.md`.

---

## Automation Levels

### Level 1 — Explicit Plugin Commands (Start Here)

Use explicit commands only. No automation. Human controls when Codex runs.

After design docs are drafted:
```
/codex:adversarial-review --background challenge the current branch design docs for missing requirements, unsafe assumptions, rollout risk, unclear ownership, and unclear implementation scope.
```

Check results and curate into `plans/design-review.md`:
```
/codex:status
/codex:result
```

After implementation:
```
/codex:review --background
```

For high-risk architecture or integration work:
```
/codex:adversarial-review --base main --background look for scope creep, Unreal lifetime/threading risks, missing verification, rollback risk, and design assumptions that should be revisited.
```

This level keeps control visible and avoids surprise loops.

### Level 2 — Claude Command Files and Subagents

Once the review prompts are proven useful, encode them as Claude command files and subagents.

**`.claude/commands/review-with-codex.md`** — run after implementation:
```md
Run /codex:review --background.
When /codex:result is ready, read the findings.
Curate accepted findings into docs/branches/{branch}/plans/code-review.md.
Mark each finding as accepted or rejected with a brief reason.
Report a summary of critical and major findings to the user.
```

**`.claude/commands/prepare-handoff.md`** — run before asking Claude to implement:
```md
Read docs/branches/{branch}/README.md, spec/technical-spec.md, and the relevant design docs.
Read plans/design-review.md if it exists.
Write a bounded handoff packet to plans/next-agent-handoff.md using the standard template.
Include: exact task, required reading, allowed write scope, do-not-modify list, constraints, verification steps, and Codex review gate reminder.
```

Invoke with:
```
/review-with-codex
/prepare-handoff
```

### Level 3 — Guardrail Hooks

Hooks should enforce discipline, not hide the workflow.

**Good hook uses:**
- Blocking Claude from stopping when required status docs were not updated after code changes
- Reminding the user to run `/codex:review --background` after implementation
- Logging raw agent output to `.agent-work/`

**Risky hook uses to avoid:**
- Running review on every `Write` event
- Enabling the Codex plugin review gate without understanding the cost
- Starting write-enabled agents automatically after document edits
- Hooks that commit, push, delete files, or rewrite branch docs without explicit user intent

The existing `.claude/hooks/post-write-review.sh` should be treated as experimental. Prefer explicit `/codex:*` commands over per-write hooks.

### Level 4 — CI and PR Automation

Use CI as the authoritative shared gate, not local hooks.

1. Keep the existing UE review bot workflows.
2. Add a root `REVIEW.md` before enabling any new LLM reviewer.
3. Enable Codex automatic PR reviews in Codex GitHub settings if desired.
4. Add Claude Code GitHub Action in manual mode first (`@claude` comment trigger).
5. Keep all LLM review jobs **non-blocking** until false-positive rate and cost are understood.
6. Convert a review output to a blocking gate only when it produces deterministic output (severity counts, JSON).

---

## Handoff Packet

Claude writes `docs/branches/{branch}/plans/next-agent-handoff.md` before implementation. Use the `/prepare-handoff` command (Level 2) or write it manually.

```md
## Task

Implement <specific behavior> from spec/technical-spec.md.

## Read First

- docs/branches/{branch}/README.md
- docs/branches/{branch}/spec/technical-spec.md
- docs/branches/{branch}/design/<design-doc>.md
- docs/branches/{branch}/plans/design-review.md
- Relevant source paths:
  - <path>

## Allowed Write Scope

- <path-or-module>
- docs/branches/{branch}/status/implementation-status.md
- docs/branches/{branch}/status/code-map.md

## Do Not Modify

- <path-or-module>

## Constraints

- Do not refactor unrelated systems.
- Keep public contracts backward-compatible unless the spec explicitly says otherwise.
- Source-code comments must follow the repo language policy in AGENTS.md.
- Do not apply Codex rescue output unless explicitly accepted by the human owner.

## Required Verification

- Run `<targeted command>` if available.
- If a manual test is required, write exact steps and expected result.

## Codex Review Gate

- Run `/codex:review --background` after implementation.
- Run `/codex:adversarial-review --background <focus>` for high-risk architecture or integration work.
- Curate accepted findings into plans/code-review.md.

## Output

- Summary of code changes.
- Verification evidence.
- Updated status docs.
- Accepted or rejected Codex findings.
- Open risks or follow-up items.
```

---

## Day-to-Day Workflow

All steps run inside a single Claude Code session.

```
Developer (one Claude Code session)
   │
   ▼
[Phase 1] Branch prep (Claude)
   "Read branch README and update branch docs."
   Claude writes/updates spec/, design/, README.md
   │
   ▼
[Phase 2] Design challenge (Codex via plugin)
   /codex:adversarial-review --background <focus>
   → /codex:status  →  /codex:result
   → Claude curates findings into plans/design-review.md
   │
   ▼
[Developer reviews findings — iterate if needed, then approve]
   │
   ▼
[Phase 3] Handoff packet (Claude)
   /prepare-handoff   (or write manually)
   → plans/next-agent-handoff.md created
   │
   ▼
[Phase 4] Implementation (Claude)
   "Read plans/next-agent-handoff.md and implement."
   → Code written within allowed scope
   → status/implementation-status.md, status/code-map.md updated
   │
   ▼
[Phase 5] Code review (Codex via plugin)
   /codex:review --background
   (or /review-with-codex command)
   → /codex:status  →  /codex:result
   → Claude curates accepted findings into plans/code-review.md
   │
   ▼
[Developer resolves critical findings, then opens PR]
   │
   ▼
[Phase 6] PR (CI + existing UE review bot)
```

---

## Claude Subagent Definitions

Place under `.claude/agents/`. Used as Codex plugin fallback or for parallel sub-tasks.

**`.claude/agents/branch-implementer.md`**
```md
---
name: branch-implementer
description: Implements a bounded task from docs/branches/{branch}/plans/next-agent-handoff.md and updates branch status docs.
tools: Read, Glob, Grep, Bash, Edit, Write
model: sonnet
permissionMode: acceptEdits
---

You implement only the task described in the handoff packet.
Respect the allowed write scope. Do not modify anything listed under Do Not Modify.
Update status/implementation-status.md and status/code-map.md after source code changes.
If the implementation invalidates the spec or design, stop and report the mismatch instead of silently changing the contract.
After implementation, ask the main Claude session to run /codex:review --background.
```

**`.claude/agents/design-reviewer.md`**
```md
---
name: design-reviewer
description: Reviews branch specs and design docs for missing requirements, contradictions, unsafe assumptions, and unclear handoff scope. Fallback when Codex plugin is unavailable.
tools: Read, Glob, Grep, Bash
model: sonnet
permissionMode: plan
---

You are a design reviewer for this repository.
Read the branch README first and treat the branch doc root as the source of truth.
Do not edit source code.
Report findings with severity (critical / major / minor), evidence, and a concrete fix recommendation.
Write durable findings to docs/branches/{branch}/plans/design-review.md.
Mark resolved findings as resolved — do not delete them.
If an independent second opinion is needed, recommend running /codex:adversarial-review --background.
```

**`.claude/agents/code-reviewer.md`**
```md
---
name: code-reviewer
description: Reviews code changes for correctness, regressions, API contract breaks, threading/lifetime risks, Unreal conventions, and missing verification. Fallback when Codex plugin is unavailable.
tools: Read, Glob, Grep, Bash
model: sonnet
permissionMode: plan
---

You are a code reviewer for this repository.
Prioritize: bugs, regressions, data loss, threading/lifetime risks, API contract breaks, missing verification.
Do not request stylistic churn unless it hides a real defect.
Ground every finding in file paths and line numbers.
Write findings to docs/branches/{branch}/plans/code-review.md.
For final second-opinion review, recommend /codex:review --background or /codex:adversarial-review --background <focus>.
```

---

## Codex Rescue Examples

Use `/codex:rescue` for bounded investigation — not as a default implementation worker.

```
/codex:rescue --background investigate why the targeted build started failing and report the smallest likely fix.

/codex:rescue --background compare the current design against the existing UGC publish/load flow and identify hidden integration risks.

/codex:rescue --model gpt-5.4-mini --effort medium investigate the flaky test and report evidence only.
```

Treat rescue output as input to branch docs. Do not blindly apply rescue changes — the human owner or Claude coordinator must accept the patch.

---

## Codex Skill Candidates

Create repo-specific Codex skills under `.agents/skills/` after the workflow stabilizes.

| Skill | Trigger | Behavior |
|---|---|---|
| `branch-docs` | Starting or resuming branch work | Resolve branch doc root, read README, initialize missing docs |
| `design-author` | Writing architecture or specs | Update `spec/` or `design/`, then update README conclusions |
| `implementation-handoff` | Before asking Claude to implement | Produce a bounded handoff packet with allowed write scope |

---

## Recommended Rollout

1. Install `codex-plugin-cc`, run `/codex:setup`, then immediately run `/codex:setup --disable-review-gate`.
2. Add root `CLAUDE.md` pointing to `AGENTS.md`.
3. Add root `REVIEW.md` with project-specific review criteria.
4. **Level 1:** Use explicit `/codex:adversarial-review --background` and `/codex:review --background` on one or two branches. Validate output quality.
5. Commit `.claude/agents/` subagent definitions.
6. **Level 2:** Add `.claude/commands/review-with-codex.md` and `prepare-handoff.md` once the prompts are proven.
7. **Level 3:** Add guardrail hooks (status-doc reminder, scope enforcement) only after Level 2 is stable.
8. **Level 4:** Add PR-level automation in non-blocking mode.
9. Promote proven Codex workflows into `.agents/skills/`.

---

## Token Cost Considerations

Each Codex invocation consumes both Claude Code and OpenAI tokens.

| Risk | Mitigation |
|---|---|
| Review gate creates unexpected loops | Keep disabled with `--disable-review-gate` until stable |
| Background jobs pile up | Run `/codex:status` before starting a new job |
| Adversarial review on small changes | Use on design docs and high-risk branches only |
| Rescue output applied without review | Human owner must explicitly accept before Claude applies |

---

## Troubleshooting

**`/codex:setup` fails:**
```bash
node --version   # need 18.18+
npm --version
echo $OPENAI_API_KEY
codex --version
```

**`/codex:rescue` returns empty or errors:**
- Run `/codex:status` — a previous job may still be running
- Run `/codex:cancel` to clear a stuck job before starting a new one

**Review quality is poor:**
- Sharpen the focus: add a specific concern to the command (`--background look for X`)
- Try a stronger model: `/codex:rescue --model gpt-5.4-mini --effort high`

**Write hook not firing (experimental):**
```bash
ls -la .claude/hooks/post-write-review.sh
echo '{"tool_input":{"file_path":"/absolute/path/to/design/feature-x.md"}}' \
  | bash .claude/hooks/post-write-review.sh
```

---

## File Reference

| File | Purpose |
|---|---|
| `AGENTS.md` | Canonical repo rules for all agents |
| `CLAUDE.md` | Claude entrypoint (`@AGENTS.md`) |
| `REVIEW.md` | Review-specific rules |
| `.claude/settings.json` | Hook wiring (Level 3 guardrails) |
| `.claude/hooks/post-write-review.sh` | Experimental Write hook |
| `.claude/agents/branch-implementer.md` | Implementation worker subagent |
| `.claude/agents/design-reviewer.md` | Claude-native design reviewer (fallback) |
| `.claude/agents/code-reviewer.md` | Claude-native code reviewer (fallback) |
| `.claude/commands/review-with-codex.md` | Codex review + curation command |
| `.claude/commands/prepare-handoff.md` | Handoff packet builder command |
| `.agent-work/` | Raw agent logs and scratch files (gitignored) |
| `docs/workflow/multi-agent-setup.md` | This document |
| `docs/branches/{branch}/plans/next-agent-handoff.md` | Task packet |
| `docs/branches/{branch}/plans/design-review.md` | Design review findings |
| `docs/branches/{branch}/plans/code-review.md` | Code review findings |
