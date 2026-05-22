<!-- multi-agent-setup-starter:begin -->
## Language Policy

- Always write branch docs, specs, plans, handoff notes, research notes, and agent replies in English.
- If the user writes in another language, interpret the request but still respond and document in English unless the user explicitly asks to override this policy.

## Working Files

- Always create and use `./.agent-work/` for generated artifacts, scratch files, downloads, logs, and temporary outputs.
- Do not leave temporary files elsewhere unless explicitly requested.
- Treat `./.codex/` as Codex settings/config only. Do not use it for high-churn work products such as branch docs or generated outputs.

## Branch Documentation Workflow

- The canonical work identifier is the current branch name unless the user explicitly names another branch.
- Use the full branch name as the documentation key. Do not derive a separate work identifier.
- Map the branch to `./docs/branches/<branch-doc-dir>/`.
- When deriving `<branch-doc-dir>`, replace `/` with `~` so branch docs remain Windows-safe. For example, `sandbox/ovdr-4397` maps to `docs/branches/sandbox~ovdr-4397/`.
- If `./docs/branches/<branch-doc-dir>/README.md` exists, read it first and treat it as the canonical documentation entrypoint for the branch.
- If the branch doc root does not exist, initialize it from `./docs/branches/_template/` or by running `bash ./tools/agent/init-branch-docs.sh`.
- For code changes on a branch, update `status/implementation-status.md` and `status/code-map.md` in the same turn unless the user explicitly says not to.
- For architecture, technical spec, rollout plan, or handoff requests, write the result into the branch doc root under `spec/`, `design/`, or `plans/` instead of leaving it only in chat.
- Treat `backup/` as read-only reference material unless the user explicitly requests edits there.
- Treat `archive/` and `research/` as non-canonical unless the branch README says otherwise.

## Multi-Agent Workflow

- Use Claude Code as the single local work console.
- Use the OpenAI Codex plugin for Claude Code for Codex drafting, adversarial review, code review, and bounded investigation.
- Use explicit `/codex:*` commands before enabling hooks or review-loop automation.
- Keep the Codex plugin review gate disabled until review quality, cost, and runtime behavior are proven.
- Codex output is advisory until a human owner or Claude coordinator curates it into branch docs.
- Prefer `/codex:review --base <base-ref> --background` for code review before PR creation.
- Prefer `/codex:adversarial-review --background <focus>` for design risk and high-risk implementation review.
- Prefer `/codex:rescue --background <bounded prompt>` for investigation or draft generation, and do not blindly apply rescue output.
- Keep accepted review findings in `plans/design-review.md` or `plans/code-review.md`.
<!-- multi-agent-setup-starter:end -->
