#!/usr/bin/env bash

set -euo pipefail

print_usage() {
	cat <<'EOF'
Usage:
  bash install-to-repo.sh /path/to/target-repo

Behavior:
  - Copy project-scoped Codex config if missing
  - Copy .agent-work skeleton files and local-only branch docs files under docs/
  - Update managed branch-docs starter files without overwriting local work roots
  - Update managed agent helper tools under tools/agent/
  - Fail if the target repository already tracks files under docs/
  - Create AGENTS.md from AGENTS.branch-docs.md if missing
  - Append or replace the marked AGENTS.branch-docs.md block if AGENTS.md already exists
  - Append or replace .gitignore rules for local-only starter files and .agent-work/
  - Remove the old tools/agent/init-branch-docs.sh helper if present
EOF
}

upsert_marked_block() {
	local begin_marker="$1"
	local end_marker="$2"
	local source_file="$3"
	local target_file="$4"
	local tmp_file

	if [[ ! -f "$target_file" ]]; then
		cp "$source_file" "$target_file"
		return 2
	fi

	if grep -Fxq "$begin_marker" "$target_file"; then
		tmp_file="$(mktemp "$upsert_temp_dir/branch-docs-upsert.XXXXXX")"
		if ! awk -v begin="$begin_marker" -v end="$end_marker" -v block_file="$source_file" '
			BEGIN {
				while ((getline line < block_file) > 0) {
					block = block line ORS
				}
				close(block_file)
				in_block = 0
				replaced = 0
			}
			$0 == begin {
				if (!replaced) {
					printf "%s", block
					replaced = 1
				}
				in_block = 1
				next
			}
			in_block && $0 == end {
				in_block = 0
				next
			}
			!in_block {
				print
			}
			END {
				if (!replaced || in_block) {
					exit 3
				}
			}
		' "$target_file" > "$tmp_file"; then
			rm -f "$tmp_file"
			return 3
		fi
		mv "$tmp_file" "$target_file"
		return 0
	fi

	if [[ -s "$target_file" ]] && [[ "$(tail -c 1 "$target_file")" != $'\n' ]]; then
		printf '\n' >> "$target_file"
	fi

	printf '\n' >> "$target_file"
	cat "$source_file" >> "$target_file"
	return 1
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
	done < <(find "$source_dir" \( -path "$target_dir" -o -path "$target_dir/*" \) -prune -o -type f -print | sort)
}

copy_file_if_missing() {
	local source_file="$1"
	local target_file="$2"

	if [[ -e "$target_file" ]]; then
		return 0
	fi

	mkdir -p "$(dirname "$target_file")"
	cp "$source_file" "$target_file"
}

copy_file_overwrite() {
	local source_file="$1"
	local target_file="$2"

	mkdir -p "$(dirname "$target_file")"
	cp "$source_file" "$target_file"
}

copy_tree_overwrite() {
	local source_dir="$1"
	local target_dir="$2"
	local source_file
	local relative_path
	local target_file

	while IFS= read -r source_file; do
		relative_path="${source_file#"$source_dir"/}"
		target_file="$target_dir/$relative_path"
		copy_file_overwrite "$source_file" "$target_file"
	done < <(find "$source_dir" -type f -print | sort)
}

sync_managed_docs() {
	local package_root="$1"
	local target_repo="$2"

	copy_file_overwrite "$package_root/docs/init-branch-docs.sh" "$target_repo/docs/init-branch-docs.sh"
	copy_file_overwrite "$package_root/docs/init-branch-docs.ps1" "$target_repo/docs/init-branch-docs.ps1"
	copy_file_overwrite "$package_root/docs/branches/README.md" "$target_repo/docs/branches/README.md"
	copy_file_overwrite "$package_root/docs/index/README.md" "$target_repo/docs/index/README.md"
	copy_file_if_missing "$package_root" "$target_repo" "$package_root/docs/index/branch-bindings.json"
	copy_file_if_missing "$package_root" "$target_repo" "$package_root/docs/index/work-items.json"
	copy_file_overwrite "$package_root/docs/work/README.md" "$target_repo/docs/work/README.md"
	copy_tree_overwrite "$package_root/docs/branches/_template" "$target_repo/docs/branches/_template"
}

