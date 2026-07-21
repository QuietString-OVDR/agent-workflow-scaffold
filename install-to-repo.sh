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
  - Fail if the target repository already tracks files under docs/
  - Create AGENTS.md from AGENTS.branch-docs.md if missing
  - Append or replace the marked AGENTS.branch-docs.md block if AGENTS.md already exists
  - Create CLAUDE.md from CLAUDE.branch-docs.md if missing
  - Append or replace the marked CLAUDE.branch-docs.md block if CLAUDE.md already exists
  - Append or replace .gitignore rules for local-only starter files and .agent-work/
  - Remove the old tools/agent/init-branch-docs.sh helper if present

Marker block contract:
  - Markers are matched as whole lines, tolerating a trailing CR
  - A marker followed by other text on the same line is not a boundary
  - A target that contains more than one begin marker is rejected
  - Only the marked block is rewritten; text outside the markers is left as-is
  - If the target file already uses CRLF, the whole file is written as CRLF;
    otherwise LF is used, and the managed block is converted to match
  - Target files must be UTF-8 without a BOM; a BOM in the target aborts the install
  - A managed target must be a regular file; a symlink or directory aborts the install
  - Managed files are built in a temp file under the target repo's ./.agent-work/ and
    renamed into place, so an interrupted run never leaves a partial managed file
EOF
}

# Detects UTF-8, UTF-16LE and UTF-16BE byte order marks. Compared as hex so the bytes never
# have to survive shell quoting.
file_has_bom() {
	local head_hex
	head_hex="$(head -c 3 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')"

	case "$head_hex" in
		efbbbf*) return 0 ;;
		fffe*) return 0 ;;
		feff*) return 0 ;;
	esac

	return 1
}

# Counts raw CR bytes. Do not use grep, sed or awk to detect CR here: under Git Bash they
# read in text mode and the CR is gone before the pattern ever runs.
file_has_crlf() {
	local cr
	cr="$(tr -dc '\r' < "$1" 2>/dev/null | wc -c | tr -d '[:space:]')"
	[[ "$cr" != "0" ]]
}

# Moves a fully built temp file onto the target with an atomic rename, so an interrupted or
# failed run can never leave a truncated target. mktemp creates mode 0600, so the mode is
# fixed up first: an existing target keeps its own mode, a new one gets the umask default.
# An interrupted run can leave a stray temp file under ./.agent-work/, never a partial target.
# A managed target must be a regular file. A symlink would be replaced by the atomic rename
# instead of written through, and a directory would swallow the temp file, so both are
# refused rather than guessed at.
target_is_unsupported() {
	local target_file="$1"

	if [[ -L "$target_file" ]]; then
		return 0
	fi

	if [[ -e "$target_file" ]] && [[ ! -f "$target_file" ]]; then
		return 0
	fi

	return 1
}

commit_temp_file() {
	local tmp_file="$1"
	local target_file="$2"
	local mode

	if [[ -e "$target_file" ]] && chmod --reference="$target_file" "$tmp_file" 2>/dev/null; then
		:
	else
		mode="$(printf '%o' "$(( 0666 & ~0$(umask) ))")"
		chmod "$mode" "$tmp_file" 2>/dev/null || true
	fi

	mv "$tmp_file" "$target_file"
}

# Creates a target file from a title line and a managed block, transactionally.
create_from_block() {
	local title="$1"
	local source_file="$2"
	local target_file="$3"
	local tmp_dir="$4"
	local tmp_file

	if [[ ! -r "$source_file" ]] || [[ ! -s "$source_file" ]]; then
		return 1
	fi

	if target_is_unsupported "$target_file"; then
		return 1
	fi

	tmp_file="$(mktemp "$tmp_dir/branch-docs-create.XXXXXX")" || return 1
	if ! { printf '%s\n\n' "$title"; sed 's/\r$//' "$source_file"; } > "$tmp_file"; then
		rm -f "$tmp_file"
		return 1
	fi
	if ! commit_temp_file "$tmp_file" "$target_file"; then
		rm -f "$tmp_file"
		return 1
	fi
}

# Rewrites every line terminator in the file to the requested style.
normalize_eol() {
	local file="$1"
	local use_crlf="$2"

	if [[ "$use_crlf" == "1" ]]; then
		sed -i 's/\r$//; s/$/\r/' "$file"
	else
		sed -i 's/\r$//' "$file"
	fi
}

