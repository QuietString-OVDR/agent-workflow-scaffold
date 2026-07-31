[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)]
	[string]$TargetRepo,

	[string]$AnchorRepo,

	[switch]$CommonStore,
	[switch]$DryRun,
	[switch]$VerifyOnly,
	[string]$CandidateRef,
	[string]$ExpectedHeadOid,
	[switch]$ApproveCurrentIgnorePolicy,
	[string]$ApprovalBackupRoot,

	[int]$LockTimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:SchemaVersion = 1
$script:CommonStoreSchemaVersion = 2
$script:CommonStoreLayoutName = "git-common-dir-store-v1"
$script:CommonStoreRelativePath = "branch-docs-starter/store"
$script:PackageRoot = $PSScriptRoot
$script:ReservedDirectoryPaths = @(
	"docs/branches",
	"docs/index",
	"docs/work"
)
$script:ReservedFilePaths = @(
	"docs/init-branch-docs.ps1",
	"docs/init-branch-docs.sh"
)
$script:BeginMarker = "# branch-docs-starter:begin"
$script:EndMarker = "# branch-docs-starter:end"

function Invoke-Git {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Repo,

		[Parameter(Mandatory = $true)]
		[string[]]$Arguments,

		[switch]$AllowFailure
	)

	$git = Get-Command git -CommandType Application -ErrorAction Stop
	$oldErrorActionPreference = $ErrorActionPreference
	$oldNativeErrorActionPreference = $null
	$hasNativePreference = Get-Variable -Name PSNativeCommandUseErrorActionPreference -Scope Global -ErrorAction SilentlyContinue
	try {
		$ErrorActionPreference = "Continue"
		if ($hasNativePreference) {
			$oldNativeErrorActionPreference = $Global:PSNativeCommandUseErrorActionPreference
			$Global:PSNativeCommandUseErrorActionPreference = $false
		}
		$output = @(& $git.Source -C $Repo @Arguments 2>&1)
		$exitCode = $LASTEXITCODE
	} finally {
		$ErrorActionPreference = $oldErrorActionPreference
		if ($hasNativePreference) {
			$Global:PSNativeCommandUseErrorActionPreference = $oldNativeErrorActionPreference
		}
	}

	if ($exitCode -ne 0 -and -not $AllowFailure) {
		$detail = ($output | ForEach-Object { "$_" }) -join [Environment]::NewLine
		throw "git -C `"$Repo`" $($Arguments -join ' ') failed with exit code $exitCode.$([Environment]::NewLine)$detail"
	}

	return [pscustomobject]@{
		ExitCode = $exitCode
		Lines = @($output | ForEach-Object { "$_" })
		Text = (($output | ForEach-Object { "$_" }) -join "`n").TrimEnd()
	}
}

function Normalize-Path {
	param([Parameter(Mandatory = $true)][string]$Path)

	$fullPath = [IO.Path]::GetFullPath($Path)
	$root = [IO.Path]::GetPathRoot($fullPath)
	if ($fullPath.Length -gt $root.Length) {
		$fullPath = $fullPath.TrimEnd('\', '/')
	}
	return $fullPath
}

function Test-PathEqual {
	param(
		[Parameter(Mandatory = $true)][string]$Left,
		[Parameter(Mandatory = $true)][string]$Right
	)

	return [string]::Equals(
		(Normalize-Path $Left),
		(Normalize-Path $Right),
		[StringComparison]::OrdinalIgnoreCase
	)
}

function Get-RepoContext {
	param([Parameter(Mandatory = $true)][string]$Repo)

	$resolvedRepo = Normalize-Path $Repo
	if (-not (Test-Path -LiteralPath $resolvedRepo -PathType Container)) {
		throw "Repository path not found: $resolvedRepo"
	}

	$inside = Invoke-Git -Repo $resolvedRepo -Arguments @("rev-parse", "--is-inside-work-tree")
	if ($inside.Text -ne "true") {
		throw "Not a Git working tree: $resolvedRepo"
	}

	$topLevel = Normalize-Path (Invoke-Git -Repo $resolvedRepo -Arguments @("rev-parse", "--show-toplevel")).Text
	$gitDir = Normalize-Path (Invoke-Git -Repo $resolvedRepo -Arguments @("rev-parse", "--path-format=absolute", "--git-dir")).Text
	$commonDir = Normalize-Path (Invoke-Git -Repo $resolvedRepo -Arguments @("rev-parse", "--path-format=absolute", "--git-common-dir")).Text
	return [pscustomobject]@{
		Root = $topLevel
		GitDir = $gitDir
		CommonDir = $commonDir
		IsMainWorktree = (Test-PathEqual $gitDir $commonDir)
	}
}

function Get-NormalizedGitPath {
	param([Parameter(Mandatory = $true)][string]$Path)

	return (($Path -replace '\\', '/').TrimStart('/')).ToLowerInvariant()
}

function Test-ReservedGitPath {
	param([Parameter(Mandatory = $true)][string]$Path)

	$normalized = Get-NormalizedGitPath $Path
	foreach ($directory in $script:ReservedDirectoryPaths) {
		$normalizedDirectory = $directory.ToLowerInvariant()
		if ($normalized -eq $normalizedDirectory -or $normalized.StartsWith("$normalizedDirectory/", [StringComparison]::Ordinal)) {
			return $true
		}
	}
	foreach ($file in $script:ReservedFilePaths) {
		if ($normalized -eq $file.ToLowerInvariant()) {
			return $true
		}
	}
	return $false
}

function Get-ReservedCollisionsFromLines {
	param([string[]]$Paths)

	$collisions = @()
	foreach ($path in @($Paths)) {
		if ($path -and (Test-ReservedGitPath $path)) {
			$collisions += $path
		}
	}
	return @($collisions | Sort-Object -Unique)
}

function Assert-NoReservedCollisions {
	param([Parameter(Mandatory = $true)][string]$Repo)

	$currentPaths = (Invoke-Git -Repo $Repo -Arguments @("ls-files", "--", ":(icase)docs")).Lines
	$currentCollisions = @(Get-ReservedCollisionsFromLines $currentPaths)
	if ($currentCollisions.Count -gt 0) {
		throw "Tracked reserved-path collision in the current index: $($currentCollisions -join ', ')"
	}

	$currentCommit = "<unknown>"
	$history = (Invoke-Git -Repo $Repo -Arguments @(
		"log",
		"--all",
		"--full-history",
		"--format=@@%H",
		"--name-only",
		"--",
		":(icase)docs"
	)).Lines
	foreach ($line in $history) {
		if ($line.StartsWith("@@", [StringComparison]::Ordinal) -and $line.Length -gt 2) {
			$currentCommit = $line.Substring(2)
			continue
		}
		if ($line -and (Test-ReservedGitPath $line)) {
			throw "Tracked reserved-path collision in commit $currentCommit`: $line"
		}
	}
}

function Test-GitTracked {
	param(
		[Parameter(Mandatory = $true)][string]$Repo,
		[Parameter(Mandatory = $true)][string]$RelativePath
	)

	$result = Invoke-Git -Repo $Repo -Arguments @("ls-files", "--error-unmatch", "--", $RelativePath) -AllowFailure
	return $result.ExitCode -eq 0
}

function Get-MarkerState {
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)][string]$BeginMarker,
		[Parameter(Mandatory = $true)][string]$EndMarker
	)

	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
		return [pscustomobject]@{ Valid = $false; BeginCount = 0; EndCount = 0 }
	}
	$lines = [IO.File]::ReadAllLines($Path)
	$beginCount = @($lines | Where-Object { $_ -ceq $BeginMarker }).Count
	$endCount = @($lines | Where-Object { $_ -ceq $EndMarker }).Count
	$beginIndex = [Array]::IndexOf($lines, $BeginMarker)
	$endIndex = [Array]::IndexOf($lines, $EndMarker)
	return [pscustomobject]@{
		Valid = ($beginCount -eq 1 -and $endCount -eq 1 -and $beginIndex -lt $endIndex)
		BeginCount = $beginCount
		EndCount = $endCount
	}
}

function Test-LinesContainExactBlock {
	param(
		[Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$TargetLines,
		[Parameter(Mandatory = $true)][string]$BlockPath,
		[Parameter(Mandatory = $true)][string]$BeginMarker,
		[Parameter(Mandatory = $true)][string]$EndMarker
	)

	$beginIndexes = @()
	$endIndexes = @()
	for ($index = 0; $index -lt $TargetLines.Count; $index++) {
		if ($TargetLines[$index] -ceq $BeginMarker) { $beginIndexes += $index }
		if ($TargetLines[$index] -ceq $EndMarker) { $endIndexes += $index }
	}
	if ($beginIndexes.Count -ne 1 -or $endIndexes.Count -ne 1 -or $beginIndexes[0] -ge $endIndexes[0]) {
		return $false
	}

	$blockLines = @([IO.File]::ReadAllLines($BlockPath))
	$managedLines = @($TargetLines[$beginIndexes[0]..$endIndexes[0]])
	if ($managedLines.Count -ne $blockLines.Count) {
		return $false
	}
	for ($index = 0; $index -lt $blockLines.Count; $index++) {
		if ($managedLines[$index] -cne $blockLines[$index]) {
			return $false
		}
	}
	return $true
}

function Test-FileContainsExactBlock {
	param(
		[Parameter(Mandatory = $true)][string]$TargetPath,
		[Parameter(Mandatory = $true)][string]$BlockPath,
		[Parameter(Mandatory = $true)][string]$BeginMarker,
		[Parameter(Mandatory = $true)][string]$EndMarker
	)

	if (-not (Test-Path -LiteralPath $TargetPath -PathType Leaf)) {
		return $false
	}
	return Test-LinesContainExactBlock `
		-TargetLines @([IO.File]::ReadAllLines($TargetPath)) `
		-BlockPath $BlockPath `
		-BeginMarker $BeginMarker `
		-EndMarker $EndMarker
}

function Test-ClaudeDelegatesToAgents {
	param([Parameter(Mandatory = $true)][string]$Path)

	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
		return $false
	}
	return @([IO.File]::ReadAllLines($Path) | Where-Object { $_.Trim() -eq "@AGENTS.md" }).Count -gt 0
}

