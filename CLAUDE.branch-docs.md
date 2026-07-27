<!-- branch-docs-starter:begin -->
## Claude Code Adapter

`AGENTS.md` is the canonical agent instruction file for this repository and is shared with
other agents. Claude Code does not read it natively, so it is imported here.

@AGENTS.md

Everything above applies to Claude Code sessions unless a rule below overrides it. The
sections below only cover places where Claude Code's tooling differs from the Codex
environment `AGENTS.md` was written for.

## Shell Selection
- Sessions run on native Windows. Use the PowerShell tool by default and keep Windows paths
  such as `Q:\...` and `C:\...` in native form.
- Claude Code's Bash tool is Git Bash, not WSL. `/mnt/c/...` does not exist there. Do not
  translate Windows paths to `/mnt/c/...` for it.
- Initialize branch docs with
  `powershell -ExecutionPolicy Bypass -File ./docs/init-branch-docs.ps1`.
  Use `bash ./docs/init-branch-docs.sh` only as a legacy fallback.

## CLAUDE.md Import Constraints
These apply to `@` import lines only. They do not relax the Windows path handling rule above.

- Use forward slashes. `@C:\path\file.md` fails silently with no error.
- Paths containing spaces do not resolve.
- Imports pointing outside this repository require a one-time approval prompt and do not
  load in headless (`claude -p`) runs.
- Imports resolve at most four levels deep.

## Local-Only Agent Setup
The "Branch Documentation Git Policy" and "Working Files" sections imported above apply
unchanged. Claude Code may be launched without permission prompts, so nothing but those
rules prevents committing local-only agent setup; follow them deliberately rather than
relying on a tool to refuse.

`./.claude/` is Claude Code configuration only. Do not use it for generated outputs,
downloads, logs, or temporary artifacts. Those belong in `./.agent-work/`.
<!-- branch-docs-starter:end -->
