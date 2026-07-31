<!-- overdare-client-build-tools-guidance:begin -->
## Repository Scope
- This repository contains the .NET build orchestration used by client,
  sandbox, and TeamCity consumers. Treat its current `README.md` as the
  authoritative source for routine build and unit-test commands.

## Build And Test Safety
- Routine validation may use `dotnet build .\projectbuildtool.sln` and the unit
  test project under `tests\unit`. If `--no-restore` fails because assets are
  missing, rerun without it rather than treating restore as permanently
  forbidden.
- Do not run the S3 integration test by default. It uses AWS credentials and
  performs real bucket queries, upload, and deletion.
- Do not use `buildtools.bat`, `buildtools.sh`, `tcprojectbuildtool.csproj`, or
  `tcuploader.csproj` for routine validation; they can rebuild or write into an
  external `sbxbin` deployment tree.
- Do not regenerate or stage tracked `bin/**` outputs unless the user explicitly
  requests runtime packaging or binary refresh. Confirm routine validation
  leaves `git status --short -- bin` unchanged.

## Clean And Rebuild Contract Changes
- For changes to clean/rebuild command names, defaults, polarity, deletion
  scope, command-set membership, or `IsRebuild`/`-clean` mapping, inspect
  affected client, sandbox, and TeamCity consumers in addition to unit tests.
<!-- overdare-client-build-tools-guidance:end -->