function Assert-TrackedInstructionCompatibility {
	param([Parameter(Mandatory = $true)][string]$Repo)

	$agentsPath = Join-Path $Repo "AGENTS.md"
	if (Test-GitTracked $Repo "AGENTS.md") {
		if (-not (Test-FileContainsExactBlock `
			-TargetPath $agentsPath `
			-BlockPath (Join-Path $script:PackageRoot "AGENTS.branch-docs.md") `
			-BeginMarker "<!-- branch-docs-starter:begin -->" `
			-EndMarker "<!-- branch-docs-starter:end -->")) {
			throw "Tracked AGENTS.md does not contain the exact current branch-docs-starter block. Use the migration script with explicit tracked-policy authorization."
		}
		if ((Invoke-Git -Repo $Repo -Arguments @("diff", "--quiet", "--", "AGENTS.md") -AllowFailure).ExitCode -ne 0) {
			throw "Tracked AGENTS.md differs from the index; refusing to bootstrap."
		}
	}

	$claudePath = Join-Path $Repo "CLAUDE.md"
	if (Test-GitTracked $Repo "CLAUDE.md") {
		$claudeLines = @([IO.File]::ReadAllLines($claudePath))
		$hasManagedMarker = @($claudeLines | Where-Object {
			$_ -ceq "<!-- branch-docs-starter:begin -->" -or
			$_ -ceq "<!-- branch-docs-starter:end -->"
		}).Count -gt 0
		$hasExactBlock = Test-FileContainsExactBlock `
			-TargetPath $claudePath `
			-BlockPath (Join-Path $script:PackageRoot "CLAUDE.branch-docs.md") `
			-BeginMarker "<!-- branch-docs-starter:begin -->" `
			-EndMarker "<!-- branch-docs-starter:end -->"
		if (($hasManagedMarker -and -not $hasExactBlock) -or
			(-not $hasManagedMarker -and -not (Test-ClaudeDelegatesToAgents $claudePath))) {
			throw "Tracked CLAUDE.md neither delegates to AGENTS.md nor contains the exact current branch-docs-starter block."
		}
		if ((Invoke-Git -Repo $Repo -Arguments @("diff", "--quiet", "--", "CLAUDE.md") -AllowFailure).ExitCode -ne 0) {
			throw "Tracked CLAUDE.md differs from the index; refusing to bootstrap."
		}
	}
}

function Assert-IgnorePolicyPreflight {
	param([Parameter(Mandatory = $true)][string]$Repo)

	$gitignorePath = Join-Path $Repo ".gitignore"
	if (-not (Test-Path -LiteralPath $gitignorePath -PathType Leaf)) {
		return
	}
	if (Test-GitTracked $Repo ".gitignore") {
		$result = Invoke-Git -Repo $Repo -Arguments @("diff", "--quiet", "--", ".gitignore") -AllowFailure
		if ($result.ExitCode -ne 0) {
			throw "Tracked .gitignore differs from the index; review and commit the migration before bootstrap."
		}
	}

	$lines = [IO.File]::ReadAllLines($gitignorePath)
	$beginCount = @($lines | Where-Object { $_ -ceq $script:BeginMarker }).Count
	$endCount = @($lines | Where-Object { $_ -ceq $script:EndMarker }).Count
	if ($beginCount -gt 1 -or $endCount -gt 1 -or $beginCount -ne $endCount) {
		throw "Malformed or duplicate branch-docs-starter marker blocks in $gitignorePath."
	}
	foreach ($line in $lines) {
		$pattern = $line.Trim()
		if ($pattern -in @("/docs/", "docs/", "/.codex/", ".codex/")) {
			throw "Blanket ignore pattern '$pattern' is incompatible with tracked product docs. Run the migration script first."
		}
	}
	if (($beginCount -eq 1 -or $endCount -eq 1) -and -not (Test-FileContainsExactBlock `
		-TargetPath $gitignorePath `
		-BlockPath (Join-Path $script:PackageRoot ".agent-work.gitignore.block") `
		-BeginMarker $script:BeginMarker `
		-EndMarker $script:EndMarker)) {
		throw "Tracked .gitignore branch-docs-starter markers are reversed or the managed block is stale. Run the migration script first."
	}
}

function Get-IgnoreFingerprint {
	param(
		[Parameter(Mandatory = $true)][string]$Repo,
		[string]$Ref
	)

	$entries = @()
	if ($Ref) {
		$treeLines = (Invoke-Git -Repo $Repo -Arguments @("ls-tree", "-r", "--full-tree", $Ref)).Lines
		foreach ($line in $treeLines) {
			if ($line -match '^[0-9]+\s+blob\s+([0-9a-fA-F]+)\t(.+)$') {
				$path = $Matches[2]
				if ($path -eq ".gitignore" -or $path.EndsWith("/.gitignore", [StringComparison]::Ordinal)) {
					$entries += "$path`t$($Matches[1].ToLowerInvariant())"
				}
			}
		}
	} else {
		$indexLines = (Invoke-Git -Repo $Repo -Arguments @("ls-files", "-s")).Lines
		foreach ($line in $indexLines) {
			if ($line -match '^[0-9]+\s+([0-9a-fA-F]+)\s+[0-9]+\t(.+)$') {
				$path = $Matches[2]
				if ($path -eq ".gitignore" -or $path.EndsWith("/.gitignore", [StringComparison]::Ordinal)) {
					$entries += "$path`t$($Matches[1].ToLowerInvariant())"
				}
			}
		}
	}

	$sortedEntries = [string[]]@($entries)
	[Array]::Sort($sortedEntries, [StringComparer]::Ordinal)
	$payload = ($sortedEntries -join "`n")
	$bytes = [Text.Encoding]::UTF8.GetBytes($payload)
	$sha256 = [Security.Cryptography.SHA256]::Create()
	try {
		$hash = $sha256.ComputeHash($bytes)
	} finally {
		$sha256.Dispose()
	}
	return (($hash | ForEach-Object { $_.ToString("x2") }) -join "")
}

function Get-FullCommitOid {
	param(
		[Parameter(Mandatory = $true)][string]$Repo,
		[Parameter(Mandatory = $true)][string]$Ref
	)

	$result = Invoke-Git -Repo $Repo -Arguments @("rev-parse", "--verify", "$Ref^{commit}") -AllowFailure
	if ($result.ExitCode -ne 0 -or -not $result.Text) {
		throw "Unable to resolve candidate commit: $Ref"
	}
	return $result.Text.ToLowerInvariant()
}

function Assert-Candidate {
	param(
		[Parameter(Mandatory = $true)][string]$Repo,
		[Parameter(Mandatory = $true)][string]$Candidate,
		[Parameter(Mandatory = $true)]$Manifest
	)

	$oid = Get-FullCommitOid $Repo $Candidate
	$paths = (Invoke-Git -Repo $Repo -Arguments @("ls-tree", "-r", "--name-only", $oid)).Lines
	$collisions = @(Get-ReservedCollisionsFromLines $paths)
	if ($collisions.Count -gt 0) {
		throw "Candidate $Candidate ($oid) contains tracked reserved paths: $($collisions -join ', ')"
	}

	$candidateFingerprint = Get-IgnoreFingerprint $Repo $oid
	if ($Manifest.approvedIgnoreFingerprints -notcontains $candidateFingerprint) {
		throw "Candidate $Candidate has an unapproved tracked ignore-policy fingerprint: $candidateFingerprint"
	}
	$candidateIgnore = Invoke-Git -Repo $Repo -Arguments @("show", "$oid`:.gitignore") -AllowFailure
	if ($candidateIgnore.ExitCode -eq 0) {
		$beginCount = @($candidateIgnore.Lines | Where-Object { $_ -ceq $script:BeginMarker }).Count
		$endCount = @($candidateIgnore.Lines | Where-Object { $_ -ceq $script:EndMarker }).Count
		if ($beginCount -gt 1 -or $endCount -gt 1 -or $beginCount -ne $endCount) {
			throw "Candidate .gitignore has malformed or duplicate branch-docs-starter marker blocks."
		}
		if (($beginCount -eq 1 -or $endCount -eq 1) -and -not (Test-LinesContainExactBlock `
			-TargetLines @($candidateIgnore.Lines) `
			-BlockPath (Join-Path $script:PackageRoot ".agent-work.gitignore.block") `
			-BeginMarker $script:BeginMarker `
			-EndMarker $script:EndMarker)) {
			throw "Candidate .gitignore branch-docs-starter block is stale or reversed."
		}
		foreach ($line in $candidateIgnore.Lines) {
			if ($line.Trim() -in @("/docs/", "docs/", "/.codex/", ".codex/")) {
				throw "Candidate .gitignore contains incompatible blanket rule '$($line.Trim())'."
			}
		}
	}

	$agentsBlob = Invoke-Git -Repo $Repo -Arguments @("show", "$oid`:AGENTS.md") -AllowFailure
	$currentAgentsTracked = Test-GitTracked $Repo "AGENTS.md"
	if ($currentAgentsTracked) {
		if ($agentsBlob.ExitCode -ne 0) {
			throw "Candidate removes tracked AGENTS.md. Create a new worktree instead."
		}
		if (-not (Test-LinesContainExactBlock `
			-TargetLines @($agentsBlob.Lines) `
			-BlockPath (Join-Path $script:PackageRoot "AGENTS.branch-docs.md") `
			-BeginMarker "<!-- branch-docs-starter:begin -->" `
			-EndMarker "<!-- branch-docs-starter:end -->")) {
			throw "Candidate AGENTS.md does not contain the exact current branch-docs-starter block."
		}
	} elseif ($agentsBlob.ExitCode -eq 0) {
		throw "Candidate changes AGENTS.md from starter-owned untracked to tracked. Create a new worktree instead."
	}

	$claudeBlob = Invoke-Git -Repo $Repo -Arguments @("show", "$oid`:CLAUDE.md") -AllowFailure
	$currentClaudeTracked = Test-GitTracked $Repo "CLAUDE.md"
	if ($currentClaudeTracked -and $claudeBlob.ExitCode -ne 0) {
		throw "Candidate removes tracked CLAUDE.md. Create a new worktree instead."
	}
	if ($currentClaudeTracked -and $claudeBlob.ExitCode -eq 0) {
		$delegates = @($claudeBlob.Lines | Where-Object { $_.Trim() -eq "@AGENTS.md" }).Count -gt 0
		$hasManagedMarker = @($claudeBlob.Lines | Where-Object {
			$_ -ceq "<!-- branch-docs-starter:begin -->" -or
			$_ -ceq "<!-- branch-docs-starter:end -->"
		}).Count -gt 0
		$hasExactBlock = Test-LinesContainExactBlock `
			-TargetLines @($claudeBlob.Lines) `
			-BlockPath (Join-Path $script:PackageRoot "CLAUDE.branch-docs.md") `
			-BeginMarker "<!-- branch-docs-starter:begin -->" `
			-EndMarker "<!-- branch-docs-starter:end -->"
		if (($hasManagedMarker -and -not $hasExactBlock) -or
			(-not $hasManagedMarker -and -not $delegates)) {
			throw "Candidate CLAUDE.md neither delegates to AGENTS.md nor contains the exact current branch-docs-starter block."
		}
	}
	if (-not $currentClaudeTracked -and $claudeBlob.ExitCode -eq 0) {
		throw "Candidate changes CLAUDE.md from starter-owned untracked to tracked. Create a new worktree instead."
	}

	$codexBlob = Invoke-Git -Repo $Repo -Arguments @("show", "$oid`:.codex/config.toml") -AllowFailure
	$currentCodexTracked = Test-GitTracked $Repo ".codex/config.toml"
	if ($currentCodexTracked -and $codexBlob.ExitCode -ne 0) {
		throw "Candidate removes tracked .codex/config.toml. Create a new worktree instead."
	}
	if (-not $currentCodexTracked -and $codexBlob.ExitCode -eq 0) {
		throw "Candidate changes .codex/config.toml from untracked or absent to tracked. Create a new worktree instead."
	}
	if ($claudeBlob.ExitCode -eq 0) {
		$hasImport = @($claudeBlob.Lines | Where-Object { $_.Trim() -eq "@AGENTS.md" }).Count -gt 0
		$beginCount = @($claudeBlob.Lines | Where-Object { $_ -ceq "<!-- branch-docs-starter:begin -->" }).Count
		$endCount = @($claudeBlob.Lines | Where-Object { $_ -ceq "<!-- branch-docs-starter:end -->" }).Count
		if (-not $hasImport -and ($beginCount -ne 1 -or $endCount -ne 1)) {
			throw "Candidate CLAUDE.md is not branch-docs compatible."
		}
	}

	return $oid
}

