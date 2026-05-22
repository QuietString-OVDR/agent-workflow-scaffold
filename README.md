# Multi-Agent Setup Starter

This package installs a Claude Code + OpenAI Codex plugin workflow into a repository.

The intended operating model is:

- **Claude Code** is the single local work console.
- **Codex** is called from inside Claude Code through `openai/codex-plugin-cc`.
- Codex drafts design/spec/handoff material, runs adversarial design reviews, reviews code, and performs bounded investigations.
- Claude and the human owner curate Codex output before it becomes canonical.
- Branch docs under `docs/branches/<branch-doc-dir>/` are the source of truth.

The canonical workflow reference lives at `docs/workflow/` (project-wide, single copy). Branch doc directories do not contain their own copy of the workflow document.

## Included Files

- `AGENTS.md`
  - Minimal starter guidance for a fresh repository.
- `AGENTS.multi-agent.md`
  - Guidance block to append to an existing `AGENTS.md`.
- `CLAUDE.md`
  - Claude Code entrypoint that points at `AGENTS.md`.
- `REVIEW.md`
  - Review criteria for local and PR review agents.
- `.codex/config.toml`
  - Example project-scoped Codex profiles.
- `.agent-work/`
  - Working-area skeleton for generated outputs, logs, and scratch files.
- `.claude/settings.json`
  - PostToolUse and Stop hooks for automatic change tracking and review reminders.
- `.claude/hooks/`
  - `track-changes.sh`: logs source file edits to `.agent-work/session-changes.log` and sets a pending-review flag.
  - `notify-pending-review.sh`: surfaces a Codex review reminder when Claude is about to stop, if source files were changed.
- `.claude/agents/`
  - Claude project subagents for implementation, design review, and code review.
- `.claude/commands/`
  - Claude command prompts for handoff preparation and Codex review.
- `docs/branches/_template/`
  - Starter branch documentation tree, including the multi-agent workflow docs.
- `tools/agent/init-branch-docs.sh`
  - Script that detects the current branch and initializes `docs/branches/<branch-doc-dir>/`.
- `install-to-repo.sh`
  - Bash installer for Linux, macOS, and WSL.
- `install-to-repo.bat`
  - Windows batch installer.

## Install

From this package directory:

```bash
bash install-to-repo.sh /path/to/target-repo
```

On Windows:

```bat
install-to-repo.bat C:\path\to\target-repo
```

The installer:

1. Creates `.codex/config.toml` if it does not exist.
2. Copies `.agent-work/`, `.claude/`, `docs/branches/_template/`, and `tools/agent/init-branch-docs.sh`.
3. Creates `AGENTS.md` if missing, or appends `AGENTS.multi-agent.md` if `AGENTS.md` already exists.
4. Creates `CLAUDE.md` and `REVIEW.md` if they do not exist.
5. Appends `.agent-work/` ignore rules to `.gitignore` if missing.

Existing files are not overwritten.

## First-Time Setup In A Target Repo

1. Install the starter package.
2. Open the target repo in Claude Code.
3. Install the Codex plugin inside Claude Code:

```text
/plugin marketplace add openai/codex-plugin-cc
/plugin install codex@openai-codex
/reload-plugins
/codex:setup
```

4. Keep the Codex plugin review gate disabled at first:

```text
/codex:setup --disable-review-gate
```

5. From the target repository root, initialize branch docs:

```bash
bash ./tools/agent/init-branch-docs.sh
```

Run this from the real repository root or from a submodule where resolving the superproject root is intended. Do not test it from a temporary directory nested inside another unrelated Git repo.

If branch docs already exist and you only want missing template files:

```bash
bash ./tools/agent/init-branch-docs.sh --sync-missing
```

## Automation Scope

The hooks in `.claude/settings.json` handle two things automatically:

- **PostToolUse (Edit/Write)**: every source file change is appended to `.agent-work/session-changes.log` and a `.agent-work/pending-codex-review` flag is created. Doc paths (`docs/`, `.agent-work/`, `.claude/`, `.codex/`) are excluded.
- **Stop**: when Claude finishes a response while the pending-review flag exists, a reminder is surfaced listing how many changes were logged and the exact command to run.

Claude cannot invoke `/codex:*` commands autonomously — those are plugin commands, not shell commands. The hooks create a signal; you or Claude act on it.

To clear the flag after review is done:

```bash
rm .agent-work/pending-codex-review
```

## Day-To-Day Usage

Run all local agent work inside one Claude Code session.

1. Prepare design/spec draft with Codex if useful:

```text
/codex:rescue --background Draft the technical spec and design for <feature>. Use AGENTS.md and the current branch docs. Write proposed content for docs/branches/<branch-doc-dir>/spec/technical-spec.md and docs/branches/<branch-doc-dir>/design/<design-doc>.md. Do not modify source code.
```

2. Check Codex output and curate accepted content:

```text
/codex:status
/codex:result
```

3. Challenge non-trivial designs:

```text
/codex:adversarial-review --background challenge the current branch design docs for missing requirements, unsafe assumptions, rollout risk, unclear ownership, and unclear implementation scope.
```

4. Write or update `plans/next-agent-handoff.md`.

5. Have Claude implement from the handoff packet. The `branch-implementer` subagent will ask Claude to run Codex review after implementation completes. The Stop hook will also surface a reminder if source files were changed.

6. Run Codex code review:

```text
/codex:review --base main --background
```

7. Curate accepted findings into `plans/code-review.md`. Clear the pending-review flag:

```bash
rm .agent-work/pending-codex-review
```

8. Run build/test/manual verification and open the PR.

## Branch Directory Rule

Use the full branch name as the documentation key. Replace `/` with `~` for the folder name:

| Branch | Branch doc directory |
| --- | --- |
| `master` | `docs/branches/master/` |
| `sandbox/ovdr-4397` | `docs/branches/sandbox~ovdr-4397/` |
| `feature/foo/bar` | `docs/branches/feature~foo~bar/` |

## Safety Notes

- The installed hooks only log changes and surface reminders — they do not invoke Codex automatically. All `/codex:*` commands are explicit.
- Keep the Codex plugin review gate disabled until review quality, runtime, and cost are understood.
- Treat `/codex:rescue` output as advisory unless a human owner or Claude coordinator curates it into branch docs.
- Keep generated logs, raw outputs, and scratch files under `.agent-work/`.
- Keep `.codex/` for Codex settings/config only.
