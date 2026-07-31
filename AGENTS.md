# Repository Guidelines

## Purpose
- This repository is the branch-docs starter package and the canonical source for repository-specific agent profiles.
- The common starter and repository profiles have separate ownership boundaries: the common installers own the shared branch-docs setup, while `tools/repo-agent-config.ps1` owns only marked repository-profile blocks in root `AGENTS.md`.
- Do not treat this repository as a normal branch-docs-enabled work repository.
- Do not create or maintain branch documentation under `./docs/branches/<branch-doc-dir>/` for this starter package unless the user explicitly asks.

## Language Policy
- Always write agent replies, plans, handoff notes, and durable repository notes in English.
- If the user writes in Korean or another language, interpret the request but still respond and document in English unless the user explicitly asks to override this policy.

## Working Files
- Always create and use `./.agent-work/` for generated artifacts, scratch files, downloads, logs, installer smoke-test targets, and temporary outputs.
- Do not leave temporary files elsewhere unless explicitly requested.

## Starter Package Files
- `AGENTS.md` is local guidance for agents working in this starter package.
- `AGENTS.branch-docs.md` is the branch-docs guidance block installed into target repositories.
- `CLAUDE.branch-docs.md` is the Claude Code adapter block installed into target repositories. It imports `AGENTS.md` and must carry only Claude-specific differences; shared policy belongs in `AGENTS.branch-docs.md`.
- `install-to-repo.bat` and `install-to-repo.sh` must stay behaviorally aligned. They currently produce byte-identical output for the create, upsert, and append paths, and the smoke tests assert that.
- `profiles/` contains the canonical repository-specific `AGENTS.md` blocks. Shared policy that must be byte-identical across profiles belongs under `profiles/shared/`.
- `config/repo-agent-profiles.json` defines eligible repositories, identity sentinels, discovery rules, block order, and source files.
- `tools/repo-agent-config.ps1` plans, verifies, or applies repository profiles after the common scaffold exists. It must not invoke or emulate the common installers.
- `tests/repo-agent-config/smoke.ps1` owns disposable profile-tool fixtures, including bare Git containers and linked worktrees.
- `docs/branches/_template/` is target-repo template material, not canonical documentation for this starter package.
- `docs/init-branch-docs.sh` is installed into target repositories and should remain portable across native Windows Git Bash, WSL, and Linux where practical. The old `tools/agent/init-branch-docs.sh` location is removed by both installers.

## Change Discipline
- When changing installer behavior, update both installer scripts and `README.md` in the same turn.
- When changing target-repo branch-doc guidance, update `AGENTS.branch-docs.md` and any README/manual install instructions that describe it.
- When shared guidance changes in a way that Claude Code sessions must also honor, check whether `CLAUDE.branch-docs.md` needs a matching change. Do not duplicate shared policy there; it is inherited through the `@AGENTS.md` import.
- When changing marked-block handling, encoding, or line-ending behavior, update the marker block contract in `README.md` and both installers' help text in the same turn.
- Keep repository-profile changes inside their marked blocks. Preserve the common `branch-docs-starter` block, `CLAUDE.md`, `.gitignore`, and other common-install outputs byte-for-byte.
- Profile application must remain fail-closed: verify the exact Git root, normalized origin, tracked sentinel, ignored local setup, valid markers, and eligible direct clone or linked worktree before writing.
- Keep `Plan` and `Verify` target-read-only. Keep `Apply` explicitly authorized, lock-protected, backed up, atomic, and rollback-capable.
- Never treat a bare Git container as an `AGENTS.md` target. Enumerate and validate its registered working trees instead.
- Keep `client-app` excluded from discovery and bulk profile operations.
- Verify installer changes with the smoke suite in `./.agent-work/orca-claude-support-plan-20260721/`. `smoke-cross.ps1` runs the batch suite, the shell suite, and the byte-identical cross-installer comparison. Do not claim the two installers agree without running it.
- Verify repository-profile changes with `tests/repo-agent-config/smoke.ps1`.
- Keep generated helpers, logs, scratch outputs, and temporary artifacts under `./.agent-work/`.
- Treat `backup/` as read-only reference material unless the user explicitly requests edits there.
