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
	>&2 echo Target repo not found: "%target_repo%"
	exit /b 1
)
for %%I in ("%target_repo%") do set "target_repo=%%~fI"

call :validate_git_layout "%target_repo%"
if errorlevel 1 exit /b 1
call :validate_tracked_policies
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
	echo Removed old tools\agent\init-branch-docs.sh from "%target_repo%"
	2>nul rmdir "%target_repo%\tools\agent"
	2>nul rmdir "%target_repo%\tools"
)
if not exist "%target_repo%\.codex\config.toml" (
	copy /y "%package_root%\.codex\config.toml" "%target_repo%\.codex\config.toml" >nul
	if errorlevel 1 exit /b 1
	echo Created .codex\config.toml in "%target_repo%"
) else (
	echo Skipped existing "%target_repo%\.codex\config.toml"
)

git -C "%target_repo%" ls-files --error-unmatch -- AGENTS.md >nul 2>nul
if not errorlevel 1 goto :tracked_agents
if exist "%target_repo%\AGENTS.md" goto :merge_agents
call :create_from_block "# Repository Guidelines" "%package_root%\AGENTS.branch-docs.md" "%target_repo%\AGENTS.md"
if errorlevel 1 exit /b 1
echo Created AGENTS.md in "%target_repo%"
goto :after_agents

:merge_agents
call :upsert_marked_block "<!-- branch-docs-starter:begin -->" "<!-- branch-docs-starter:end -->" "%package_root%\AGENTS.branch-docs.md" "%target_repo%\AGENTS.md"
set "agents_result=%errorlevel%"
if "%agents_result%"=="0" goto :agents_updated
if "%agents_result%"=="5" goto :agents_merged
>&2 echo Unable to update branch docs guidance in "%target_repo%\AGENTS.md" ^(code %agents_result%^)
exit /b 1

:agents_updated
echo Updated branch docs guidance in "%target_repo%\AGENTS.md"
goto :after_agents

:agents_merged
echo Merged branch docs guidance into "%target_repo%\AGENTS.md"
goto :after_agents

:tracked_agents
echo Preserved compatible tracked "%target_repo%\AGENTS.md"

:after_agents

git -C "%target_repo%" ls-files --error-unmatch -- CLAUDE.md >nul 2>nul
if not errorlevel 1 goto :tracked_claude
if exist "%target_repo%\CLAUDE.md" goto :merge_claude
call :create_from_block "# Claude Code Instructions" "%package_root%\CLAUDE.branch-docs.md" "%target_repo%\CLAUDE.md"
if errorlevel 1 exit /b 1
echo Created CLAUDE.md in "%target_repo%"
goto :after_claude

:merge_claude
call :upsert_marked_block "<!-- branch-docs-starter:begin -->" "<!-- branch-docs-starter:end -->" "%package_root%\CLAUDE.branch-docs.md" "%target_repo%\CLAUDE.md"
set "claude_result=%errorlevel%"
if "%claude_result%"=="0" goto :claude_updated
if "%claude_result%"=="5" goto :claude_merged
>&2 echo Unable to update branch docs guidance in "%target_repo%\CLAUDE.md" ^(code %claude_result%^)
exit /b 1

:claude_updated
echo Updated branch docs guidance in "%target_repo%\CLAUDE.md"
goto :after_claude

:claude_merged
echo Merged branch docs guidance into "%target_repo%\CLAUDE.md"
goto :after_claude

:tracked_claude
echo Preserved compatible tracked "%target_repo%\CLAUDE.md"

:after_claude

git -C "%target_repo%" ls-files --error-unmatch -- .gitignore >nul 2>nul
if not errorlevel 1 goto :tracked_gitignore
call :upsert_marked_block "# branch-docs-starter:begin" "# branch-docs-starter:end" "%package_root%\.agent-work.gitignore.block" "%target_repo%\.gitignore"
set "gitignore_result=%errorlevel%"
if "%gitignore_result%"=="0" goto :gitignore_updated
if "%gitignore_result%"=="5" goto :gitignore_appended
if "%gitignore_result%"=="2" goto :gitignore_created
>&2 echo Unable to update branch-docs ignore block in "%target_repo%\.gitignore" ^(code %gitignore_result%^)
exit /b 1

:gitignore_updated
echo Updated branch-docs ignore block in "%target_repo%\.gitignore"
goto :after_gitignore

:gitignore_appended
echo Appended branch-docs ignore block to "%target_repo%\.gitignore"
goto :after_gitignore

