[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)]
	[string]$TargetRepo,

	[switch]$Apply,
	[switch]$AllowTrackedPolicyChanges,
	[switch]$InstallTrackedInstructions,
	[switch]$NormalizeGitIgnore,
	[string]$BackupRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:PackageRoot = $PSScriptRoot
$script:AgentBegin = "<!-- branch-docs-starter:begin -->"
$script:AgentEnd = "<!-- branch-docs-starter:end -->"
$script:IgnoreBegin = "# branch-docs-starter:begin"
$script:IgnoreEnd = "# branch-docs-starter:end"

function Invoke-Git {
	param(
		[Parameter(Mandatory = $true)][string]$Repo,
		[Parameter(Mandatory = $true)][string[]]$Arguments,
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
		throw "git -C `"$Repo`" $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
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

function Test-GitTracked {
	param(
		[Parameter(Mandatory = $true)][string]$Repo,
		[Parameter(Mandatory = $true)][string]$RelativePath
	)

	return (Invoke-Git $Repo @("ls-files", "--error-unmatch", "--", $RelativePath) -AllowFailure).ExitCode -eq 0
}

function Get-MarkerState {
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)][string]$Begin,
		[Parameter(Mandatory = $true)][string]$End
	)

	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
		return [pscustomobject]@{ Valid = $false; BeginCount = 0; EndCount = 0 }
	}
	$lines = [IO.File]::ReadAllLines($Path)
	$beginCount = @($lines | Where-Object { $_ -ceq $Begin }).Count
	$endCount = @($lines | Where-Object { $_ -ceq $End }).Count
	return [pscustomobject]@{
		Valid = ($beginCount -eq 1 -and $endCount -eq 1)
		BeginCount = $beginCount
		EndCount = $endCount
	}
}

function Test-MarkedBlockMatches {
	param(
		[Parameter(Mandatory = $true)][string]$TargetPath,
		[Parameter(Mandatory = $true)][string]$BlockPath,
		[Parameter(Mandatory = $true)][string]$Begin,
		[Parameter(Mandatory = $true)][string]$End
	)

	$state = Get-MarkerState $TargetPath $Begin $End
	if (-not $state.Valid) {
		return $false
	}
	$targetLines = @([IO.File]::ReadAllLines($TargetPath))
	$blockLines = @([IO.File]::ReadAllLines($BlockPath))
	$beginIndex = -1
	$endIndex = -1
	for ($index = 0; $index -lt $targetLines.Count; $index++) {
		if ($targetLines[$index] -eq $Begin) {
			$beginIndex = $index
		}
		if ($beginIndex -ge 0 -and $targetLines[$index] -eq $End) {
			$endIndex = $index
			break
		}
	}
	if ($beginIndex -lt 0 -or $endIndex -lt $beginIndex) {
		return $false
	}
	$managedLines = @($targetLines[$beginIndex..$endIndex])
	if ($managedLines.Count -ne $blockLines.Count) {
		return $false
	}
	for ($index = 0; $index -lt $managedLines.Count; $index++) {
		if ($managedLines[$index] -cne $blockLines[$index]) {
			return $false
		}
	}
	return $true
}

function Assert-MigrationTargetSafe {
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)][string]$Begin,
		[Parameter(Mandatory = $true)][string]$End,
		[switch]$AllowDuplicateBlocks
	)

	$item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
	if (-not $item -or $item -is [IO.DirectoryInfo] -or
		($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
		throw "Migration target must be an existing regular non-reparse file: $Path"
	}
	$bytes = [IO.File]::ReadAllBytes($Path)
	if (($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) -or
		($bytes.Length -ge 2 -and (($bytes[0] -eq 255 -and $bytes[1] -eq 254) -or
			($bytes[0] -eq 254 -and $bytes[1] -eq 255)))) {
		throw "Migration target must be UTF-8 without a BOM: $Path"
	}
	$lines = @([IO.File]::ReadAllLines($Path))
	$blockCount = 0
	$insideBlock = $false
	foreach ($line in $lines) {
		if ($line -ceq $Begin) {
			if ($insideBlock) {
				throw "Nested managed markers in $Path"
			}
			$insideBlock = $true
			$blockCount++
			continue
		}
		if ($line -ceq $End) {
			if (-not $insideBlock) {
				throw "Reversed or unmatched managed markers in $Path"
			}
			$insideBlock = $false
		}
	}
	if ($insideBlock -or (-not $AllowDuplicateBlocks -and $blockCount -gt 1)) {
		throw "Malformed or duplicate managed markers in $Path"
	}
}

function Enter-LifecycleLock {
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[int]$TimeoutSeconds = 30
	)

	$parent = Split-Path -Parent $Path
	if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
		New-Item -ItemType Directory -Path $parent -Force | Out-Null
	}
	$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
	while ([DateTime]::UtcNow -lt $deadline) {
		try {
			return [IO.File]::Open($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
		} catch [IO.IOException] {
			Start-Sleep -Milliseconds 200
		}
	}
	throw "Timed out waiting for branch-docs lifecycle lock: $Path"
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
	$tempPath = Join-Path $parent ("branch-docs-migrate-" + [Guid]::NewGuid().ToString("N") + ".tmp")
	$backupPath = Join-Path $parent ("branch-docs-migrate-" + [Guid]::NewGuid().ToString("N") + ".bak")
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

function Upsert-MarkedBlock {
	param(
		[Parameter(Mandatory = $true)][string]$TargetPath,
		[Parameter(Mandatory = $true)][string]$BlockPath,
		[Parameter(Mandatory = $true)][string]$Begin,
		[Parameter(Mandatory = $true)][string]$End
	)

	Assert-MigrationTargetSafe $TargetPath $Begin $End

	$text = [IO.File]::ReadAllText($TargetPath)
	$block = [IO.File]::ReadAllText($BlockPath)
	$lineEnding = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
	$text = $text -replace "`r?`n", $lineEnding
	$block = $block -replace "`r?`n", $lineEnding
	$beginPattern = "(?m)^" + [regex]::Escape($Begin) + "(?=`r?$)"
	$endPattern = "(?m)^" + [regex]::Escape($End) + "(`r?`n|$)"
	$beginMatches = [regex]::Matches($text, $beginPattern)
	if ($beginMatches.Count -gt 1) {
		throw "Duplicate begin markers in $TargetPath"
	}
	if ($beginMatches.Count -eq 1) {
		$beginMatch = $beginMatches[0]
		$afterBegin = $text.Substring($beginMatch.Index + $beginMatch.Length)
		$endMatch = [regex]::Match($afterBegin, $endPattern)
		if (-not $endMatch.Success) {
			throw "Unmatched begin marker in $TargetPath"
		}
		$absoluteEnd = $beginMatch.Index + $beginMatch.Length + $endMatch.Index + $endMatch.Length
		$newText = $text.Substring(0, $beginMatch.Index) + $block + $text.Substring($absoluteEnd)
		Write-Utf8Atomic $TargetPath $newText
		return
	}

	if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) {
		$text += $lineEnding
	}
	Write-Utf8Atomic $TargetPath ($text + $lineEnding + $block)
}

