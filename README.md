# Branch Docs Starter

This package applies a branch-scoped documentation workflow to a repository.

Core rules:

- Jira-backed work docs live under `docs/work/<WORK-KEY>/`, where the work key is a normalized Jira key such as `OVDR-12401`
- Branch compatibility paths live under `docs/branches/<branch-doc-dir>/`
- Branch names may include prefixes such as `sandbox/` or `client/`; the initializer scans the full branch path for a Jira key
- The branch compatibility folder name is the branch name after stripping a trailing build-test suffix such as `-b`, `-bb`, or `-bbb`; replace `/` with `~` for the folder name
- Sessions that start with detached HEAD or on the exact `master` branch use lightweight mode by default and do not create or update branch/work docs unless the user explicitly requests documentation
- Repository-owned tracked product documentation under `docs/**` remains branch-specific
- Local-only starter paths are limited to `docs/branches/**`, `docs/index/**`, `docs/work/**`, and the two initializer files
- The installers fail only when a repository tracks one of those reserved paths; tracked product docs elsewhere are supported
- Generated artifacts, scratch files, downloads, logs, and temporary outputs live under `./.agent-work/`
- Agent replies and internal branch docs must be written in English
- Share docs under `share/` must be written in Korean
- Before code lookup, agents must read the branch README and `status/code-map.md` and use the code map as the first search index
- Jira parent/child context is cached under `docs/index/work-items.json`
- Current architecture lives in `architecture/current-architecture.md`; agents update that file instead of creating additional architecture drafts by default
- Teammate-facing or externally shareable documents live under `share/<doc-type>/`, such as `share/guides/` and `share/specs/`
- Implementation plans are lifecycle-managed through `plans/README.md`, `plans/active.md`, and `archive/plans/`

## Included Files

- `AGENTS.md`
  - Local guidance for agents working in this starter package
- `AGENTS.branch-docs.md`
  - Branch-docs guidance block used to create or update target repository `AGENTS.md` files
- `CLAUDE.branch-docs.md`
  - Claude Code adapter block used to create or update target repository `CLAUDE.md` files; it imports `AGENTS.md` with `@AGENTS.md` and only adds the parts where Claude Code's tooling differs
- `.agent-work/.gitignore` and `.agent-work/README.md`
  - Working-area skeleton files for generated outputs
- `.agent-work.gitignore.block`
  - Ignore rules that keep target-repo starter files local-only while preserving `.agent-work/` skeleton behavior
- `docs/init-branch-docs.sh`
  - Legacy Bash initializer for branch-name-only docs; skips detached HEAD and `master` by default
- `docs/init-branch-docs.ps1`
  - Primary Windows PowerShell initializer that detects Jira work keys, updates local indexes, and creates branch compatibility junctions; skips detached HEAD and `master` by default
- `docs/branches/_template/`
  - Starter template for new branch doc roots
- `docs/index/`
  - Local branch binding and Jira work item index templates
- `docs/work/`
  - Canonical Jira work document roots
- `install-to-repo.sh`
  - Helper script that installs the starter into a target repository
- `install-to-repo.bat`
  - Windows batch helper that installs the starter into a target repository
- `assert-install-policy.ps1`
  - Read-only Windows preflight used by the batch installer to protect compatible tracked policy files
- `bootstrap-worktree.ps1`
  - Native Windows entrypoint for initializing a primary anchor and projecting the reserved branch-doc paths into same-clone linked worktrees
- `unbootstrap-worktree.ps1`
  - Native Windows archive entrypoint that removes only verified child-worktree junction leaves before Orca or Git deletes the worktree
- `migrate-orca-worktree-layout.ps1`
  - Dry-run-by-default helper for explicitly approved tracked instruction or ignore-policy migrations

## Recommended Install

```bash
bash install-to-repo.sh /path/to/target-repo
```

```bat
install-to-repo.bat C:\path\to\target-repo
```

