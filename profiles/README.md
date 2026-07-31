# Repository Agent Profile Sources

Each profile source contains exactly one marked `AGENTS.md` block. The manifest in
`config/repo-agent-profiles.json` defines which blocks compose each repository profile and
their canonical order.

Ownership is deliberately narrow:

- `profiles/client/AGENTS.profile.md` owns client-specific guidance
- `profiles/sandbox/AGENTS.profile.md` owns sandbox-specific guidance
- `profiles/client-build-tools/AGENTS.profile.md` owns build-tools-specific guidance
- `profiles/shared/AGENTS.unreal-clean-build-guard.md` owns the byte-identical clean-build
  guard shared by the client and sandbox profiles
- `AGENTS.branch-docs.md` remains the common block owned by the existing starter installers

Do not copy common branch-docs policy into a repository profile. Do not copy the shared
clean-build guard into both Unreal profile files. Update the canonical source and validate
composition with `tests/repo-agent-config/smoke.ps1`.
