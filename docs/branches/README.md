# Branch Docs

This directory is the canonical root for branch documentation in the repository.

Structure:

- `_template/`
  - Starter template used to create a new branch doc root
- `<branch-doc-dir>/`
  - The actual canonical doc root for a branch
  - Current architecture lives in `architecture/current-architecture.md`
  - Teammate-facing documents live in `share/<doc-type>/`, such as `share/guides/` and `share/specs/`

Workflow:

1. Create or check out a branch such as `sandbox/ovdr-4397`, `feature/new-login`, or `ovdr-4397-some-work`
2. Run `bash ./docs/init-branch-docs.sh` to create `docs/branches/<branch-doc-dir>/`
3. The script uses the full branch name and replaces `/` with `~` for a Windows-safe folder name
4. Before code lookup, read the branch README and `status/code-map.md`; use the code map as the first search index
5. When code changes on a branch, update `status/implementation-status.md` and `status/code-map.md` together
6. When a decision affects future work, update `status/decisions.md`
7. Before creating a new plan, read `plans/README.md` and update `plans/active.md` or an existing topic plan unless the work is a distinct new workstream
8. Move implemented, superseded, or parked plans under `archive/plans/` or summarize them there so stale plans do not stay equally visible

Notes:

- This `docs/` tree is personal local agent setup in target work repositories and is intentionally ignored by Git.
- `_template/` is never a canonical document source
- `archive/`, `research/`, and `backup/` are not the source of truth unless the branch README explicitly says otherwise
- Branch docs in this tree should always be written in English
- `share/` documents may use the audience's requested language when the user explicitly asks for a shareable non-English document
- Legacy ticket-scoped docs should be migrated into a branch doc root instead of kept in a separate canonical tree
- Older branch roots may still contain `design/`; new branch roots use `architecture/`