The install script:

1. Copies `.agent-work` skeleton files and the local-only branch-docs setup under `docs/`
2. Updates managed starter files such as initializers, README files, and templates without overwriting local work roots or local index JSON
3. Fails before writing if the target tracks a reserved branch-doc path
4. Preserves tracked `AGENTS.md`, `CLAUDE.md`, and `.gitignore` byte-for-byte after verifying exact compatibility; incompatible tracked policy files fail before any write and must use the explicit migration script
5. Creates `AGENTS.md` from `AGENTS.branch-docs.md` if it does not exist
6. Appends or replaces the marked `AGENTS.branch-docs.md` block only when `AGENTS.md` is untracked
7. Creates `CLAUDE.md` from `CLAUDE.branch-docs.md` if it does not exist
8. Appends or replaces the marked `CLAUDE.branch-docs.md` block only when `CLAUDE.md` is untracked
9. Appends or replaces local-only starter and `.agent-work/` ignore rules only when `.gitignore` is untracked
10. Removes the old `tools/agent/init-branch-docs.sh` helper if present

Both installers require `git` on `PATH`. The install aborts when `git` is missing, when the
tracked-path query fails, when `git rev-parse` fails for any reason other than "not a git
repository", when the target resolves to something that is not a working tree, or when the
target is a linked worktree. Run full installation only from the main worktree. Only a
positively identified non-repository is skipped with a warning so the install can continue.

### Marker block contract

Both installers manage `AGENTS.md`, `CLAUDE.md`, and `.gitignore` through the same marked
block mechanism. For the create, replace, and append paths they produce byte-identical
output, and the smoke tests assert that.

- Markers are matched as exact whole lines, tolerating a trailing CR. A marker mentioned
  mid-line, for example inside a sentence, is not a block boundary, and neither is a marker
  line with trailing spaces or tabs.
- A marker line followed by other text is not a boundary either, so a malformed block fails
  closed instead of being spliced.
- A target containing more than one begin marker is rejected. Duplicate managed regions are
  not supported.
- Only the marked block is rewritten. Text outside the markers is preserved, except for line
  terminators, which are normalized as described below.
- If the target file already uses CRLF, the whole file is written as CRLF. Otherwise LF is
  used. The managed block is converted to match the target either way, so the source
  checkout's line endings do not leak into the target.
- Target files must be UTF-8 without a BOM. A UTF-8, UTF-16LE or UTF-16BE byte order mark in
  the target aborts the install rather than being silently stripped or corrupted.
- A managed target must be a regular file. A symlink, reparse point, or directory in place of
  `AGENTS.md`, `CLAUDE.md`, or `.gitignore` aborts the install instead of being replaced or
  written through.
- Every managed file is written by building the new content in a temporary file under the
  target repository's `./.agent-work/` and then renaming it into place, so an interrupted run
  can leave a stray temporary file but never a partial managed file.
- Re-running an installer replaces the block in place, so repeated installs are idempotent.

Marked-block helper exit codes, shared by both installers: `0` replaced in place, `2` target
created from the block, `3` malformed markers, `4` I/O failure or unsupported target, `5`
appended to an existing file. Any other code is treated as a failure.

## Orca Linked Worktrees

The native Windows worktree layout keeps each checkout's `docs/` directory physical. Only
these reserved subpaths are shared:

- `docs/branches/`
- `docs/index/`
- `docs/work/`

The primary checkout stores those directories physically. A same-clone linked worktree has
exact-target NTFS junctions at those three paths. Product docs outside the reserved paths,
the initializer scripts, `.agent-work/`, and local agent configuration remain per-worktree.

Initialize the primary checkout first. Quote both paths when they contain spaces:

```powershell
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File "T:\OneDrive - KRAFTON\Work\agent-setup\branch-docs-starter\bootstrap-worktree.ps1" `
  -TargetRepo "Q:\path\to\primary" `
  -AnchorRepo "Q:\path\to\primary"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
```

