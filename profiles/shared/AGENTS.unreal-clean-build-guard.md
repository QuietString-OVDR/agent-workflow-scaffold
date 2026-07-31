<!-- OVDR_UNREAL_CLEAN_BUILD_GUARD:START -->
## Overdare Unreal Clean-Build Guard

In the protected Overdare Unreal client and sandbox checkouts, never run a
clean, rebuild, or equivalent destructive build unless the user explicitly
requests that exact operation and the session was launched with the clean-build
override for the exact checkout.

`Build`, `test`, `verify`, `fix`, `cleanup`, `reconcile generated outputs`, or
broad task completion does not authorize a clean build.

Treat UBT/UAT clean or rebuild flags, IDE/MSBuild Clean or Rebuild,
ProjectBuildTool clean/rebuild modes, non-dry-run `git clean`, and broad
removal or relocation of `Binaries`, `Intermediate`, `DerivedDataCache`, or
`Saved` as clean-build equivalents.

Use the smallest relevant incremental target by default. If clean state appears
necessary, stop and report the exact command, directories affected, reason,
estimated cost, and narrower alternatives. Wait for the user to launch a
clean-enabled session for that exact checkout.

If the requested result is already verified, do not run an additional
confidence-only build. If an incremental build unexpectedly expands into an
engine-wide rebuild, stop it and ask before continuing.

The mechanical override requires both variables in the parent environment
before Codex starts:

```text
OVDR_ALLOW_UNREAL_CLEAN_BUILD=1
OVDR_UNREAL_CLEAN_BUILD_ROOT=<exact protected checkout>
```

Chat approval or setting these variables inside a tool subprocess cannot unlock
the current session.
<!-- OVDR_UNREAL_CLEAN_BUILD_GUARD:END -->
