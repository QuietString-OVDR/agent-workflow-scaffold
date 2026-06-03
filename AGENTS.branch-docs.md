<!-- branch-docs-starter:begin -->
## Language Policy
- Always write branch docs, specs, plans, handoff notes, research notes, and agent replies in English.
- If the user writes in Korean or another language, interpret the request but still respond and document in English unless the user explicitly asks to override this policy.

## Working Files
- Always create and use `./.agent-work/` for generated artifacts, scratch files, downloads, logs, and temporary outputs.
- Do not leave temporary files elsewhere unless explicitly requested.
- Treat `./.codex/` as Codex settings/config only. Do not use it for high-churn work products such as branch docs, generated outputs, downloads, logs, or temporary artifacts.

## Branch Documentation Workflow
- The canonical work identifier is the current branch name unless the user explicitly names another branch.
- Use the full branch name as the documentation key. Do not try to derive a separate work identifier.
- Map the branch to `./docs/branches/<branch-doc-dir>/`.
- When working inside a nested repo or submodule, resolve the super project root first and infer the branch from there.
- When deriving `<branch-doc-dir>`, replace `/` with `~` so branch docs remain Windows-safe. For example, `sandbox/ovdr-4397` maps to `docs/branches/sandbox~ovdr-4397/`.
- If `./docs/branches/<branch-doc-dir>/README.md` exists, read it first and treat it as the canonical documentation entrypoint for the branch.
- If the branch doc root does not exist, initialize it from `./docs/branches/_template/` or by running `bash ./tools/agent/init-branch-docs.sh`.
- For code changes on a branch, update `status/implementation-status.md` and `status/code-map.md` in the same turn unless the user explicitly says not to.
- For architecture, technical spec, rollout plan, or handoff requests, write the result into the branch doc root under `spec/`, `design/`, or `plans/` instead of leaving the result only in chat.
- Treat `backup/` as read-only reference material unless the user explicitly requests edits there.
- Treat `archive/` and `research/` as non-canonical unless the branch README says otherwise.
- Keep generated helpers, logs, scratch outputs, and temporary artifacts under `./.agent-work/`.

## Branch Documentation Git Policy
- `docs/branches/**` is local-only agent working context and is intentionally ignored by Git.
- Do not force-add branch docs unless the user explicitly asks.
- Do not change `.gitignore` to make branch docs trackable unless the user explicitly asks.
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