function Normalize-GitIgnore {
	param(
		[Parameter(Mandatory = $true)][string]$TargetPath,
		[Parameter(Mandatory = $true)][string]$BlockPath,
		[Parameter(Mandatory = $true)][string]$Begin,
		[Parameter(Mandatory = $true)][string]$End
	)

	Assert-MigrationTargetSafe $TargetPath $Begin $End -AllowDuplicateBlocks
	$text = [IO.File]::ReadAllText($TargetPath)
	$lineEnding = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
	$sourceLines = @([IO.File]::ReadAllLines($TargetPath))
	$outputLines = New-Object Collections.Generic.List[string]
	$insideBlock = $false
	foreach ($line in $sourceLines) {
		if ($line -ceq $Begin) {
			$insideBlock = $true
			continue
		}
		if ($line -ceq $End) {
			$insideBlock = $false
			continue
		}
		if ($insideBlock) {
			continue
		}
		if ($line.Trim() -in @("/docs/", "docs/", "/.codex/", ".codex/")) {
			continue
		}
		$outputLines.Add($line)
	}
	while ($outputLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($outputLines[$outputLines.Count - 1])) {
		$outputLines.RemoveAt($outputLines.Count - 1)
	}
	if ($outputLines.Count -gt 0) {
		$outputLines.Add("")
	}
	foreach ($line in [IO.File]::ReadAllLines($BlockPath)) {
		$outputLines.Add($line)
	}
	Write-Utf8Atomic $TargetPath (($outputLines -join $lineEnding) + $lineEnding)
}

