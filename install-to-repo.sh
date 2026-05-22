#!/usr/bin/env bash

set -euo pipefail

print_usage() {
	cat <<'EOF'
Usage:
  bash install-to-repo.sh /path/to/target-repo

Behavior:
  - Copy project-scoped Codex config if missing
  - Copy .agent-work/, .claude/, docs/branches/_template/, docs/workflow/, and tools/agent/init-branch-docs.sh
  - Create AGENTS.md if missing
  - Append AGENTS.multi-agent.md block if AGENTS.md already exists and the block is not present
  - Create CLAUDE.md and REVIEW.md if missing
  - Append .gitignore rules for .agent-work/ if missing
EOF
}

append_if_missing() {
	local marker="$1"
	local source_file="$2"
	local target_file="$3"

	if grep -Fq "$marker" "$target_file" 2>/dev/null; then
		return 1
	fi

	if [[ -f "$target_file" ]]; then
		printf '\n' >> "$target_file"
	fi

	cat "$source_file" >> "$target_file"
	return 0
}

copy_tree_if_missing() {
	local source_dir="$1"
	local target_dir="$2"
	local source_file
	local relative_path
	local target_file

	while IFS= read -r source_file; do
		relative_path="${source_file#"$source_dir"/}"
		target_file="$target_dir/$relative_path"

		if [[ -e "$target_file" ]]; then
			continue
		fi

		mkdir -p "$(dirname "$target_file")"
		cp "$source_file" "$target_file"
	done < <(find "$source_dir" -type f | sort)
}

main() {
	local package_root
	local target_repo
	local agents_marker="<!-- multi-agent-setup-starter:begin -->"
	local gitignore_marker="# multi-agent-setup-starter:begin"

	if [[ $# -ne 1 ]]; then
		print_usage
		exit 1
	fi

	if [[ "$1" == "-h" || "$1" == "--help" ]]; then
		print_usage
		exit 0
	fi

	package_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	target_repo="$1"

	if [[ ! -d "$target_repo" ]]; then
		printf 'Target repo not found: %s\n' "$target_repo" >&2
		exit 1
	fi

	target_repo="$(cd "$target_repo" && pwd)"

	mkdir -p \
		"$target_repo/.codex" \
		"$target_repo/.agent-work" \
		"$target_repo/.claude" \
		"$target_repo/docs/branches" \
		"$target_repo/docs/workflow" \
		"$target_repo/tools/agent"

	copy_tree_if_missing "$package_root/.agent-work" "$target_repo/.agent-work"
	copy_tree_if_missing "$package_root/.claude" "$target_repo/.claude"
	copy_tree_if_missing "$package_root/docs/branches" "$target_repo/docs/branches"
	copy_tree_if_missing "$package_root/docs/workflow" "$target_repo/docs/workflow"
	copy_tree_if_missing "$package_root/tools/agent" "$target_repo/tools/agent"

	if [[ ! -f "$target_repo/.codex/config.toml" ]]; then
		cp "$package_root/.codex/config.toml" "$target_repo/.codex/config.toml"
		printf 'Created .codex/config.toml in %s\n' "$target_repo"
	else
		printf 'Skipped existing %s/.codex/config.toml\n' "$target_repo"
	fi

	if [[ ! -f "$target_repo/AGENTS.md" ]]; then
		cp "$package_root/AGENTS.md" "$target_repo/AGENTS.md"
		printf 'Created AGENTS.md in %s\n' "$target_repo"
	else
		if append_if_missing "$agents_marker" "$package_root/AGENTS.multi-agent.md" "$target_repo/AGENTS.md"; then
			printf 'Merged multi-agent guidance into %s/AGENTS.md\n' "$target_repo"
		else
			printf 'Skipped existing multi-agent guidance in %s/AGENTS.md\n' "$target_repo"
		fi
	fi

	if [[ ! -f "$target_repo/CLAUDE.md" ]]; then
		cp "$package_root/CLAUDE.md" "$target_repo/CLAUDE.md"
		printf 'Created CLAUDE.md in %s\n' "$target_repo"
	else
		if append_if_missing "$agents_marker" "$package_root/AGENTS.multi-agent.md" "$target_repo/CLAUDE.md"; then
			printf 'Merged multi-agent guidance into %s/CLAUDE.md\n' "$target_repo"
		else
			printf 'Skipped existing multi-agent guidance in %s/CLAUDE.md\n' "$target_repo"
		fi
	fi

	if [[ ! -f "$target_repo/REVIEW.md" ]]; then
		cp "$package_root/REVIEW.md" "$target_repo/REVIEW.md"
		printf 'Created REVIEW.md in %s\n' "$target_repo"
	else
		printf 'Skipped existing %s/REVIEW.md\n' "$target_repo"
	fi

	if append_if_missing "$gitignore_marker" "$package_root/.agent-work.gitignore.block" "$target_repo/.gitignore"; then
		printf 'Appended .agent-work ignore block to %s/.gitignore\n' "$target_repo"
	else
		printf 'Skipped existing .agent-work ignore block in %s/.gitignore\n' "$target_repo"
	fi

	printf 'Starter package installed into %s\n' "$target_repo"
}

main "$@"
