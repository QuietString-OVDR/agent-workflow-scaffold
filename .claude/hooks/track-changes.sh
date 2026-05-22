#!/usr/bin/env bash
# PostToolUse hook: logs source file changes and sets a pending-review flag.
# Skips docs/, .agent-work/, .claude/, .codex/ — only tracks source changes.
set -euo pipefail

input=$(cat)
file_path=$(printf '%s' "$input" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    ti = d.get('tool_input', {})
    print(ti.get('file_path', '') or ti.get('path', ''), end='')
except Exception:
    pass
" 2>/dev/null || true)

[[ -z "$file_path" ]] && exit 0

case "$file_path" in
    docs/*|.agent-work/*|.claude/*|.codex/*) exit 0 ;;
esac

mkdir -p .agent-work
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
printf '%s  %s\n' "$timestamp" "$file_path" >> .agent-work/session-changes.log
touch .agent-work/pending-codex-review
