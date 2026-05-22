@echo off
setlocal EnableExtensions DisableDelayedExpansion

if "%~1"=="-h" goto :print_usage_ok
if "%~1"=="--help" goto :print_usage_ok
if "%~1"=="" goto :print_usage_error
if not "%~2"=="" goto :print_usage_error

set "package_root=%~dp0"
if "%package_root:~-1%"=="\" set "package_root=%package_root:~0,-1%"
for %%I in ("%package_root%") do set "package_root=%%~fI"

set "target_repo=%~1"
if not exist "%target_repo%\" (
	>&2 echo Target repo not found: %target_repo%
	exit /b 1
)
for %%I in ("%target_repo%") do set "target_repo=%%~fI"

if not exist "%target_repo%\.codex\" mkdir "%target_repo%\.codex"
if not exist "%target_repo%\.agent-work\" mkdir "%target_repo%\.agent-work"
if not exist "%target_repo%\.claude\" mkdir "%target_repo%\.claude"
if not exist "%target_repo%\docs\" mkdir "%target_repo%\docs"
if not exist "%target_repo%\docs\branches\" mkdir "%target_repo%\docs\branches"
if not exist "%target_repo%\docs\workflow\" mkdir "%target_repo%\docs\workflow"
if not exist "%target_repo%\tools\" mkdir "%target_repo%\tools"
if not exist "%target_repo%\tools\agent\" mkdir "%target_repo%\tools\agent"

call :copy_tree_if_missing "%package_root%\.agent-work" "%target_repo%\.agent-work"
if errorlevel 1 exit /b 1
call :copy_tree_if_missing "%package_root%\.claude" "%target_repo%\.claude"
if errorlevel 1 exit /b 1
call :copy_tree_if_missing "%package_root%\docs\branches" "%target_repo%\docs\branches"
if errorlevel 1 exit /b 1
call :copy_tree_if_missing "%package_root%\docs\workflow" "%target_repo%\docs\workflow"
if errorlevel 1 exit /b 1
call :copy_tree_if_missing "%package_root%\tools\agent" "%target_repo%\tools\agent"
if errorlevel 1 exit /b 1

if not exist "%target_repo%\.codex\config.toml" (
	copy /y "%package_root%\.codex\config.toml" "%target_repo%\.codex\config.toml" >nul
	if errorlevel 1 exit /b 1
	echo Created .codex\config.toml in %target_repo%
) else (
	echo Skipped existing %target_repo%\.codex\config.toml
)

if not exist "%target_repo%\AGENTS.md" (
	copy /y "%package_root%\AGENTS.md" "%target_repo%\AGENTS.md" >nul
	if errorlevel 1 exit /b 1
	echo Created AGENTS.md in %target_repo%
) else (
	call :append_if_missing "<!-- multi-agent-setup-starter:begin -->" "%package_root%\AGENTS.multi-agent.md" "%target_repo%\AGENTS.md"
	if errorlevel 2 exit /b 1
	if errorlevel 1 (
		echo Skipped existing multi-agent guidance in %target_repo%\AGENTS.md
	) else (
		echo Merged multi-agent guidance into %target_repo%\AGENTS.md
	)
)

if not exist "%target_repo%\CLAUDE.md" (
	copy /y "%package_root%\CLAUDE.md" "%target_repo%\CLAUDE.md" >nul
	if errorlevel 1 exit /b 1
	echo Created CLAUDE.md in %target_repo%
) else (
	echo Skipped existing %target_repo%\CLAUDE.md
)

if not exist "%target_repo%\REVIEW.md" (
	copy /y "%package_root%\REVIEW.md" "%target_repo%\REVIEW.md" >nul
	if errorlevel 1 exit /b 1
	echo Created REVIEW.md in %target_repo%
) else (
	echo Skipped existing %target_repo%\REVIEW.md
)

call :append_if_missing "# multi-agent-setup-starter:begin" "%package_root%\.agent-work.gitignore.block" "%target_repo%\.gitignore"
if errorlevel 2 exit /b 1
if errorlevel 1 (
	echo Skipped existing .agent-work ignore block in %target_repo%\.gitignore
) else (
	echo Appended .agent-work ignore block to %target_repo%\.gitignore
)

echo Starter package installed into %target_repo%
exit /b 0

:print_usage
echo Usage:
echo   install-to-repo.bat ^<path-to-target-repo^>
echo(
echo Behavior:
echo   - Copy project-scoped Codex config if missing
echo   - Copy .agent-work/, .claude\, docs\branches\_template\, docs\workflow\, and tools\agent\init-branch-docs.sh
echo   - Create AGENTS.md if missing
echo   - Append AGENTS.multi-agent.md block if AGENTS.md already exists and the block is not present
echo   - Create CLAUDE.md and REVIEW.md if missing
echo   - Append .gitignore rules for .agent-work/ if missing
exit /b 0

:print_usage_ok
call :print_usage
exit /b 0

:print_usage_error
call :print_usage
exit /b 1

:append_if_missing
setlocal EnableExtensions DisableDelayedExpansion
set "marker=%~1"
set "source_file=%~2"
set "target_file=%~3"

if exist "%target_file%" (
	findstr /L /C:"%marker%" "%target_file%" >nul 2>&1
	if not errorlevel 1 (
		endlocal & exit /b 1
	)
	>> "%target_file%" echo(
	if errorlevel 1 (
		endlocal & exit /b 2
	)
	type "%source_file%" >> "%target_file%"
	if errorlevel 1 (
		endlocal & exit /b 2
	)
) else (
	type "%source_file%" > "%target_file%"
	if errorlevel 1 (
		endlocal & exit /b 2
	)
)

endlocal & exit /b 0

:copy_tree_if_missing
setlocal EnableExtensions DisableDelayedExpansion
set "source_dir=%~f1"
set "target_dir=%~f2"

for /r "%source_dir%" %%F in (*) do (
	call :copy_file_if_missing "%source_dir%" "%target_dir%" "%%~fF"
	if errorlevel 1 (
		endlocal & exit /b 1
	)
)

endlocal & exit /b 0

:copy_file_if_missing
setlocal EnableExtensions EnableDelayedExpansion
set "source_dir=%~f1"
set "target_dir=%~f2"
set "source_file=%~f3"
set "relative_path=!source_file:%source_dir%\=!"
set "target_file=!target_dir!\!relative_path!"

if not exist "!target_file!" (
	for %%D in ("!target_file!") do if not exist "%%~dpD" mkdir "%%~dpD" >nul 2>&1
	if errorlevel 1 (
		endlocal & exit /b 1
	)
	copy /y "!source_file!" "!target_file!" >nul
	if errorlevel 1 (
		endlocal & exit /b 1
	)
)

endlocal & exit /b 0
