<!-- overdare-sandbox-guidance:begin -->
## Repository Scope
- The canonical project is `<repo-root>\Sandbox\Sandbox.uproject`; use
  `<repo-root>\Sandbox` as the exact Rider project root.
- Resolve the exact clone from Git and Rider instead of hard-coding
  `sandbox1`, `sandbox2`, or `sandbox3`.
- `Sandbox/Plugins` is shared with client consumers.
- Sandbox uses a customized modular Unreal Editor and may retain editor
  definitions in packaged Game targets; do not assume conventional
  non-editor target behavior.

## Rider MCP Build Validation
- Rider MCP is the only automatic path for routine local Unreal compile
  validation.
- Derive `N` only from the exact top-level Git clone directory basename
  matching `sandboxN`; if the basename does not match or `N` cannot be derived
  exactly, treat preflight as failed.
- For Rider MCP solution builds only, clone `sandboxN` uses
  `<repo-root>\Sandbox\SandboxN.uproject` when it is byte-identical to
  canonical `<repo-root>\Sandbox\Sandbox.uproject`. If the clone-specific copy
  is missing or differs, treat preflight as failed.
- Pass `<repo-root>\Sandbox` as `rootFolder` and require the `SandboxN`
  Uproject run configuration before building; do not require or fall back to
  `Sandbox`.
- Start only `build_solution_start` with `rebuild: false`, poll the returned
  session with a bounded timeout, and never start a concurrent build. Report
  Live Coding or Hot Reload as such.
- Rider MCP does not expose enough state to claim the active toolbar build
  configuration was verified. Do not guess or report it as confirmed.
- Rider may invoke UBT and UBT may use XGE/IncrediBuild internally; this remains
  a Rider-initiated validation, not a manual fallback.
- On failed preflight or build, preserve the first actionable reason and
  report:
  `Build validation: Skipped — Rider MCP <reason>; no manual UBT/Build.bat/MSBuild/XGE fallback was attempted.`
- Do not run a manual or build-producing fallback. A manual build is allowed
  only when the user explicitly requests that build path as the task itself,
  and it remains subject to the clean-build guard in this file.

## Search And Editing Boundaries
- Use the branch documentation code map first when enabled; otherwise narrow
  searches to `Sandbox/Source`, `Sandbox/Plugins`, and the relevant engine or
  authored-content root.
- Do not hand-edit or broadly remove `Binaries`, `Intermediate`,
  `DerivedDataCache`, or `Saved`.

## Engine Fork Changes
- Mark local engine-fork changes with `MGL_BEGIN`/`MGL_END`, or
  `MGL_BEGIN_END` for a single-line modification.
- Gate configurable changes through the existing MGL configuration pattern and
  keep enabled and disabled configurations source-compatible where practical.
- Do not add MGL markers to an otherwise unmodified upstream Epic commit;
  preserve the upstream commit reference instead.

## Commit And Pull Request Sources
- Treat the current Git hooks, `.github/pull_request_template.md`, and
  `.github/workflows/` as authoritative for mutable commit and PR rules.
- For current-branch PR creation, use the installed `overdare-pr-create`
  workflow rather than duplicating its policy here.
<!-- overdare-sandbox-guidance:end -->
