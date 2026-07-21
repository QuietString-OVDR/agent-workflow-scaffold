<!-- branch-docs-starter:begin -->
## Language Policy
- Always write agent replies and internal branch docs in English, including `README.md`, `status/`, `spec/`, `architecture/`, `plans/`, and `research/`.
- If the user writes in Korean or another language, interpret the request but still respond and document internal branch memory in English unless the user explicitly asks to override this policy.
- Write share docs under `share/` in Korean, including teammate-facing and externally shareable documents.

## Working Files
- Always create and use `./.agent-work/` for generated artifacts, scratch files, downloads, logs, and temporary outputs.
- Do not leave temporary files elsewhere unless explicitly requested.
- Treat `./.codex/` as Codex settings/config only. Do not use it for high-churn work products such as branch docs, generated outputs, downloads, logs, or temporary artifacts.

## Session-Start Documentation Gate
- At the start of each agent session, resolve the top-level or super project Git state before applying the branch documentation workflow.
- If the session starts with detached HEAD or on the exact `master` branch, use lightweight mode by default. In lightweight mode, do not create, initialize, sync, or update `docs/work/**`, `docs/branches/**`, or the branch/work indexes.
- The lightweight-mode choice is based on the session-start Git state. A later checkout does not enable branch docs automatically during the same session.
- Only leave lightweight mode when the user explicitly asks to create, use, sync, or update branch/work documentation. When that happens on detached HEAD or `master`, pass the initializer's explicit non-work-ref override.
- Existing branch docs may be consulted when directly useful, but they are not a required bootstrap in lightweight mode. Use `./.agent-work/` for temporary notes or evidence that do not need durable branch memory.
- This gate disables automatic branch/work memory only. It does not suppress a document or persistent record that the user explicitly requests.

## Branch Documentation Workflow
- Apply this workflow only when lightweight mode is not active or the user has explicitly opted into branch/work documentation for the current task.
- For Jira-backed work, the canonical work identifier is the Jira issue key, normalized to uppercase form such as `OVDR-12401`.
- Branch names are implementation handles. They may include prefixes such as `sandbox/`, `client/`, `feature/`, or other workflow segments.
- At branch start, prefer a user-provided Jira link or work key. If the user provides a child task link and a parent/Epic link, record both.
- If the branch name contains exactly one Jira key anywhere in the path, such as `sandbox/ovdr-12401` or `feature/sandbox/OVDR-12401-mapdlc`, resolve the work key to that Jira key.
- If the branch name contains multiple Jira keys, use an exact `docs/index/branch-bindings.json` entry or ask the user which key is canonical before creating new docs.
- If the branch name ends with a local build-test suffix made of `-` plus one or more lowercase `b` characters, such as `-b`, `-bb`, or `-bbb`, strip that suffix before deriving branch docs. For example, `ovdr-11678-shader-bb` documents under `ovdr-11678-shader`, and `sandbox/qa-5001-collab-block-b` documents under `sandbox/qa-5001-collab-block`.
- Store canonical Jira-backed work docs under `./docs/work/<WORK-KEY>/`.
- Map the branch compatibility path to `./docs/branches/<branch-doc-dir>/`, where `<branch-doc-dir>` is the branch name with `/` replaced by `~`.
- When working inside a nested repo or submodule, resolve the super project root first and infer the branch from there.
- When deriving `<branch-doc-dir>`, replace `/` with `~` so branch docs remain Windows-safe. For example, `sandbox/ovdr-4397` maps to `docs/branches/sandbox~ovdr-4397/`.
- Native Windows PowerShell is the primary supported environment for initializing and migrating branch docs. Prefer `powershell -ExecutionPolicy Bypass -File ./docs/init-branch-docs.ps1`.
- Use `bash ./docs/init-branch-docs.sh` only as a legacy fallback for branch-name-only docs.
- If `./docs/work/<WORK-KEY>/README.md` exists, read it first and treat it as the canonical documentation entrypoint for Jira-backed work.
- If only `./docs/branches/<branch-doc-dir>/README.md` exists, read it as the compatibility entrypoint.
- If the work doc root does not exist, initialize it by running `powershell -ExecutionPolicy Bypass -File ./docs/init-branch-docs.ps1`. Pass `-WorkKey`, `-ParentWorkKey`, `-IssueUrl`, or `-ParentIssueUrl` when the user provides that context.
- Keep `docs/index/branch-bindings.json` and `docs/index/work-items.json` aligned with new branch/work-key mappings. `work-items.json` is the local Jira parent/child context cache, not a replacement for Jira.
- For code changes on a branch with branch documentation enabled, update `status/implementation-status.md` and `status/code-map.md` in the same turn unless the user explicitly says not to.
- For accepted decisions that affect future work, update `status/decisions.md` or the relevant canonical `spec/` section.
- If a child task decision affects sibling tasks, shared rollout, or validation strategy, also update the parent work root.
- For current architecture documentation, update `architecture/current-architecture.md`; do not create additional `architecture/*.md` files unless the branch README explicitly declares them canonical.
- For technical specs, update or create the relevant contract document under `spec/`.
- For implementation plans, read `plans/README.md` first and update `plans/active.md` or an existing topic plan by default. Create a new plan file only for a distinct workstream that is not already covered.
- For handoff requests, update `plans/next-agent-handoff.md`.
- For teammate-facing or externally shareable documents, write under `share/<doc-type>/`, such as `share/guides/` or `share/specs/`, and write the document in Korean. Do not place polished share docs in `spec/`, `architecture/`, or `plans/` unless they are also the canonical branch source.
- For architecture, technical spec, rollout plan, share-doc, or handoff requests, write the result into the branch doc root instead of leaving the result only in chat.
- When a plan is implemented, superseded, or no longer active, update its lifecycle metadata and move or summarize it under `archive/plans/` so stale plans do not remain equally visible.
- Treat `backup/` as read-only reference material unless the user explicitly requests edits there.
- Treat `archive/` and `research/` as non-canonical unless the branch README says otherwise.
- Keep generated helpers, logs, scratch outputs, and temporary artifacts under `./.agent-work/`.

