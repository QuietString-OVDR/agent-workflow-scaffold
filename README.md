# Branch Docs Starter

This package applies a branch-scoped documentation workflow to a repository.

Core rules:

- Canonical branch docs live under `docs/branches/<branch-doc-dir>/`
- The current branch name is the documentation key; replace `/` with `~` for the folder name
- In target work repositories, branch-docs-starter-installed files are personal local setup and should stay ignored by Git
- Generated artifacts, scratch files, downloads, logs, and temporary outputs live under `./.agent-work/`
- `./.codex/` is reserved for project-scoped Codex configuration files
- Agent replies and internal branch docs must be written in English
- Share docs under `share/` must be written in Korean
- Before code lookup, agents must read the branch README and `status/code-map.md` and use the code map as the first search index
- Current architecture lives in `architecture/current-architecture.md`; agents update that file instead of creating additional architecture drafts by default
- Teammate-facing or externally shareable documents live under `share/<doc-type>/`, such as `share/guides/` and `share/specs/`
- Implementation plans are lifecycle-managed through `plans/README.md`, `plans/active.md`, and `archive/plans/`

This layout reflects the OpenAI Codex guidance for `workspace-write` sandboxes, where `.codex/` is treated as a protected path.

## Included Files

- `AGENTS.md`
  - Local guidance for agents working in this starter package
- `AGENTS.branch-docs.md`
  - Branch-docs guidance block used to create or update target repository `AGENTS.md` files
- `.codex/config.toml`
  - Example project-scoped Codex profiles
- `.agent-work/.gitignore` and `.agent-work/README.md`
  - Working-area skeleton files for generated outputs
- `.agent-work.gitignore.block`
  - Ignore rules that keep target-repo starter files local-only while preserving `.agent-work/` skeleton behavior
- `docs/init-branch-docs.sh`
  - Script that detects the current branch and initializes `docs/branches/<branch-doc-dir>/`
- `docs/branches/_template/`
  - Starter template for new branch doc roots
- `install-to-repo.sh`
  - Helper script that installs the starter into a target repository
- `install-to-repo.bat`
  - Windows batch helper that installs the starter into a target repository

## Recommended Install

```bash
bash install-to-repo.sh /path/to/target-repo
```

```bat
install-to-repo.bat C:\path\to\target-repo
```

The install script:

1. Creates `.codex/config.toml` if it does not exist
2. Copies `.agent-work` skeleton files and the local-only branch-docs setup under `docs/`
3. Creates `AGENTS.md` from `AGENTS.branch-docs.md` if it does not exist
4. Appends or replaces the marked `AGENTS.branch-docs.md` block if `AGENTS.md` already exists
5. Appends or replaces local-only starter and `.agent-work/` ignore rules in `.gitignore`
6. Removes the old `tools/agent/init-branch-docs.sh` helper if present

## Manual Install

1. Copy `.codex/config.toml` into the target repo's `.codex/`
2. Copy `.agent-work/.gitignore`, `.agent-work/README.md`, and `docs/`
3. If the target repo has no `AGENTS.md`, create one with a `# Repository Guidelines` header and the contents of `AGENTS.branch-docs.md`
4. If the target repo already has `AGENTS.md`, replace the existing marked `branch-docs-starter` block or append it if missing
5. Replace the existing marked `branch-docs-starter` `.gitignore` block or append it if missing
6. Remove `tools/agent/init-branch-docs.sh` from the target repo if it was installed by an older starter version

## Usage

1. Create or check out a branch such as `sandbox/ovdr-4397`, `feature/new-login`, or `ovdr-4397-some-work`
2. Run:

```bash
bash ./docs/init-branch-docs.sh
```

3. If the branch doc root already exists and you only want to add missing template files, run:

```bash
bash ./docs/init-branch-docs.sh --sync-missing
```

4. Before source investigation or code edits, read the branch README and `status/code-map.md`. Use `Search First` entries before any broad content search.
5. Before creating a new plan, read `plans/README.md` and update `plans/active.md` or an existing topic plan unless the work is a distinct new workstream.

## Branch Doc Structure

New branch roots use this shape:

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

## Notes

- The package uses the full branch name as the documentation key; it does not try to derive a separate work identifier
- This package's own `AGENTS.md` is local-only and is not installed into target repositories
- The generated target-repo `AGENTS.md`, `.codex/`, and `docs/` setup are intended to remain local-only and ignored by Git
- Only `.agent-work` skeleton files are installed; local scratch subdirectories are not copied into target repositories
- Target repositories with team-owned `docs/` content should adapt the ignore block before install; the default assumes `docs/` is reserved for personal branch-docs-starter files
- Branch doc directories are Windows-safe. For example, `sandbox/ovdr-4397` becomes `docs/branches/sandbox~ovdr-4397/`
- `init-branch-docs.sh` can infer the branch from worktrees whose `.git` file points at a Windows-style gitdir such as `Q:/...`
- The package does not overwrite existing branch docs
- Execution bits are not guaranteed in this environment, so prefer `bash <script>`
- `_template/` is a starter only and is never a canonical branch doc root
- Older branch roots may still contain `design/`; new roots use `architecture/` instead, and agents should migrate current-system content into `architecture/current-architecture.md` when practical