Use the same command as the first command in the Orca project's local-only Setup Script,
with `-TargetRepo "%ORCA_WORKTREE_PATH%"` and the explicit primary checkout as
`-AnchorRepo`. Keep `Run by default` enabled and wait for setup to finish before starting an
agent.

For `client-app`, compose the existing dependency setup exactly once and only after a
successful bootstrap:

```powershell
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File "T:\OneDrive - KRAFTON\Work\agent-setup\branch-docs-starter\bootstrap-worktree.ps1" `
  -TargetRepo "%ORCA_WORKTREE_PATH%" `
  -AnchorRepo "Q:\workspace\client-app"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

npm install
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
```

Do not keep a second standalone `npm install` action after adding this combined Setup
Script. For other repositories, preserve each existing setup command once, in its original
order, after the bootstrap gate.

Configure the Orca project's local-only Archive Script as well:

```powershell
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File "T:\OneDrive - KRAFTON\Work\agent-setup\branch-docs-starter\unbootstrap-worktree.ps1" `
  -TargetRepo "%ORCA_WORKTREE_PATH%" `
  -AnchorRepo "Q:\path\to\primary"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# Keep each pre-existing archive command exactly once below this line.
```

The archive command verifies the manifest, common Git directory, physical `docs/` root, and
all three exact junction targets before removing the junction leaves. It never removes the
canonical target directories. If a previous archive attempt stopped after removing only
one or two junctions, running the same Archive Script again safely removes the verified
remainder. On Windows, do not run `git worktree remove` while these
junctions are present: Git can traverse the junctions and remove canonical shared content.
Use Orca's archive-enabled removal path; when using the CLI, pass `orca worktree rm
--run-hooks ...`. If the archive hook did not complete successfully, stop and inspect the
worktree instead of forcing removal.

The bootstrap fails closed when:

- target and anchor do not share the same Git common directory
- the anchor is itself a linked worktree
- any current or known ref tracks a reserved path, including a Windows case-fold collision
- tracked `AGENTS.md` lacks the compatibility block
- tracked instruction files differ from the index
- `.gitignore` contains duplicate starter markers or blanket `/docs/` or `/.codex/`
- `docs/` is a reparse point, a reserved child path is physical, or a junction has the wrong target

Use `migrate-orca-worktree-layout.ps1` for explicit tracked-policy preparation. It is a
zero-write dry run unless `-Apply` is present, backs up every changed policy file, and
requires `-AllowTrackedPolicyChanges` before changing a tracked file. Its ignore
normalization collapses duplicate valid starter blocks and removes exact legacy `/docs/`,
`docs/`, `/.codex/`, and `.codex/` blanket lines, then verifies the result before success.

After a reviewed `.gitignore` migration is committed in an already enrolled anchor, approve
the new tracked ignore fingerprint with the exact reviewed HEAD and a new backup directory:

```powershell
$reviewedHead = git -C "Q:\path\to\primary" rev-parse HEAD
& "T:\OneDrive - KRAFTON\Work\agent-setup\branch-docs-starter\bootstrap-worktree.ps1" `
  -TargetRepo "Q:\path\to\primary" `
  -AnchorRepo "Q:\path\to\primary" `
  -ApproveCurrentIgnorePolicy `
  -ExpectedHeadOid $reviewedHead `
  -ApprovalBackupRoot "Q:\safe-backups\branch-docs-ignore-approval-20260724"
```

This is the only normal path that adds a new fingerprint to the manifest. It revalidates
the anchor under the lifecycle lock and backs up the prior manifest before changing it.

Once a checkout is enrolled, do not use direct `git pull`, rebase, cherry-pick sequences, or
unverified branch/tag/SHA transitions. Fetch first, verify the candidate, and transition to
the returned full commit OID:

