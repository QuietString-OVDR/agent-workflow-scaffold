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

## Unreal Build Validation
- Do not use Rider MCP solution-build tools for Unreal compile, build, or
  rebuild validation.

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