function Read-Manifest {
	param([Parameter(Mandatory = $true)][string]$Path)

	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
		return $null
	}
	return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json)
}

function Write-Utf8Atomic {
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)][string]$Text
	)

	$parent = Split-Path -Parent $Path
	if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
		New-Item -ItemType Directory -Path $parent -Force | Out-Null
	}
	$tempPath = Join-Path $parent ("branch-docs-" + [Guid]::NewGuid().ToString("N") + ".tmp")
	$backupPath = Join-Path $parent ("branch-docs-" + [Guid]::NewGuid().ToString("N") + ".bak")
	$encoding = New-Object Text.UTF8Encoding $false
	try {
		[IO.File]::WriteAllText($tempPath, $Text, $encoding)
		if ([IO.File]::Exists($Path)) {
			[IO.File]::Replace($tempPath, $Path, $backupPath)
			if (Test-Path -LiteralPath $backupPath) {
				Remove-Item -LiteralPath $backupPath -Force
			}
		} else {
			[IO.File]::Move($tempPath, $Path)
		}
	} finally {
		if (Test-Path -LiteralPath $tempPath) {
			Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
		}
		if (Test-Path -LiteralPath $backupPath) {
			Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
		}
	}
}

function Write-Manifest {
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)]$Manifest
	)

	$json = $Manifest | ConvertTo-Json -Depth 16
	Write-Utf8Atomic $Path "$json`n"
}

function Enter-LifecycleLock {
	param(
		[Parameter(Mandatory = $true)][string]$LockPath,
		[Parameter(Mandatory = $true)][int]$TimeoutSeconds
	)

	$parent = Split-Path -Parent $LockPath
	if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
		New-Item -ItemType Directory -Path $parent -Force | Out-Null
	}
	$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
	while ([DateTime]::UtcNow -lt $deadline) {
		try {
			return [IO.File]::Open($LockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
		} catch [IO.IOException] {
			Start-Sleep -Milliseconds 200
		}
	}
	throw "Timed out waiting for lifecycle lock: $LockPath"
}

function Assert-PhysicalDirectory {
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)][string]$Description
	)

	$item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
	if (-not $item -or -not ($item -is [IO.DirectoryInfo])) {
		throw "$Description must be a directory: $Path"
	}
	if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
		throw "$Description must be a physical non-reparse directory: $Path"
	}
}

function Assert-WorktreeProjectionSafety {
	param([Parameter(Mandatory = $true)][string]$Repo)

	foreach ($directory in @("docs", ".agent-work")) {
		$path = Join-Path $Repo $directory
		if (Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue) {
			Assert-PhysicalDirectory $path "Per-worktree $directory root"
		}
	}
	foreach ($relativePath in @(
		"AGENTS.md",
		"CLAUDE.md",
		"docs/init-branch-docs.ps1",
		"docs/init-branch-docs.sh"
	)) {
		$path = Join-Path $Repo $relativePath
		$item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
		if ($item -and ($item -is [IO.DirectoryInfo] -or
			($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
			throw "Per-worktree managed file must be a regular non-reparse file: $path"
		}
	}
}

function Get-JunctionTarget {
	param([Parameter(Mandatory = $true)][string]$Path)

	$item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
	if (-not $item) {
		return $null
	}
	if ($item.LinkType -ne "Junction") {
		throw "Expected a junction but found '$($item.LinkType)' at $Path."
	}
	$targets = @($item.Target)
	if ($targets.Count -ne 1 -or -not $targets[0]) {
		throw "Unable to resolve the junction target at $Path."
	}
	return Normalize-Path $targets[0]
}

function Assert-OrCreateJunction {
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)][string]$Target,
		[switch]$Create
	)

	$item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
	if ($item) {
		$actualTarget = Get-JunctionTarget $Path
		if (-not (Test-PathEqual $actualTarget $Target)) {
			throw "Wrong junction target at $Path. Expected '$Target', found '$actualTarget'."
		}
		return
	}
	if (-not $Create) {
		throw "Expected junction is missing: $Path"
	}
	New-Item -ItemType Junction -Path $Path -Target $Target | Out-Null
}

function Copy-File {
	param(
		[Parameter(Mandatory = $true)][string]$Source,
		[Parameter(Mandatory = $true)][string]$Target,
		[switch]$OnlyIfMissing
	)

	$targetItem = Get-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
	if ($targetItem) {
		if ($targetItem -is [IO.DirectoryInfo] -or
			($targetItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
			throw "Managed file target must be a regular non-reparse file: $Target"
		}
		if ($OnlyIfMissing) {
			return
		}
	}
	$parent = Split-Path -Parent $Target
	if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
		New-Item -ItemType Directory -Path $parent -Force | Out-Null
	}
	Copy-Item -LiteralPath $Source -Destination $Target -Force
}

function Upsert-MarkedBlock {
	param(
		[Parameter(Mandatory = $true)][string]$TargetPath,
		[Parameter(Mandatory = $true)][string]$BlockPath,
		[Parameter(Mandatory = $true)][string]$BeginMarker,
		[Parameter(Mandatory = $true)][string]$EndMarker,
		[string]$CreateTitle
	)

	$block = [IO.File]::ReadAllText($BlockPath)
	if (-not (Test-Path -LiteralPath $TargetPath)) {
		$text = ""
		if ($CreateTitle) {
			$text = "$CreateTitle`n`n"
		}
		Write-Utf8Atomic $TargetPath ($text + ($block -replace "`r?`n", "`n"))
		return
	}

	$item = Get-Item -LiteralPath $TargetPath -Force
	if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item -is [IO.DirectoryInfo]) {
		throw "Managed instruction target must be a regular file: $TargetPath"
	}
	$text = [IO.File]::ReadAllText($TargetPath)
	$lineEnding = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
	$text = $text -replace "`r?`n", $lineEnding
	$block = $block -replace "`r?`n", $lineEnding
	$beginPattern = "(?m)^" + [regex]::Escape($BeginMarker) + "(?=`r?$)"
	$endPattern = "(?m)^" + [regex]::Escape($EndMarker) + "(`r?`n|$)"
	$beginMatches = [regex]::Matches($text, $beginPattern)
	if ($beginMatches.Count -gt 1) {
		throw "More than one begin marker in $TargetPath"
	}
	if ($beginMatches.Count -eq 1) {
		$beginMatch = $beginMatches[0]
		$endMatch = [regex]::Match($text, $endPattern, [Text.RegularExpressions.RegexOptions]::None, [TimeSpan]::FromSeconds(2))
		if (-not $endMatch.Success -or $endMatch.Index -lt $beginMatch.Index) {
			throw "Matching end marker not found in $TargetPath"
		}
		$newText = $text.Substring(0, $beginMatch.Index) + $block + $text.Substring($endMatch.Index + $endMatch.Length)
		Write-Utf8Atomic $TargetPath $newText
		return
	}

	if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) {
		$text += $lineEnding
	}
	Write-Utf8Atomic $TargetPath ($text + $lineEnding + $block)
}

function Get-ManagedExcludePatterns {
	param([Parameter(Mandatory = $true)][string]$Anchor)

	$patterns = @(
		"/.agent-work/",
		"/docs/branches/",
		"/docs/index/",
		"/docs/work/",
		"/docs/init-branch-docs.ps1",
		"/docs/init-branch-docs.sh"
	)
	if (-not (Test-GitTracked $Anchor "AGENTS.md")) {
		$patterns += "/AGENTS.md"
	}
	if (-not (Test-GitTracked $Anchor "CLAUDE.md")) {
		$patterns += "/CLAUDE.md"
	}
	return $patterns
}

function Get-InstructionOwnership {
	param([Parameter(Mandatory = $true)][string]$Repo)

	return [pscustomobject][ordered]@{
		agentsTracked = [bool](Test-GitTracked $Repo "AGENTS.md")
		claudeTracked = [bool](Test-GitTracked $Repo "CLAUDE.md")
		codexConfigTracked = [bool](Test-GitTracked $Repo ".codex/config.toml")
	}
}

function Get-ManagedExcludePatternsFromOwnership {
	param([Parameter(Mandatory = $true)]$Ownership)

	$patterns = @(
		"/.agent-work/",
		"/docs/branches/",
		"/docs/index/",
		"/docs/work/",
		"/docs/init-branch-docs.ps1",
		"/docs/init-branch-docs.sh"
	)
	if (-not [bool]$Ownership.agentsTracked) {
		$patterns += "/AGENTS.md"
	}
	if (-not [bool]$Ownership.claudeTracked) {
		$patterns += "/CLAUDE.md"
	}
	return $patterns
}

function Assert-InstructionOwnership {
	param(
		[Parameter(Mandatory = $true)][string]$Repo,
		[Parameter(Mandatory = $true)]$Expected
	)

	foreach ($property in @("agentsTracked", "claudeTracked", "codexConfigTracked")) {
		if (-not $Expected.PSObject.Properties[$property] -or
			-not ($Expected.$property -is [bool])) {
			throw "Manifest instructionOwnership.$property must be a boolean."
		}
	}
	$actual = Get-InstructionOwnership $Repo
	foreach ($property in @("agentsTracked", "claudeTracked", "codexConfigTracked")) {
		if ([bool]$actual.$property -ne [bool]$Expected.$property) {
			throw "Target ownership for $property does not match the common-store manifest ownership."
		}
	}
}

