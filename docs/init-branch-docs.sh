#!/usr/bin/env bash

set -euo pipefail

print_usage() {
	cat <<'EOF'
Usage:
  powershell -ExecutionPolicy Bypass -File ./docs/init-branch-docs.ps1 [options]
  bash ./docs/init-branch-docs.sh [branch-name]
  bash ./docs/init-branch-docs.sh --print-branch [branch-name]
  bash ./docs/init-branch-docs.sh --print-doc-dir [branch-name]
  bash ./docs/init-branch-docs.sh --sync-missing [branch-name]
  bash ./docs/init-branch-docs.sh --allow-non-work-ref [branch-name]

Behavior:
  - PowerShell is the primary supported initializer for Jira work-key docs.
  - If branch-name is omitted, infer it from the current repo or super project branch.
  - The documentation key is the branch name after removing a trailing build-test suffix
    such as `-b`, `-bb`, or `-bbb`.
  - `./docs/branches/<branch-doc-dir>/` uses the documentation key with `/` replaced by `~`.
  - Detached HEAD and `master` skip branch doc creation unless --allow-non-work-ref is passed.
  - Existing files are never overwritten.
EOF
}

resolve_super_root() {
	local super_root

	super_root="$(git rev-parse --show-superproject-working-tree 2>/dev/null || true)"
	if [[ -n "$super_root" ]]; then
		printf '%s\n' "$super_root"
		return
	fi

	if super_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
		printf '%s\n' "$super_root"
		return
	fi

	find_work_tree_root_fallback
}

find_work_tree_root_fallback() {
	local dir="$PWD"

	while [[ "$dir" != "/" ]]; do
		if [[ -e "$dir/.git" ]]; then
			printf '%s\n' "$dir"
			return
		fi

		dir="$(dirname "$dir")"
	done

	printf 'Unable to resolve git work tree root from %s\n' "$PWD" >&2
	exit 1
}

