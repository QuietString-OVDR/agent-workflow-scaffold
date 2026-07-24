[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)]
	[string]$FixtureRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$packageRoot = Split-Path -Parent $PSScriptRoot
$batchInstaller = Join-Path $packageRoot "install-to-repo.bat"
$shellInstaller = Join-Path $packageRoot "install-to-repo.sh"
$fixtureRoot = [IO.Path]::GetFullPath($FixtureRoot)
$failures = 0

function Check {
	param(
		[Parameter(Mandatory = $true)][string]$Name,
		[Parameter(Mandatory = $true)][bool]$Condition
	)

	if ($Condition) {
		Write-Host "PASS  $Name"
	} else {
		$script:failures++
		Write-Host "FAIL  $Name"
	}
}

function Invoke-Git {
	param(
		[Parameter(Mandatory = $true)][string]$Repo,
		[Parameter(Mandatory = $true)][string[]]$Arguments
	)

	$oldErrorActionPreference = $ErrorActionPreference
	try {
		$ErrorActionPreference = "Continue"
		$output = @(& git -C $Repo @Arguments 2>&1)
		$exitCode = $LASTEXITCODE
	} finally {
		$ErrorActionPreference = $oldErrorActionPreference
	}
	if ($exitCode -ne 0) {
		throw "git -C `"$Repo`" $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
	}
	return @($output | ForEach-Object { "$_" })
}

function New-Repo {
	param(
		[Parameter(Mandatory = $true)][string]$Name,
		[switch]$ReservedCollision
	)

	$repo = Join-Path $fixtureRoot $Name
	New-Item -ItemType Directory -Path (Join-Path $repo "docs/product") -Force | Out-Null
	Invoke-Git $repo @("init", "-q") | Out-Null
	Invoke-Git $repo @("config", "user.email", "branch-docs-fixture@example.invalid") | Out-Null
	Invoke-Git $repo @("config", "user.name", "Branch Docs Fixture") | Out-Null
	Invoke-Git $repo @("config", "core.autocrlf", "false") | Out-Null
	[IO.File]::WriteAllText((Join-Path $repo "docs/product/guide.md"), "product-doc`n")
	if ($ReservedCollision) {
		New-Item -ItemType Directory -Path (Join-Path $repo "docs/WORK") -Force | Out-Null
		[IO.File]::WriteAllText((Join-Path $repo "docs/WORK/collision.md"), "collision`n")
	}
	Invoke-Git $repo @("add", ".") | Out-Null
	Invoke-Git $repo @("commit", "-q", "-m", "fixture baseline") | Out-Null
	return $repo
}

function Invoke-BatchInstaller {
	param([Parameter(Mandatory = $true)][string]$Repo)

	$oldErrorActionPreference = $ErrorActionPreference
	try {
		$ErrorActionPreference = "Continue"
		$output = @(& $batchInstaller $Repo 2>&1)
		$exitCode = $LASTEXITCODE
	} finally {
		$ErrorActionPreference = $oldErrorActionPreference
	}
	return [pscustomobject]@{
		ExitCode = $exitCode
		Output = ($output -join [Environment]::NewLine)
	}
}

$gitExe = (Get-Command git -CommandType Application -ErrorAction Stop).Source
$gitBash = Join-Path (Split-Path (Split-Path $gitExe -Parent) -Parent) "bin/bash.exe"
if (-not (Test-Path -LiteralPath $gitBash -PathType Leaf)) {
	throw "Git Bash not found: $gitBash"
}

function Convert-ToGitBashPath {
	param([Parameter(Mandatory = $true)][string]$Path)

	$fullPath = [IO.Path]::GetFullPath($Path)
	if ($fullPath -notmatch "^(?<drive>[A-Za-z]):(?<tail>.*)$") {
		throw "Expected a drive-qualified Windows path: $fullPath"
	}
	return "/" + $Matches.drive.ToLowerInvariant() + ($Matches.tail -replace "\\", "/")
}

$shellInstallerUnix = Convert-ToGitBashPath $shellInstaller
function Invoke-ShellInstaller {
	param([Parameter(Mandatory = $true)][string]$Repo)

	$repoUnix = Convert-ToGitBashPath $Repo
	$oldErrorActionPreference = $ErrorActionPreference
	try {
		$ErrorActionPreference = "Continue"
		$output = @(& $gitBash $shellInstallerUnix $repoUnix 2>&1)
		$exitCode = $LASTEXITCODE
	} finally {
		$ErrorActionPreference = $oldErrorActionPreference
	}
	return [pscustomobject]@{
		ExitCode = $exitCode
		Output = ($output -join [Environment]::NewLine)
	}
}

$segments = $fixtureRoot -split '[\\/]'
if ((Split-Path -Leaf $fixtureRoot) -ne "installer-layout" -or -not ($segments -contains ".agent-work")) {
	throw "Fixture root must be an installer-layout directory under .agent-work: $fixtureRoot"
}
if (Test-Path -LiteralPath $fixtureRoot) {
	Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null

Write-Output "=== tracked product docs are supported ==="
$batchRepo = New-Repo "batch-product"
$shellRepo = New-Repo "shell-product"
$batchProductHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $batchRepo "docs/product/guide.md")).Hash
$shellProductHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $shellRepo "docs/product/guide.md")).Hash
$batchResult = Invoke-BatchInstaller $batchRepo
$shellResult = Invoke-ShellInstaller $shellRepo
if ($batchResult.ExitCode -ne 0) { Write-Host $batchResult.Output }
if ($shellResult.ExitCode -ne 0) { Write-Host $shellResult.Output }
Check "batch installer exit 0" ($batchResult.ExitCode -eq 0)
Check "shell installer exit 0" ($shellResult.ExitCode -eq 0)
Check "batch product doc byte-preserved" (
	(Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $batchRepo "docs/product/guide.md")).Hash -eq $batchProductHash
)
Check "shell product doc byte-preserved" (
	(Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $shellRepo "docs/product/guide.md")).Hash -eq $shellProductHash
)
foreach ($repo in @($batchRepo, $shellRepo)) {
	$ignorePath = Join-Path $repo ".gitignore"
	if (-not (Test-Path -LiteralPath $ignorePath -PathType Leaf)) {
		Check "$(Split-Path -Leaf $repo) created .gitignore" $false
		continue
	}
	$ignoreText = [IO.File]::ReadAllText($ignorePath)
	Check "$(Split-Path -Leaf $repo) has no blanket /docs/" (-not ($ignoreText -match "(?m)^/docs/\r?$"))
	Check "$(Split-Path -Leaf $repo) ignores reserved docs/work" ($ignoreText -match "(?m)^/docs/work/\r?$")
}
foreach ($relative in @("AGENTS.md", "CLAUDE.md", ".gitignore")) {
	$batchPath = Join-Path $batchRepo $relative
	$shellPath = Join-Path $shellRepo $relative
	if (-not (Test-Path -LiteralPath $batchPath -PathType Leaf) -or
		-not (Test-Path -LiteralPath $shellPath -PathType Leaf)) {
		Check "batch and shell agree for $relative" $false
		continue
	}
	$batchBytes = [IO.File]::ReadAllBytes($batchPath)
	$shellBytes = [IO.File]::ReadAllBytes($shellPath)
	Check "batch and shell agree for $relative" (
		@(Compare-Object $batchBytes $shellBytes -SyncWindow 0).Count -eq 0
	)
}

