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

1. Create or check out a branch such as `sandbox/ovdr-4397`, `feature/new-login`, `ovdr-4397-some-work`, or a build-test branch such as `ovdr-11678-shader-bb`
2. In native Windows PowerShell, run `powershell -ExecutionPolicy Bypass -File ./docs/init-branch-docs.ps1`
3. If the branch contains a single Jira key such as `sandbox/ovdr-12401`, the script creates `docs/work/OVDR-12401/` and a compatibility junction under `docs/branches/`
4. If the user provides parent context, pass it explicitly, for example `-ParentWorkKey OVDR-12368 -IssueUrl https://overdare.atlassian.net/browse/OVDR-12401`
5. The script strips a trailing build-test suffix such as `-b` or `-bb` for branch doc compatibility paths, then replaces `/` with `~` for a Windows-safe folder name
6. Before code lookup, read the work README and `status/code-map.md`; use the code map as the first search index
7. During source edits, add Korean explanation comments for meaningful changed logic whose reason or branch context is not obvious from the code alone
8. When code changes on a branch, update `status/implementation-status.md` and `status/code-map.md` together
9. When a decision affects future work, update `status/decisions.md`; if it affects sibling tasks or rollout, update the parent work root too
10. Before creating a new plan, read `plans/README.md` and update `plans/active.md` or an existing topic plan unless the work is a distinct new workstream
11. Move implemented, superseded, or parked plans under `archive/plans/` or summarize them there so stale plans do not stay equally visible

Notes:

- This `docs/` tree is personal local agent setup in target work repositories and is intentionally ignored by Git.
- Native Windows PowerShell is the primary supported environment for creating Jira work docs and branch compatibility junctions.
- `_template/` is never a canonical document source
- `archive/`, `research/`, and `backup/` are not the source of truth unless the branch README explicitly says otherwise
- Branch docs in this tree should always be written in English, except for `share/` documents
- `share/` documents must be written in Korean
- Legacy ticket-scoped docs should be migrated into a branch doc root instead of kept in a separate canonical tree
- Older branch roots may still contain `design/`; new branch roots use `architecture/`
