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

call :fail_if_docs_tracked "%target_repo%"
if errorlevel 1 exit /b 1

if not exist "%target_repo%\.codex\" mkdir "%target_repo%\.codex"
if not exist "%target_repo%\.agent-work\" mkdir "%target_repo%\.agent-work"
if not exist "%target_repo%\docs\" mkdir "%target_repo%\docs"

if not exist "%target_repo%\.agent-work\.gitignore" (
	copy /y "%package_root%\.agent-work\.gitignore" "%target_repo%\.agent-work\.gitignore" >nul
	if errorlevel 1 exit /b 1
)
if not exist "%target_repo%\.agent-work\README.md" (
	copy /y "%package_root%\.agent-work\README.md" "%target_repo%\.agent-work\README.md" >nul
	if errorlevel 1 exit /b 1
)
call :copy_tree_if_missing "%package_root%\docs" "%target_repo%\docs"
if errorlevel 1 exit /b 1
call :sync_managed_docs "%package_root%" "%target_repo%"
if errorlevel 1 exit /b 1

if exist "%target_repo%\tools\agent\init-branch-docs.sh" (
	del /f /q "%target_repo%\tools\agent\init-branch-docs.sh" >nul
	if errorlevel 1 exit /b 1
	echo Removed old tools\agent\init-branch-docs.sh from %target_repo%
	2>nul rmdir "%target_repo%\tools\agent"
	2>nul rmdir "%target_repo%\tools"
)
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
call :upsert_marked_block "<!-- branch-docs-starter:begin -->" "<!-- branch-docs-starter:end -->" "%package_root%\AGENTS.branch-docs.md" "%target_repo%\AGENTS.md"
set "agents_result=%errorlevel%"
if %agents_result% GEQ 3 exit /b 1
if %agents_result% EQU 0 echo Updated branch docs guidance in %target_repo%\AGENTS.md
if %agents_result% EQU 1 echo Merged branch docs guidance into %target_repo%\AGENTS.md

:after_agents

call :upsert_marked_block "# branch-docs-starter:begin" "# branch-docs-starter:end" "%package_root%\.agent-work.gitignore.block" "%target_repo%\.gitignore"
set "gitignore_result=%errorlevel%"
if %gitignore_result% GEQ 3 exit /b 1
if %gitignore_result% EQU 0 echo Updated branch-docs ignore block in %target_repo%\.gitignore
if %gitignore_result% EQU 1 echo Appended branch-docs ignore block to %target_repo%\.gitignore
if %gitignore_result% EQU 2 echo Created branch-docs ignore block in %target_repo%\.gitignore

echo Starter package installed into %target_repo%
exit /b 0

:print_usage
echo Usage:
echo   install-to-repo.bat ^<path-to-target-repo^>
echo.
echo Behavior:
echo   - Copy project-scoped Codex config if missing
echo   - Copy .agent-work skeleton files and local-only branch docs files under docs\
echo   - Update managed branch-docs starter files without overwriting local work roots
echo   - Fail if the target repository already tracks files under docs\
echo   - Create AGENTS.md from AGENTS.branch-docs.md if missing
echo   - Append or replace the marked AGENTS.branch-docs.md block if AGENTS.md already exists
echo   - Append or replace .gitignore rules for local-only starter files and .agent-work/
echo   - Remove the old tools\agent\init-branch-docs.sh helper if present
exit /b 0

:print_usage_ok
call :print_usage
exit /b 0

:print_usage_error
call :print_usage
exit /b 1

:fail_if_docs_tracked
setlocal EnableExtensions DisableDelayedExpansion
set "target_repo=%~f1"
set "tracked_docs="

for /f "delims=" %%F in ('git -C "%target_repo%" ls-files -- docs 2^>nul') do (
	set "tracked_docs=%%F"
	goto :found_tracked_docs
)

endlocal & exit /b 0

:found_tracked_docs
>&2 echo Refusing to install branch-docs-starter because target repo tracks files under docs/: %tracked_docs%
>&2 echo This starter is intended for internal project repos where docs/ is local-only agent workspace.
endlocal & exit /b 1

