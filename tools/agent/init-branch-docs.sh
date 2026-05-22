#!/usr/bin/env bash

set -euo pipefail

print_usage() {
	cat <<'EOF'
Usage:
  bash ./tools/agent/init-branch-docs.sh [branch-name]
  bash ./tools/agent/init-branch-docs.sh --print-branch [branch-name]
  bash ./tools/agent/init-branch-docs.sh --print-doc-dir [branch-name]
  bash ./tools/agent/init-branch-docs.sh --sync-missing [branch-name]

Behavior:
  - If branch-name is omitted, infer it from the current repo or super project branch.
  - The full branch name is the documentation key; no separate work identifier is derived.
  - `./docs/branches/<branch-doc-dir>/` uses the branch name with `/` replaced by `~`.
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

	git rev-parse --show-toplevel
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

	if ! git check-ref-format --branch "$branch_name" >/dev/null 2>&1; then
		printf 'Invalid branch name: %s\n' "$1" >&2
		exit 1
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

	branch="$(git -C "$super_root" branch --show-current)"
	if [[ -z "$branch" ]]; then
		printf 'Unable to detect current branch from %s\n' "$super_root" >&2
		exit 1
	fi

	normalize_branch_name "$branch"
}

escape_sed_replacement() {
	printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'
}

render_template_file() {
	local source_file="$1"
	local target_file="$2"
	local branch_name="$3"
	local branch_doc_dir="$4"
	local branch_name_escaped
	local branch_doc_dir_escaped

	branch_name_escaped="$(escape_sed_replacement "$branch_name")"
	branch_doc_dir_escaped="$(escape_sed_replacement "$branch_doc_dir")"

	sed \
		-e "s|__BRANCH_NAME__|$branch_name_escaped|g" \
		-e "s|__BRANCH_DOC_DIR_NAME__|$branch_doc_dir_escaped|g" \
		"$source_file" > "$target_file"
}

main() {
	local sync_missing="false"
	local print_branch_only="false"
	local print_doc_dir_only="false"
	local input_branch=""
	local super_root
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

	if [[ -n "$input_branch" ]]; then
		branch_name="$(normalize_branch_name "$input_branch")"
	else
		branch_name="$(detect_branch_from_repo "$super_root")"
	fi

	branch_doc_dir="$(sanitize_branch_dir_name "$branch_name")"

	if [[ "$print_branch_only" == "true" ]]; then
		printf '%s\n' "$branch_name"
		exit 0
	fi

	if [[ "$print_doc_dir_only" == "true" ]]; then
		printf '%s\n' "$branch_doc_dir"
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
		"$doc_root/design" \
		"$doc_root/status" \
		"$doc_root/plans" \
		"$doc_root/research" \
		"$doc_root/archive" \
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
