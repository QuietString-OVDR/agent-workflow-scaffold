# Claude Code Instructions

`AGENTS.md` is the canonical instruction file for this starter package and is shared with other agents. Claude Code does not read it natively, so it is imported here.

@AGENTS.md

Everything above applies to Claude Code sessions. Note in particular the Language Policy: reply, plan, and document in English even when the request is written in Korean.

## Shell selection

Sessions run on native Windows. Use the PowerShell tool by default and keep Windows paths in native form.

Claude Code's Bash tool is **Git Bash, not WSL** — `/mnt/c/...` does not exist there. Use it for the POSIX installer path (`install-to-repo.sh`, `docs/init-branch-docs.sh`) and for portability checks. Those scripts are expected to work across native Windows Git Bash, WSL, and Linux, so verifying under Git Bash covers only one of the three; do not report WSL or Linux behavior as verified from a Git Bash run alone.

## Change discipline reminder

`install-to-repo.bat` and `install-to-repo.sh` must stay behaviorally aligned. When either changes, update both plus `README.md` in the same turn — this is the rule most easily missed when editing only the shell script from a Bash-tool session. The two installers currently produce byte-identical output; verify that with the smoke tests rather than assuming it.

This package ships two blocks for target repositories: `AGENTS.branch-docs.md` for agents that read `AGENTS.md`, and `CLAUDE.branch-docs.md` for Claude Code, which does not read `AGENTS.md` natively. `CLAUDE.branch-docs.md` imports `AGENTS.md` with `@AGENTS.md` and must contain only the Claude-specific differences. Do not copy shared policy into it.

Keep generated artifacts, smoke-test targets, and scratch output under `./.agent-work/`.