:gitignore_created
echo Created branch-docs ignore block in "%target_repo%\.gitignore"
goto :after_gitignore

:tracked_gitignore
echo Preserved compatible tracked "%target_repo%\.gitignore"

:after_gitignore

echo Starter package installed into "%target_repo%"
exit /b 0

:print_usage
echo Usage:
echo   install-to-repo.bat ^<path-to-target-repo^>
echo.
echo Behavior:
echo   - Copy project-scoped Codex config if missing
echo   - Copy .agent-work skeleton files and local-only branch docs files under docs\
echo   - Update managed branch-docs starter files without overwriting local work roots
echo   - Allow tracked product docs outside the reserved branch-docs namespace
echo   - Fail on tracked docs\branches, docs\index, docs\work, or initializer collisions
echo   - Refuse full installation from a linked worktree; use bootstrap-worktree.ps1
echo   - Create AGENTS.md from AGENTS.branch-docs.md if missing
echo   - Append or replace the marked AGENTS.branch-docs.md block if AGENTS.md already exists
echo   - Create CLAUDE.md from CLAUDE.branch-docs.md if missing
echo   - Append or replace the marked CLAUDE.branch-docs.md block if CLAUDE.md already exists
echo   - Append or replace .gitignore rules for local-only starter files and .agent-work/
echo   - Remove the old tools\agent\init-branch-docs.sh helper if present
echo.
echo Marker block contract:
echo   - Markers are matched as whole lines, tolerating a trailing CR
echo   - A marker followed by other text on the same line is not a boundary
echo   - A target that contains more than one begin marker is rejected
echo   - Only the marked block is rewritten; text outside the markers is left as-is
echo   - If the target file already uses CRLF, the whole file is written as CRLF;
echo     otherwise LF is used, and the managed block is converted to match
echo   - Target files must be UTF-8 without a BOM; a BOM in the target aborts the install
echo   - A managed target must be a regular file; a symlink or directory aborts the install
echo   - Managed files are built in a temp file under the target repo's .agent-work\ and
echo     renamed into place, so an interrupted run never leaves a partial managed file
exit /b 0

:print_usage_ok
call :print_usage
exit /b 0

:print_usage_error
call :print_usage
exit /b 1

:validate_git_layout
setlocal EnableExtensions DisableDelayedExpansion
set "target_repo=%~f1"
set "tracked_docs="
set "ls_output=%TEMP%\branch-docs-ls-files-%RANDOM%%RANDOM%.txt"

set "rev_output=%TEMP%\branch-docs-rev-parse-%RANDOM%%RANDOM%.txt"
set "rev_state="

where git >nul 2>nul
if errorlevel 1 goto :git_missing

git -C "%target_repo%" rev-parse --is-inside-work-tree > "%rev_output%" 2>&1
if errorlevel 1 goto :rev_parse_failed

for /f "usebackq delims=" %%S in ("%rev_output%") do set "rev_state=%%S"
del /f /q "%rev_output%" >nul 2>nul
if not "%rev_state%"=="true" goto :not_a_work_tree

set "git_dir="
set "common_dir="
for /f "usebackq delims=" %%G in (`git -C "%target_repo%" rev-parse --path-format^=absolute --git-dir 2^>nul`) do set "git_dir=%%G"
if not defined git_dir goto :git_ls_failed
for /f "usebackq delims=" %%G in (`git -C "%target_repo%" rev-parse --path-format^=absolute --git-common-dir 2^>nul`) do set "common_dir=%%G"
if not defined common_dir goto :git_ls_failed
if /i not "%git_dir%"=="%common_dir%" goto :linked_worktree

git -C "%target_repo%" ls-files -- ":(icase)docs" > "%ls_output%" 2>nul
if errorlevel 1 goto :git_ls_failed
git -C "%target_repo%" log --all --full-history --format^= --name-only -- ":(icase)docs" >> "%ls_output%" 2>nul
if errorlevel 1 goto :git_ls_failed

for /f "usebackq delims=" %%F in ("%ls_output%") do (
	call :is_reserved_docs_path "%%F"
	if not errorlevel 1 (
		set "tracked_docs=%%F"
		goto :found_tracked_docs
	)
)

del /f /q "%ls_output%" >nul 2>nul
endlocal & exit /b 0

:git_missing
>&2 echo git was not found on PATH. It is required to verify the target repository layout.
endlocal & exit /b 1