windows_path_to_wsl() {
	local path="$1"
	local drive
	local rest

	case "$path" in
		[A-Za-z]:/*)
			drive="$(printf '%s' "${path%%:*}" | tr '[:upper:]' '[:lower:]')"
			rest="${path#?:/}"
			printf '/mnt/%s/%s\n' "$drive" "$rest"
			;;
		*)
			printf '%s\n' "$path"
			;;
	esac
}

resolve_git_dir_fallback() {
	local super_root="$1"
	local git_marker="$super_root/.git"
	local git_dir

	if [[ -d "$git_marker" ]]; then
		printf '%s\n' "$git_marker"
		return
	fi

	if [[ ! -f "$git_marker" ]]; then
		printf 'Git marker not found: %s\n' "$git_marker" >&2
		exit 1
	fi

	git_dir="$(sed -n 's/^gitdir: //p' "$git_marker" | head -n 1)"
	if [[ -z "$git_dir" ]]; then
		printf 'Unable to parse gitdir from %s\n' "$git_marker" >&2
		exit 1
	fi

	git_dir="$(windows_path_to_wsl "$git_dir")"
	if [[ "$git_dir" != /* ]]; then
		git_dir="$super_root/$git_dir"
	fi

	printf '%s\n' "$git_dir"
}

normalize_branch_name() {
	local raw="$1"
	local branch_name=""

	raw="${raw#refs/heads/}"
	raw="${raw#refs/remotes/}"
	raw="${raw#origin/}"

	if [[ -z "$raw" ]]; then
		printf 'Branch name is empty.\n' >&2
		exit 1
	fi

	branch_name="$raw"

	if ! git -C / check-ref-format --branch "$branch_name" >/dev/null 2>&1; then
		printf 'Invalid branch name: %s\n' "$1" >&2
		exit 1
	fi

	printf '%s\n' "$branch_name"
}

derive_documentation_branch_name() {
	local branch_name="$1"

	if [[ "$branch_name" =~ ^(.+)-b+$ ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
		return
	fi

	printf '%s\n' "$branch_name"
}

sanitize_branch_dir_name() {
	local branch_name="$1"
	local branch_doc_dir="$branch_name"

	# `~` is not allowed in git branch names, so this replacement stays readable
	# while avoiding collisions with valid raw branch names.
	branch_doc_dir="$(printf '%s' "$branch_doc_dir" | tr '/' '~')"

	case "$(printf '%s' "$branch_doc_dir" | tr '[:upper:]' '[:lower:]')" in
		con|prn|aux|nul|com[1-9]|lpt[1-9])
			branch_doc_dir="_$branch_doc_dir"
			;;
	esac

	printf '%s\n' "$branch_doc_dir"
}

detect_branch_from_repo() {
	local super_root="$1"
	local branch
	local git_status
	local git_dir
	local head_file
	local head

	if branch="$(git -C "$super_root" symbolic-ref --quiet --short HEAD 2>/dev/null)"; then
		if [[ -z "$branch" ]]; then
			printf 'git symbolic-ref returned an empty branch name for %s.\n' "$super_root" >&2
			return 2
		fi
		if branch="$(normalize_branch_name "$branch")"; then
			printf '%s\n' "$branch"
			return 0
		fi
		return 2
	else
		git_status=$?
	fi

	if [[ "$git_status" -eq 1 ]]; then
		return 1
	fi

	if ! git_dir="$(resolve_git_dir_fallback "$super_root")"; then
		printf 'Unable to resolve current branch from %s: git symbolic-ref failed with exit code %s and the Git directory fallback failed.\n' "$super_root" "$git_status" >&2
		return 2
	fi

	head_file="$git_dir/HEAD"
	if [[ ! -r "$head_file" ]]; then
		printf 'Unable to read HEAD after git symbolic-ref failed with exit code %s: %s\n' "$git_status" "$head_file" >&2
		return 2
	fi

	head="$(sed -n '1p' "$head_file")"
	case "$head" in
		ref:\ refs/heads/*)
			branch="${head#ref: refs/heads/}"
			if branch="$(normalize_branch_name "$branch")"; then
				printf '%s\n' "$branch"
				return 0
			fi
			return 2
			;;
	esac

	if [[ "$head" =~ ^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$ ]]; then
		return 1
	fi

	printf 'Unable to interpret HEAD after git symbolic-ref failed with exit code %s: %s\n' "$git_status" "$head_file" >&2
	return 2
}

escape_sed_replacement() {
	printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'
}

render_template_file() {
	local source_file="$1"
	local target_file="$2"
	local branch_name="$3"
	local branch_doc_dir="$4"
	local work_key="${5:-$branch_name}"
	local branch_name_escaped
	local branch_doc_dir_escaped
	local work_key_escaped

	branch_name_escaped="$(escape_sed_replacement "$branch_name")"
	branch_doc_dir_escaped="$(escape_sed_replacement "$branch_doc_dir")"
	work_key_escaped="$(escape_sed_replacement "$work_key")"

	sed \
		-e "s|__BRANCH_NAME__|$branch_name_escaped|g" \
		-e "s|__BRANCH_DOC_DIR_NAME__|$branch_doc_dir_escaped|g" \
		-e "s|__WORK_KEY__|$work_key_escaped|g" \
		-e "s|__PARENT_WORK_KEY__||g" \
		-e "s|__ISSUE_URL__||g" \
		"$source_file" > "$target_file"
}

main() {
	local sync_missing="false"
	local allow_non_work_ref="false"
	local print_branch_only="false"
	local print_doc_dir_only="false"
	local input_branch=""
	local super_root
	local branch_detection_status
	local current_branch=""
	local raw_branch_name
	local branch_name
	local branch_doc_dir
	local template_root
	local docs_root
	local doc_root
	local template_file
	local relative_path
	local target_file

	while [[ $# -gt 0 ]]; do
		case "$1" in
			--sync-missing)
				sync_missing="true"
				;;
			--allow-non-work-ref)
				allow_non_work_ref="true"
				;;
			--print-branch)
				print_branch_only="true"
				;;
			--print-doc-dir)
				print_doc_dir_only="true"
				;;
			-h|--help)
				print_usage
				exit 0
				;;
			*)
				if [[ -n "$input_branch" ]]; then
					printf 'Unexpected extra argument: %s\n' "$1" >&2
					exit 1
				fi
				input_branch="$1"
				;;
		esac
		shift
	done

	super_root="$(resolve_super_root)"
	template_root="$super_root/docs/branches/_template"
	docs_root="$super_root/docs/branches"

	if [[ ! -d "$template_root" ]]; then
		printf 'Template root not found: %s\n' "$template_root" >&2
		exit 1
	fi

	if current_branch="$(detect_branch_from_repo "$super_root")"; then
		:
	else
		branch_detection_status=$?
		if [[ "$branch_detection_status" -ne 1 ]]; then
			exit "$branch_detection_status"
		fi
		current_branch=""
	fi

	if [[ -n "$input_branch" ]]; then
		raw_branch_name="$(normalize_branch_name "$input_branch")"
	else
		raw_branch_name="$current_branch"
	fi

	if [[ -z "$raw_branch_name" ]]; then
		if [[ "$print_branch_only" == "true" || "$print_doc_dir_only" == "true" ]]; then
			printf 'Unable to detect current branch from %s because HEAD is detached.\n' "$super_root" >&2
			exit 1
		fi
		if [[ "$allow_non_work_ref" == "true" ]]; then
			printf 'Detached HEAD requires an explicit branch-name with --allow-non-work-ref.\n' >&2
			exit 1
		fi
		printf 'Branch docs skipped: HEAD is detached. Continue without branch documentation unless the user explicitly requests it.\n'
		exit 0
	fi

	branch_name="$(derive_documentation_branch_name "$raw_branch_name")"
	branch_doc_dir="$(sanitize_branch_dir_name "$branch_name")"

	if [[ "$print_branch_only" == "true" ]]; then
		printf '%s\n' "$branch_name"
		exit 0
	fi

	if [[ "$print_doc_dir_only" == "true" ]]; then
		printf '%s\n' "$branch_doc_dir"
		exit 0
	fi

	if [[ "$allow_non_work_ref" == "false" && -z "$current_branch" ]]; then
		printf 'Branch docs skipped: HEAD is detached. Continue without branch documentation unless the user explicitly requests it.\n'
		exit 0
	fi

	if [[ "$allow_non_work_ref" == "false" && ( "$current_branch" == "master" || "$raw_branch_name" == "master" ) ]]; then
		printf 'Branch docs skipped: the current or requested branch is master. Continue without branch documentation unless the user explicitly requests it.\n'
		exit 0
	fi

	doc_root="$docs_root/$branch_doc_dir"

	if [[ -d "$doc_root" && "$sync_missing" == "false" ]]; then
		printf 'Branch docs already exist: %s\n' "$doc_root"
		printf 'Use --sync-missing to add only missing template files.\n'
		exit 0
	fi

	mkdir -p \
		"$doc_root/spec" \
		"$doc_root/architecture" \
		"$doc_root/status" \
		"$doc_root/plans" \
		"$doc_root/share/guides" \
		"$doc_root/share/specs" \
		"$doc_root/research" \
		"$doc_root/archive" \
		"$doc_root/archive/plans" \
		"$doc_root/backup"

	while IFS= read -r template_file; do
		relative_path="${template_file#"$template_root"/}"
		target_file="$doc_root/$relative_path"

		if [[ -e "$target_file" ]]; then
			continue
		fi

		mkdir -p "$(dirname "$target_file")"
		render_template_file "$template_file" "$target_file" "$branch_name" "$branch_doc_dir"
	done < <(find "$template_root" -type f | sort)

	printf 'Branch docs ready: %s\n' "$doc_root"
}

main "$@"