Write-Output "=== tracked policy files require compatible preflight and remain byte-preserved ==="
$batchTracked = New-Repo "batch-tracked-policy"
$shellTracked = New-Repo "shell-tracked-policy"
foreach ($repo in @($batchTracked, $shellTracked)) {
	[IO.File]::WriteAllText(
		(Join-Path $repo "AGENTS.md"),
		"# Repository Guidelines`n`n" + [IO.File]::ReadAllText((Join-Path $packageRoot "AGENTS.branch-docs.md")),
		(New-Object Text.UTF8Encoding $false)
	)
	[IO.File]::WriteAllText((Join-Path $repo "CLAUDE.md"), "@AGENTS.md`n", (New-Object Text.UTF8Encoding $false))
	Copy-Item -LiteralPath (Join-Path $packageRoot ".agent-work.gitignore.block") -Destination (Join-Path $repo ".gitignore")
	Invoke-Git $repo @("add", "-f", "AGENTS.md", "CLAUDE.md", ".gitignore") | Out-Null
	Invoke-Git $repo @("commit", "-q", "-m", "compatible tracked policies") | Out-Null
}
$batchTrackedHashes = @{}
$shellTrackedHashes = @{}
foreach ($relative in @("AGENTS.md", "CLAUDE.md", ".gitignore")) {
	$batchTrackedHashes[$relative] = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $batchTracked $relative)).Hash
	$shellTrackedHashes[$relative] = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $shellTracked $relative)).Hash
}
$batchResult = Invoke-BatchInstaller $batchTracked
$shellResult = Invoke-ShellInstaller $shellTracked
if ($batchResult.ExitCode -ne 0) { Write-Host $batchResult.Output }
if ($shellResult.ExitCode -ne 0) { Write-Host $shellResult.Output }
Check "batch compatible tracked policy installs" ($batchResult.ExitCode -eq 0)
Check "shell compatible tracked policy installs" ($shellResult.ExitCode -eq 0)
foreach ($relative in @("AGENTS.md", "CLAUDE.md", ".gitignore")) {
	Check "batch preserves tracked $relative bytes" (
		(Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $batchTracked $relative)).Hash -eq $batchTrackedHashes[$relative]
	)
	Check "shell preserves tracked $relative bytes" (
		(Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $shellTracked $relative)).Hash -eq $shellTrackedHashes[$relative]
	)
}
Check "batch compatible tracked policy status clean" (
	@((Invoke-Git $batchTracked @("status", "--porcelain=v1"))).Count -eq 0
)
Check "shell compatible tracked policy status clean" (
	@((Invoke-Git $shellTracked @("status", "--porcelain=v1"))).Count -eq 0
)