:rev_parse_failed
findstr /i /c:"not a git repository" "%rev_output%" >nul 2>nul
if errorlevel 1 goto :rev_parse_unknown
del /f /q "%rev_output%" >nul 2>nul
>&2 echo Warning: "%target_repo%" is not a Git repository; skipping the reserved-path check.
endlocal & exit /b 0

:rev_parse_unknown
del /f /q "%rev_output%" >nul 2>nul
>&2 echo Unable to determine the Git status of "%target_repo%"; refusing to install.
endlocal & exit /b 1

:not_a_work_tree
>&2 echo Refusing to install into "%target_repo%": git rev-parse --is-inside-work-tree did not report a working tree.
endlocal & exit /b 1

:git_ls_failed
del /f /q "%ls_output%" >nul 2>nul
>&2 echo Unable to inspect the Git layout or tracked docs paths in "%target_repo%"; refusing to install.
endlocal & exit /b 1

:linked_worktree
del /f /q "%ls_output%" >nul 2>nul
>&2 echo Refusing full branch-docs-starter installation from linked worktree "%target_repo%".
>&2 echo Use bootstrap-worktree.ps1 with an explicit primary -AnchorRepo.
endlocal & exit /b 1

:found_tracked_docs
del /f /q "%ls_output%" >nul 2>nul
>&2 echo Refusing to install branch-docs-starter because the target tracks a reserved branch-docs path: "%tracked_docs%"
>&2 echo Product docs outside docs/branches, docs/index, docs/work, and the initializer paths are supported.
endlocal & exit /b 1

:is_reserved_docs_path
setlocal EnableExtensions DisableDelayedExpansion
set "tracked_path=%~1"
if /i "%tracked_path%"=="docs/branches" endlocal & exit /b 0
if /i "%tracked_path:~0,14%"=="docs/branches/" endlocal & exit /b 0
if /i "%tracked_path%"=="docs/index" endlocal & exit /b 0
if /i "%tracked_path:~0,11%"=="docs/index/" endlocal & exit /b 0
if /i "%tracked_path%"=="docs/work" endlocal & exit /b 0
if /i "%tracked_path:~0,10%"=="docs/work/" endlocal & exit /b 0
if /i "%tracked_path%"=="docs/init-branch-docs.ps1" endlocal & exit /b 0
if /i "%tracked_path%"=="docs/init-branch-docs.sh" endlocal & exit /b 0
endlocal & exit /b 1

:validate_tracked_policies
setlocal EnableExtensions DisableDelayedExpansion
set "powershell_path=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%powershell_path%" set "powershell_path=powershell"
"%powershell_path%" -NoProfile -ExecutionPolicy Bypass -File "%package_root%\assert-install-policy.ps1" -TargetRepo "%target_repo%" -PackageRoot "%package_root%"
endlocal & exit /b %errorlevel%

:create_from_block
setlocal EnableExtensions DisableDelayedExpansion
set "CREATE_TITLE=%~1"
set "CREATE_SOURCE=%~2"
set "CREATE_TARGET=%~3"
set "CREATE_TEMP_DIR=%target_repo%\.agent-work"
set "powershell_path=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%powershell_path%" set "powershell_path=powershell"
set "CREATE_SCRIPT=$ErrorActionPreference='Stop'; $tmp=$null; $bak=$null; try { $enc=New-Object System.Text.UTF8Encoding $false; $lf=[string][char]10; $target=$env:CREATE_TARGET; if (Test-Path -LiteralPath $target) { $targetItem=Get-Item -LiteralPath $target -Force; if ((($targetItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or ($targetItem -is [IO.DirectoryInfo])) { exit 1 } }; $block=[IO.File]::ReadAllText($env:CREATE_SOURCE); if ($block.Length -eq 0) { exit 1 }; $block=[regex]::Replace($block,'\r?\n',$lf); $tmpDir=$env:CREATE_TEMP_DIR; if (-not $tmpDir -or -not (Test-Path -LiteralPath $tmpDir)) { $tmpDir=[IO.Path]::GetDirectoryName($target) }; $tmp=[IO.Path]::Combine($tmpDir,'branch-docs-create-'+[Guid]::NewGuid().ToString('N')+'.tmp'); [IO.File]::WriteAllText($tmp,$env:CREATE_TITLE+$lf+$lf+$block,$enc); if ([IO.File]::Exists($target)) { $bak=[IO.Path]::Combine($tmpDir,'branch-docs-backup-'+[Guid]::NewGuid().ToString('N')+'.tmp'); [IO.File]::Replace($tmp,$target,$bak); if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue } } else { [IO.File]::Move($tmp,$target) }; exit 0 } catch { if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }; if ($bak -and (Test-Path -LiteralPath $bak)) { Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue }; exit 1 }"
"%powershell_path%" -NoProfile -ExecutionPolicy Bypass -Command "%CREATE_SCRIPT%"
endlocal & exit /b %errorlevel%

