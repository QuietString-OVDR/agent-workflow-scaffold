<!-- overdare-client-guidance:begin -->
## Repository Scope And Boundaries
- The canonical Unreal client project is `<repo-root>\Meta\Meta.uproject`;
  this checkout does not contain the Sandbox authoring project.
- Resolve the exact clone from Git and Rider instead of hard-coding
  `client1`, `client2`, or `client3`.

## Unreal Build Validation
- Do not use Rider MCP solution-build tools for Unreal compile, build, or
  rebuild validation.

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
