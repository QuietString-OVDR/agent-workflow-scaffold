<!-- overdare-client-guidance:begin -->
## Repository Scope And Boundaries
- The canonical Unreal client project is `<repo-root>\Meta\Meta.uproject`;
  this checkout does not contain the Sandbox authoring project.
- Resolve the exact clone from Git and Rider instead of hard-coding
  `client1`, `client2`, or `client3`.

## Rider MCP Build Validation
- Rider MCP is the only automatic path for routine local Unreal compile
  validation.
- Derive `N` only from the exact top-level Git clone directory basename
  matching `clientN`; if the basename does not match or `N` cannot be derived
  exactly, treat preflight as failed.
- For Rider MCP solution builds only, clone `clientN` uses
  `<repo-root>\Meta\MetaN.uproject` when it is byte-identical to canonical
  `<repo-root>\Meta\Meta.uproject`. If the clone-specific copy is missing or
  differs, treat preflight as failed.
- Pass `<repo-root>\Meta` as `rootFolder` and require the `MetaN` Uproject run
  configuration before building; do not require or fall back to `Meta`.
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

## File Safety
- Never run `0.git-clean.bat` for routine setup, cleanup, or validation.
- Do not broadly remove generated directories or assume every `bin/` or `obj/`
  path is disposable. Some `client-build-tools/bin` outputs are tracked; check
  `git ls-files` and the nearest README first.

## Commit And Pull Request Sources
- Treat the current Git hooks, `.github/pull_request_template.md`, and
  `.github/workflows/` as authoritative for mutable commit and PR rules.
- For current-branch PR creation, use the installed `overdare-pr-create`
  workflow rather than duplicating its policy here.
<!-- overdare-client-guidance:end -->
