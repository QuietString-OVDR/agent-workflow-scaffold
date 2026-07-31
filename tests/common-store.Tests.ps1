[CmdletBinding()]
param(
	[string]$FixtureRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$packageRoot = Split-Path -Parent $PSScriptRoot
$bootstrap = Join-Path $packageRoot "bootstrap-worktree.ps1"
$unbootstrap = Join-Path $packageRoot "unbootstrap-worktree.ps1"
$migration = Join-Path $packageRoot "migrate-anchorless-store.ps1"
$policyMigration = Join-Path $packageRoot "migrate-orca-worktree-layout.ps1"
$fixtureRoot = if ($FixtureRoot) {
	[IO.Path]::GetFullPath($FixtureRoot)
} else {
	Join-Path $packageRoot ".agent-work/tests/common-store"
}
$script:failures = 0

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

function Invoke-Script {
	param(
		[Parameter(Mandatory = $true)][string]$Script,
		[Parameter(Mandatory = $true)][string[]]$Arguments,
		[switch]$ExpectFailure
	)

	$commandArguments = @(
		"-NoProfile",
		"-NonInteractive",
		"-ExecutionPolicy", "Bypass",
		"-File", $Script
	) + $Arguments
	$oldErrorActionPreference = $ErrorActionPreference
	try {
		$ErrorActionPreference = "Continue"
		$output = @(& powershell.exe @commandArguments 2>&1)
		$exitCode = $LASTEXITCODE
	} finally {
		$ErrorActionPreference = $oldErrorActionPreference
	}
	if ($ExpectFailure) {
		Check "$(Split-Path -Leaf $Script) expected failure" ($exitCode -ne 0)
	} elseif ($exitCode -ne 0) {
		Write-Host ($output -join [Environment]::NewLine)
	}
	return [pscustomobject]@{
		ExitCode = $exitCode
		Output = ($output -join [Environment]::NewLine)
	}
}

function New-CompatibleRepo {
	param([Parameter(Mandatory = $true)][string]$Path)

	New-Item -ItemType Directory -Path $Path -Force | Out-Null
	Invoke-Git $Path @("init", "-q", "-b", "master") | Out-Null
	Invoke-Git $Path @("config", "user.email", "branch-docs-fixture@example.invalid") | Out-Null
	Invoke-Git $Path @("config", "user.name", "Branch Docs Fixture") | Out-Null
	Invoke-Git $Path @("config", "core.autocrlf", "false") | Out-Null
	Invoke-Git $Path @("remote", "add", "origin", "git@github.com:overdare/client-app.git") | Out-Null

	$agents = "# Repository Guidelines`n`n" + [IO.File]::ReadAllText((Join-Path $packageRoot "AGENTS.branch-docs.md"))
	[IO.File]::WriteAllText((Join-Path $Path "AGENTS.md"), $agents, [Text.UTF8Encoding]::new($false))
	[IO.File]::WriteAllText((Join-Path $Path "CLAUDE.md"), "@AGENTS.md`n", [Text.UTF8Encoding]::new($false))
	[IO.File]::WriteAllText((Join-Path $Path ".gitignore"), "build/`n", [Text.UTF8Encoding]::new($false))
	[IO.File]::WriteAllText((Join-Path $Path "README.md"), "fixture`n", [Text.UTF8Encoding]::new($false))
	Invoke-Git $Path @("add", ".") | Out-Null
	Invoke-Git $Path @("commit", "-q", "-m", "fixture baseline") | Out-Null
	return $Path
}

function Test-ExactJunction {
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)][string]$Target
	)

	$item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
	if (-not $item -or $item.LinkType -ne "Junction") {
		return $false
	}
	$targets = @($item.Target)
	if ($targets.Count -ne 1 -or -not $targets[0]) {
		return $false
	}
	$actual = [IO.Path]::GetFullPath([string]$targets[0]).TrimEnd('\', '/')
	$expected = [IO.Path]::GetFullPath($Target).TrimEnd('\', '/')
	return [string]::Equals($actual, $expected, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-CommonProjection {
	param(
		[Parameter(Mandatory = $true)][string]$Worktree,
		[Parameter(Mandatory = $true)][string]$CommonDir,
		[Parameter(Mandatory = $true)][string]$Label
	)

	foreach ($name in @("branches", "index", "work")) {
		Check "$Label projects docs/$name to common store" (
			Test-ExactJunction `
				(Join-Path $Worktree "docs/$name") `
				(Join-Path $CommonDir "branch-docs-starter/store/$name")
		)
	}
}

if (Test-Path -LiteralPath $fixtureRoot) {
	$resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
	$segments = $resolvedFixture -split '[\\/]'
	if ((Split-Path -Leaf $resolvedFixture) -ne "common-store" -or
		-not ($segments -contains ".agent-work")) {
		throw "Fixture cleanup target must be a common-store directory under .agent-work: $resolvedFixture"
	}
	Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null

Write-Output "=== schema-v2 common store in a regular main worktree ==="
$commonMain = New-CompatibleRepo (Join-Path $fixtureRoot "common-main")
$result = Invoke-Script $bootstrap @("-TargetRepo", $commonMain, "-CommonStore")
Check "initial common-store bootstrap exits 0" ($result.ExitCode -eq 0)
$commonDir = [IO.Path]::GetFullPath([string](Invoke-Git $commonMain @("rev-parse", "--path-format=absolute", "--git-common-dir")))
$manifestPath = Join-Path $commonDir "branch-docs-starter/manifest.json"
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
Check "initial manifest is schema v2" ([int]$manifest.schemaVersion -eq 2)
Check "initial manifest contains no anchor path" (-not $manifest.PSObject.Properties["anchorRepoRoot"])
Assert-CommonProjection $commonMain $commonDir "main"

$commonChild = Join-Path $fixtureRoot "common-child"
Invoke-Git $commonMain @("worktree", "add", "-q", "-b", "feature/common-child", $commonChild) | Out-Null
$result = Invoke-Script $bootstrap @("-TargetRepo", $commonChild, "-CommonStore")
Check "child common-store bootstrap exits 0" ($result.ExitCode -eq 0)
Assert-CommonProjection $commonChild $commonDir "child"
$result = Invoke-Script (Join-Path $commonChild "docs/init-branch-docs.ps1") @(
	"-BranchName", "feature/OVDR-123-common-child",
	"-WorkKey", "OVDR-123",
	"-Summary", "Fixture common-store work"
)
Check "schema-v2 initializer exits 0" ($result.ExitCode -eq 0)
Check "schema-v2 initializer creates canonical work root" (
	Test-Path -LiteralPath (Join-Path $commonDir "branch-docs-starter/store/work/OVDR-123") -PathType Container
)
Check "schema-v2 initializer creates compatibility junction" (
	Test-ExactJunction `
		(Join-Path $commonDir "branch-docs-starter/store/branches/feature~OVDR-123-common-child") `
		(Join-Path $commonDir "branch-docs-starter/store/work/OVDR-123")
)
$result = Invoke-Script $unbootstrap @("-TargetRepo", $commonChild, "-CommonStore")
Check "schema-v2 child unbootstrap exits 0" ($result.ExitCode -eq 0)
Check "schema-v2 child unbootstrap preserves common store" (
	Test-Path -LiteralPath (Join-Path $commonDir "branch-docs-starter/store/work/OVDR-123") -PathType Container
)
$result = Invoke-Script $bootstrap @("-TargetRepo", $commonChild, "-CommonStore")
Check "schema-v2 child rebootstrap exits 0" ($result.ExitCode -eq 0)

Write-Output "=== bare common directory with direct child worktrees ==="
$bareSource = New-CompatibleRepo (Join-Path $fixtureRoot "bare-source")
$bareRoot = Join-Path $fixtureRoot "bare-client-app"
& git clone --bare --quiet $bareSource $bareRoot
if ($LASTEXITCODE -ne 0) {
	throw "git clone --bare failed."
}
$bareMaster = Join-Path $bareRoot "master"
$bareIteration = Join-Path $bareRoot "unreal-iteration"
Invoke-Git $bareRoot @("worktree", "add", "-q", $bareMaster, "master") | Out-Null
Invoke-Git $bareRoot @("worktree", "add", "-q", "-b", "unreal/local-iteration", $bareIteration, "master") | Out-Null
$result = Invoke-Script $bootstrap @("-TargetRepo", $bareMaster, "-CommonStore")
Check "bare master bootstrap exits 0" ($result.ExitCode -eq 0)
$result = Invoke-Script $bootstrap @("-TargetRepo", $bareIteration, "-CommonStore")
Check "bare iteration bootstrap exits 0" ($result.ExitCode -eq 0)
Assert-CommonProjection $bareMaster $bareRoot "bare master"
Assert-CommonProjection $bareIteration $bareRoot "bare iteration"
$bareManifest = Get-Content -Raw -LiteralPath (Join-Path $bareRoot "branch-docs-starter/manifest.json") | ConvertFrom-Json
Check "bare manifest uses relative store identity" (
	$bareManifest.storeRelativePath -ceq "branch-docs-starter/store" -and
		-not $bareManifest.PSObject.Properties["commonDir"]
)
$result = Invoke-Script $policyMigration @("-TargetRepo", $bareIteration)
Check "schema-v2 linked worktree supports tracked-policy migration dry-run" ($result.ExitCode -eq 0)

Write-Output "=== schema-v1 anchor migration preserves data and internal junctions ==="
$legacyMain = New-CompatibleRepo (Join-Path $fixtureRoot "legacy-main")
$legacyChild = Join-Path $fixtureRoot "legacy-child"
Invoke-Git $legacyMain @("worktree", "add", "-q", "-b", "feature/OVDR-456-legacy", $legacyChild) | Out-Null
$result = Invoke-Script $bootstrap @("-TargetRepo", $legacyMain, "-AnchorRepo", $legacyMain)
Check "legacy anchor bootstrap exits 0" ($result.ExitCode -eq 0)
$result = Invoke-Script $bootstrap @("-TargetRepo", $legacyChild, "-AnchorRepo", $legacyMain)
Check "legacy child bootstrap exits 0" ($result.ExitCode -eq 0)
$result = Invoke-Script (Join-Path $legacyChild "docs/init-branch-docs.ps1") @(
	"-BranchName", "feature/OVDR-456-legacy",
	"-WorkKey", "OVDR-456",
	"-Summary", "Fixture legacy migration"
)
Check "legacy initializer exits 0" ($result.ExitCode -eq 0)
$legacyCommonDir = [IO.Path]::GetFullPath([string](Invoke-Git $legacyMain @("rev-parse", "--path-format=absolute", "--git-common-dir")))
$result = Invoke-Script $migration @("-AnchorRepo", $legacyMain)
Check "migration dry-run exits 0" ($result.ExitCode -eq 0)
Check "migration dry-run leaves schema v1" (
	[int]((Get-Content -Raw -LiteralPath (Join-Path $legacyCommonDir "branch-docs-starter/manifest.json") | ConvertFrom-Json).schemaVersion) -eq 1
)
$migrationBackup = Join-Path $fixtureRoot "legacy-migration-backup"
$result = Invoke-Script $migration @("-AnchorRepo", $legacyMain, "-Apply", "-BackupRoot", $migrationBackup)
Check "migration apply exits 0" ($result.ExitCode -eq 0)
if ($result.ExitCode -ne 0) {
	Write-Output $result.Output
}
$migratedManifest = Get-Content -Raw -LiteralPath (Join-Path $legacyCommonDir "branch-docs-starter/manifest.json") | ConvertFrom-Json
Check "migration writes schema v2" ([int]$migratedManifest.schemaVersion -eq 2)
Check "migration backup retains v1 manifest" (
	[int]((Get-Content -Raw -LiteralPath (Join-Path $migrationBackup "manifest-v1.json") | ConvertFrom-Json).schemaVersion) -eq 1
)
Assert-CommonProjection $legacyMain $legacyCommonDir "migrated main"
Assert-CommonProjection $legacyChild $legacyCommonDir "migrated child"
Check "migration preserves canonical work document" (
	Test-Path -LiteralPath (Join-Path $legacyCommonDir "branch-docs-starter/store/work/OVDR-456/README.md") -PathType Leaf
)
Check "migration retargets internal compatibility junction" (
	Test-ExactJunction `
		(Join-Path $legacyCommonDir "branch-docs-starter/store/branches/feature~OVDR-456-legacy") `
		(Join-Path $legacyCommonDir "branch-docs-starter/store/work/OVDR-456")
)
$result = Invoke-Script $bootstrap @("-TargetRepo", $legacyChild, "-VerifyOnly")
Check "auto-detected schema-v2 verification exits 0" ($result.ExitCode -eq 0)

Write-Output "=== schema-v2 manifest tampering is fail-closed ==="
$migratedManifestPath = Join-Path $legacyCommonDir "branch-docs-starter/manifest.json"
$migratedManifestText = [IO.File]::ReadAllText($migratedManifestPath)
$tampered = $migratedManifestText | ConvertFrom-Json
$tampered.storeRelativePath = "unexpected/store"
[IO.File]::WriteAllText(
	$migratedManifestPath,
	(($tampered | ConvertTo-Json -Depth 12) + "`n"),
	[Text.UTF8Encoding]::new($false)
)
$result = Invoke-Script $bootstrap @("-TargetRepo", $legacyChild) -ExpectFailure
Check "tampered schema-v2 store path is explained" ($result.Output -match "storeRelativePath|store path")
[IO.File]::WriteAllText($migratedManifestPath, $migratedManifestText, [Text.UTF8Encoding]::new($false))

Write-Output ""
if ($script:failures -gt 0) {
	Write-Output "COMMON-STORE TEST FAILURES: $script:failures"
	exit $script:failures
}
Write-Output "ALL COMMON-STORE TESTS PASSED"
exit 0