function Assert-ManifestExcludePatterns {
	param(
		[Parameter(Mandatory = $true)]$Manifest,
		[Parameter(Mandatory = $true)][string]$Anchor
	)

	$expected = @(Get-ManagedExcludePatterns $Anchor)
	$actual = @($Manifest.commonExcludePatterns)
	if ($actual.Count -ne $expected.Count) {
		throw "Manifest commonExcludePatterns does not match the exact ownership-derived pattern set."
	}
	for ($index = 0; $index -lt $expected.Count; $index++) {
		if (-not ($actual[$index] -is [string]) -or $actual[$index] -cne $expected[$index]) {
			throw "Manifest commonExcludePatterns does not match the exact ownership-derived pattern set."
		}
	}
}

function Assert-CommonExcludeState {
	param(
		[Parameter(Mandatory = $true)][string]$CommonDir,
		[Parameter(Mandatory = $true)][string[]]$ExpectedPatterns,
		[switch]$RequireManagedBlock
	)

	$path = Join-Path $CommonDir "info/exclude"
	if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
		if ($RequireManagedBlock) {
			throw "Managed common exclude file is missing: $path"
		}
		return
	}
	$item = Get-Item -LiteralPath $path -Force
	if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
		throw "Common exclude must be a regular non-reparse file: $path"
	}
	$lines = @([IO.File]::ReadAllLines($path))
	$beginIndexes = @()
	$endIndexes = @()
	for ($index = 0; $index -lt $lines.Count; $index++) {
		if ($lines[$index] -ceq $script:BeginMarker) { $beginIndexes += $index }
		if ($lines[$index] -ceq $script:EndMarker) { $endIndexes += $index }
	}
	if ($beginIndexes.Count -eq 0 -and $endIndexes.Count -eq 0) {
		if ($RequireManagedBlock) {
			throw "Managed common exclude block is missing: $path"
		}
		return
	}
	if ($beginIndexes.Count -ne 1 -or $endIndexes.Count -ne 1 -or $beginIndexes[0] -ge $endIndexes[0]) {
		throw "Managed common exclude markers are malformed or duplicated: $path"
	}
	$managedLines = @($lines[$beginIndexes[0]..$endIndexes[0]])
	$expectedLines = @($script:BeginMarker) + @($ExpectedPatterns) + @($script:EndMarker)
	if ($managedLines.Count -ne $expectedLines.Count) {
		throw "Managed common exclude block does not match the exact ownership-derived pattern set."
	}
	for ($index = 0; $index -lt $expectedLines.Count; $index++) {
		if ($managedLines[$index] -cne $expectedLines[$index]) {
			throw "Managed common exclude block does not match the exact ownership-derived pattern set."
		}
	}
}

function Upsert-CommonExclude {
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)][string[]]$Patterns
	)

	$blockLines = @($script:BeginMarker) + @($Patterns) + @($script:EndMarker)
	$block = ($blockLines -join "`n") + "`n"
	$text = if (Test-Path -LiteralPath $Path -PathType Leaf) { [IO.File]::ReadAllText($Path) } else { "" }
	$beginPattern = "(?m)^" + [regex]::Escape($script:BeginMarker) + "(?=`r?$)"
	$endPattern = "(?m)^" + [regex]::Escape($script:EndMarker) + "(`r?`n|$)"
	$beginMatches = [regex]::Matches($text, $beginPattern)
	if ($beginMatches.Count -gt 1) {
		throw "Duplicate branch-docs-starter blocks in $Path"
	}
	if ($beginMatches.Count -eq 1) {
		$beginMatch = $beginMatches[0]
		$endMatch = [regex]::Match($text.Substring($beginMatch.Index + $beginMatch.Length), $endPattern)
		if (-not $endMatch.Success) {
			throw "Unmatched branch-docs-starter block in $Path"
		}
		$absoluteEnd = $beginMatch.Index + $beginMatch.Length + $endMatch.Index + $endMatch.Length
		$text = $text.Substring(0, $beginMatch.Index) + $block + $text.Substring($absoluteEnd)
	} else {
		if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) {
			$text += "`n"
		}
		if ($text.Length -gt 0) {
			$text += "`n"
		}
		$text += $block
	}
	Write-Utf8Atomic $Path ($text -replace "`r?`n", "`n")
}

function Install-PerWorktreeFiles {
	param([Parameter(Mandatory = $true)][string]$Repo)

	$agentWork = Join-Path $Repo ".agent-work"
	if (-not (Test-Path -LiteralPath $agentWork -PathType Container)) {
		New-Item -ItemType Directory -Path $agentWork -Force | Out-Null
	}
	Assert-PhysicalDirectory $agentWork "Per-worktree .agent-work root"
	Copy-File (Join-Path $script:PackageRoot ".agent-work/.gitignore") (Join-Path $agentWork ".gitignore") -OnlyIfMissing
	Copy-File (Join-Path $script:PackageRoot ".agent-work/README.md") (Join-Path $agentWork "README.md") -OnlyIfMissing

	if (-not (Test-GitTracked $Repo "AGENTS.md")) {
		Upsert-MarkedBlock `
			-TargetPath (Join-Path $Repo "AGENTS.md") `
			-BlockPath (Join-Path $script:PackageRoot "AGENTS.branch-docs.md") `
			-BeginMarker "<!-- branch-docs-starter:begin -->" `
			-EndMarker "<!-- branch-docs-starter:end -->" `
			-CreateTitle "# Repository Guidelines"
	}
	if (-not (Test-GitTracked $Repo "CLAUDE.md")) {
		Upsert-MarkedBlock `
			-TargetPath (Join-Path $Repo "CLAUDE.md") `
			-BlockPath (Join-Path $script:PackageRoot "CLAUDE.branch-docs.md") `
			-BeginMarker "<!-- branch-docs-starter:begin -->" `
			-EndMarker "<!-- branch-docs-starter:end -->" `
			-CreateTitle "# Claude Code Instructions"
	}

	Copy-File (Join-Path $script:PackageRoot "docs/init-branch-docs.ps1") (Join-Path $Repo "docs/init-branch-docs.ps1")
	Copy-File (Join-Path $script:PackageRoot "docs/init-branch-docs.sh") (Join-Path $Repo "docs/init-branch-docs.sh")
}