function Backup-File {
	param(
		[Parameter(Mandatory = $true)][string]$Repo,
		[Parameter(Mandatory = $true)][string]$RelativePath,
		[Parameter(Mandatory = $true)][string]$DestinationRoot
	)

	$source = Join-Path $Repo $RelativePath
	if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
		return $null
	}
	$target = Join-Path $DestinationRoot $RelativePath
	$parent = Split-Path -Parent $target
	New-Item -ItemType Directory -Path $parent -Force | Out-Null
	Copy-Item -LiteralPath $source -Destination $target -Force
	return [pscustomobject][ordered]@{
		path = $RelativePath
		sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash
		tracked = (Test-GitTracked $Repo $RelativePath)
	}
}

function Get-MigrationState {
	param([Parameter(Mandatory = $true)][string]$Repo)

	$actions = @()
	$agentsPath = Join-Path $Repo "AGENTS.md"
	if ($InstallTrackedInstructions -and (Test-GitTracked $Repo "AGENTS.md")) {
		$matches = Test-MarkedBlockMatches `
			-TargetPath $agentsPath `
			-BlockPath (Join-Path $script:PackageRoot "AGENTS.branch-docs.md") `
			-Begin $script:AgentBegin `
			-End $script:AgentEnd
		if (-not $matches) {
			$actions += [pscustomobject][ordered]@{
				action = "upsert-tracked-agents"
				path = "AGENTS.md"
			}
		}
	}

	$claudePath = Join-Path $Repo "CLAUDE.md"
	if ($InstallTrackedInstructions -and (Test-GitTracked $Repo "CLAUDE.md")) {
		$state = Get-MarkerState $claudePath $script:AgentBegin $script:AgentEnd
		$matches = Test-MarkedBlockMatches `
			-TargetPath $claudePath `
			-BlockPath (Join-Path $script:PackageRoot "CLAUDE.branch-docs.md") `
			-Begin $script:AgentBegin `
			-End $script:AgentEnd
		$delegates = @([IO.File]::ReadAllLines($claudePath) | Where-Object { $_.Trim() -eq "@AGENTS.md" }).Count -gt 0
		$hasManagedMarker = $state.BeginCount -gt 0 -or $state.EndCount -gt 0
		if (($hasManagedMarker -and -not $matches) -or
			(-not $hasManagedMarker -and -not $delegates)) {
			$actions += [pscustomobject][ordered]@{
				action = "upsert-tracked-claude"
				path = "CLAUDE.md"
			}
		}
	}

	$gitignorePath = Join-Path $Repo ".gitignore"
	if ($NormalizeGitIgnore -and (Test-Path -LiteralPath $gitignorePath -PathType Leaf)) {
		Assert-MigrationTargetSafe $gitignorePath $script:IgnoreBegin $script:IgnoreEnd -AllowDuplicateBlocks
		$state = Get-MarkerState $gitignorePath $script:IgnoreBegin $script:IgnoreEnd
		$matches = Test-MarkedBlockMatches `
			-TargetPath $gitignorePath `
			-BlockPath (Join-Path $script:PackageRoot ".agent-work.gitignore.block") `
			-Begin $script:IgnoreBegin `
			-End $script:IgnoreEnd
		$hasBlanket = @([IO.File]::ReadAllLines($gitignorePath) | Where-Object {
			$_.Trim() -in @("/docs/", "docs/", "/.codex/", ".codex/")
		}).Count -gt 0
		if (-not $state.Valid -or -not $matches -or $hasBlanket) {
			$actions += [pscustomobject][ordered]@{
				action = "normalize-gitignore"
				path = ".gitignore"
			}
		}
	}

	return [pscustomobject]@{
		Actions = @($actions)
		AgentsPath = $agentsPath
		ClaudePath = $claudePath
		GitIgnorePath = $gitignorePath
	}
}

