# Repository Guidelines

## Purpose
- This repository is the branch-docs starter package used to install agent setup into target work repositories.
- Do not treat this repository as a normal branch-docs-enabled work repository.
- Do not create or maintain branch documentation under `./docs/branches/<branch-doc-dir>/` for this starter package unless the user explicitly asks.

## Language Policy
- Always write agent replies, plans, handoff notes, and durable repository notes in English.
- If the user writes in Korean or another language, interpret the request but still respond and document in English unless the user explicitly asks to override this policy.

## Working Files
- Always create and use `./.agent-work/` for generated artifacts, scratch files, downloads, logs, installer smoke-test targets, and temporary outputs.
- Do not leave temporary files elsewhere unless explicitly requested.
- Treat `./.codex/` as Codex settings/config only. Do not use it for high-churn work products.

## Starter Package Files
- `AGENTS.md` is local guidance for agents working in this starter package.
- `AGENTS.branch-docs.md` is the branch-docs guidance block installed into target repositories.
- `install-to-repo.bat` and `install-to-repo.sh` must stay behaviorally aligned.
- `docs/branches/_template/` is target-repo template material, not canonical documentation for this starter package.
- `tools/agent/init-branch-docs.sh` is installed into target repositories and should remain portable across native Windows Git Bash, WSL, and Linux where practical.

## Change Discipline
- When changing installer behavior, update both installer scripts and `README.md` in the same turn.
- When changing target-repo branch-doc guidance, update `AGENTS.branch-docs.md` and any README/manual install instructions that describe it.
- Keep generated helpers, logs, scratch outputs, and temporary artifacts under `./.agent-work/`.
- Treat `backup/` as read-only reference material unless the user explicitly requests edits there.