count_marker_lines() {
	local marker="$1"
	local target_file="$2"

	awk -v marker="$marker" '
		{
			line = $0
			sub(/\r$/, "", line)
			if (line == marker) {
				count++
			}
		}
		END { print count + 0 }
	' "$target_file"
}

# Return codes:
#   0 marked block replaced in place
#   2 target file created from the block
#   3 markers are malformed: begin without end, or more than one begin
#   4 an I/O step failed, or the target is not supported (BOM)
#   5 marked block appended to an existing file
upsert_marked_block() {
	local begin_marker="$1"
	local end_marker="$2"
	local source_file="$3"
	local target_file="$4"
	local tmp_file
	local trailing_newlines
	local target_crlf=0
	local begin_count

	if [[ ! -r "$source_file" ]] || [[ ! -s "$source_file" ]]; then
		return 4
	fi

	if target_is_unsupported "$target_file"; then
		return 4
	fi

	if [[ ! -f "$target_file" ]]; then
		tmp_file="$(mktemp "$upsert_temp_dir/branch-docs-create.XXXXXX")" || return 4
		if ! sed 's/\r$//' "$source_file" > "$tmp_file"; then
			rm -f "$tmp_file"
			return 4
		fi
		if ! commit_temp_file "$tmp_file" "$target_file"; then
			rm -f "$tmp_file"
			return 4
		fi
		return 2
	fi

	if file_has_bom "$target_file"; then
		return 4
	fi

	if file_has_crlf "$target_file"; then
		target_crlf=1
	fi

	begin_count="$(count_marker_lines "$begin_marker" "$target_file")" || return 4
	if [[ "$begin_count" -gt 1 ]]; then
		return 3
	fi

	if [[ "$begin_count" == "1" ]]; then
		tmp_file="$(mktemp "$upsert_temp_dir/branch-docs-upsert.XXXXXX")" || return 4
		if ! awk -v begin="$begin_marker" -v end="$end_marker" -v block_file="$source_file" '
			BEGIN {
				while ((getline line < block_file) > 0) {
					block = block line ORS
				}
				close(block_file)
				in_block = 0
				replaced = 0
			}
			{
				marker_line = $0
				sub(/\r$/, "", marker_line)
			}
			marker_line == begin {
				if (!replaced) {
					printf "%s", block
					replaced = 1
				}
				in_block = 1
				next
			}
			in_block && marker_line == end {
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
		if ! normalize_eol "$tmp_file" "$target_crlf"; then
			rm -f "$tmp_file"
			return 4
		fi
		if ! commit_temp_file "$tmp_file" "$target_file"; then
			rm -f "$tmp_file"
			return 4
		fi
		return 0
	fi

	# Append into a copy so a failed source read cannot leave the live file half-written.
	tmp_file="$(mktemp "$upsert_temp_dir/branch-docs-append.XXXXXX")" || return 4
	if ! cp "$target_file" "$tmp_file"; then
		rm -f "$tmp_file"
		return 4
	fi

	trailing_newlines="$(tail -c 1 "$tmp_file" | wc -l | tr -d '[:space:]')"
	if [[ -s "$tmp_file" ]] && [[ "$trailing_newlines" == "0" ]]; then
		printf '\n' >> "$tmp_file" || { rm -f "$tmp_file"; return 4; }
	fi

	printf '\n' >> "$tmp_file" || { rm -f "$tmp_file"; return 4; }
	if ! sed 's/\r$//' "$source_file" >> "$tmp_file"; then
		rm -f "$tmp_file"
		return 4
	fi
	if ! normalize_eol "$tmp_file" "$target_crlf"; then
		rm -f "$tmp_file"
		return 4
	fi
	if ! commit_temp_file "$tmp_file" "$target_file"; then
		rm -f "$tmp_file"
		return 4
	fi
	return 5
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
	copy_file_if_missing "$package_root/docs/index/branch-bindings.json" "$target_repo/docs/index/branch-bindings.json"
	copy_file_if_missing "$package_root/docs/index/work-items.json" "$target_repo/docs/index/work-items.json"
	copy_file_overwrite "$package_root/docs/work/README.md" "$target_repo/docs/work/README.md"
	copy_tree_overwrite "$package_root/docs/branches/_template" "$target_repo/docs/branches/_template"
}

require_git() {
	if ! command -v git >/dev/null 2>&1; then
		printf 'git was not found on PATH. It is required to verify that the target repository does not track docs/.\n' >&2
		exit 1
	fi
}

fail_if_docs_tracked() {
	local target_repo="$1"
	local tracked_docs

	local rev_parse_output

	if ! rev_parse_output="$(git -C "$target_repo" rev-parse --is-inside-work-tree 2>&1)"; then
		if printf '%s' "$rev_parse_output" | grep -qi 'not a git repository'; then
			printf 'Warning: %s is not a Git repository; skipping the tracked docs/ check.\n' "$target_repo" >&2
			return 0
		fi
		printf 'Unable to determine the Git status of %s; refusing to install: %s\n' "$target_repo" "$rev_parse_output" >&2
		exit 1
	fi

	if [[ "$rev_parse_output" != "true" ]]; then
		printf 'Refusing to install into %s: git rev-parse --is-inside-work-tree did not report a working tree.\n' "$target_repo" >&2
		exit 1
	fi

	if ! tracked_docs="$(git -C "$target_repo" ls-files -- docs)"; then
		printf 'Unable to list tracked files under docs/ in %s; refusing to install.\n' "$target_repo" >&2
		exit 1
	fi

	tracked_docs="$(printf '%s' "$tracked_docs" | head -n 1)"
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

	require_git
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
	if [[ ! -f "$target_repo/.codex/config.toml" ]]; then
		cp "$package_root/.codex/config.toml" "$target_repo/.codex/config.toml"
		printf 'Created .codex/config.toml in %s\n' "$target_repo"
	else
		printf 'Skipped existing %s/.codex/config.toml\n' "$target_repo"
	fi

	if [[ ! -f "$target_repo/AGENTS.md" ]]; then
		if ! create_from_block '# Repository Guidelines' "$package_root/AGENTS.branch-docs.md" "$target_repo/AGENTS.md" "$target_repo/.agent-work"; then
			printf 'Unable to create %s/AGENTS.md\n' "$target_repo" >&2
			exit 1
		fi
		printf 'Created AGENTS.md in %s\n' "$target_repo"
	else
		upsert_temp_dir="$target_repo/.agent-work"
		set +e
		upsert_marked_block "$agents_marker" "$agents_end_marker" "$package_root/AGENTS.branch-docs.md" "$target_repo/AGENTS.md"
		upsert_result=$?
		set -e
		if [[ "$upsert_result" -eq 0 ]]; then
			printf 'Updated branch docs guidance in %s/AGENTS.md\n' "$target_repo"
		elif [[ "$upsert_result" -eq 5 ]]; then
			printf 'Merged branch docs guidance into %s/AGENTS.md\n' "$target_repo"
		else
			printf 'Unable to update branch docs guidance in %s/AGENTS.md\n' "$target_repo" >&2
			exit 1
		fi
	fi

	if [[ ! -f "$target_repo/CLAUDE.md" ]]; then
		if ! create_from_block '# Claude Code Instructions' "$package_root/CLAUDE.branch-docs.md" "$target_repo/CLAUDE.md" "$target_repo/.agent-work"; then
			printf 'Unable to create %s/CLAUDE.md\n' "$target_repo" >&2
			exit 1
		fi
		printf 'Created CLAUDE.md in %s\n' "$target_repo"
	else
		upsert_temp_dir="$target_repo/.agent-work"
		set +e
		upsert_marked_block "$agents_marker" "$agents_end_marker" "$package_root/CLAUDE.branch-docs.md" "$target_repo/CLAUDE.md"
		upsert_result=$?
		set -e
		if [[ "$upsert_result" -eq 0 ]]; then
			printf 'Updated branch docs guidance in %s/CLAUDE.md\n' "$target_repo"
		elif [[ "$upsert_result" -eq 5 ]]; then
			printf 'Merged branch docs guidance into %s/CLAUDE.md\n' "$target_repo"
		else
			printf 'Unable to update branch docs guidance in %s/CLAUDE.md\n' "$target_repo" >&2
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
	elif [[ "$upsert_result" -eq 5 ]]; then
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
