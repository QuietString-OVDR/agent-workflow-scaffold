# Review With Codex

Run a Codex review from Claude Code and then curate the result into branch docs.

Recommended command:

```text
/codex:review --base main --background
```

For high-risk or architecture-sensitive changes:

```text
/codex:adversarial-review --base main --background look for scope creep, lifetime or ownership risks, missing verification, rollback risk, and design assumptions that should be revisited.
```

After the job starts:

```text
/codex:status
/codex:result
```

Curate accepted findings into `docs/branches/<branch-doc-dir>/plans/code-review.md`.

Do not blindly apply Codex output. Mark each finding as accepted, rejected, deferred, or resolved.