:upsert_marked_block
setlocal EnableExtensions DisableDelayedExpansion
set "UPSERT_BEGIN=%~1"
set "UPSERT_END=%~2"
set "UPSERT_SOURCE=%~3"
set "UPSERT_TARGET=%~4"
set "powershell_path=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if exist "%powershell_path%" (
	"%powershell_path%" -NoProfile -ExecutionPolicy Bypass -Command "$begin=$env:UPSERT_BEGIN; $end=$env:UPSERT_END; $source=$env:UPSERT_SOURCE; $target=$env:UPSERT_TARGET; $enc=New-Object System.Text.UTF8Encoding $false; $block=[IO.File]::ReadAllText($source); if ([IO.File]::Exists($target)) { $text=[IO.File]::ReadAllText($target); $start=$text.IndexOf($begin); if ($start -ge 0) { $finish=$text.IndexOf($end,$start); if ($finish -lt 0) { Write-Error 'End marker not found'; exit 3 }; $finish += $end.Length; $text=$text.Substring(0,$start)+$block+$text.Substring($finish); [IO.File]::WriteAllText($target,$text,$enc); exit 0 } else { if ($text.Length -gt 0 -and -not $text.EndsWith([string][char]10)) { $text += [Environment]::NewLine }; $text += [Environment]::NewLine + $block; [IO.File]::WriteAllText($target,$text,$enc); exit 1 } } else { [IO.File]::WriteAllText($target,$block,$enc); exit 2 }"
) else (
	powershell -NoProfile -ExecutionPolicy Bypass -Command "$begin=$env:UPSERT_BEGIN; $end=$env:UPSERT_END; $source=$env:UPSERT_SOURCE; $target=$env:UPSERT_TARGET; $enc=New-Object System.Text.UTF8Encoding $false; $block=[IO.File]::ReadAllText($source); if ([IO.File]::Exists($target)) { $text=[IO.File]::ReadAllText($target); $start=$text.IndexOf($begin); if ($start -ge 0) { $finish=$text.IndexOf($end,$start); if ($finish -lt 0) { Write-Error 'End marker not found'; exit 3 }; $finish += $end.Length; $text=$text.Substring(0,$start)+$block+$text.Substring($finish); [IO.File]::WriteAllText($target,$text,$enc); exit 0 } else { if ($text.Length -gt 0 -and -not $text.EndsWith([string][char]10)) { $text += [Environment]::NewLine }; $text += [Environment]::NewLine + $block; [IO.File]::WriteAllText($target,$text,$enc); exit 1 } } else { [IO.File]::WriteAllText($target,$block,$enc); exit 2 }"
)
endlocal & exit /b %errorlevel%

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

:sync_managed_docs
setlocal EnableExtensions DisableDelayedExpansion
set "package_root=%~f1"
set "target_repo=%~f2"

call :copy_file_overwrite "%package_root%\docs\init-branch-docs.sh" "%target_repo%\docs\init-branch-docs.sh"
if errorlevel 1 (endlocal & exit /b 1)
call :copy_file_overwrite "%package_root%\docs\init-branch-docs.ps1" "%target_repo%\docs\init-branch-docs.ps1"
if errorlevel 1 (endlocal & exit /b 1)
call :copy_file_overwrite "%package_root%\docs\branches\README.md" "%target_repo%\docs\branches\README.md"
if errorlevel 1 (endlocal & exit /b 1)
call :copy_file_overwrite "%package_root%\docs\index\README.md" "%target_repo%\docs\index\README.md"
if errorlevel 1 (endlocal & exit /b 1)
call :copy_file_if_missing "%package_root%" "%target_repo%" "%package_root%\docs\index\branch-bindings.json"
if errorlevel 1 (endlocal & exit /b 1)
call :copy_file_if_missing "%package_root%" "%target_repo%" "%package_root%\docs\index\work-items.json"
if errorlevel 1 (endlocal & exit /b 1)
call :copy_file_overwrite "%package_root%\docs\work\README.md" "%target_repo%\docs\work\README.md"
if errorlevel 1 (endlocal & exit /b 1)
call :copy_tree_overwrite "%package_root%\docs\branches\_template" "%target_repo%\docs\branches\_template"
if errorlevel 1 (endlocal & exit /b 1)

endlocal & exit /b 0

:copy_tree_overwrite
setlocal EnableExtensions EnableDelayedExpansion
set "source_dir=%~f1"
set "target_dir=%~f2"

for /r "%source_dir%" %%F in (*) do (
	call :copy_file_from_tree_overwrite "%source_dir%" "%target_dir%" "%%~fF"
	if errorlevel 1 (
		endlocal & exit /b 1
	)
)

endlocal & exit /b 0

:copy_file_from_tree_overwrite
setlocal EnableExtensions EnableDelayedExpansion
set "source_dir=%~f1"
set "target_dir=%~f2"
set "source_file=%~f3"
set "relative_path=!source_file:%source_dir%\=!"
set "target_file=!target_dir!\!relative_path!"

call :copy_file_overwrite "!source_file!" "!target_file!"
if errorlevel 1 (
	endlocal & exit /b 1
)

endlocal & exit /b 0

:copy_file_overwrite
setlocal EnableExtensions EnableDelayedExpansion
set "source_file=%~f1"
set "target_file=%~f2"

for %%D in ("!target_file!") do if not exist "%%~dpD" mkdir "%%~dpD" >nul 2>&1
if errorlevel 1 (
	endlocal & exit /b 1
)
copy /y "!source_file!" "!target_file!" >nul
if errorlevel 1 (
	endlocal & exit /b 1
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
