[CmdletBinding()]
param(
	[string]$FixtureRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$packageRoot = Split-Path -Parent $PSScriptRoot
$bootstrap = Join-Path $packageRoot "bootstrap-worktree.ps1"
$unbootstrap = Join-Path $packageRoot "unbootstrap-worktree.ps1"
$migration = Join-Path $packageRoot "migrate-orca-worktree-layout.ps1"
$fixtureRoot = if ($FixtureRoot) {
	[IO.Path]::GetFullPath($FixtureRoot)
} else {
	Join-Path $packageRoot ".agent-work/tests/orca-worktree-bootstrap"
}
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

function New-TestRepo {
	param(
		[Parameter(Mandatory = $true)][string]$Name,
		[switch]$CompatibleInstructions,
		[switch]$TrackedProductDocs,
		[switch]$BlanketIgnore
	)

	$repo = Join-Path $fixtureRoot $Name
	New-Item -ItemType Directory -Path $repo -Force | Out-Null
	Invoke-Git $repo @("init", "-q") | Out-Null
	Invoke-Git $repo @("config", "user.email", "branch-docs-fixture@example.invalid") | Out-Null
	Invoke-Git $repo @("config", "user.name", "Branch Docs Fixture") | Out-Null
	Invoke-Git $repo @("config", "core.autocrlf", "false") | Out-Null

	if ($TrackedProductDocs) {
		New-Item -ItemType Directory -Path (Join-Path $repo "docs/product") -Force | Out-Null
		[IO.File]::WriteAllText(
			(Join-Path $repo "docs/product/guide.md"),
			"product-doc`n",
			(New-Object Text.UTF8Encoding $false)
		)
	}

	if ($CompatibleInstructions) {
		$agents = "# Repository Guidelines`n`n" + [IO.File]::ReadAllText((Join-Path $packageRoot "AGENTS.branch-docs.md"))
		[IO.File]::WriteAllText((Join-Path $repo "AGENTS.md"), $agents, (New-Object Text.UTF8Encoding $false))
		[IO.File]::WriteAllText((Join-Path $repo "CLAUDE.md"), "@AGENTS.md`n", (New-Object Text.UTF8Encoding $false))
		New-Item -ItemType Directory -Path (Join-Path $repo ".codex") -Force | Out-Null
		Copy-Item -LiteralPath (Join-Path $packageRoot ".codex/config.toml") -Destination (Join-Path $repo ".codex/config.toml")
	} else {
		[IO.File]::WriteAllText((Join-Path $repo "AGENTS.md"), "# Repository Guidelines`n`nNo starter compatibility block.`n")
		[IO.File]::WriteAllText((Join-Path $repo "CLAUDE.md"), "@AGENTS.md`n")
	}

	if ($BlanketIgnore) {
		[IO.File]::WriteAllText(
			(Join-Path $repo ".gitignore"),
			"# branch-docs-starter:begin`n/docs/`n/.codex/`n# branch-docs-starter:end`n",
			(New-Object Text.UTF8Encoding $false)
		)
	} else {
		[IO.File]::WriteAllText((Join-Path $repo ".gitignore"), "build/`n", (New-Object Text.UTF8Encoding $false))
	}

	Invoke-Git $repo @("add", ".") | Out-Null
	if ($TrackedProductDocs) {
		Invoke-Git $repo @("add", "-f", "docs/product/guide.md") | Out-Null
	}
	Invoke-Git $repo @("commit", "-q", "-m", "fixture baseline") | Out-Null
	return $repo
}

function Invoke-Bootstrap {
	param(
		[Parameter(Mandatory = $true)][string]$Target,
		[Parameter(Mandatory = $true)][string]$Anchor,
		[switch]$ExpectFailure,
		[string[]]$ExtraArguments = @()
	)

	$arguments = @(
		"-NoProfile",
		"-NonInteractive",
		"-ExecutionPolicy", "Bypass",
		"-File", $bootstrap,
		"-TargetRepo", $Target,
		"-AnchorRepo", $Anchor
	) + $ExtraArguments
	$oldErrorActionPreference = $ErrorActionPreference
	try {
		$ErrorActionPreference = "Continue"
		$output = @(& powershell.exe @arguments 2>&1)
		$exitCode = $LASTEXITCODE
	} finally {
		$ErrorActionPreference = $oldErrorActionPreference
	}
	if ($ExpectFailure) {
		Check "bootstrap expected failure for $(Split-Path -Leaf $Target)" ($exitCode -ne 0)
	} else {
		if ($exitCode -ne 0) {
			Write-Output ($output -join [Environment]::NewLine)
		}
		Check "bootstrap exit 0 for $(Split-Path -Leaf $Target)" ($exitCode -eq 0)
	}
	return [pscustomobject]@{
		ExitCode = $exitCode
		Output = ($output -join [Environment]::NewLine)
	}
}

function Invoke-Initializer {
	param(
		[Parameter(Mandatory = $true)][string]$Repo,
		[Parameter(Mandatory = $true)][string[]]$Arguments,
		[switch]$ExpectFailure
	)

	$commandArguments = @(
		"-NoProfile",
		"-NonInteractive",
		"-ExecutionPolicy", "Bypass",
		"-File", (Join-Path $Repo "docs/init-branch-docs.ps1")
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
		Check "initializer expected failure for $(Split-Path -Leaf $Repo)" ($exitCode -ne 0)
	} else {
		if ($exitCode -ne 0) {
			Write-Output ($output -join [Environment]::NewLine)
		}
		Check "initializer exit 0 for $(Split-Path -Leaf $Repo)" ($exitCode -eq 0)
	}
	return [pscustomobject]@{
		ExitCode = $exitCode
		Output = ($output -join [Environment]::NewLine)
	}
}

function Invoke-Migration {
	param(
		[Parameter(Mandatory = $true)][string]$Repo,
		[Parameter(Mandatory = $true)][string[]]$Arguments,
		[switch]$ExpectFailure
	)

	$commandArguments = @(
		"-NoProfile",
		"-NonInteractive",
		"-ExecutionPolicy", "Bypass",
		"-File", $migration,
		"-TargetRepo", $Repo
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
		Check "migration expected failure for $(Split-Path -Leaf $Repo)" ($exitCode -ne 0)
	} else {
		if ($exitCode -ne 0) {
			Write-Output ($output -join [Environment]::NewLine)
		}
		Check "migration exit 0 for $(Split-Path -Leaf $Repo)" ($exitCode -eq 0)
	}
	return [pscustomobject]@{
		ExitCode = $exitCode
		Output = ($output -join [Environment]::NewLine)
	}
}

function Get-FileHashText {
	param([Parameter(Mandatory = $true)][string]$Path)

	return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

function Test-GitPathClean {
	param(
		[Parameter(Mandatory = $true)][string]$Repo,
		[Parameter(Mandatory = $true)][string]$Path
	)

	& git -C $Repo diff --quiet -- $Path
	return $LASTEXITCODE -eq 0
}

function Test-PhysicalDirectory {
	param([Parameter(Mandatory = $true)][string]$Path)

	$item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
	return $item -and $item -is [IO.DirectoryInfo] -and
		(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)
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
	$actual = [IO.Path]::GetFullPath(@($item.Target)[0]).TrimEnd('\', '/')
	$expected = [IO.Path]::GetFullPath($Target).TrimEnd('\', '/')
	return [string]::Equals($actual, $expected, [StringComparison]::OrdinalIgnoreCase)
}

if (Test-Path -LiteralPath $fixtureRoot) {
	$resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
	$segments = $resolvedFixture -split '[\\/]'
	if ((Split-Path -Leaf $resolvedFixture) -ne "orca-worktree-bootstrap" -or
		-not ($segments -contains ".agent-work")) {
		throw "Fixture cleanup target must be an orca-worktree-bootstrap directory under .agent-work: $resolvedFixture"
	}
	Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null

Write-Output "=== incompatible tracked instruction is fail-closed ==="
$incompatible = New-TestRepo "incompatible" -TrackedProductDocs
$beforeStatus = (Invoke-Git $incompatible @("status", "--porcelain=v1")) -join "`n"
$beforeAgents = Get-FileHashText (Join-Path $incompatible "AGENTS.md")
$result = Invoke-Bootstrap $incompatible $incompatible -ExpectFailure
Check "failure explains tracked AGENTS compatibility" ($result.Output -match "Tracked AGENTS.md")
Check "incompatible status unchanged" (((Invoke-Git $incompatible @("status", "--porcelain=v1")) -join "`n") -eq $beforeStatus)
Check "incompatible AGENTS byte-preserved" ((Get-FileHashText (Join-Path $incompatible "AGENTS.md")) -eq $beforeAgents)
Check "incompatible bootstrap created no reserved store" (-not (Test-Path -LiteralPath (Join-Path $incompatible "docs/work")))

Write-Output "=== stale and reversed tracked instruction blocks are fail-closed ==="
$staleInstructions = New-TestRepo "stale-instructions" -CompatibleInstructions -TrackedProductDocs
[IO.File]::WriteAllText(
	(Join-Path $staleInstructions "AGENTS.md"),
	"# Repository Guidelines`n`n<!-- branch-docs-starter:begin -->`nstale policy`n<!-- branch-docs-starter:end -->`n",
	(New-Object Text.UTF8Encoding $false)
)
Invoke-Git $staleInstructions @("add", "AGENTS.md") | Out-Null
Invoke-Git $staleInstructions @("commit", "-q", "-m", "stale instruction block") | Out-Null
$result = Invoke-Bootstrap $staleInstructions $staleInstructions -ExpectFailure
Check "stale tracked AGENTS block is rejected" ($result.Output -match "exact current")
Check "stale tracked AGENTS creates no reserved store" (-not (Test-Path -LiteralPath (Join-Path $staleInstructions "docs/work")))

$reversedInstructions = New-TestRepo "reversed-instructions" -CompatibleInstructions -TrackedProductDocs
[IO.File]::WriteAllText(
	(Join-Path $reversedInstructions "AGENTS.md"),
	"# Repository Guidelines`n`n<!-- branch-docs-starter:end -->`npolicy`n<!-- branch-docs-starter:begin -->`n",
	(New-Object Text.UTF8Encoding $false)
)
Invoke-Git $reversedInstructions @("add", "AGENTS.md") | Out-Null
Invoke-Git $reversedInstructions @("commit", "-q", "-m", "reversed instruction markers") | Out-Null
$result = Invoke-Bootstrap $reversedInstructions $reversedInstructions -ExpectFailure
Check "reversed tracked AGENTS markers are rejected" ($result.Output -match "exact current")
Check "reversed tracked AGENTS creates no reserved store" (-not (Test-Path -LiteralPath (Join-Path $reversedInstructions "docs/work")))

$staleClaude = New-TestRepo "stale-claude" -CompatibleInstructions -TrackedProductDocs
[IO.File]::WriteAllText(
	(Join-Path $staleClaude "CLAUDE.md"),
	"@AGENTS.md`n`n<!-- branch-docs-starter:begin -->`nstale adapter`n<!-- branch-docs-starter:end -->`n",
	(New-Object Text.UTF8Encoding $false)
)
Invoke-Git $staleClaude @("add", "CLAUDE.md") | Out-Null
Invoke-Git $staleClaude @("commit", "-q", "-m", "stale claude block with delegate") | Out-Null
$result = Invoke-Bootstrap $staleClaude $staleClaude -ExpectFailure
Check "stale CLAUDE block is rejected even with delegate" ($result.Output -match "exact current")
$staleClaudeBackup = Join-Path $fixtureRoot "stale-claude-migration-backup"
$result = Invoke-Migration $staleClaude @(
	"-Apply",
	"-AllowTrackedPolicyChanges",
	"-InstallTrackedInstructions",
	"-BackupRoot", $staleClaudeBackup
)
Check "stale CLAUDE block can be explicitly migrated" ($result.ExitCode -eq 0)
Check "stale CLAUDE migration installs exact block" (
	[IO.File]::ReadAllText((Join-Path $staleClaude "CLAUDE.md")) -match [regex]::Escape(
		[IO.File]::ReadAllText((Join-Path $packageRoot "CLAUDE.branch-docs.md")).TrimEnd()
	)
)

Write-Output "=== blanket ignore is fail-closed ==="
$blanket = New-TestRepo "blanket" -CompatibleInstructions -TrackedProductDocs -BlanketIgnore
$beforeIgnore = Get-FileHashText (Join-Path $blanket ".gitignore")
$result = Invoke-Bootstrap $blanket $blanket -ExpectFailure
Check "failure explains blanket ignore" ($result.Output -match "Blanket ignore pattern")
Check "blanket ignore byte-preserved" ((Get-FileHashText (Join-Path $blanket ".gitignore")) -eq $beforeIgnore)
Check "blanket bootstrap created no reserved store" (-not (Test-Path -LiteralPath (Join-Path $blanket "docs/work")))

Write-Output "=== tracked policy migration is explicit and backed up ==="
$migrationRepo = New-TestRepo "migration" -CompatibleInstructions -TrackedProductDocs -BlanketIgnore
$migrationStatus = (Invoke-Git $migrationRepo @("status", "--porcelain=v1")) -join "`n"
$migrationIgnoreHash = Get-FileHashText (Join-Path $migrationRepo ".gitignore")
$result = Invoke-Migration $migrationRepo @("-NormalizeGitIgnore")
Check "migration dry run reports normalize action" ($result.Output -match "normalize-gitignore")
Check "migration dry run leaves status unchanged" (
	((Invoke-Git $migrationRepo @("status", "--porcelain=v1")) -join "`n") -eq $migrationStatus
)
Check "migration dry run byte-preserves gitignore" (
	(Get-FileHashText (Join-Path $migrationRepo ".gitignore")) -eq $migrationIgnoreHash
)
$result = Invoke-Migration $migrationRepo @("-Apply", "-NormalizeGitIgnore") -ExpectFailure
Check "tracked migration requires explicit authorization" ($result.Output -match "AllowTrackedPolicyChanges")
Check "unauthorized migration created no lifecycle state" (
	-not (Test-Path -LiteralPath (Join-Path $migrationRepo ".git/branch-docs-starter"))
)
$migrationBackup = Join-Path $fixtureRoot "migration-backup"
$result = Invoke-Migration $migrationRepo @(
	"-Apply",
	"-AllowTrackedPolicyChanges",
	"-NormalizeGitIgnore",
	"-BackupRoot", $migrationBackup
)
Check "migration backup manifest exists" (Test-Path -LiteralPath (Join-Path $migrationBackup "migration-backup.json") -PathType Leaf)
Check "migration backup contains original gitignore" (
	(Get-FileHashText (Join-Path $migrationBackup ".gitignore")) -eq $migrationIgnoreHash
)
$result = Invoke-Bootstrap $migrationRepo $migrationRepo -ExpectFailure
Check "bootstrap rejects uncommitted tracked ignore migration" ($result.Output -match "differs from the index")
Invoke-Git $migrationRepo @("add", ".gitignore") | Out-Null
Invoke-Git $migrationRepo @("commit", "-q", "-m", "normalize ignore policy") | Out-Null
Invoke-Bootstrap $migrationRepo $migrationRepo | Out-Null
Check "committed migrated policy bootstraps cleanly" (
	((Invoke-Git $migrationRepo @("status", "--porcelain=v1")) -join "`n") -eq ""
)
$malformedMigrationRepo = New-TestRepo "migration-malformed" -CompatibleInstructions -TrackedProductDocs
[IO.File]::WriteAllText(
	(Join-Path $malformedMigrationRepo ".gitignore"),
	"# branch-docs-starter:end`n",
	(New-Object Text.UTF8Encoding $false)
)
Invoke-Git $malformedMigrationRepo @("add", ".gitignore") | Out-Null
Invoke-Git $malformedMigrationRepo @("commit", "-q", "-m", "malformed marker") | Out-Null
$malformedBackup = Join-Path $fixtureRoot "malformed-migration-backup"
$result = Invoke-Migration $malformedMigrationRepo @(
	"-Apply",
	"-AllowTrackedPolicyChanges",
	"-NormalizeGitIgnore",
	"-BackupRoot", $malformedBackup
) -ExpectFailure
Check "malformed migration marker fails closed" ($result.Output -match "Malformed|Reversed|unmatched")
Check "malformed migration creates no backup" (-not (Test-Path -LiteralPath $malformedBackup))
Check "malformed migration creates no lifecycle state" (
	-not (Test-Path -LiteralPath (Join-Path $malformedMigrationRepo ".git/branch-docs-starter"))
)

$duplicateMigrationRepo = New-TestRepo "migration-duplicate" -CompatibleInstructions -TrackedProductDocs
$ignoreBlock = [IO.File]::ReadAllText((Join-Path $packageRoot ".agent-work.gitignore.block"))
[IO.File]::WriteAllText(
	(Join-Path $duplicateMigrationRepo ".gitignore"),
	"build/`n/docs/`n$ignoreBlock`n$ignoreBlock",
	(New-Object Text.UTF8Encoding $false)
)
Invoke-Git $duplicateMigrationRepo @("add", ".gitignore") | Out-Null
Invoke-Git $duplicateMigrationRepo @("commit", "-q", "-m", "duplicate ignore blocks") | Out-Null
$duplicateBackup = Join-Path $fixtureRoot "duplicate-migration-backup"
$result = Invoke-Migration $duplicateMigrationRepo @(
	"-Apply",
	"-AllowTrackedPolicyChanges",
	"-NormalizeGitIgnore",
	"-BackupRoot", $duplicateBackup
)
Check "duplicate ignore blocks normalize successfully" ($result.ExitCode -eq 0)
$normalizedIgnoreLines = @([IO.File]::ReadAllLines((Join-Path $duplicateMigrationRepo ".gitignore")))
Check "duplicate migration leaves one begin marker" (
	@($normalizedIgnoreLines | Where-Object { $_ -ceq "# branch-docs-starter:begin" }).Count -eq 1
)
Check "duplicate migration leaves one end marker" (
	@($normalizedIgnoreLines | Where-Object { $_ -ceq "# branch-docs-starter:end" }).Count -eq 1
)
Check "duplicate migration removes outside blanket rule" (
	@($normalizedIgnoreLines | Where-Object { $_.Trim() -in @("/docs/", "docs/", "/.codex/", ".codex/") }).Count -eq 0
)

Write-Output "=== per-worktree reparse roots fail before writes ==="
$reparseRepo = New-TestRepo "reparse-root" -CompatibleInstructions -TrackedProductDocs
$reparseTarget = Join-Path $fixtureRoot "reparse-agent-work-target"
New-Item -ItemType Directory -Path $reparseTarget -Force | Out-Null
$reparseSentinel = Join-Path $reparseTarget "sentinel.md"
[IO.File]::WriteAllText($reparseSentinel, "keep`n")
New-Item -ItemType Junction -Path (Join-Path $reparseRepo ".agent-work") -Target $reparseTarget | Out-Null
$result = Invoke-Bootstrap $reparseRepo $reparseRepo -ExpectFailure
Check "reparse .agent-work failure is explained" ($result.Output -match "physical non-reparse")
Check "reparse target sentinel preserved" (Test-Path -LiteralPath $reparseSentinel -PathType Leaf)
Check "reparse bootstrap created no reserved store" (-not (Test-Path -LiteralPath (Join-Path $reparseRepo "docs/work")))
& cmd.exe /d /c rmdir "`"$(Join-Path $reparseRepo '.agent-work')`"" | Out-Null
Check "test reparse leaf cleanup exit 0" ($LASTEXITCODE -eq 0)

Write-Output "=== anchor and child projection ==="
$anchor = New-TestRepo "anchor" -CompatibleInstructions -TrackedProductDocs
$agentsHash = Get-FileHashText (Join-Path $anchor "AGENTS.md")
$claudeHash = Get-FileHashText (Join-Path $anchor "CLAUDE.md")
$configHash = Get-FileHashText (Join-Path $anchor ".codex/config.toml")
Invoke-Bootstrap $anchor $anchor | Out-Null

Check "anchor docs is physical" (Test-PhysicalDirectory (Join-Path $anchor "docs"))
foreach ($name in @("branches", "index", "work")) {
	Check "anchor docs/$name is physical" (Test-PhysicalDirectory (Join-Path $anchor "docs/$name"))
}
Check "anchor tracked AGENTS preserved" ((Get-FileHashText (Join-Path $anchor "AGENTS.md")) -eq $agentsHash)
Check "anchor tracked CLAUDE preserved" ((Get-FileHashText (Join-Path $anchor "CLAUDE.md")) -eq $claudeHash)
Check "anchor tracked config preserved" ((Get-FileHashText (Join-Path $anchor ".codex/config.toml")) -eq $configHash)
Check "anchor tracked product doc preserved" (Test-GitPathClean $anchor "docs/product/guide.md")

Write-Output "=== verified commit transition inputs ==="
$anchorHead = (Invoke-Git $anchor @("rev-parse", "HEAD") | Select-Object -First 1)
$result = Invoke-Bootstrap $anchor $anchor -ExtraArguments @("-VerifyOnly", "-CandidateRef", "HEAD")
Check "candidate verification returns full OID" ($result.Output -match "candidateOid=$anchorHead")
$result = Invoke-Bootstrap $anchor $anchor -ExtraArguments @("-VerifyOnly", "-ExpectedHeadOid", $anchorHead)
Check "expected HEAD OID passes" ($result.ExitCode -eq 0)
$result = Invoke-Bootstrap $anchor $anchor -ExpectFailure -ExtraArguments @("-VerifyOnly", "-ExpectedHeadOid", ("0" * 40))
Check "wrong expected HEAD OID fails closed" ($result.Output -match "HEAD OID mismatch")

Invoke-Git $anchor @("checkout", "-q", "-b", "candidate/remove-codex") | Out-Null
Invoke-Git $anchor @("rm", "-q", ".codex/config.toml") | Out-Null
Invoke-Git $anchor @("commit", "-q", "-m", "remove tracked codex config") | Out-Null
Invoke-Git $anchor @("checkout", "-q", "master") | Out-Null
$result = Invoke-Bootstrap $anchor $anchor -ExpectFailure -ExtraArguments @(
	"-VerifyOnly",
	"-CandidateRef", "candidate/remove-codex"
)
Check "candidate removal of tracked codex config fails" ($result.Output -match "removes tracked .codex/config.toml")

[IO.File]::AppendAllText((Join-Path $anchor ".gitignore"), "approved-ignore-rule/`n")
Invoke-Git $anchor @("add", ".gitignore") | Out-Null
Invoke-Git $anchor @("commit", "-q", "-m", "reviewed ignore policy change") | Out-Null
$approvedHead = (Invoke-Git $anchor @("rev-parse", "HEAD") | Select-Object -First 1)
$result = Invoke-Bootstrap $anchor $anchor -ExpectFailure -ExtraArguments @("-VerifyOnly")
Check "changed current ignore fingerprint requires approval" ($result.Output -match "fingerprint is not approved")
$approvalBackup = Join-Path $fixtureRoot "ignore-policy-approval-backup"
$result = Invoke-Bootstrap $anchor $anchor -ExtraArguments @(
	"-ApproveCurrentIgnorePolicy",
	"-ExpectedHeadOid", $approvedHead,
	"-ApprovalBackupRoot", $approvalBackup
)
Check "explicit ignore fingerprint approval succeeds" ($result.ExitCode -eq 0)
Check "ignore fingerprint approval backs up prior manifest" (
	Test-Path -LiteralPath (Join-Path $approvalBackup "manifest.json") -PathType Leaf
)
$result = Invoke-Bootstrap $anchor $anchor -ExtraArguments @("-VerifyOnly")
Check "approved current ignore fingerprint verifies" ($result.ExitCode -eq 0)
$manifestPath = Join-Path ((Invoke-Git $anchor @("rev-parse", "--path-format=absolute", "--git-common-dir") | Select-Object -First 1)) "branch-docs-starter/manifest.json"
$approvedBeforeRerun = @(([IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json).approvedIgnoreFingerprints)
Invoke-Bootstrap $anchor $anchor | Out-Null
$approvedAfterRerun = @(([IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json).approvedIgnoreFingerprints)
Check "anchor rerun preserves all approved ignore fingerprints" (
	$approvedBeforeRerun.Count -eq $approvedAfterRerun.Count -and
		@($approvedBeforeRerun | Where-Object { $approvedAfterRerun -notcontains $_ }).Count -eq 0
)

$complexIgnoreAnchor = New-TestRepo "complex-ignore-anchor" -CompatibleInstructions -TrackedProductDocs
Invoke-Bootstrap $complexIgnoreAnchor $complexIgnoreAnchor | Out-Null
$complexCommon = (Invoke-Git $complexIgnoreAnchor @("rev-parse", "--path-format=absolute", "--git-common-dir") | Select-Object -First 1)
$complexManifestPath = Join-Path $complexCommon "branch-docs-starter/manifest.json"
$complexManifestHash = Get-FileHashText $complexManifestPath
[IO.File]::AppendAllText((Join-Path $complexIgnoreAnchor ".gitignore"), "/docs/**`n")
Invoke-Git $complexIgnoreAnchor @("add", ".gitignore") | Out-Null
Invoke-Git $complexIgnoreAnchor @("commit", "-q", "-m", "complex broad docs ignore") | Out-Null
$complexHead = (Invoke-Git $complexIgnoreAnchor @("rev-parse", "HEAD") | Select-Object -First 1)
$complexBackup = Join-Path $fixtureRoot "complex-ignore-approval-backup"
$result = Invoke-Bootstrap $complexIgnoreAnchor $complexIgnoreAnchor -ExpectFailure -ExtraArguments @(
	"-ApproveCurrentIgnorePolicy",
	"-ExpectedHeadOid", $complexHead,
	"-ApprovalBackupRoot", $complexBackup
)
Check "complex broad docs ignore cannot be approved" ($result.Output -match "Product documentation probe is unexpectedly ignored")
Check "failed complex ignore approval preserves manifest" (
	(Get-FileHashText $complexManifestPath) -eq $complexManifestHash
)
Check "failed complex ignore approval creates no backup" (-not (Test-Path -LiteralPath $complexBackup))

$ownershipChild = Join-Path $fixtureRoot "ownership-child"
Invoke-Git $anchor @("checkout", "-q", "-b", "candidate/remove-optional-ownership") | Out-Null
Invoke-Git $anchor @("rm", "-q", "AGENTS.md", "CLAUDE.md", ".codex/config.toml") | Out-Null
Invoke-Git $anchor @("commit", "-q", "-m", "remove optional tracked ownership") | Out-Null
Invoke-Git $anchor @("checkout", "-q", "master") | Out-Null
Invoke-Git $anchor @("worktree", "add", "-q", $ownershipChild, "candidate/remove-optional-ownership") | Out-Null
$result = Invoke-Bootstrap $ownershipChild $anchor -ExpectFailure
Check "child optional ownership mismatch fails before writes" ($result.Output -match "does not match the anchor manifest ownership")
Check "ownership mismatch creates no agent-work" (-not (Test-Path -LiteralPath (Join-Path $ownershipChild ".agent-work")))
Check "ownership mismatch creates no branch projection" (-not (Get-Item -LiteralPath (Join-Path $ownershipChild "docs/branches") -Force -ErrorAction SilentlyContinue))
Invoke-Git $anchor @("worktree", "remove", "--force", $ownershipChild) | Out-Null

$unapprovedChild = Join-Path $fixtureRoot "unapproved-child"
Invoke-Git $anchor @("worktree", "add", "-q", "-b", "feature/unapproved-ignore", $unapprovedChild) | Out-Null
[IO.File]::AppendAllText((Join-Path $unapprovedChild ".gitignore"), "new-ignore-rule/`n")
Invoke-Git $unapprovedChild @("add", ".gitignore") | Out-Null
Invoke-Git $unapprovedChild @("commit", "-q", "-m", "change ignore policy") | Out-Null
$excludePath = Join-Path ((Invoke-Git $anchor @("rev-parse", "--path-format=absolute", "--git-common-dir") | Select-Object -First 1)) "info/exclude"
$excludeHash = Get-FileHashText $excludePath
$result = Invoke-Bootstrap $unapprovedChild $anchor -ExpectFailure
Check "unapproved child fingerprint fails before writes" ($result.Output -match "fingerprint is not approved")
Check "unapproved child creates no agent-work" (-not (Test-Path -LiteralPath (Join-Path $unapprovedChild ".agent-work")))
Check "unapproved child creates no branch projection" (-not (Get-Item -LiteralPath (Join-Path $unapprovedChild "docs/branches") -Force -ErrorAction SilentlyContinue))
Check "unapproved child preserves common exclude" ((Get-FileHashText $excludePath) -eq $excludeHash)
Invoke-Git $anchor @("worktree", "remove", "--force", $unapprovedChild) | Out-Null

$child = Join-Path $fixtureRoot "child"
Invoke-Git $anchor @("worktree", "add", "-q", "-b", "feature/ovdr-123", $child) | Out-Null
Invoke-Bootstrap $child $anchor | Out-Null
Check "child docs is physical" (Test-PhysicalDirectory (Join-Path $child "docs"))
Check "child tracked product doc preserved" (Test-GitPathClean $child "docs/product/guide.md")
Check "child initializer is physical file" ((Get-Item -LiteralPath (Join-Path $child "docs/init-branch-docs.ps1") -Force).LinkType -ne "Junction")
foreach ($name in @("branches", "index", "work")) {
	Check "child docs/$name exact junction" (Test-ExactJunction (Join-Path $child "docs/$name") (Join-Path $anchor "docs/$name"))
}

Invoke-Bootstrap $child $anchor | Out-Null
foreach ($name in @("branches", "index", "work")) {
	Check "repeat child docs/$name exact junction" (Test-ExactJunction (Join-Path $child "docs/$name") (Join-Path $anchor "docs/$name"))
}
Check "repeat product doc preserved" (Test-GitPathClean $child "docs/product/guide.md")
Check "repeat marker remains valid" ((Get-FileHashText (Join-Path $child ".agent-work/branch-docs-bootstrap.json")) -ne $null)

Write-Output "=== initializer path containment ==="
$result = Invoke-Initializer $child @("-WorkKey", "..\escape") -ExpectFailure
Check "invalid work key is rejected" ($result.Output -match "must be a Jira key")
Check "invalid work key created no escaped path" (-not (Test-Path -LiteralPath (Join-Path $anchor "docs/escape")))
$workReparseTarget = Join-Path $fixtureRoot "initializer-work-target"
New-Item -ItemType Directory -Path $workReparseTarget -Force | Out-Null
$workReparseSentinel = Join-Path $workReparseTarget "sentinel.md"
[IO.File]::WriteAllText($workReparseSentinel, "keep`n")
$workReparseLink = Join-Path $anchor "docs/work/OVDR-666"
New-Item -ItemType Junction -Path $workReparseLink -Target $workReparseTarget | Out-Null
$result = Invoke-Initializer $child @("-WorkKey", "OVDR-666") -ExpectFailure
Check "reparse canonical work root is rejected" ($result.Output -match "physical non-reparse")
Check "reparse canonical target sentinel preserved" (Test-Path -LiteralPath $workReparseSentinel -PathType Leaf)
& cmd.exe /d /c rmdir "`"$workReparseLink`"" | Out-Null
Check "test work-root reparse leaf cleanup exit 0" ($LASTEXITCODE -eq 0)

Write-Output "=== initializer writes through physical anchor roots ==="
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
	-File (Join-Path $child "docs/init-branch-docs.ps1") `
	-WorkKey OVDR-123
Check "initializer exit 0" ($LASTEXITCODE -eq 0)
$canonicalWork = Join-Path $anchor "docs/work/OVDR-123"
Check "canonical work created in anchor" (Test-Path -LiteralPath $canonicalWork -PathType Container)
Check "branch compatibility target is physical anchor work" (
	Test-ExactJunction (Join-Path $anchor "docs/branches/feature~ovdr-123") $canonicalWork
)
$emptyCanonical = Join-Path $anchor "docs/work/OVDR-124"
New-Item -ItemType Directory -Path $emptyCanonical -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $emptyCanonical "README.md"), "")
$result = Invoke-Initializer $child @(
	"-BranchName", "feature/ovdr-124",
	"-WorkKey", "OVDR-124"
) -ExpectFailure
Check "initializer rejects empty pre-existing template file" ($result.Output -match "empty or whitespace-only")

Write-Output "=== concurrent initializer serialization ==="
$logA = Join-Path $fixtureRoot "initializer-a.log"
$logB = Join-Path $fixtureRoot "initializer-b.log"
$initializer = Join-Path $child "docs/init-branch-docs.ps1"
$jobScript = {
	param($Initializer, $BranchName, $WorkKey)
	$output = @(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
		-File $Initializer -BranchName $BranchName -WorkKey $WorkKey 2>&1)
	if ($LASTEXITCODE -ne 0) {
		throw ($output -join [Environment]::NewLine)
	}
	return $output
}
$jobA = Start-Job -ScriptBlock $jobScript -ArgumentList $initializer, "feature/ovdr-201", "OVDR-201"
$jobB = Start-Job -ScriptBlock $jobScript -ArgumentList $initializer, "feature/ovdr-202", "OVDR-202"
Wait-Job -Job $jobA, $jobB | Out-Null
$outputA = @(Receive-Job -Job $jobA -Keep | ForEach-Object { "$_" })
$outputB = @(Receive-Job -Job $jobB -Keep | ForEach-Object { "$_" })
[IO.File]::WriteAllLines($logA, $outputA)
[IO.File]::WriteAllLines($logB, $outputB)
Check "concurrent initializer A exit 0" ($jobA.State -eq "Completed")
Check "concurrent initializer B exit 0" ($jobB.State -eq "Completed")
Remove-Job -Job $jobA, $jobB -Force
$bindings = [IO.File]::ReadAllText((Join-Path $anchor "docs/index/branch-bindings.json")) | ConvertFrom-Json
Check "concurrent binding OVDR-201 preserved" (@($bindings.bindings | Where-Object { $_.workKey -eq "OVDR-201" }).Count -eq 1)
Check "concurrent binding OVDR-202 preserved" (@($bindings.bindings | Where-Object { $_.workKey -eq "OVDR-202" }).Count -eq 1)

Write-Output "=== wrong target fails without deletion ==="
$wrongChild = Join-Path $fixtureRoot "wrong-child"
Invoke-Git $anchor @("worktree", "add", "-q", "-b", "feature/wrong-target", $wrongChild) | Out-Null
$wrongTarget = Join-Path $fixtureRoot "wrong-target"
New-Item -ItemType Directory -Path $wrongTarget -Force | Out-Null
New-Item -ItemType Junction -Path (Join-Path $wrongChild "docs/work") -Target $wrongTarget | Out-Null
$result = Invoke-Bootstrap $wrongChild $anchor -ExpectFailure
Check "wrong target explains mismatch" ($result.Output -match "Wrong junction target")
Check "wrong target junction preserved" (Test-ExactJunction (Join-Path $wrongChild "docs/work") $wrongTarget)

Write-Output "=== case-folded tracked reserved path in another ref blocks bootstrap ==="
$collisionRepo = New-TestRepo "collision-ref" -CompatibleInstructions -TrackedProductDocs
Invoke-Git $collisionRepo @("checkout", "-q", "-b", "collision") | Out-Null
New-Item -ItemType Directory -Path (Join-Path $collisionRepo "Docs/WORK") -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $collisionRepo "Docs/WORK/tracked.md"), "collision`n")
Invoke-Git $collisionRepo @("add", "-f", "Docs/WORK/tracked.md") | Out-Null
Invoke-Git $collisionRepo @("commit", "-q", "-m", "reserved collision") | Out-Null
Invoke-Git $collisionRepo @("checkout", "-q", "master") | Out-Null
$result = Invoke-Bootstrap $collisionRepo $collisionRepo -ExpectFailure
Check "collision ref explains reserved path" ($result.Output -match "Tracked reserved-path collision")
Check "collision ref bootstrap created no manifest" (-not (Test-Path -LiteralPath (Join-Path $collisionRepo ".git/branch-docs-starter/manifest.json")))

Write-Output "=== tampered manifest roots fail before child writes ==="
$manifestAnchor = New-TestRepo "manifest-anchor" -CompatibleInstructions -TrackedProductDocs
Invoke-Bootstrap $manifestAnchor $manifestAnchor | Out-Null
$manifestCommon = (Invoke-Git $manifestAnchor @("rev-parse", "--path-format=absolute", "--git-common-dir") | Select-Object -First 1)
$manifestPath = Join-Path $manifestCommon "branch-docs-starter/manifest.json"
$tamperedManifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
$tamperedManifest.workRoot = Join-Path $fixtureRoot "manifest-external-work"
New-Item -ItemType Directory -Path $tamperedManifest.workRoot -Force | Out-Null
[IO.File]::WriteAllText($manifestPath, (($tamperedManifest | ConvertTo-Json -Depth 16) + "`n"))
$manifestChild = Join-Path $fixtureRoot "manifest-child"
Invoke-Git $manifestAnchor @("worktree", "add", "-q", "-b", "feature/manifest-child", $manifestChild) | Out-Null
$result = Invoke-Bootstrap $manifestChild $manifestAnchor -ExpectFailure
Check "tampered manifest exact-root mismatch is explained" ($result.Output -match "exact anchor repository layout")
Check "tampered manifest created no child agent-work" (-not (Test-Path -LiteralPath (Join-Path $manifestChild ".agent-work")))
Check "tampered manifest created no child work projection" (-not (Get-Item -LiteralPath (Join-Path $manifestChild "docs/work") -Force -ErrorAction SilentlyContinue))
Invoke-Git $manifestAnchor @("worktree", "remove", "--force", $manifestChild) | Out-Null

Write-Output "=== tampered manifest patterns and missing revision fail before writes ==="
$excludeAnchor = New-TestRepo "exclude-anchor" -CompatibleInstructions -TrackedProductDocs
Invoke-Bootstrap $excludeAnchor $excludeAnchor | Out-Null
$excludeCommon = (Invoke-Git $excludeAnchor @("rev-parse", "--path-format=absolute", "--git-common-dir") | Select-Object -First 1)
$excludeManifestPath = Join-Path $excludeCommon "branch-docs-starter/manifest.json"
$excludeManifestOriginal = [IO.File]::ReadAllText($excludeManifestPath)
$excludeFile = Join-Path $excludeCommon "info/exclude"
$excludeFileHash = Get-FileHashText $excludeFile
$excludeManifest = $excludeManifestOriginal | ConvertFrom-Json
$excludeManifest.commonExcludePatterns = @("/docs/")
[IO.File]::WriteAllText($excludeManifestPath, (($excludeManifest | ConvertTo-Json -Depth 16) + "`n"))
$excludeChild = Join-Path $fixtureRoot "exclude-child"
Invoke-Git $excludeAnchor @("worktree", "add", "-q", "-b", "feature/exclude-child", $excludeChild) | Out-Null
$result = Invoke-Bootstrap $excludeChild $excludeAnchor -ExpectFailure
Check "tampered common exclude patterns are rejected" ($result.Output -match "exact ownership-derived pattern set")
Check "tampered pattern preserves common exclude bytes" ((Get-FileHashText $excludeFile) -eq $excludeFileHash)
Check "tampered pattern creates no child agent-work" (-not (Test-Path -LiteralPath (Join-Path $excludeChild ".agent-work")))
Invoke-Git $excludeAnchor @("worktree", "remove", "--force", $excludeChild) | Out-Null

$missingRevisionManifest = $excludeManifestOriginal | ConvertFrom-Json
$missingRevisionManifest.PSObject.Properties.Remove("starterRevision")
[IO.File]::WriteAllText($excludeManifestPath, (($missingRevisionManifest | ConvertTo-Json -Depth 16) + "`n"))
$missingRevisionChild = Join-Path $fixtureRoot "missing-revision-child"
Invoke-Git $excludeAnchor @("worktree", "add", "-q", "-b", "feature/missing-revision-child", $missingRevisionChild) | Out-Null
$result = Invoke-Bootstrap $missingRevisionChild $excludeAnchor -ExpectFailure
Check "missing starter revision is rejected" ($result.Output -match "starterRevision.*missing")
Check "missing revision creates no child agent-work" (-not (Test-Path -LiteralPath (Join-Path $missingRevisionChild ".agent-work")))
Invoke-Git $excludeAnchor @("worktree", "remove", "--force", $missingRevisionChild) | Out-Null

Write-Output "=== child removal preserves anchor store ==="
$sentinel = Join-Path $anchor "docs/work/sentinel.md"
[IO.File]::WriteAllText($sentinel, "keep`n")
& cmd.exe /d /c rmdir "`"$(Join-Path $child 'docs/branches')`"" | Out-Null
Check "simulated interrupted unbootstrap removed one junction" ($LASTEXITCODE -eq 0)
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
	-File $unbootstrap `
	-TargetRepo $child `
	-AnchorRepo $anchor
Check "unbootstrap exit 0" ($LASTEXITCODE -eq 0)
foreach ($name in @("branches", "index", "work")) {
	Check "unbootstrap removed child docs/$name junction" (-not (Get-Item -LiteralPath (Join-Path $child "docs/$name") -Force -ErrorAction SilentlyContinue))
}
Check "anchor sentinel survives unbootstrap" (Test-Path -LiteralPath $sentinel -PathType Leaf)
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
	-File $unbootstrap `
	-TargetRepo $child `
	-AnchorRepo $anchor
Check "repeat unbootstrap is idempotent" ($LASTEXITCODE -eq 0)
Invoke-Git $anchor @("worktree", "remove", "--force", $child) | Out-Null
Check "anchor sentinel survives child removal" (Test-Path -LiteralPath $sentinel -PathType Leaf)
Check "canonical OVDR-123 survives child removal" (Test-Path -LiteralPath $canonicalWork -PathType Container)

Write-Output ""
if ($failures -gt 0) {
	Write-Output "BOOTSTRAP TEST FAILURES: $failures"
	exit $failures
}
Write-Output "ALL BOOTSTRAP TESTS PASSED"
exit 0