```powershell
.\bootstrap-worktree.ps1 -TargetRepo Q:\path\to\worktree `
  -AnchorRepo Q:\path\to\primary -VerifyOnly -CandidateRef origin/feature

git -C Q:\path\to\worktree merge --ff-only <verified-full-oid>

.\bootstrap-worktree.ps1 -TargetRepo Q:\path\to\worktree `
  -AnchorRepo Q:\path\to\primary -VerifyOnly -ExpectedHeadOid <verified-full-oid>
```

Run the native-Windows regression suites with disposable fixture roots under `.agent-work`:

```powershell
.\tests\orca-worktree-bootstrap.Tests.ps1 `
  -FixtureRoot Q:\scratch\.agent-work\branch-docs-starter-tests\orca-worktree-bootstrap

.\tests\installer-layout.Tests.ps1 `
  -FixtureRoot Q:\scratch\.agent-work\branch-docs-starter-tests\installer-layout
```

## Manual Install

1. Confirm no tracked path collides with `docs/branches`, `docs/index`, `docs/work`, or the two initializer paths
2. Copy `.agent-work/.gitignore`, `.agent-work/README.md`, and `docs/`
3. Before touching `AGENTS.md`, `CLAUDE.md`, or `.gitignore`, check whether Git tracks it
4. Preserve a compatible tracked policy file byte-for-byte; for an incompatible tracked file, stop and use `migrate-orca-worktree-layout.ps1` with dry-run, backup, and explicit tracked-policy authorization
5. If the target repo has no `AGENTS.md`, create one with a `# Repository Guidelines` header and the contents of `AGENTS.branch-docs.md`
6. For an existing untracked `AGENTS.md`, replace the marked `branch-docs-starter` block or append it if missing
7. If the target repo has no `CLAUDE.md`, create one with a `# Claude Code Instructions` header and the contents of `CLAUDE.branch-docs.md`
8. For an existing untracked `CLAUDE.md`, replace the marked `branch-docs-starter` block or append it if missing
9. For an untracked `.gitignore`, replace the marked `branch-docs-starter` block or append it if missing
10. Remove `tools/agent/init-branch-docs.sh` from the target repo if it was installed by an older starter version

## Usage

1. At session start, check the top-level or super project Git state. If HEAD is detached or the exact branch is `master`, work without branch/work docs by default and use `./.agent-work/` for disposable notes or evidence.
2. For documented work, create or check out a work branch such as `sandbox/ovdr-4397`, `feature/new-login`, `ovdr-4397-some-work`, or a build-test branch such as `ovdr-11678-shader-bb`.
3. In native Windows PowerShell, run:

```powershell
powershell -ExecutionPolicy Bypass -File ./docs/init-branch-docs.ps1
```

4. When the user provides Jira context, pass it explicitly:

```powershell
powershell -ExecutionPolicy Bypass -File ./docs/init-branch-docs.ps1 `
  -WorkKey OVDR-12385 `
  -ParentWorkKey OVDR-12368 `
  -IssueUrl https://overdare.atlassian.net/browse/OVDR-12385 `
  -ParentIssueUrl https://overdare.atlassian.net/browse/OVDR-12368
```

5. If the branch contains exactly one Jira key, such as `sandbox/ovdr-12401`, the initializer resolves `OVDR-12401` automatically.
6. If the branch doc root already exists and you only want to add missing template files, run:

```powershell
powershell -ExecutionPolicy Bypass -File ./docs/init-branch-docs.ps1 -SyncMissing
```

7. If the user explicitly requests branch/work documentation while HEAD is detached or the current/requested branch is `master`, use `-AllowNonWorkRef`. Detached HEAD also requires an explicit `-BranchName`:

```powershell
powershell -ExecutionPolicy Bypass -File ./docs/init-branch-docs.ps1 `
  -AllowNonWorkRef `
  -BranchName investigation/manual-docs
