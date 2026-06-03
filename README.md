# Branch Docs Starter

This package applies a branch-scoped documentation workflow to a repository.

Core rules:

- Canonical branch docs live under `docs/branches/<branch-doc-dir>/`
- The current branch name is the documentation key; replace `/` with `~` for the folder name
- Generated artifacts, scratch files, downloads, logs, and temporary outputs live under `./.agent-work/`
- `./.codex/` is reserved for project-scoped Codex configuration files
- Branch docs and agent replies must always be written in English
- Before code lookup, agents must read the branch README and `status/code-map.md` and use the code map as the first search index

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
  - Ignore rules for `.agent-work/` plus branch-docs/tool exceptions for repositories with blanket-ignore policies
- `docs/branches/_template/`
  - Starter template for new branch doc roots
- `tools/agent/init-branch-docs.sh`
  - Script that detects the current branch and initializes `docs/branches/<branch-doc-dir>/`
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
2. Copies `.agent-work` skeleton files, `docs/branches/_template/`, and `tools/agent/init-branch-docs.sh`
3. Creates `AGENTS.md` from `AGENTS.branch-docs.md` if it does not exist
4. Appends the `AGENTS.branch-docs.md` block if `AGENTS.md` already exists
5. Appends branch-docs and `.agent-work/` ignore rules to `.gitignore` if they are missing

## Manual Install

1. Copy `.codex/config.toml` into the target repo's `.codex/`
2. Copy `.agent-work/.gitignore`, `.agent-work/README.md`, `docs/branches/_template/`, and `tools/agent/init-branch-docs.sh`
3. If the target repo has no `AGENTS.md`, create one with a `# Repository Guidelines` header and the contents of `AGENTS.branch-docs.md`
4. If the target repo already has `AGENTS.md`, append the block from `AGENTS.branch-docs.md`
5. Add the branch-docs and `.agent-work/` ignore block to `.gitignore`

## Usage

1. Create or check out a branch such as `sandbox/ovdr-4397`, `feature/new-login`, or `ovdr-4397-some-work`
2. Run:

```bash
bash ./tools/agent/init-branch-docs.sh
```

3. If the branch doc root already exists and you only want to add missing template files, run:

```bash
bash ./tools/agent/init-branch-docs.sh --sync-missing
```

4. Before source investigation or code edits, read the branch README and `status/code-map.md`. Use `Search First` entries before any broad content search.

## Notes

- The package uses the full branch name as the documentation key; it does not try to derive a separate work identifier
- This package's own `AGENTS.md` is local-only and is not installed into target repositories
- Only `.agent-work` skeleton files are installed; local scratch subdirectories are not copied into target repositories
- Branch doc directories are Windows-safe. For example, `sandbox/ovdr-4397` becomes `docs/branches/sandbox~ovdr-4397/`
- `init-branch-docs.sh` can infer the branch from worktrees whose `.git` file points at a Windows-style gitdir such as `Q:/...`
- The package does not overwrite existing branch docs
- Execution bits are not guaranteed in this environment, so prefer `bash <script>`
- `_template/` is a starter only and is never a canonical branch doc root
