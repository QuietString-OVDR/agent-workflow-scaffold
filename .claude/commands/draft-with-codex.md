# Draft With Codex

Use Codex for draft generation, then curate the result before it becomes canonical.

For design/spec drafting:

```text
/codex:rescue --background Draft the technical spec and design for <feature>. Use AGENTS.md and the current branch docs. Write proposed content for docs/branches/<branch-doc-dir>/spec/technical-spec.md and docs/branches/<branch-doc-dir>/design/<design-doc>.md. Do not modify source code.
```

For handoff drafting:

```text
/codex:rescue --background Write a handoff packet for implementing <feature> to docs/branches/<branch-doc-dir>/plans/next-agent-handoff.md. Include read order, allowed write scope, do-not-modify scope, required verification, and open risks. Do not modify source code.
```

After the job starts:

```text
/codex:status
/codex:result
```

Review the output before accepting it into branch docs.