$batchStaleClaude = New-Repo "batch-stale-claude"
$shellStaleClaude = New-Repo "shell-stale-claude"
foreach ($repo in @($batchStaleClaude, $shellStaleClaude)) {
	[IO.File]::WriteAllText(
		(Join-Path $repo "AGENTS.md"),
		"# Repository Guidelines`n`n" + [IO.File]::ReadAllText((Join-Path $packageRoot "AGENTS.branch-docs.md")),
		(New-Object Text.UTF8Encoding $false)
	)
	[IO.File]::WriteAllText(
		(Join-Path $repo "CLAUDE.md"),
		"@AGENTS.md`n`n<!-- branch-docs-starter:begin -->`nstale adapter`n<!-- branch-docs-starter:end -->`n",
		(New-Object Text.UTF8Encoding $false)
	)
	Copy-Item -LiteralPath (Join-Path $packageRoot ".agent-work.gitignore.block") -Destination (Join-Path $repo ".gitignore")
	Invoke-Git $repo @("add", "-f", "AGENTS.md", "CLAUDE.md", ".gitignore") | Out-Null
	Invoke-Git $repo @("commit", "-q", "-m", "stale tracked claude adapter") | Out-Null
}
$batchStaleClaudeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $batchStaleClaude "CLAUDE.md")).Hash
$shellStaleClaudeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $shellStaleClaude "CLAUDE.md")).Hash
$batchResult = Invoke-BatchInstaller $batchStaleClaude
$shellResult = Invoke-ShellInstaller $shellStaleClaude
Check "batch stale tracked CLAUDE fails despite delegate" (
	$batchResult.ExitCode -ne 0 -and $batchResult.Output -match "CLAUDE.md"
)
Check "shell stale tracked CLAUDE fails despite delegate" (
	$shellResult.ExitCode -ne 0 -and $shellResult.Output -match "CLAUDE.md"
)
Check "batch stale tracked CLAUDE byte-preserved" (
	(Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $batchStaleClaude "CLAUDE.md")).Hash -eq $batchStaleClaudeHash
)
Check "shell stale tracked CLAUDE byte-preserved" (
	(Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $shellStaleClaude "CLAUDE.md")).Hash -eq $shellStaleClaudeHash
)

$batchIncompatiblePolicy = New-Repo "batch-incompatible-policy"
$shellIncompatiblePolicy = New-Repo "shell-incompatible-policy"
foreach ($repo in @($batchIncompatiblePolicy, $shellIncompatiblePolicy)) {
	[IO.File]::WriteAllText((Join-Path $repo "AGENTS.md"), "# Incompatible tracked policy`n")
	[IO.File]::WriteAllText((Join-Path $repo "CLAUDE.md"), "# No delegation`n")
	[IO.File]::WriteAllText((Join-Path $repo ".gitignore"), "build/`n")
	Invoke-Git $repo @("add", "AGENTS.md", "CLAUDE.md", ".gitignore") | Out-Null
	Invoke-Git $repo @("commit", "-q", "-m", "incompatible tracked policies") | Out-Null
}
$batchPolicyStatus = @((Invoke-Git $batchIncompatiblePolicy @("status", "--porcelain=v1")))
$shellPolicyStatus = @((Invoke-Git $shellIncompatiblePolicy @("status", "--porcelain=v1")))
$batchResult = Invoke-BatchInstaller $batchIncompatiblePolicy
$shellResult = Invoke-ShellInstaller $shellIncompatiblePolicy
Check "batch incompatible tracked policy fails before writes" (
	$batchResult.ExitCode -ne 0 -and $batchResult.Output -match "Tracked AGENTS.md"
)
Check "shell incompatible tracked policy fails before writes" (
	$shellResult.ExitCode -ne 0 -and $shellResult.Output -match "Tracked AGENTS.md"
)
Check "batch incompatible policy status preserved" (
	(@((Invoke-Git $batchIncompatiblePolicy @("status", "--porcelain=v1"))) -join "`n") -eq ($batchPolicyStatus -join "`n")
)
Check "shell incompatible policy status preserved" (
	(@((Invoke-Git $shellIncompatiblePolicy @("status", "--porcelain=v1"))) -join "`n") -eq ($shellPolicyStatus -join "`n")
)
Check "batch incompatible policy created no agent-work" (
	-not (Test-Path -LiteralPath (Join-Path $batchIncompatiblePolicy ".agent-work"))
)
Check "shell incompatible policy created no agent-work" (
	-not (Test-Path -LiteralPath (Join-Path $shellIncompatiblePolicy ".agent-work"))
)