function Install-AnchorStore {
	param([Parameter(Mandatory = $true)][string]$Anchor)

	$docsRoot = Join-Path $Anchor "docs"
	if (-not (Test-Path -LiteralPath $docsRoot)) {
		New-Item -ItemType Directory -Path $docsRoot -Force | Out-Null
	}
	Assert-PhysicalDirectory $docsRoot "Anchor docs root"

	$branchesRoot = Join-Path $docsRoot "branches"
	$indexRoot = Join-Path $docsRoot "index"
	$workRoot = Join-Path $docsRoot "work"
	foreach ($directory in @($branchesRoot, $indexRoot, $workRoot)) {
		if (-not (Test-Path -LiteralPath $directory)) {
			New-Item -ItemType Directory -Path $directory -Force | Out-Null
		}
		Assert-PhysicalDirectory $directory "Anchor reserved namespace"
	}

	Copy-File (Join-Path $script:PackageRoot "docs/branches/README.md") (Join-Path $branchesRoot "README.md")
	Copy-File (Join-Path $script:PackageRoot "docs/index/README.md") (Join-Path $indexRoot "README.md")
	Copy-File (Join-Path $script:PackageRoot "docs/work/README.md") (Join-Path $workRoot "README.md")
	Copy-File (Join-Path $script:PackageRoot "docs/index/branch-bindings.json") (Join-Path $indexRoot "branch-bindings.json") -OnlyIfMissing
	Copy-File (Join-Path $script:PackageRoot "docs/index/work-items.json") (Join-Path $indexRoot "work-items.json") -OnlyIfMissing

	$templateSource = Join-Path $script:PackageRoot "docs/branches/_template"
	$templateTarget = Join-Path $branchesRoot "_template"
	if (-not (Test-Path -LiteralPath $templateTarget)) {
		New-Item -ItemType Directory -Path $templateTarget -Force | Out-Null
	}
	Assert-PhysicalDirectory $templateTarget "Anchor branch-doc template root"
	$reparseDescendants = @(Get-ChildItem -LiteralPath $templateTarget -Recurse -Force -ErrorAction Stop |
		Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
	if ($reparseDescendants.Count -gt 0) {
		throw "Anchor branch-doc template contains a reparse point: $($reparseDescendants[0].FullName)"
	}
	Copy-Item -Path (Join-Path $templateSource "*") -Destination $templateTarget -Recurse -Force

	return [pscustomobject]@{
		DocsRoot = $docsRoot
		BranchesRoot = $branchesRoot
		IndexRoot = $indexRoot
		WorkRoot = $workRoot
	}
}

function Get-CommonStoreLayout {
	param([Parameter(Mandatory = $true)][string]$CommonDir)

	$stateRoot = Join-Path $CommonDir "branch-docs-starter"
	$storeRoot = Join-Path $CommonDir $script:CommonStoreRelativePath
	return [pscustomobject][ordered]@{
		StateRoot = Normalize-Path $stateRoot
		StoreRoot = Normalize-Path $storeRoot
		BranchesRoot = Normalize-Path (Join-Path $storeRoot "branches")
		IndexRoot = Normalize-Path (Join-Path $storeRoot "index")
		WorkRoot = Normalize-Path (Join-Path $storeRoot "work")
		ManifestPath = Normalize-Path (Join-Path $stateRoot "manifest.json")
		LockPath = Normalize-Path (Join-Path $stateRoot "lifecycle.lock")
	}
}

function Install-CommonStore {
	param([Parameter(Mandatory = $true)]$Layout)

	if (-not (Test-Path -LiteralPath $Layout.StoreRoot)) {
		New-Item -ItemType Directory -Path $Layout.StoreRoot -Force | Out-Null
	}
	Assert-PhysicalDirectory $Layout.StoreRoot "Common branch-docs store root"

	foreach ($directory in @($Layout.BranchesRoot, $Layout.IndexRoot, $Layout.WorkRoot)) {
		if (-not (Test-Path -LiteralPath $directory)) {
			New-Item -ItemType Directory -Path $directory -Force | Out-Null
		}
		Assert-PhysicalDirectory $directory "Common branch-docs reserved namespace"
	}

	Copy-File (Join-Path $script:PackageRoot "docs/branches/README.md") (Join-Path $Layout.BranchesRoot "README.md")
	Copy-File (Join-Path $script:PackageRoot "docs/index/README.md") (Join-Path $Layout.IndexRoot "README.md")
	Copy-File (Join-Path $script:PackageRoot "docs/work/README.md") (Join-Path $Layout.WorkRoot "README.md")
	Copy-File (Join-Path $script:PackageRoot "docs/index/branch-bindings.json") (Join-Path $Layout.IndexRoot "branch-bindings.json") -OnlyIfMissing
	Copy-File (Join-Path $script:PackageRoot "docs/index/work-items.json") (Join-Path $Layout.IndexRoot "work-items.json") -OnlyIfMissing

	$templateSource = Join-Path $script:PackageRoot "docs/branches/_template"
	$templateTarget = Join-Path $Layout.BranchesRoot "_template"
	if (-not (Test-Path -LiteralPath $templateTarget)) {
		New-Item -ItemType Directory -Path $templateTarget -Force | Out-Null
	}
	Assert-PhysicalDirectory $templateTarget "Common branch-doc template root"
	$reparseDescendants = @(Get-ChildItem -LiteralPath $templateTarget -Recurse -Force -ErrorAction Stop |
		Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
	if ($reparseDescendants.Count -gt 0) {
		throw "Common branch-doc template contains a reparse point: $($reparseDescendants[0].FullName)"
	}
	Copy-Item -Path (Join-Path $templateSource "*") -Destination $templateTarget -Recurse -Force
}

function Verify-EffectiveIgnore {
	param(
		[Parameter(Mandatory = $true)][string]$Repo,
		[Parameter(Mandatory = $true)][string[]]$Patterns
	)

	foreach ($path in @(
		"docs/branches/.branch-docs-ignore-probe",
		"docs/index/.branch-docs-ignore-probe",
		"docs/work/.branch-docs-ignore-probe",
		"docs/init-branch-docs.ps1",
		"docs/init-branch-docs.sh",
		".agent-work/.branch-docs-ignore-probe"
	)) {
		$result = Invoke-Git -Repo $Repo -Arguments @("check-ignore", "--no-index", "-q", "--", $path) -AllowFailure
		if ($result.ExitCode -ne 0) {
			throw "Expected starter-owned path to be ignored: $path"
		}
	}

	foreach ($path in @(
		"docs/.branch-docs-product-probe.md",
		"docs/customize/.branch-docs-product-probe.md"
	)) {
		$result = Invoke-Git -Repo $Repo -Arguments @("check-ignore", "--no-index", "-q", "--", $path) -AllowFailure
		if ($result.ExitCode -eq 0) {
			throw "Product documentation probe is unexpectedly ignored: $path"
		}
		if ($result.ExitCode -ne 1) {
			throw "git check-ignore failed for product documentation probe: $path"
		}
	}

	# A repository may intentionally keep a tracked instruction or config file matched by an
	# older ignore rule. Git continues to track that file, so bootstrap preserves it and does
	# not reinterpret the repository's policy. Get-ManagedExcludePatterns independently keeps
	# these paths out of the starter-managed common exclude block when they are tracked.
}

function Verify-ProductDocumentationNotIgnored {
	param([Parameter(Mandatory = $true)][string]$Repo)

	foreach ($path in @(
		"docs/.branch-docs-product-probe.md",
		"docs/customize/.branch-docs-product-probe.md"
	)) {
		$result = Invoke-Git -Repo $Repo -Arguments @("check-ignore", "--no-index", "-q", "--", $path) -AllowFailure
		if ($result.ExitCode -eq 0) {
			throw "Product documentation probe is unexpectedly ignored: $path"
		}
		if ($result.ExitCode -ne 1) {
			throw "git check-ignore failed for product documentation probe: $path"
		}
	}
}

function Assert-AuthoritativeState {
	param(
		[Parameter(Mandatory = $true)]$TargetContext,
		[Parameter(Mandatory = $true)]$AnchorContext,
		$Manifest,
		[switch]$AllowUnapprovedCurrentIgnorePolicy
	)

	if (-not (Test-PathEqual $TargetContext.CommonDir $AnchorContext.CommonDir)) {
		throw "Target and anchor do not share the same Git common directory."
	}
	if (-not $AnchorContext.IsMainWorktree) {
		throw "AnchorRepo must be the main worktree: $($AnchorContext.Root)"
	}

	Assert-WorktreeProjectionSafety $AnchorContext.Root
	if (-not (Test-PathEqual $TargetContext.Root $AnchorContext.Root)) {
		Assert-WorktreeProjectionSafety $TargetContext.Root
	}
	if (Test-PathEqual $TargetContext.Root $AnchorContext.Root) {
		foreach ($name in @("branches", "index", "work")) {
			$path = Join-Path $AnchorContext.Root "docs/$name"
			if (Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue) {
				Assert-PhysicalDirectory $path "Anchor reserved namespace"
			}
		}
	}

	Assert-NoReservedCollisions $AnchorContext.Root
	if (-not (Test-PathEqual $TargetContext.Root $AnchorContext.Root)) {
		Assert-NoReservedCollisions $TargetContext.Root
	}
	Assert-TrackedInstructionCompatibility $AnchorContext.Root
	if (-not (Test-PathEqual $TargetContext.Root $AnchorContext.Root)) {
		Assert-TrackedInstructionCompatibility $TargetContext.Root
	}
	Assert-IgnorePolicyPreflight $AnchorContext.Root
	if (-not (Test-PathEqual $TargetContext.Root $AnchorContext.Root)) {
		Assert-IgnorePolicyPreflight $TargetContext.Root
	}
	foreach ($relativePath in @("AGENTS.md", "CLAUDE.md")) {
		$anchorTracked = Test-GitTracked $AnchorContext.Root $relativePath
		$targetTracked = Test-GitTracked $TargetContext.Root $relativePath
		if ($anchorTracked -ne $targetTracked) {
			throw "Target ownership for $relativePath does not match the anchor manifest ownership."
		}
	}
	Verify-ProductDocumentationNotIgnored $TargetContext.Root

	if (-not $Manifest) {
		if (-not (Test-PathEqual $TargetContext.Root $AnchorContext.Root)) {
			throw "Anchor is not initialized. Run bootstrap against AnchorRepo first."
		}
		$initialPatterns = @(Get-ManagedExcludePatterns $AnchorContext.Root)
		Assert-CommonExcludeState $AnchorContext.CommonDir $initialPatterns
		return
	}

	if ([int]$Manifest.schemaVersion -ne $script:SchemaVersion) {
		throw "Unsupported manifest schema version: $($Manifest.schemaVersion)"
	}
	foreach ($property in @(
		"anchorRepoRoot",
		"commonDir",
		"branchesRoot",
		"indexRoot",
		"workRoot",
		"starterRevision",
		"approvedIgnoreFingerprints",
		"ignoreFingerprintAlgorithm",
		"commonExcludePatterns"
	)) {
		if (-not $Manifest.PSObject.Properties[$property] -or $null -eq $Manifest.$property) {
			throw "Manifest property '$property' is missing."
		}
	}
	if (-not (Test-PathEqual $Manifest.anchorRepoRoot $AnchorContext.Root)) {
		throw "Manifest anchor does not match -AnchorRepo."
	}
	if ($Manifest.ignoreFingerprintAlgorithm -cne "tracked-gitignore-path-blob-v1") {
		throw "Unsupported ignore fingerprint algorithm: $($Manifest.ignoreFingerprintAlgorithm)"
	}
	Assert-ManifestExcludePatterns $Manifest $AnchorContext.Root
	Assert-CommonExcludeState `
		-CommonDir $AnchorContext.CommonDir `
		-ExpectedPatterns @($Manifest.commonExcludePatterns) `
		-RequireManagedBlock
	$expectedDocsRoot = Join-Path $AnchorContext.Root "docs"
	if (-not (Test-PathEqual $Manifest.commonDir $AnchorContext.CommonDir) -or
		-not (Test-PathEqual $Manifest.branchesRoot (Join-Path $expectedDocsRoot "branches")) -or
		-not (Test-PathEqual $Manifest.indexRoot (Join-Path $expectedDocsRoot "index")) -or
		-not (Test-PathEqual $Manifest.workRoot (Join-Path $expectedDocsRoot "work"))) {
		throw "Manifest roots do not match the exact anchor repository layout."
	}
	if (-not (Test-PathEqual $TargetContext.Root $AnchorContext.Root)) {
		$childDocsRoot = Join-Path $TargetContext.Root "docs"
		if (Get-Item -LiteralPath $childDocsRoot -Force -ErrorAction SilentlyContinue) {
			Assert-PhysicalDirectory $childDocsRoot "Child docs root"
		}
		foreach ($projection in @(
			@("branches", $Manifest.branchesRoot),
			@("index", $Manifest.indexRoot),
			@("work", $Manifest.workRoot)
		)) {
			$projectionPath = Join-Path $childDocsRoot $projection[0]
			if (Get-Item -LiteralPath $projectionPath -Force -ErrorAction SilentlyContinue) {
				Assert-OrCreateJunction $projectionPath $projection[1]
			}
		}
	}

	if (-not $AllowUnapprovedCurrentIgnorePolicy) {
		$currentFingerprint = Get-IgnoreFingerprint $TargetContext.Root
		if ($Manifest.approvedIgnoreFingerprints -notcontains $currentFingerprint) {
			throw "Current tracked ignore-policy fingerprint is not approved: $currentFingerprint"
		}
	}
}

function Assert-CommonStoreProjection {
	param(
		[Parameter(Mandatory = $true)]$TargetContext,
		[Parameter(Mandatory = $true)]$Layout,
		[switch]$Create,
		[switch]$Require
	)

	$docsRoot = Join-Path $TargetContext.Root "docs"
	$docsItem = Get-Item -LiteralPath $docsRoot -Force -ErrorAction SilentlyContinue
	if (-not $docsItem -and $Create) {
		New-Item -ItemType Directory -Path $docsRoot -Force | Out-Null
		$docsItem = Get-Item -LiteralPath $docsRoot -Force
	}
	if ($docsItem) {
		Assert-PhysicalDirectory $docsRoot "Worktree docs root"
	} elseif ($Require) {
		throw "Worktree docs root is missing: $docsRoot"
	} else {
		return
	}

	foreach ($projection in @(
		@("branches", $Layout.BranchesRoot),
		@("index", $Layout.IndexRoot),
		@("work", $Layout.WorkRoot)
	)) {
		$projectionPath = Join-Path $docsRoot $projection[0]
		$item = Get-Item -LiteralPath $projectionPath -Force -ErrorAction SilentlyContinue
		if ($item) {
			Assert-OrCreateJunction $projectionPath $projection[1]
		} elseif ($Create) {
			Assert-OrCreateJunction $projectionPath $projection[1] -Create
		} elseif ($Require) {
			throw "Expected common-store junction is missing: $projectionPath"
		}
	}
}

function Assert-CommonStoreManifest {
	param(
		[Parameter(Mandatory = $true)]$TargetContext,
		[Parameter(Mandatory = $true)]$Manifest,
		[Parameter(Mandatory = $true)]$Layout,
		[switch]$AllowUnapprovedCurrentIgnorePolicy,
		[switch]$RequireProjection
	)

	if ([int]$Manifest.schemaVersion -ne $script:CommonStoreSchemaVersion) {
		throw "Unsupported common-store manifest schema version: $($Manifest.schemaVersion)"
	}
	foreach ($property in @(
		"layout",
		"storeRelativePath",
		"starterRevision",
		"instructionOwnership",
		"commonExcludePatterns",
		"ignoreFingerprintAlgorithm",
		"approvedIgnoreFingerprints"
	)) {
		if (-not $Manifest.PSObject.Properties[$property] -or $null -eq $Manifest.$property) {
			throw "Manifest property '$property' is missing."
		}
	}
	if ($Manifest.layout -cne $script:CommonStoreLayoutName) {
		throw "Unsupported common-store layout: $($Manifest.layout)"
	}
	if ($Manifest.storeRelativePath -cne $script:CommonStoreRelativePath) {
		throw "Manifest storeRelativePath must be '$($script:CommonStoreRelativePath)'."
	}
	if ($Manifest.ignoreFingerprintAlgorithm -cne "tracked-gitignore-path-blob-v1") {
		throw "Unsupported ignore fingerprint algorithm: $($Manifest.ignoreFingerprintAlgorithm)"
	}

	Assert-PhysicalDirectory $Layout.StoreRoot "Common branch-docs store root"
	foreach ($path in @($Layout.BranchesRoot, $Layout.IndexRoot, $Layout.WorkRoot)) {
		Assert-PhysicalDirectory $path "Common branch-docs reserved namespace"
	}

	Assert-WorktreeProjectionSafety $TargetContext.Root
	Assert-NoReservedCollisions $TargetContext.Root
	Assert-TrackedInstructionCompatibility $TargetContext.Root
	Assert-IgnorePolicyPreflight $TargetContext.Root
	Assert-InstructionOwnership $TargetContext.Root $Manifest.instructionOwnership
	Verify-ProductDocumentationNotIgnored $TargetContext.Root

	$expectedPatterns = @(Get-ManagedExcludePatternsFromOwnership $Manifest.instructionOwnership)
	$actualPatterns = @($Manifest.commonExcludePatterns)
	if ($actualPatterns.Count -ne $expectedPatterns.Count) {
		throw "Manifest commonExcludePatterns does not match the exact ownership-derived pattern set."
	}
	for ($index = 0; $index -lt $expectedPatterns.Count; $index++) {
		if (-not ($actualPatterns[$index] -is [string]) -or
			$actualPatterns[$index] -cne $expectedPatterns[$index]) {
			throw "Manifest commonExcludePatterns does not match the exact ownership-derived pattern set."
		}
	}
	Assert-CommonExcludeState `
		-CommonDir $TargetContext.CommonDir `
		-ExpectedPatterns $expectedPatterns `
		-RequireManagedBlock
	Assert-CommonStoreProjection `
		-TargetContext $TargetContext `
		-Layout $Layout `
		-Require:$RequireProjection

	if (-not $AllowUnapprovedCurrentIgnorePolicy) {
		$currentFingerprint = Get-IgnoreFingerprint $TargetContext.Root
		if ($Manifest.approvedIgnoreFingerprints -notcontains $currentFingerprint) {
			throw "Current tracked ignore-policy fingerprint is not approved: $currentFingerprint"
		}
	}
}

function Assert-CommonStoreInitializationPreflight {
	param(
		[Parameter(Mandatory = $true)]$TargetContext,
		[Parameter(Mandatory = $true)]$Layout
	)

	Assert-WorktreeProjectionSafety $TargetContext.Root
	Assert-NoReservedCollisions $TargetContext.Root
	Assert-TrackedInstructionCompatibility $TargetContext.Root
	Assert-IgnorePolicyPreflight $TargetContext.Root
	Verify-ProductDocumentationNotIgnored $TargetContext.Root
	if (Get-Item -LiteralPath $Layout.StoreRoot -Force -ErrorAction SilentlyContinue) {
		throw "Common branch-docs store exists without a schema-v2 manifest: $($Layout.StoreRoot)"
	}
	$ownership = Get-InstructionOwnership $TargetContext.Root
	$patterns = @(Get-ManagedExcludePatternsFromOwnership $ownership)
	Assert-CommonExcludeState $TargetContext.CommonDir $patterns
	Assert-CommonStoreProjection -TargetContext $TargetContext -Layout $Layout
	return [pscustomobject][ordered]@{
		Ownership = $ownership
		Patterns = $patterns
	}
}

function Get-StarterRevision {
	$result = Invoke-Git -Repo $script:PackageRoot -Arguments @("rev-parse", "--verify", "HEAD") -AllowFailure
	return $(if ($result.ExitCode -eq 0) { $result.Text } else { "uncommitted" })
}

function Invoke-CommonStoreMode {
	param(
		[Parameter(Mandatory = $true)]$InitialTargetContext,
		$InitialManifest
	)

	$targetContext = $InitialTargetContext
	$layout = Get-CommonStoreLayout $targetContext.CommonDir
	$manifest = $InitialManifest
	if ($manifest -and [int]$manifest.schemaVersion -eq $script:SchemaVersion) {
		throw "Legacy anchor manifest detected. Run migrate-anchorless-store.ps1 before using -CommonStore."
	}
	if ($manifest -and [int]$manifest.schemaVersion -ne $script:CommonStoreSchemaVersion) {
		throw "Unsupported branch-docs manifest schema version: $($manifest.schemaVersion)"
	}

	if ($manifest) {
		Assert-CommonStoreManifest `
			-TargetContext $targetContext `
			-Manifest $manifest `
			-Layout $layout `
			-AllowUnapprovedCurrentIgnorePolicy:$ApproveCurrentIgnorePolicy
	} else {
		Assert-CommonStoreInitializationPreflight -TargetContext $targetContext -Layout $layout | Out-Null
	}

	if ($DryRun) {
		Write-Output "DRY RUN"
		Write-Output "mode=common-store"
		Write-Output "target=$($targetContext.Root)"
		Write-Output "commonDir=$($targetContext.CommonDir)"
		Write-Output "storeRoot=$($layout.StoreRoot)"
		return
	}

	if ($ApproveCurrentIgnorePolicy) {
		if (-not $manifest) {
			throw "Ignore-policy approval requires an existing manifest."
		}
		$approvalLock = $null
		try {
			$approvalLock = Enter-LifecycleLock $layout.LockPath $LockTimeoutSeconds
			$targetContext = Get-RepoContext $targetContext.Root
			$layout = Get-CommonStoreLayout $targetContext.CommonDir
			$manifest = Read-Manifest $layout.ManifestPath
			if (-not $manifest) {
				throw "Branch-docs manifest disappeared while waiting for the lifecycle lock."
			}
			Assert-CommonStoreManifest `
				-TargetContext $targetContext `
				-Manifest $manifest `
				-Layout $layout `
				-AllowUnapprovedCurrentIgnorePolicy
			$expected = $ExpectedHeadOid.ToLowerInvariant()
			$currentOid = Get-FullCommitOid $targetContext.Root "HEAD"
			if ($expected -ne $currentOid) {
				throw "HEAD OID mismatch. Expected $expected, found $currentOid."
			}
			$ignoreDiff = Invoke-Git `
				-Repo $targetContext.Root `
				-Arguments @("diff", "--quiet", "HEAD", "--", ".gitignore", ":(glob)**/.gitignore") `
				-AllowFailure
			if ($ignoreDiff.ExitCode -ne 0) {
				throw "Tracked .gitignore files differ from the reviewed HEAD; commit or restore them before approval."
			}
			$reviewedFingerprint = Get-IgnoreFingerprint $targetContext.Root $currentOid
			$indexedFingerprint = Get-IgnoreFingerprint $targetContext.Root
			if ($indexedFingerprint -ne $reviewedFingerprint) {
				throw "Tracked .gitignore index differs from the reviewed HEAD; commit or restore it before approval."
			}
			Verify-EffectiveIgnore $targetContext.Root @($manifest.commonExcludePatterns)
			$currentFingerprint = $indexedFingerprint
			if ($manifest.approvedIgnoreFingerprints -contains $currentFingerprint) {
				Write-Output "Ignore-policy fingerprint is already approved: $currentFingerprint"
				return
			}

			$approvalBackup = Normalize-Path $ApprovalBackupRoot
			if (Test-Path -LiteralPath $approvalBackup) {
				throw "Approval backup root already exists: $approvalBackup"
			}
			New-Item -ItemType Directory -Path $approvalBackup | Out-Null
			Copy-Item -LiteralPath $layout.ManifestPath -Destination (Join-Path $approvalBackup "manifest.json")
			$approvalRecord = [pscustomobject][ordered]@{
				schemaVersion = $script:CommonStoreSchemaVersion
				repoRoot = $targetContext.Root
				commonDir = $targetContext.CommonDir
				headOid = $currentOid
				approvedIgnoreFingerprint = $currentFingerprint
				createdAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssK")
			}
			Write-Manifest (Join-Path $approvalBackup "ignore-policy-approval.json") $approvalRecord

			$manifest.approvedIgnoreFingerprints = @($manifest.approvedIgnoreFingerprints) + $currentFingerprint
			$manifest.updatedAt = Get-Date -Format "yyyy-MM-ddTHH:mm:ssK"
			Write-Manifest $layout.ManifestPath $manifest
			Assert-CommonStoreManifest `
				-TargetContext $targetContext `
				-Manifest (Read-Manifest $layout.ManifestPath) `
				-Layout $layout
			Write-Output "Approved ignore-policy fingerprint: $currentFingerprint"
			Write-Output "Approval backup: $approvalBackup"
		} finally {
			if ($approvalLock) {
				$approvalLock.Dispose()
			}
		}
		return
	}

	if ($VerifyOnly) {
		if (-not $manifest) {
			throw "Verify-only requires an existing manifest."
		}
		$verifyLock = $null
		try {
			$verifyLock = Enter-LifecycleLock $layout.LockPath $LockTimeoutSeconds
			$targetContext = Get-RepoContext $targetContext.Root
			$layout = Get-CommonStoreLayout $targetContext.CommonDir
			$manifest = Read-Manifest $layout.ManifestPath
			if (-not $manifest) {
				throw "Branch-docs manifest disappeared while waiting for the lifecycle lock."
			}
			Assert-CommonStoreManifest `
				-TargetContext $targetContext `
				-Manifest $manifest `
				-Layout $layout `
				-RequireProjection
			if ($ExpectedHeadOid) {
				$expected = $ExpectedHeadOid.ToLowerInvariant()
				$currentOid = Get-FullCommitOid $targetContext.Root "HEAD"
				if ($expected -ne $currentOid) {
					throw "HEAD OID mismatch. Expected $expected, found $currentOid."
				}
			}
			if ($CandidateRef) {
				$candidateOid = Assert-Candidate $targetContext.Root $CandidateRef $manifest
				Write-Output "candidateOid=$candidateOid"
			}
			Verify-EffectiveIgnore $targetContext.Root @($manifest.commonExcludePatterns)
			Write-Output "Verified common-store branch-docs worktree: $($targetContext.Root)"
		} finally {
			if ($verifyLock) {
				$verifyLock.Dispose()
			}
		}
		return
	}

	$lock = $null
	try {
		$lock = Enter-LifecycleLock $layout.LockPath $LockTimeoutSeconds
		$targetContext = Get-RepoContext $targetContext.Root
		$layout = Get-CommonStoreLayout $targetContext.CommonDir
		$manifest = Read-Manifest $layout.ManifestPath
		if ($manifest -and [int]$manifest.schemaVersion -ne $script:CommonStoreSchemaVersion) {
			throw "Common-store bootstrap found a non-v2 manifest while waiting for the lifecycle lock."
		}

		if (-not $manifest) {
			$initial = Assert-CommonStoreInitializationPreflight -TargetContext $targetContext -Layout $layout
			Install-CommonStore $layout
			$ignoreFingerprint = Get-IgnoreFingerprint $targetContext.Root
			$manifest = [pscustomobject][ordered]@{
				schemaVersion = $script:CommonStoreSchemaVersion
				layout = $script:CommonStoreLayoutName
				storeRelativePath = $script:CommonStoreRelativePath
				starterRevision = Get-StarterRevision
				instructionOwnership = $initial.Ownership
				commonExcludePatterns = @($initial.Patterns)
				ignoreFingerprintAlgorithm = "tracked-gitignore-path-blob-v1"
				approvedIgnoreFingerprints = @($ignoreFingerprint)
				updatedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssK")
			}
			Upsert-CommonExclude (Join-Path $targetContext.CommonDir "info/exclude") @($manifest.commonExcludePatterns)
			Write-Manifest $layout.ManifestPath $manifest
		} else {
			Assert-CommonStoreManifest -TargetContext $targetContext -Manifest $manifest -Layout $layout
			Install-CommonStore $layout
			$manifest.starterRevision = Get-StarterRevision
			$manifest.updatedAt = Get-Date -Format "yyyy-MM-ddTHH:mm:ssK"
			Write-Manifest $layout.ManifestPath $manifest
			Upsert-CommonExclude (Join-Path $targetContext.CommonDir "info/exclude") @($manifest.commonExcludePatterns)
		}

		Install-PerWorktreeFiles $targetContext.Root
		Assert-CommonStoreProjection -TargetContext $targetContext -Layout $layout -Create
	} finally {
		if ($lock) {
			$lock.Dispose()
		}
	}

	& $PSCommandPath `
		-TargetRepo $targetContext.Root `
		-CommonStore `
		-VerifyOnly `
		-LockTimeoutSeconds $LockTimeoutSeconds
	if ($LASTEXITCODE -ne 0) {
		throw "Post-bootstrap common-store verification failed."
	}

	$manifest = Read-Manifest $layout.ManifestPath
	$marker = [pscustomobject][ordered]@{
		schemaVersion = $script:CommonStoreSchemaVersion
		commonDir = $targetContext.CommonDir
		storeRoot = $layout.StoreRoot
		starterRevision = $manifest.starterRevision
		verifiedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssK")
	}
	Write-Manifest (Join-Path $targetContext.Root ".agent-work/branch-docs-bootstrap.json") $marker
	Write-Output "Bootstrapped common-store branch-docs worktree: $($targetContext.Root)"
}

if ($env:OS -ne "Windows_NT") {
	throw "bootstrap-worktree.ps1 supports native Windows only."
}
if ($DryRun -and $VerifyOnly) {
	throw "-DryRun and -VerifyOnly are mutually exclusive."
}
if ($CandidateRef -and -not $VerifyOnly) {
	throw "-CandidateRef requires -VerifyOnly."
}
if ($ExpectedHeadOid -and -not $VerifyOnly -and -not $ApproveCurrentIgnorePolicy) {
	throw "-ExpectedHeadOid requires -VerifyOnly or -ApproveCurrentIgnorePolicy."
}
if ($ApproveCurrentIgnorePolicy) {
	if ($DryRun -or $VerifyOnly -or $CandidateRef) {
		throw "-ApproveCurrentIgnorePolicy cannot be combined with -DryRun, -VerifyOnly, or -CandidateRef."
	}
	if (-not $ExpectedHeadOid -or -not $ApprovalBackupRoot) {
		throw "-ApproveCurrentIgnorePolicy requires -ExpectedHeadOid and -ApprovalBackupRoot."
	}
} elseif ($ApprovalBackupRoot) {
	throw "-ApprovalBackupRoot requires -ApproveCurrentIgnorePolicy."
}
if ($LockTimeoutSeconds -lt 1) {
	throw "-LockTimeoutSeconds must be at least 1."
}

$targetContext = Get-RepoContext $TargetRepo
$detectedCommonStoreLayout = Get-CommonStoreLayout $targetContext.CommonDir
$detectedManifest = Read-Manifest $detectedCommonStoreLayout.ManifestPath
if ($CommonStore -or
	($detectedManifest -and [int]$detectedManifest.schemaVersion -eq $script:CommonStoreSchemaVersion)) {
	Invoke-CommonStoreMode -InitialTargetContext $targetContext -InitialManifest $detectedManifest
	exit 0
}
if (-not $AnchorRepo) {
	throw "-AnchorRepo is required for the legacy anchor layout. Use -CommonStore for the anchorless common-dir layout."
}
$anchorContext = Get-RepoContext $AnchorRepo
if (-not (Test-PathEqual $targetContext.CommonDir $anchorContext.CommonDir)) {
	throw "Target and anchor do not share the same Git common directory."
}
if (-not $anchorContext.IsMainWorktree) {
	throw "AnchorRepo must be the main worktree: $($anchorContext.Root)"
}
Assert-WorktreeProjectionSafety $anchorContext.Root
if (-not (Test-PathEqual $targetContext.Root $anchorContext.Root)) {
	Assert-WorktreeProjectionSafety $targetContext.Root
}
if (Test-PathEqual $targetContext.Root $anchorContext.Root) {
	foreach ($name in @("branches", "index", "work")) {
		$path = Join-Path $anchorContext.Root "docs/$name"
		if (Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue) {
			Assert-PhysicalDirectory $path "Anchor reserved namespace"
		}
	}
}

Assert-NoReservedCollisions $anchorContext.Root
if (-not (Test-PathEqual $targetContext.Root $anchorContext.Root)) {
	Assert-NoReservedCollisions $targetContext.Root
}
Assert-TrackedInstructionCompatibility $anchorContext.Root
if (-not (Test-PathEqual $targetContext.Root $anchorContext.Root)) {
	Assert-TrackedInstructionCompatibility $targetContext.Root
}
Assert-IgnorePolicyPreflight $anchorContext.Root
if (-not (Test-PathEqual $targetContext.Root $anchorContext.Root)) {
	Assert-IgnorePolicyPreflight $targetContext.Root
}

$stateRoot = Join-Path $anchorContext.CommonDir "branch-docs-starter"
$manifestPath = Join-Path $stateRoot "manifest.json"
$lockPath = Join-Path $stateRoot "lifecycle.lock"
$manifest = Read-Manifest $manifestPath

if ($manifest) {
	if ([int]$manifest.schemaVersion -ne $script:SchemaVersion) {
		throw "Unsupported manifest schema version: $($manifest.schemaVersion)"
	}
	foreach ($property in @(
		"anchorRepoRoot",
		"commonDir",
		"branchesRoot",
		"indexRoot",
		"workRoot",
		"starterRevision",
		"approvedIgnoreFingerprints",
		"ignoreFingerprintAlgorithm",
		"commonExcludePatterns"
	)) {
		if (-not $manifest.PSObject.Properties[$property] -or $null -eq $manifest.$property) {
			throw "Manifest property '$property' is missing."
		}
	}
	if (-not (Test-PathEqual $manifest.anchorRepoRoot $anchorContext.Root)) {
		throw "Manifest anchor does not match -AnchorRepo."
	}
	if ($manifest.ignoreFingerprintAlgorithm -cne "tracked-gitignore-path-blob-v1") {
		throw "Unsupported ignore fingerprint algorithm: $($manifest.ignoreFingerprintAlgorithm)"
	}
	Assert-ManifestExcludePatterns $manifest $anchorContext.Root
	Assert-CommonExcludeState `
		-CommonDir $anchorContext.CommonDir `
		-ExpectedPatterns @($manifest.commonExcludePatterns) `
		-RequireManagedBlock
	$expectedDocsRoot = Join-Path $anchorContext.Root "docs"
	if (-not (Test-PathEqual $manifest.commonDir $anchorContext.CommonDir) -or
		-not (Test-PathEqual $manifest.branchesRoot (Join-Path $expectedDocsRoot "branches")) -or
		-not (Test-PathEqual $manifest.indexRoot (Join-Path $expectedDocsRoot "index")) -or
		-not (Test-PathEqual $manifest.workRoot (Join-Path $expectedDocsRoot "work"))) {
		throw "Manifest roots do not match the exact anchor repository layout."
	}
	if (-not (Test-PathEqual $targetContext.Root $anchorContext.Root)) {
		$childDocsRoot = Join-Path $targetContext.Root "docs"
		if (Get-Item -LiteralPath $childDocsRoot -Force -ErrorAction SilentlyContinue) {
			Assert-PhysicalDirectory $childDocsRoot "Child docs root"
		}
		foreach ($projection in @(
			@("branches", $manifest.branchesRoot),
			@("index", $manifest.indexRoot),
			@("work", $manifest.workRoot)
		)) {
			$projectionPath = Join-Path $childDocsRoot $projection[0]
			if (Get-Item -LiteralPath $projectionPath -Force -ErrorAction SilentlyContinue) {
				Assert-OrCreateJunction $projectionPath $projection[1]
			}
		}
	}
}

if ($manifest -and -not $ApproveCurrentIgnorePolicy) {
	$currentFingerprint = Get-IgnoreFingerprint $targetContext.Root
	if ($manifest.approvedIgnoreFingerprints -notcontains $currentFingerprint) {
		throw "Current tracked ignore-policy fingerprint is not approved: $currentFingerprint"
	}
}

if ($DryRun) {
	Write-Output "DRY RUN"
	Write-Output "target=$($targetContext.Root)"
	Write-Output "anchor=$($anchorContext.Root)"
	Write-Output "commonDir=$($anchorContext.CommonDir)"
	Write-Output "role=$(if (Test-PathEqual $targetContext.Root $anchorContext.Root) { 'anchor' } else { 'child' })"
	exit 0
}

if ($ApproveCurrentIgnorePolicy) {
	if (-not $manifest) {
		throw "Ignore-policy approval requires an existing manifest."
	}
	$approvalLock = $null
	try {
		$approvalLock = Enter-LifecycleLock $lockPath $LockTimeoutSeconds
		$targetContext = Get-RepoContext $targetContext.Root
		$anchorContext = Get-RepoContext $anchorContext.Root
		$manifest = Read-Manifest $manifestPath
		if (-not $manifest) {
			throw "Branch-docs manifest disappeared while waiting for the lifecycle lock."
		}
		Assert-AuthoritativeState `
			-TargetContext $targetContext `
			-AnchorContext $anchorContext `
			-Manifest $manifest `
			-AllowUnapprovedCurrentIgnorePolicy
		$expected = $ExpectedHeadOid.ToLowerInvariant()
		$currentOid = Get-FullCommitOid $targetContext.Root "HEAD"
		if ($expected -ne $currentOid) {
			throw "HEAD OID mismatch. Expected $expected, found $currentOid."
		}
		$ignoreDiff = Invoke-Git `
			-Repo $targetContext.Root `
			-Arguments @("diff", "--quiet", "HEAD", "--", ".gitignore", ":(glob)**/.gitignore") `
			-AllowFailure
		if ($ignoreDiff.ExitCode -ne 0) {
			throw "Tracked .gitignore files differ from the reviewed HEAD; commit or restore them before approval."
		}
		$reviewedFingerprint = Get-IgnoreFingerprint $targetContext.Root $currentOid
		$indexedFingerprint = Get-IgnoreFingerprint $targetContext.Root
		if ($indexedFingerprint -ne $reviewedFingerprint) {
			throw "Tracked .gitignore index differs from the reviewed HEAD; commit or restore it before approval."
		}
		Verify-EffectiveIgnore $targetContext.Root @($manifest.commonExcludePatterns)
		$currentFingerprint = $indexedFingerprint
		if ($manifest.approvedIgnoreFingerprints -contains $currentFingerprint) {
			Write-Output "Ignore-policy fingerprint is already approved: $currentFingerprint"
			exit 0
		}

		$approvalBackup = Normalize-Path $ApprovalBackupRoot
		if (Test-Path -LiteralPath $approvalBackup) {
			throw "Approval backup root already exists: $approvalBackup"
		}
		New-Item -ItemType Directory -Path $approvalBackup | Out-Null
		Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $approvalBackup "manifest.json")
		$approvalRecord = [pscustomobject][ordered]@{
			schemaVersion = 1
			repoRoot = $targetContext.Root
			anchorRepoRoot = $anchorContext.Root
			headOid = $currentOid
			approvedIgnoreFingerprint = $currentFingerprint
			createdAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssK")
		}
		Write-Manifest (Join-Path $approvalBackup "ignore-policy-approval.json") $approvalRecord

		$manifest.approvedIgnoreFingerprints = @($manifest.approvedIgnoreFingerprints) + $currentFingerprint
		$manifest.updatedAt = Get-Date -Format "yyyy-MM-ddTHH:mm:ssK"
		Write-Manifest $manifestPath $manifest
		Assert-AuthoritativeState $targetContext $anchorContext (Read-Manifest $manifestPath)
		Write-Output "Approved ignore-policy fingerprint: $currentFingerprint"
		Write-Output "Approval backup: $approvalBackup"
	} finally {
		if ($approvalLock) {
			$approvalLock.Dispose()
		}
	}
	exit 0
}

if ($VerifyOnly) {
	if (-not $manifest) {
		throw "Verify-only requires an existing manifest."
	}
	$verifyLock = $null
	try {
		$verifyLock = Enter-LifecycleLock $lockPath $LockTimeoutSeconds
		$targetContext = Get-RepoContext $targetContext.Root
		$anchorContext = Get-RepoContext $anchorContext.Root
		$manifest = Read-Manifest $manifestPath
		if (-not $manifest) {
			throw "Branch-docs manifest disappeared while waiting for the lifecycle lock."
		}
		Assert-AuthoritativeState $targetContext $anchorContext $manifest
		if ($ExpectedHeadOid) {
			$expected = $ExpectedHeadOid.ToLowerInvariant()
			$currentOid = Get-FullCommitOid $targetContext.Root "HEAD"
			if ($expected -ne $currentOid) {
				throw "HEAD OID mismatch. Expected $expected, found $currentOid."
			}
		}
		if ($CandidateRef) {
			$candidateOid = Assert-Candidate $targetContext.Root $CandidateRef $manifest
			Write-Output "candidateOid=$candidateOid"
		}

		$docsRoot = Join-Path $targetContext.Root "docs"
		Assert-PhysicalDirectory $docsRoot "Worktree docs root"
		if (Test-PathEqual $targetContext.Root $anchorContext.Root) {
			foreach ($path in @($manifest.branchesRoot, $manifest.indexRoot, $manifest.workRoot)) {
				Assert-PhysicalDirectory $path "Anchor reserved namespace"
			}
		} else {
			Assert-OrCreateJunction (Join-Path $docsRoot "branches") $manifest.branchesRoot
			Assert-OrCreateJunction (Join-Path $docsRoot "index") $manifest.indexRoot
			Assert-OrCreateJunction (Join-Path $docsRoot "work") $manifest.workRoot
		}
		Verify-EffectiveIgnore $targetContext.Root @($manifest.commonExcludePatterns)
		Write-Output "Verified branch-docs worktree: $($targetContext.Root)"
	} finally {
		if ($verifyLock) {
			$verifyLock.Dispose()
		}
	}
	exit 0
}

$lock = $null
try {
	$lock = Enter-LifecycleLock $lockPath $LockTimeoutSeconds

	$targetContext = Get-RepoContext $targetContext.Root
	$anchorContext = Get-RepoContext $anchorContext.Root
	if (-not (Test-PathEqual $targetContext.CommonDir $anchorContext.CommonDir)) {
		throw "Target and anchor common-directory identity changed while waiting for the lock."
	}
	if (-not $anchorContext.IsMainWorktree) {
		throw "Anchor stopped being the main worktree while waiting for the lock."
	}
	$manifest = Read-Manifest $manifestPath
	Assert-AuthoritativeState $targetContext $anchorContext $manifest

	if (Test-PathEqual $targetContext.Root $anchorContext.Root) {
		$store = Install-AnchorStore $anchorContext.Root
		Install-PerWorktreeFiles $anchorContext.Root
		$patterns = @(Get-ManagedExcludePatterns $anchorContext.Root)
		$excludePath = Join-Path $anchorContext.CommonDir "info/exclude"
		Upsert-CommonExclude $excludePath $patterns

		$starterRevisionResult = Invoke-Git -Repo $script:PackageRoot -Arguments @("rev-parse", "--verify", "HEAD") -AllowFailure
		$starterRevision = if ($starterRevisionResult.ExitCode -eq 0) { $starterRevisionResult.Text } else { "uncommitted" }
		$ignoreFingerprint = Get-IgnoreFingerprint $anchorContext.Root
		$approvedIgnoreFingerprints = if ($manifest) {
			@($manifest.approvedIgnoreFingerprints)
		} else {
			@()
		}
		if ($approvedIgnoreFingerprints -notcontains $ignoreFingerprint) {
			$approvedIgnoreFingerprints += $ignoreFingerprint
		}
		$manifest = [pscustomobject][ordered]@{
			schemaVersion = $script:SchemaVersion
			anchorRepoRoot = $anchorContext.Root
			commonDir = $anchorContext.CommonDir
			branchesRoot = $store.BranchesRoot
			indexRoot = $store.IndexRoot
			workRoot = $store.WorkRoot
			starterRevision = $starterRevision
			commonExcludePatterns = $patterns
			ignoreFingerprintAlgorithm = "tracked-gitignore-path-blob-v1"
			approvedIgnoreFingerprints = @($approvedIgnoreFingerprints)
			updatedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssK")
		}
		Write-Manifest $manifestPath $manifest
	} else {
		if (-not $manifest) {
			throw "Anchor is not initialized. Run bootstrap against AnchorRepo first."
		}
		if (-not (Test-PathEqual $manifest.anchorRepoRoot $anchorContext.Root)) {
			throw "Manifest anchor does not match -AnchorRepo."
		}
		foreach ($path in @($manifest.branchesRoot, $manifest.indexRoot, $manifest.workRoot)) {
			Assert-PhysicalDirectory $path "Anchor reserved namespace"
		}

		$docsRoot = Join-Path $targetContext.Root "docs"
		if (-not (Test-Path -LiteralPath $docsRoot)) {
			New-Item -ItemType Directory -Path $docsRoot -Force | Out-Null
		}
		Assert-PhysicalDirectory $docsRoot "Child docs root"
		Install-PerWorktreeFiles $targetContext.Root
		Assert-OrCreateJunction (Join-Path $docsRoot "branches") $manifest.branchesRoot -Create
		Assert-OrCreateJunction (Join-Path $docsRoot "index") $manifest.indexRoot -Create
		Assert-OrCreateJunction (Join-Path $docsRoot "work") $manifest.workRoot -Create
		Upsert-CommonExclude (Join-Path $anchorContext.CommonDir "info/exclude") @($manifest.commonExcludePatterns)
	}
} finally {
	if ($lock) {
		$lock.Dispose()
	}
}

$verificationArgs = @{
	TargetRepo = $targetContext.Root
	AnchorRepo = $anchorContext.Root
	VerifyOnly = $true
	LockTimeoutSeconds = $LockTimeoutSeconds
}
& $PSCommandPath @verificationArgs
if ($LASTEXITCODE -ne 0) {
	throw "Post-bootstrap verification failed."
}

$marker = [pscustomobject][ordered]@{
	schemaVersion = $script:SchemaVersion
	anchorRepoRoot = $anchorContext.Root
	starterRevision = $manifest.starterRevision
	verifiedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssK")
}
Write-Manifest (Join-Path $targetContext.Root ".agent-work/branch-docs-bootstrap.json") $marker
Write-Output "Bootstrapped branch-docs worktree: $($targetContext.Root)"