if ($env:OS -ne "Windows_NT") {
	throw "migrate-orca-worktree-layout.ps1 supports native Windows only."
}
if ($Apply -and -not ($InstallTrackedInstructions -or $NormalizeGitIgnore)) {
	throw "-Apply requires at least one migration action."
}

$repoRoot = Normalize-Path (Invoke-Git $TargetRepo @("rev-parse", "--show-toplevel")).Text
$gitDir = Normalize-Path (Invoke-Git $repoRoot @("rev-parse", "--path-format=absolute", "--git-dir")).Text
$commonDir = Normalize-Path (Invoke-Git $repoRoot @("rev-parse", "--path-format=absolute", "--git-common-dir")).Text
if (-not [string]::Equals($gitDir, $commonDir, [StringComparison]::OrdinalIgnoreCase)) {
	throw "Run layout migration from the main worktree, not a linked worktree."
}

$migrationState = Get-MigrationState $repoRoot
$actions = @($migrationState.Actions)
$agentsPath = $migrationState.AgentsPath
$claudePath = $migrationState.ClaudePath
$gitignorePath = $migrationState.GitIgnorePath

$inventory = [pscustomobject][ordered]@{
	repoRoot = $repoRoot
	gitCommonDir = $commonDir
	mode = $(if ($Apply) { "apply" } else { "dry-run" })
	actions = $actions
}

if (-not $Apply) {
	$inventory | ConvertTo-Json -Depth 8
	exit 0
}

if ($actions.Count -eq 0) {
	Write-Output "No migration actions are required."
	exit 0
}

foreach ($action in $actions) {
	switch ($action.action) {
		"upsert-tracked-agents" {
			Assert-MigrationTargetSafe $agentsPath $script:AgentBegin $script:AgentEnd
		}
		"upsert-tracked-claude" {
			Assert-MigrationTargetSafe $claudePath $script:AgentBegin $script:AgentEnd
		}
		"normalize-gitignore" {
			Assert-MigrationTargetSafe $gitignorePath $script:IgnoreBegin $script:IgnoreEnd -AllowDuplicateBlocks
		}
	}
}

$trackedActions = @($actions | Where-Object { Test-GitTracked $repoRoot $_.path })
if ($trackedActions.Count -gt 0 -and -not $AllowTrackedPolicyChanges) {
	throw "Migration would change tracked policy files. Re-run with -AllowTrackedPolicyChanges after reviewing the dry-run."
}

