# Branch Docs

This directory is the compatibility root for branch documentation in the repository.

Canonical work documentation for Jira-backed work lives under `../work/<WORK-KEY>/`.
Branch paths under this directory may be Windows junctions to those work roots.

Structure:

- `_template/`
  - Starter template used to create a new branch doc root
- `<branch-doc-dir>/`
  - Compatibility path for a branch
  - For Jira-backed work this may point to `../work/<WORK-KEY>/`
  - Current architecture lives in `architecture/current-architecture.md`
  - Teammate-facing documents live in `share/<doc-type>/`, such as `share/guides/` and `share/specs/`, and must be written in Korean

Workflow:

1. At session start, check the top-level or super project Git state. If HEAD is detached or the exact branch is `master`, work in lightweight mode without creating or updating branch/work docs by default.
2. For documented work, create or check out a branch such as `sandbox/ovdr-4397`, `feature/new-login`, `ovdr-4397-some-work`, or a build-test branch such as `ovdr-11678-shader-bb`.
3. In native Windows PowerShell, run `powershell -ExecutionPolicy Bypass -File ./docs/init-branch-docs.ps1`.
4. If the user explicitly requests docs on detached HEAD or `master`, pass `-AllowNonWorkRef`; detached HEAD also requires an explicit `-BranchName`. The Bash fallback uses `--allow-non-work-ref`.
5. If the branch contains a single Jira key such as `sandbox/ovdr-12401`, the script creates `docs/work/OVDR-12401/` and a compatibility junction under `docs/branches/`.
6. If the user provides parent context, pass it explicitly, for example `-ParentWorkKey OVDR-12368 -IssueUrl https://overdare.atlassian.net/browse/OVDR-12401`.
7. The script strips a trailing build-test suffix such as `-b` or `-bb` for branch doc compatibility paths, then replaces `/` with `~` for a Windows-safe folder name.
8. When branch documentation is enabled, before code lookup, read the work README and `status/code-map.md`; use the code map as the first search index.
9. When code changes on a branch with branch documentation enabled, update `status/implementation-status.md` and `status/code-map.md` together.
10. When a decision affects future work, update `status/decisions.md`; if it affects sibling tasks or rollout, update the parent work root too.
11. Before creating a new plan, read `plans/README.md` and update `plans/active.md` or an existing topic plan unless the work is a distinct new workstream.
12. Move implemented, superseded, or parked plans under `archive/plans/` or summarize them there so stale plans do not stay equally visible.

Notes:

- Only the starter-owned `docs/branches/`, `docs/index/`, `docs/work/`, and initializer files are personal local agent setup and intentionally ignored by Git.
- Other repository-owned product documentation under `docs/` remains tracked and branch-specific.
- In an Orca linked worktree, `docs/` stays physical and only the three starter-owned directories are junctions to the primary checkout.
- The Orca Archive Script must run `unbootstrap-worktree.ps1` before worktree deletion; direct `git worktree remove` is unsafe while those Windows junctions exist.
- The lightweight-mode choice is based on the session-start ref and remains in effect until the user explicitly asks to use branch/work documentation.
- Native Windows PowerShell is the primary supported environment for creating Jira work docs and branch compatibility junctions.
- `_template/` is never a canonical document source
- `archive/`, `research/`, and `backup/` are not the source of truth unless the branch README explicitly says otherwise
- Branch docs in this tree should always be written in English, except for `share/` documents
- `share/` documents must be written in Korean
- Legacy ticket-scoped docs should be migrated into a branch doc root instead of kept in a separate canonical tree
- Older branch roots may still contain `design/`; new branch roots use `architecture/`
