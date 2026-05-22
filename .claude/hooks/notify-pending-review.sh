#!/usr/bin/env bash
# Stop hook: reminds about pending Codex review when source files were changed.
# Outputs a message that Claude Code surfaces as a system note before stopping.
set -euo pipefail

[[ -f .agent-work/pending-codex-review ]] || exit 0

changed_count=$(wc -l < .agent-work/session-changes.log 2>/dev/null || echo 0)
printf 'Pending Codex review: %s source file change(s) logged this session.\n' "$changed_count"
printf 'Run: /codex:review --base main --background\n'
printf 'Then: /codex:result  — curate findings into plans/code-review.md\n'
printf 'To clear this flag after review: rm .agent-work/pending-codex-review\n'