$lifecycleLock = $null
try {
$lifecycleLock = Enter-LifecycleLock (Join-Path $commonDir "branch-docs-starter/lifecycle.lock")
$lockedRepoRoot = Normalize-Path (Invoke-Git $TargetRepo @("rev-parse", "--show-toplevel")).Text
$lockedGitDir = Normalize-Path (Invoke-Git $lockedRepoRoot @("rev-parse", "--path-format=absolute", "--git-dir")).Text
$lockedCommonDir = Normalize-Path (Invoke-Git $lockedRepoRoot @("rev-parse", "--path-format=absolute", "--git-common-dir")).Text
if (-not [string]::Equals($lockedRepoRoot, $repoRoot, [StringComparison]::OrdinalIgnoreCase) -or
	-not [string]::Equals($lockedGitDir, $lockedCommonDir, [StringComparison]::OrdinalIgnoreCase) -or
	-not [string]::Equals($lockedCommonDir, $commonDir, [StringComparison]::OrdinalIgnoreCase)) {
	throw "Repository identity changed while waiting for the lifecycle lock."
}
$migrationState = Get-MigrationState $lockedRepoRoot
$actions = @($migrationState.Actions)
$agentsPath = $migrationState.AgentsPath
$claudePath = $migrationState.ClaudePath
$gitignorePath = $migrationState.GitIgnorePath
if ($actions.Count -eq 0) {
	Write-Output "No migration actions are required."
	return
}
$trackedActions = @($actions | Where-Object { Test-GitTracked $lockedRepoRoot $_.path })
if ($trackedActions.Count -gt 0 -and -not $AllowTrackedPolicyChanges) {
	throw "Migration would change tracked policy files. Re-run with -AllowTrackedPolicyChanges after reviewing the dry-run."
}
foreach ($action in $actions) {
	switch ($action.action) {
		"upsert-tracked-agents" {
			Assert-MigrationTargetSafe $agentsPath $script:AgentBegin $script:AgentEnd
		}
		"upsert-tracked-claude" {
			Assert-MigrationTargetSafe $claudePath $script:AgentBegin $script:AgentEnd
		}
		"normalize-gitignore" {
			Assert-MigrationTargetSafe $gitignorePath $script:IgnoreBegin $script:IgnoreEnd -AllowDuplicateBlocks
		}
	}
}

if (-not $BackupRoot) {
	$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
	$BackupRoot = Join-Path $repoRoot ".agent-work/branch-docs-migration-$stamp"
}
$BackupRoot = Normalize-Path $BackupRoot
if (Test-Path -LiteralPath $BackupRoot) {
	throw "Backup root already exists: $BackupRoot"
}
New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null

$backupEntries = @()
foreach ($action in $actions) {
	$entry = Backup-File $repoRoot $action.path $BackupRoot
	if ($entry) {
		$backupEntries += $entry
	}
}
$manifest = [pscustomobject][ordered]@{
	schemaVersion = 1
	repoRoot = $repoRoot
	createdAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssK")
	actions = $actions
	files = $backupEntries
}
$manifestJson = $manifest | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText(
	(Join-Path $BackupRoot "migration-backup.json"),
	"$manifestJson`n",
	(New-Object Text.UTF8Encoding $false)
)

foreach ($action in $actions) {
	switch ($action.action) {
		"upsert-tracked-agents" {
			Upsert-MarkedBlock `
				-TargetPath $agentsPath `
				-BlockPath (Join-Path $script:PackageRoot "AGENTS.branch-docs.md") `
				-Begin $script:AgentBegin `
				-End $script:AgentEnd
		}
		"upsert-tracked-claude" {
			Upsert-MarkedBlock `
				-TargetPath $claudePath `
				-BlockPath (Join-Path $script:PackageRoot "CLAUDE.branch-docs.md") `
				-Begin $script:AgentBegin `
				-End $script:AgentEnd
		}
		"normalize-gitignore" {
			Normalize-GitIgnore `
				-TargetPath $gitignorePath `
				-BlockPath (Join-Path $script:PackageRoot ".agent-work.gitignore.block") `
				-Begin $script:IgnoreBegin `
				-End $script:IgnoreEnd
		}
		default {
			throw "Unknown migration action: $($action.action)"
		}
	}
}

if ($NormalizeGitIgnore -and (Test-Path -LiteralPath $gitignorePath -PathType Leaf)) {
	if (-not (Test-MarkedBlockMatches `
		-TargetPath $gitignorePath `
		-BlockPath (Join-Path $script:PackageRoot ".agent-work.gitignore.block") `
		-Begin $script:IgnoreBegin `
		-End $script:IgnoreEnd)) {
		throw "Post-migration .gitignore does not contain the exact managed block."
	}
	$remainingBlanket = @([IO.File]::ReadAllLines($gitignorePath) | Where-Object {
		$_.Trim() -in @("/docs/", "docs/", "/.codex/", ".codex/")
	})
	if ($remainingBlanket.Count -gt 0) {
		throw "Post-migration .gitignore still contains a blanket docs or .codex rule."
	}
}

Write-Output "Applied branch-docs migration. Backup: $BackupRoot"
} finally {
	if ($lifecycleLock) {
		$lifecycleLock.Dispose()
	}
}