## Branch Documentation Git Policy
- Branch-docs-starter-installed files in target work repositories are personal local agent setup and must not be committed unless the user explicitly asks.
- `AGENTS.md`, `CLAUDE.md`, `.codex/`, local `.claude/` settings, and `docs/**` are intentionally local-only in target work repositories.
- `docs/branches/**` is local-only agent working context and is intentionally ignored by Git.
- `docs/work/**` and `docs/index/**` are local-only agent working context and are intentionally ignored by Git.
- Do not force-add branch-docs-starter files or branch docs unless the user explicitly asks.
- Do not change `.gitignore` to make branch-docs-starter files or branch docs trackable unless the user explicitly asks.
- When branch documentation is enabled, agents should still read and update `docs/branches/<branch-doc-dir>/` as local working memory.
- For Jira-backed work, agents should update the canonical `docs/work/<WORK-KEY>/` root; `docs/branches/<branch-doc-dir>/` should be treated as a compatibility path.
- Do not rely on `git status` to confirm branch-doc updates; verify with filesystem reads instead.

## Code Lookup Bootstrap
- When branch documentation is enabled, before locating code, opening guessed source paths, or running broad `rg`, resolve the current work doc root and read these files if present: `README.md`, `status/code-map.md`, and `status/implementation-status.md`.
- Treat `status/code-map.md` as the first search index, not only as an update log.
- Check the code map's `Search First`, `Symbol / Module Aliases`, and `External Engine / Plugin Dependencies` sections before searching source text.
- In the first working update for code investigation with branch documentation enabled, state which branch code map was read. If the branch code map is missing, state that and initialize or sync branch docs when appropriate.
- Prefer filename, module, plugin, `.Build.cs`, and `.uplugin` lookup before content search.
- Do not run repo-wide content searches until code-map paths, likely module/plugin roots, and filename search have been checked.
- If the likely root is still unclear after two targeted attempts or roughly 60 seconds, ask the user for the expected module/root instead of continuing a full-tree search.
<!-- branch-docs-starter:end -->