Write-Output "=== reserved tracked paths fail before writes ==="
$batchCollision = New-Repo "batch-collision" -ReservedCollision
$shellCollision = New-Repo "shell-collision" -ReservedCollision
$batchResult = Invoke-BatchInstaller $batchCollision
$shellResult = Invoke-ShellInstaller $shellCollision
Check "batch reserved collision fails" ($batchResult.ExitCode -ne 0 -and $batchResult.Output -match "reserved")
Check "shell reserved collision fails" ($shellResult.ExitCode -ne 0 -and $shellResult.Output -match "reserved")
Check "batch collision created no AGENTS" (-not (Test-Path -LiteralPath (Join-Path $batchCollision "AGENTS.md")))
Check "shell collision created no AGENTS" (-not (Test-Path -LiteralPath (Join-Path $shellCollision "AGENTS.md")))

Write-Output "=== reserved paths in another ref fail before writes ==="
$batchHistory = New-Repo "batch-history"
$shellHistory = New-Repo "shell-history"
foreach ($repo in @($batchHistory, $shellHistory)) {
	Invoke-Git $repo @("checkout", "-q", "-b", "reserved-history") | Out-Null
	New-Item -ItemType Directory -Path (Join-Path $repo "docs/work") -Force | Out-Null
	[IO.File]::WriteAllText((Join-Path $repo "docs/work/collision.md"), "collision`n")
	Invoke-Git $repo @("add", "-f", "docs/work/collision.md") | Out-Null
	Invoke-Git $repo @("commit", "-q", "-m", "reserved history collision") | Out-Null
	Invoke-Git $repo @("checkout", "-q", "master") | Out-Null
}
$batchResult = Invoke-BatchInstaller $batchHistory
$shellResult = Invoke-ShellInstaller $shellHistory
Check "batch historical reserved collision fails" ($batchResult.ExitCode -ne 0 -and $batchResult.Output -match "reserved")
Check "shell historical reserved collision fails" ($shellResult.ExitCode -ne 0 -and $shellResult.Output -match "reserved")
Check "batch historical collision created no AGENTS" (-not (Test-Path -LiteralPath (Join-Path $batchHistory "AGENTS.md")))
Check "shell historical collision created no AGENTS" (-not (Test-Path -LiteralPath (Join-Path $shellHistory "AGENTS.md")))

Write-Output "=== linked worktrees reject full installation ==="
$anchor = New-Repo "linked-anchor"
$batchChild = Join-Path $fixtureRoot "linked-batch"
$shellChild = Join-Path $fixtureRoot "linked-shell"
Invoke-Git $anchor @("worktree", "add", "-q", "-b", "installer/batch-linked", $batchChild) | Out-Null
Invoke-Git $anchor @("worktree", "add", "-q", "-b", "installer/shell-linked", $shellChild) | Out-Null
$batchResult = Invoke-BatchInstaller $batchChild
$shellResult = Invoke-ShellInstaller $shellChild
Check "batch linked worktree fails" ($batchResult.ExitCode -ne 0 -and $batchResult.Output -match "linked worktree")
Check "shell linked worktree fails" ($shellResult.ExitCode -ne 0 -and $shellResult.Output -match "linked worktree")
Check "batch linked worktree has no starter AGENTS" (-not (Test-Path -LiteralPath (Join-Path $batchChild "AGENTS.md")))
Check "shell linked worktree has no starter AGENTS" (-not (Test-Path -LiteralPath (Join-Path $shellChild "AGENTS.md")))

Write-Output ""
if ($failures -gt 0) {
	Write-Output "INSTALLER TEST FAILURES: $failures"
	exit $failures
}
Write-Output "ALL INSTALLER TESTS PASSED"
exit 0
