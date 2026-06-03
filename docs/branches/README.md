# Branch Docs

This directory is the canonical root for branch documentation in the repository.

Structure:

- `_template/`
  - Starter template used to create a new branch doc root
- `<branch-doc-dir>/`
  - The actual canonical doc root for a branch

Workflow:

1. Create or check out a branch such as `sandbox/ovdr-4397`, `feature/new-login`, or `ovdr-4397-some-work`
2. Run `bash ./tools/agent/init-branch-docs.sh` to create `docs/branches/<branch-doc-dir>/`
3. The script uses the full branch name and replaces `/` with `~` for a Windows-safe folder name
4. Before code lookup, read the branch README and `status/code-map.md`; use the code map as the first search index
5. When code changes on a branch, update `status/implementation-status.md` and `status/code-map.md` together

Notes:

- `_template/` is never a canonical document source
- `archive/`, `research/`, and `backup/` are not the source of truth unless the branch README explicitly says otherwise
- Branch docs in this tree should always be written in English
- Legacy ticket-scoped docs should be migrated into a branch doc root instead of kept in a separate canonical tree