sync_managed_tools() {
	local package_root="$1"
	local target_repo="$2"

	copy_file_overwrite "$package_root/tools/agent/audit-source-comment-policy.ps1" "$target_repo/tools/agent/audit-source-comment-policy.ps1"
}

fail_if_docs_tracked() {
	local target_repo="$1"
	local tracked_docs

	tracked_docs="$(git -C "$target_repo" ls-files -- docs 2>/dev/null | head -n 1 || true)"
	if [[ -n "$tracked_docs" ]]; then
		printf 'Refusing to install branch-docs-starter because target repo tracks files under docs/: %s\n' "$tracked_docs" >&2
		printf 'This starter is intended for internal project repos where docs/ is local-only agent workspace.\n' >&2
		exit 1
	fi
}

main() {
	local package_root
	local target_repo
	local agents_marker="<!-- branch-docs-starter:begin -->"
	local agents_end_marker="<!-- branch-docs-starter:end -->"
	local gitignore_marker="# branch-docs-starter:begin"
	local gitignore_end_marker="# branch-docs-starter:end"
	local upsert_result

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

	fail_if_docs_tracked "$target_repo"

	mkdir -p \
		"$target_repo/.codex" \
		"$target_repo/.agent-work" \
		"$target_repo/docs"

	copy_file_if_missing "$package_root/.agent-work/.gitignore" "$target_repo/.agent-work/.gitignore"
	copy_file_if_missing "$package_root/.agent-work/README.md" "$target_repo/.agent-work/README.md"
	copy_tree_if_missing "$package_root/docs" "$target_repo/docs"
	sync_managed_docs "$package_root" "$target_repo"

	if [[ -f "$target_repo/tools/agent/init-branch-docs.sh" ]]; then
		rm -f "$target_repo/tools/agent/init-branch-docs.sh"
		printf 'Removed old tools/agent/init-branch-docs.sh from %s\n' "$target_repo"
		rmdir "$target_repo/tools/agent" 2>/dev/null || true
		rmdir "$target_repo/tools" 2>/dev/null || true
	fi
	sync_managed_tools "$package_root" "$target_repo"

	if [[ ! -f "$target_repo/.codex/config.toml" ]]; then
		cp "$package_root/.codex/config.toml" "$target_repo/.codex/config.toml"
		printf 'Created .codex/config.toml in %s\n' "$target_repo"
	else
		printf 'Skipped existing %s/.codex/config.toml\n' "$target_repo"
	fi

	if [[ ! -f "$target_repo/AGENTS.md" ]]; then
		{
			printf '# Repository Guidelines\n\n'
			cat "$package_root/AGENTS.branch-docs.md"
		} > "$target_repo/AGENTS.md"
		printf 'Created AGENTS.md in %s\n' "$target_repo"
	else
		upsert_temp_dir="$target_repo/.agent-work"
		set +e
		upsert_marked_block "$agents_marker" "$agents_end_marker" "$package_root/AGENTS.branch-docs.md" "$target_repo/AGENTS.md"
		upsert_result=$?
		set -e
		if [[ "$upsert_result" -eq 0 ]]; then
			printf 'Updated branch docs guidance in %s/AGENTS.md\n' "$target_repo"
		elif [[ "$upsert_result" -eq 1 ]]; then
			printf 'Merged branch docs guidance into %s/AGENTS.md\n' "$target_repo"
		else
			printf 'Unable to update branch docs guidance in %s/AGENTS.md\n' "$target_repo" >&2
			exit 1
		fi
	fi

	upsert_temp_dir="$target_repo/.agent-work"
	set +e
	upsert_marked_block "$gitignore_marker" "$gitignore_end_marker" "$package_root/.agent-work.gitignore.block" "$target_repo/.gitignore"
	upsert_result=$?
	set -e
	if [[ "$upsert_result" -eq 0 ]]; then
		printf 'Updated branch-docs ignore block in %s/.gitignore\n' "$target_repo"
	elif [[ "$upsert_result" -eq 1 ]]; then
		printf 'Appended branch-docs ignore block to %s/.gitignore\n' "$target_repo"
	elif [[ "$upsert_result" -eq 2 ]]; then
		printf 'Created branch-docs ignore block in %s/.gitignore\n' "$target_repo"
	else
		printf 'Unable to update branch-docs ignore block in %s/.gitignore\n' "$target_repo" >&2
		exit 1
	fi

	printf 'Starter package installed into %s\n' "$target_repo"
}

main "$@"
