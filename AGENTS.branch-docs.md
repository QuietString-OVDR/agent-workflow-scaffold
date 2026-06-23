<!-- branch-docs-starter:begin -->
## Language Policy
- Always write agent replies and internal branch docs in English, including `README.md`, `status/`, `spec/`, `architecture/`, `plans/`, and `research/`.
- If the user writes in Korean or another language, interpret the request but still respond and document internal branch memory in English unless the user explicitly asks to override this policy.
- Write share docs under `share/` in Korean, including teammate-facing and externally shareable documents.

## Working Files
- Always create and use `./.agent-work/` for generated artifacts, scratch files, downloads, logs, and temporary outputs.
- Do not leave temporary files elsewhere unless explicitly requested.
- Treat `./.codex/` as Codex settings/config only. Do not use it for high-churn work products such as branch docs, generated outputs, downloads, logs, or temporary artifacts.

## Source Code Comment Policy
- When editing source code, proactively add concise Korean explanation comments near meaningful changed logic, without waiting for a separate user reminder.
- These comments should explain the changed behavior, reason, branch-specific constraint, workaround, or integration point that is not obvious from the code alone.
- Do not add noisy comments that merely restate syntax or obvious assignments; focus on changes future maintainers would otherwise need branch context to understand.

## Branch Documentation Workflow
- The canonical work identifier is the current branch name unless the user explicitly names another branch.
- If the branch name ends with a local build-test suffix made of `-` plus one or more lowercase `b` characters, such as `-b`, `-bb`, or `-bbb`, strip that suffix before deriving branch docs. For example, `ovdr-11678-shader-bb` documents under `ovdr-11678-shader`, and `sandbox/qa-5001-collab-block-b` documents under `sandbox/qa-5001-collab-block`.
- Use the resulting branch name as the documentation key. Do not try to derive any other separate work identifier.
- Map the branch to `./docs/branches/<branch-doc-dir>/`.
- When working inside a nested repo or submodule, resolve the super project root first and infer the branch from there.
- When deriving `<branch-doc-dir>`, replace `/` with `~` so branch docs remain Windows-safe. For example, `sandbox/ovdr-4397` maps to `docs/branches/sandbox~ovdr-4397/`.
- If `./docs/branches/<branch-doc-dir>/README.md` exists, read it first and treat it as the canonical documentation entrypoint for the branch.
- If the branch doc root does not exist, initialize it from `./docs/branches/_template/` or by running `bash ./docs/init-branch-docs.sh`.
- For code changes on a branch, update `status/implementation-status.md` and `status/code-map.md` in the same turn unless the user explicitly says not to.
- For accepted decisions that affect future work, update `status/decisions.md` or the relevant canonical `spec/` section.
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
- `AGENTS.md`, `.codex/`, and `docs/**` are intentionally local-only in target work repositories.
- `docs/branches/**` is local-only agent working context and is intentionally ignored by Git.
- Do not force-add branch-docs-starter files or branch docs unless the user explicitly asks.
- Do not change `.gitignore` to make branch-docs-starter files or branch docs trackable unless the user explicitly asks.
- Agents should still read and update `docs/branches/<branch-doc-dir>/` as local working memory.
- Do not rely on `git status` to confirm branch-doc updates; verify with filesystem reads instead.

## Code Lookup Bootstrap
- Before locating code, opening guessed source paths, or running broad `rg`, resolve the current branch doc root and read these files if present: `README.md`, `status/code-map.md`, and `status/implementation-status.md`.
- Treat `status/code-map.md` as the first search index, not only as an update log.
- Check the code map's `Search First`, `Symbol / Module Aliases`, and `External Engine / Plugin Dependencies` sections before searching source text.
- In the first working update for code investigation, state which branch code map was read. If the branch code map is missing, state that and initialize or sync branch docs when appropriate.
- Prefer filename, module, plugin, `.Build.cs`, and `.uplugin` lookup before content search.
- Do not run repo-wide content searches until code-map paths, likely module/plugin roots, and filename search have been checked.
- If the likely root is still unclear after two targeted attempts or roughly 60 seconds, ask the user for the expected module/root instead of continuing a full-tree search.
<!-- branch-docs-starter:end -->
