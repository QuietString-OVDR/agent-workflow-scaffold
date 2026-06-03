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
if not exist "%target_repo%\docs\" mkdir "%target_repo%\docs"
if not exist "%target_repo%\docs\branches\" mkdir "%target_repo%\docs\branches"
if not exist "%target_repo%\tools\" mkdir "%target_repo%\tools"
if not exist "%target_repo%\tools\agent\" mkdir "%target_repo%\tools\agent"

if not exist "%target_repo%\.agent-work\.gitignore" (
	copy /y "%package_root%\.agent-work\.gitignore" "%target_repo%\.agent-work\.gitignore" >nul
	if errorlevel 1 exit /b 1
)
if not exist "%target_repo%\.agent-work\README.md" (
	copy /y "%package_root%\.agent-work\README.md" "%target_repo%\.agent-work\README.md" >nul
	if errorlevel 1 exit /b 1
)
call :copy_tree_if_missing "%package_root%\docs\branches" "%target_repo%\docs\branches"
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

if exist "%target_repo%\AGENTS.md" goto :merge_agents
> "%target_repo%\AGENTS.md" echo(# Repository Guidelines|| exit /b 1
>> "%target_repo%\AGENTS.md" echo(|| exit /b 1
type "%package_root%\AGENTS.branch-docs.md" >> "%target_repo%\AGENTS.md" || exit /b 1
echo Created AGENTS.md in %target_repo%
goto :after_agents

:merge_agents
call :append_if_missing "branch-docs-starter:begin" "%package_root%\AGENTS.branch-docs.md" "%target_repo%\AGENTS.md"
if errorlevel 2 exit /b 1
if errorlevel 1 (
	echo Skipped existing branch docs guidance in %target_repo%\AGENTS.md
) else (
	echo Merged branch docs guidance into %target_repo%\AGENTS.md
)

:after_agents

call :append_if_missing "# branch-docs-starter:begin" "%package_root%\.agent-work.gitignore.block" "%target_repo%\.gitignore"
if errorlevel 2 exit /b 1
if errorlevel 1 (
	echo Skipped existing branch-docs ignore block in %target_repo%\.gitignore
) else (
	echo Appended branch-docs ignore block to %target_repo%\.gitignore
)

echo Starter package installed into %target_repo%
exit /b 0

:print_usage
echo Usage:
echo   install-to-repo.bat ^<path-to-target-repo^>
echo.
echo Behavior:
echo   - Copy project-scoped Codex config if missing
echo   - Copy .agent-work skeleton files, docs\branches\_template\, and tools\agent\init-branch-docs.sh
echo   - Create AGENTS.md from AGENTS.branch-docs.md if missing
echo   - Append AGENTS.branch-docs.md block if AGENTS.md already exists and the block is not present
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

if not exist "%target_file%" goto :append_if_missing_create_file

set "findstr_path=%SystemRoot%\System32\findstr.exe"
if exist "%findstr_path%" goto :append_if_missing_use_findstr_path
findstr /L /C:"%marker%" "%target_file%" >nul 2>&1
goto :append_if_missing_after_findstr

:append_if_missing_use_findstr_path
"%findstr_path%" /L /C:"%marker%" "%target_file%" >nul 2>&1

:append_if_missing_after_findstr
if errorlevel 1 goto :append_if_missing_append_existing
endlocal & exit /b 1

:append_if_missing_append_existing
>> "%target_file%" echo(|| goto :append_if_missing_failed
type "%source_file%" >> "%target_file%" || goto :append_if_missing_failed
endlocal & exit /b 0

:append_if_missing_create_file
type "%source_file%" > "%target_file%" || goto :append_if_missing_failed
endlocal & exit /b 0

:append_if_missing_failed
endlocal & exit /b 2

:copy_tree_if_missing
setlocal EnableExtensions EnableDelayedExpansion
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