:upsert_marked_block
setlocal EnableExtensions DisableDelayedExpansion
set "UPSERT_BEGIN=%~1"
set "UPSERT_END=%~2"
set "UPSERT_SOURCE=%~3"
set "UPSERT_TARGET=%~4"
set "UPSERT_TEMP_DIR=%target_repo%\.agent-work"
set "powershell_path=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

set "UPSERT_SCRIPT=$ErrorActionPreference='Stop'; $tmp=$null; $bak=$null; try { $begin=$env:UPSERT_BEGIN; $end=$env:UPSERT_END; $source=$env:UPSERT_SOURCE; $target=$env:UPSERT_TARGET; $enc=New-Object System.Text.UTF8Encoding $false; $lf=[string][char]10; $crlf=[string][char]13+$lf; $block=[IO.File]::ReadAllText($source); if ($block.Length -eq 0) { exit 4 }; if (Test-Path -LiteralPath $target) { $targetItem=Get-Item -LiteralPath $target -Force; if (($targetItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Write-Error 'Symlink and reparse-point targets are not supported'; exit 4 }; if ($targetItem -is [IO.DirectoryInfo]) { Write-Error 'Directory targets are not supported'; exit 4 } }; $tmpDir=$env:UPSERT_TEMP_DIR; if (-not $tmpDir -or -not (Test-Path -LiteralPath $tmpDir)) { $tmpDir=[IO.Path]::GetDirectoryName($target) }; $tmp=[IO.Path]::Combine($tmpDir,'branch-docs-upsert-'+[Guid]::NewGuid().ToString('N')+'.tmp'); if (-not [IO.File]::Exists($target)) { [IO.File]::WriteAllText($tmp,[regex]::Replace($block,'\r?\n',$lf),$enc); [IO.File]::Move($tmp,$target); exit 2 }; $bytes=[IO.File]::ReadAllBytes($target); if (($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) -or ($bytes.Length -ge 2 -and (($bytes[0] -eq 255 -and $bytes[1] -eq 254) -or ($bytes[0] -eq 254 -and $bytes[1] -eq 255)))) { Write-Error 'BOM targets are not supported'; exit 4 }; $text=[IO.File]::ReadAllText($target); $eol=$lf; if ($text.Contains($crlf)) { $eol=$crlf }; $block=[regex]::Replace($block,'\r?\n',$eol); $text=[regex]::Replace($text,'\r?\n',$eol); $beginRe=[regex]('(?m)^'+[regex]::Escape($begin)+'(?=\r?$)'); $endRe=[regex]('(?m)^'+[regex]::Escape($end)+'(\r?\n|$)'); $beginMatches=$beginRe.Matches($text); if ($beginMatches.Count -gt 1) { Write-Error 'More than one begin marker'; exit 3 }; if ($beginMatches.Count -eq 1) { $beginMatch=$beginMatches[0]; $endMatch=$endRe.Match($text,$beginMatch.Index+$beginMatch.Length); if (-not $endMatch.Success) { Write-Error 'End marker not found'; exit 3 }; $text=$text.Substring(0,$beginMatch.Index)+$block+$text.Substring($endMatch.Index+$endMatch.Length); [IO.File]::WriteAllText($tmp,$text,$enc); $bak=[IO.Path]::Combine($tmpDir,'branch-docs-backup-'+[Guid]::NewGuid().ToString('N')+'.tmp'); [IO.File]::Replace($tmp,$target,$bak); if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue }; exit 0 }; if ($text.Length -gt 0 -and -not $text.EndsWith($lf)) { $text += $eol }; $text += $eol + $block; [IO.File]::WriteAllText($tmp,$text,$enc); $bak=[IO.Path]::Combine($tmpDir,'branch-docs-backup-'+[Guid]::NewGuid().ToString('N')+'.tmp'); [IO.File]::Replace($tmp,$target,$bak); if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue }; exit 5 } catch { if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }; if ($bak -and (Test-Path -LiteralPath $bak)) { Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue }; exit 4 }"

if not exist "%powershell_path%" set "powershell_path=powershell"
"%powershell_path%" -NoProfile -ExecutionPolicy Bypass -Command "%UPSERT_SCRIPT%"
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