```

The Bash fallback uses `--allow-non-work-ref`.

8. When branch documentation is enabled, before source investigation or code edits, read the work README and `status/code-map.md`. Use `Search First` entries before any broad content search.
9. Before creating a new plan, read `plans/README.md` and update `plans/active.md` or an existing topic plan unless the work is a distinct new workstream.

## Branch Doc Structure

New Jira-backed work roots use this shape:

- `status/`
  - Current progress, accepted decisions, implementation log, and code lookup map
- `spec/`
  - Canonical technical contracts and requirements
- `architecture/`
  - Current implementation structure; default canonical file is `current-architecture.md`
- `plans/`
  - Active implementation planning and next-agent handoff only
- `share/`
  - Polished teammate-facing documents grouped by document type, such as `guides/` and `specs/`; these documents must be written in Korean
- `research/`
  - Investigation notes and reference material
- `archive/`
  - Superseded, implemented, or parked documents, including old plans under `archive/plans/`
- `backup/`
  - User-kept safe copies; read-only unless explicitly requested

The initializer also updates:

- `docs/index/branch-bindings.json`
  - Maps raw branches such as `sandbox/ovdr-12401` to `OVDR-12401`
- `docs/index/work-items.json`
  - Caches Jira parent/child context supplied by the user or local tooling

## Notes

- The package uses Jira keys as canonical work identifiers when a key is provided or can be parsed from the branch name
- Detached HEAD and exact `master` sessions are lightweight by default: agents do not initialize, sync, or update `docs/work/**`, `docs/branches/**`, or their indexes unless the user explicitly opts into documentation
- Branch-name-only docs remain available as a legacy fallback when no Jira key is available
- This package's own `AGENTS.md` and `CLAUDE.md` are local-only and are not installed into target repositories
- Generated `AGENTS.md` and `CLAUDE.md` are local-only only when the repository does not already track them; tracked instruction files are repository-owned
- Only the reserved branch-doc paths under `docs/` are local-only; other product documentation remains tracked
- Claude Code does not read `AGENTS.md` natively, so the installed `CLAUDE.md` imports it with `@AGENTS.md` and carries only the Claude-specific differences; shared policy stays in `AGENTS.branch-docs.md` and must not be duplicated
- The managed ignore block deliberately contains no blanket `/docs/`, `/.codex/`, or `/.claude/` rule. Only exact starter-owned paths are ignored so tracked product docs and repository-owned configuration remain visible
- Re-running an installer overwrites the managed starter files: both initializers, `docs/branches/README.md`, `docs/index/README.md`, `docs/work/README.md`, and the whole `docs/branches/_template/` tree. Local edits to those files are lost
- The starter does not create, copy, ignore, or modify `.codex/config.toml`; repository-owned tracked Codex configuration, including working-tree changes, is byte-preserved while tracked/untracked ownership transitions remain protected by candidate-ref checks
- Only `.agent-work` skeleton files are installed; local scratch subdirectories are not copied into target repositories
- Repositories may track product documentation under `docs/` as long as none of the reserved branch-doc paths is tracked
- Branch doc directories are Windows-safe. For example, `sandbox/ovdr-4397` becomes `docs/branches/sandbox~ovdr-4397/`, and `sandbox/qa-5001-collab-block-b` becomes `docs/branches/sandbox~qa-5001-collab-block/`
- `init-branch-docs.sh` can infer the branch from worktrees whose `.git` file points at a Windows-style gitdir such as `Q:/...`
- The package does not overwrite existing branch docs
- The installer updates managed starter files such as initializers, README files, and templates, but it does not overwrite local `docs/work/<WORK-KEY>/` or `docs/branches/<branch-doc-dir>/` work roots
- Native Windows PowerShell is the primary supported initializer environment; use the Bash script only as a legacy fallback
- `_template/` is a starter only and is never a canonical branch doc root
- Older branch roots may still contain `design/`; new roots use `architecture/` instead, and agents should migrate current-system content into `architecture/current-architecture.md` when practical
