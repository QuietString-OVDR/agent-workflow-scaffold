[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)][string]$AnchorRepo,
	[string]$BackupRoot,
	[switch]$Apply,
	[int]$LockTimeoutSeconds = 30
)

$ErrorActionPreference = "Stop"
$script:SchemaVersion = 2
$script:LayoutName = "git-common-dir-store-v1"
$script:StoreRelativePath = "branch-docs-starter/store"
$script:ReservedNames = @("branches", "index", "work")

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

function Get-RelativePathInside {
	param(
		[Parameter(Mandatory = $true)][string]$Root,
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)][string]$Description
	)

	$rootPath = Normalize-Path $Root
	$pathValue = Normalize-Path $Path
	if (Test-PathEqual $rootPath $pathValue) {
		return "."
	}
	$rootPrefix = $rootPath.TrimEnd('\', '/') + '\'
	if (-not $pathValue.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
		throw "$Description is outside the expected root: $pathValue"
	}
	$relative = $pathValue.Substring($rootPrefix.Length).Replace('/', '\')
	return $relative
}

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
	if ($hasNativePreference) {
		$oldNativeErrorActionPreference = $Global:PSNativeCommandUseErrorActionPreference
		$Global:PSNativeCommandUseErrorActionPreference = $false
	}
	try {
		$ErrorActionPreference = "Continue"
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
		Lines = @($output | ForEach-Object { [string]$_ })
		Text = (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
	}
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

function Resolve-JunctionTarget {
	param([Parameter(Mandatory = $true)][IO.DirectoryInfo]$Item)

	if ($Item.LinkType -ne "Junction") {
		throw "Only directory junctions are supported in the managed store: $($Item.FullName)"
	}
	$targets = @($Item.Target)
	if ($targets.Count -ne 1 -or -not $targets[0]) {
		throw "Unable to resolve junction target: $($Item.FullName)"
	}
	$target = [string]$targets[0]
	if (-not [IO.Path]::IsPathRooted($target)) {
		$target = Join-Path $Item.Parent.FullName $target
	}
	return (Normalize-Path $target)
}

function Assert-ExactJunction {
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)][string]$ExpectedTarget,
		[Parameter(Mandatory = $true)][string]$Description
	)

	$item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
	if (-not $item -or -not ($item -is [IO.DirectoryInfo]) -or $item.LinkType -ne "Junction") {
		throw "$Description must be a junction: $Path"
	}
	$actualTarget = Resolve-JunctionTarget $item
	if (-not (Test-PathEqual $actualTarget $ExpectedTarget)) {
		throw "$Description points to the wrong target: $Path -> $actualTarget; expected $ExpectedTarget"
	}
}

function Remove-ExactJunction {
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)][string]$ExpectedTarget
	)

	Assert-ExactJunction $Path $ExpectedTarget "Managed projection"
	[IO.Directory]::Delete((Normalize-Path $Path), $false)
}

function New-ExactJunction {
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)][string]$Target
	)

	if (Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue) {
		throw "Junction destination already exists: $Path"
	}
	$parent = Split-Path -Parent $Path
	Assert-PhysicalDirectory $parent "Junction parent"
	New-Item -ItemType Junction -Path $Path -Target $Target -ErrorAction Stop | Out-Null
	Assert-ExactJunction $Path $Target "Created managed projection"
}

function Get-WorktreeRoots {
	param([Parameter(Mandatory = $true)][string]$Repo)

	$result = Invoke-Git $Repo @("worktree", "list", "--porcelain")
	$roots = @(
		$result.Lines |
			Where-Object { $_.StartsWith("worktree ", [StringComparison]::Ordinal) } |
			ForEach-Object { Normalize-Path $_.Substring(9) }
	)
	if ($roots.Count -lt 1) {
		throw "No Git worktrees were reported for $Repo"
	}
	return $roots
}

function Test-TrackedPath {
	param(
		[Parameter(Mandatory = $true)][string]$Repo,
		[Parameter(Mandatory = $true)][string]$Path
	)

	return (Invoke-Git $Repo @("ls-files", "--error-unmatch", "--", $Path) -AllowFailure).ExitCode -eq 0
}

function Get-InstructionOwnership {
	param([Parameter(Mandatory = $true)][string]$Repo)

	return [pscustomobject][ordered]@{
		agentsTracked = [bool](Test-TrackedPath $Repo "AGENTS.md")
		claudeTracked = [bool](Test-TrackedPath $Repo "CLAUDE.md")
		codexConfigTracked = [bool](Test-TrackedPath $Repo ".codex/config.toml")
	}
}

function Get-StoreInventory {
	param([Parameter(Mandatory = $true)][string]$Root)

	$rootPath = Normalize-Path $Root
	$directories = [Collections.Generic.List[string]]::new()
	$files = [Collections.Generic.List[object]]::new()
	$junctions = [Collections.Generic.List[object]]::new()
	$queue = [Collections.Generic.Queue[IO.DirectoryInfo]]::new()

	foreach ($name in $script:ReservedNames) {
		$path = Join-Path $rootPath $name
		Assert-PhysicalDirectory $path "Canonical $name root"
		$directories.Add($name)
		$queue.Enqueue((Get-Item -LiteralPath $path -Force))
	}

	while ($queue.Count -gt 0) {
		$current = $queue.Dequeue()
		foreach ($item in Get-ChildItem -LiteralPath $current.FullName -Force -ErrorAction Stop) {
			$relative = Get-RelativePathInside $rootPath $item.FullName "Managed store entry"
			$isReparse = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
			if ($isReparse) {
				if (-not ($item -is [IO.DirectoryInfo])) {
					throw "Managed store reparse files are unsupported: $($item.FullName)"
				}
				$target = Resolve-JunctionTarget $item
				$targetRelative = Get-RelativePathInside $rootPath $target "Managed store junction target"
				$targetTopLevel = $targetRelative.Split('\')[0]
				if ($script:ReservedNames -notcontains $targetTopLevel) {
					throw "Managed store junction target is outside the reserved roots: $($item.FullName) -> $target"
				}
				$junctions.Add([pscustomobject][ordered]@{
					path = $relative
					target = $targetRelative
				})
				continue
			}
			if ($item -is [IO.DirectoryInfo]) {
				$directories.Add($relative)
				$queue.Enqueue($item)
				continue
			}
			if (-not ($item -is [IO.FileInfo])) {
				throw "Unsupported managed store entry: $($item.FullName)"
			}
			$files.Add([pscustomobject][ordered]@{
				path = $relative
				length = [long]$item.Length
				sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
			})
		}
	}

	return [pscustomobject][ordered]@{
		directories = @($directories | Sort-Object)
		files = @($files | Sort-Object path)
		junctions = @($junctions | Sort-Object path)
	}
}

function Assert-InventoryEqual {
	param(
		[Parameter(Mandatory = $true)]$Expected,
		[Parameter(Mandatory = $true)]$Actual,
		[Parameter(Mandatory = $true)][string]$Description
	)

	$expectedJson = $Expected | ConvertTo-Json -Depth 8 -Compress
	$actualJson = $Actual | ConvertTo-Json -Depth 8 -Compress
	if ($expectedJson -cne $actualJson) {
		throw "$Description inventory does not match the source store."
	}
}

function Copy-VerifiedStore {
	param(
		[Parameter(Mandatory = $true)][string]$SourceRoot,
		[Parameter(Mandatory = $true)][string]$DestinationRoot,
		$ExpectedInventory
	)

	$sourceRootPath = Normalize-Path $SourceRoot
	$destinationRootPath = Normalize-Path $DestinationRoot
	if (Test-Path -LiteralPath $destinationRootPath) {
		throw "Verified-copy destination already exists: $destinationRootPath"
	}
	$inventory = if ($ExpectedInventory) { $ExpectedInventory } else { Get-StoreInventory $sourceRootPath }
	New-Item -ItemType Directory -Path $destinationRootPath -ErrorAction Stop | Out-Null

	foreach ($relative in $inventory.directories) {
		$destination = Join-Path $destinationRootPath $relative
		if (-not (Test-Path -LiteralPath $destination)) {
			New-Item -ItemType Directory -Path $destination -ErrorAction Stop | Out-Null
		}
	}
	foreach ($file in $inventory.files) {
		$source = Join-Path $sourceRootPath $file.path
		$destination = Join-Path $destinationRootPath $file.path
		Copy-Item -LiteralPath $source -Destination $destination -ErrorAction Stop
	}
	foreach ($junction in $inventory.junctions) {
		New-ExactJunction `
			-Path (Join-Path $destinationRootPath $junction.path) `
			-Target (Join-Path $destinationRootPath $junction.target)
	}

	$copiedInventory = Get-StoreInventory $destinationRootPath
	Assert-InventoryEqual $inventory $copiedInventory "Copied store"
	return $copiedInventory
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
	$temp = Join-Path $parent (".{0}.{1}.tmp" -f [IO.Path]::GetFileName($Path), [Guid]::NewGuid().ToString("N"))
	[IO.File]::WriteAllText($temp, $Text, [Text.UTF8Encoding]::new($false))
	try {
		Move-Item -LiteralPath $temp -Destination $Path -Force
	} finally {
		if (Test-Path -LiteralPath $temp) {
			Remove-Item -LiteralPath $temp -Force
		}
	}
}

function Write-JsonAtomic {
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)]$Value
	)

	Write-Utf8Atomic $Path (($Value | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
}

function Enter-LifecycleLock {
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)][int]$TimeoutSeconds
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

function Get-MigrationState {
	param([Parameter(Mandatory = $true)][string]$RequestedAnchor)

	$anchor = Normalize-Path (Resolve-Path -LiteralPath $RequestedAnchor).Path
	$topLevel = Normalize-Path (Invoke-Git $anchor @("rev-parse", "--show-toplevel")).Text
	$gitDir = Normalize-Path (Invoke-Git $anchor @("rev-parse", "--path-format=absolute", "--git-dir")).Text
	$commonDir = Normalize-Path (Invoke-Git $anchor @("rev-parse", "--path-format=absolute", "--git-common-dir")).Text
	if (-not (Test-PathEqual $anchor $topLevel) -or -not (Test-PathEqual $gitDir $commonDir)) {
		throw "AnchorRepo must be the main worktree: $anchor"
	}

	$stateRoot = Join-Path $commonDir "branch-docs-starter"
	$manifestPath = Join-Path $stateRoot "manifest.json"
	if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
		throw "Legacy branch-docs manifest is missing: $manifestPath"
	}
	$manifestText = [IO.File]::ReadAllText($manifestPath)
	$manifest = $manifestText | ConvertFrom-Json
	if (-not $manifest.schemaVersion -or [int]$manifest.schemaVersion -ne 1) {
		throw "Migration requires a schema-v1 anchor manifest: $manifestPath"
	}
	foreach ($property in @("anchorRepoRoot", "commonDir", "branchesRoot", "indexRoot", "workRoot")) {
		if (-not $manifest.PSObject.Properties[$property] -or -not $manifest.$property) {
			throw "Manifest property '$property' is missing in $manifestPath"
		}
	}
	if (-not (Test-PathEqual $manifest.anchorRepoRoot $anchor) -or
		-not (Test-PathEqual $manifest.commonDir $commonDir)) {
		throw "Legacy manifest anchor/common directory does not match the requested repository."
	}

	$docsRoot = Join-Path $anchor "docs"
	Assert-PhysicalDirectory $docsRoot "Anchor docs root"
	$roots = [ordered]@{}
	foreach ($name in $script:ReservedNames) {
		$path = Normalize-Path (Join-Path $docsRoot $name)
		if (-not (Test-PathEqual $manifest."${name}Root" $path)) {
			throw "Legacy manifest $name root does not match the anchor reserved namespace."
		}
		Assert-PhysicalDirectory $path "Anchor $name root"
		$roots[$name] = $path
	}

	$worktrees = @(Get-WorktreeRoots $anchor)
	if (-not ($worktrees | Where-Object { Test-PathEqual $_ $anchor })) {
		throw "The requested anchor is absent from git worktree list."
	}
	foreach ($worktree in $worktrees) {
		$worktreeDocs = Join-Path $worktree "docs"
		Assert-PhysicalDirectory $worktreeDocs "Worktree docs root"
		if (Test-PathEqual $worktree $anchor) {
			continue
		}
		foreach ($name in $script:ReservedNames) {
			Assert-ExactJunction (Join-Path $worktreeDocs $name) $roots[$name] "Legacy $name projection"
		}
	}

	$storeRoot = Normalize-Path (Join-Path $commonDir $script:StoreRelativePath)
	if (Test-Path -LiteralPath $storeRoot) {
		throw "Schema-v2 store destination already exists: $storeRoot"
	}

	return [pscustomobject]@{
		Anchor = $anchor
		CommonDir = $commonDir
		StateRoot = Normalize-Path $stateRoot
		ManifestPath = Normalize-Path $manifestPath
		Manifest = $manifest
		ManifestText = $manifestText
		DocsRoot = Normalize-Path $docsRoot
		Roots = $roots
		Worktrees = $worktrees
		StoreRoot = $storeRoot
		LockPath = Normalize-Path (Join-Path $stateRoot "lifecycle.lock")
	}
}

function New-SchemaV2Manifest {
	param([Parameter(Mandatory = $true)]$State)

	$legacy = $State.Manifest
	return [pscustomobject][ordered]@{
		schemaVersion = $script:SchemaVersion
		layout = $script:LayoutName
		storeRelativePath = $script:StoreRelativePath
		starterRevision = [string]$legacy.starterRevision
		instructionOwnership = Get-InstructionOwnership $State.Anchor
		commonExcludePatterns = @($legacy.commonExcludePatterns)
		ignoreFingerprintAlgorithm = [string]$legacy.ignoreFingerprintAlgorithm
		approvedIgnoreFingerprints = @($legacy.approvedIgnoreFingerprints)
		updatedAt = Get-Date -Format "yyyy-MM-ddTHH:mm:ssK"
	}
}

function Restore-LegacyProjection {
	param(
		[Parameter(Mandatory = $true)]$State,
		[Parameter(Mandatory = $true)][string]$Backup
	)

	foreach ($worktree in $State.Worktrees) {
		foreach ($name in $script:ReservedNames) {
			$path = Join-Path (Join-Path $worktree "docs") $name
			$item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
			if ($item -and $item.LinkType -eq "Junction") {
				$target = Resolve-JunctionTarget $item
				$newTarget = Join-Path $State.StoreRoot $name
				if (Test-PathEqual $target $newTarget) {
					[IO.Directory]::Delete((Normalize-Path $path), $false)
				}
			}
		}
	}

	foreach ($name in $script:ReservedNames) {
		$original = Join-Path (Join-Path $Backup "anchor-original") $name
		$restored = Join-Path $State.DocsRoot $name
		if ((Test-Path -LiteralPath $original) -and -not (Test-Path -LiteralPath $restored)) {
			Move-Item -LiteralPath $original -Destination $restored
		}
	}
	foreach ($worktree in $State.Worktrees) {
		if (Test-PathEqual $worktree $State.Anchor) {
			continue
		}
		foreach ($name in $script:ReservedNames) {
			$path = Join-Path (Join-Path $worktree "docs") $name
			if (-not (Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue)) {
				New-ExactJunction $path (Join-Path $State.DocsRoot $name)
			}
		}
	}
	Write-Utf8Atomic $State.ManifestPath $State.ManifestText
}

if ($env:OS -ne "Windows_NT") {
	throw "migrate-anchorless-store.ps1 supports native Windows only."
}
if ($LockTimeoutSeconds -lt 1) {
	throw "-LockTimeoutSeconds must be at least 1."
}
if ($Apply -and [string]::IsNullOrWhiteSpace($BackupRoot)) {
	throw "-Apply requires a new, nonexisting -BackupRoot."
}

$state = Get-MigrationState $AnchorRepo
$sourceInventory = Get-StoreInventory $state.DocsRoot
$fileCount = @($sourceInventory.files).Count
$totalBytes = [long](($sourceInventory.files | Measure-Object -Property length -Sum).Sum)
$junctionCount = @($sourceInventory.junctions).Count

Write-Output $(if ($Apply) { "APPLY" } else { "DRY RUN" })
Write-Output "anchor=$($state.Anchor)"
Write-Output "commonDir=$($state.CommonDir)"
Write-Output "storeRoot=$($state.StoreRoot)"
Write-Output "worktrees=$($state.Worktrees.Count)"
Write-Output "files=$fileCount"
Write-Output "bytes=$totalBytes"
Write-Output "internalJunctions=$junctionCount"
foreach ($worktree in $state.Worktrees) {
	Write-Output "worktree=$worktree"
}
if (-not $Apply) {
	Write-Output "No files were changed. Re-run with -Apply and a new -BackupRoot to migrate."
	exit 0
}

$backup = Normalize-Path $BackupRoot
if (Test-Path -LiteralPath $backup) {
	throw "Backup root already exists: $backup"
}
[void](Get-RelativePathInside (Split-Path -Parent $backup) $backup "Backup root")
foreach ($protectedRoot in @($state.Anchor, $state.CommonDir, $state.DocsRoot, $state.StoreRoot)) {
	try {
		[void](Get-RelativePathInside $protectedRoot $backup "Backup root")
		throw "Backup root must be outside the repository and Git common directory: $backup"
	} catch {
		if ($_.Exception.Message -notlike "*outside the expected root*") {
			throw
		}
	}
}

$lock = $null
$migrationStarted = $false
try {
	$lock = Enter-LifecycleLock $state.LockPath $LockTimeoutSeconds
	$state = Get-MigrationState $state.Anchor
	$lockedInventory = Get-StoreInventory $state.DocsRoot
	Assert-InventoryEqual $sourceInventory $lockedInventory "Locked source store"

	New-Item -ItemType Directory -Path $backup -ErrorAction Stop | Out-Null
	Write-Utf8Atomic (Join-Path $backup "manifest-v1.json") $state.ManifestText
	Write-JsonAtomic (Join-Path $backup "inventory-v1.json") $lockedInventory
	Copy-VerifiedStore $state.DocsRoot (Join-Path $backup "canonical-store-copy") $lockedInventory | Out-Null

	$stage = Normalize-Path (Join-Path $state.StateRoot ("store.stage-{0}" -f [Guid]::NewGuid().ToString("N")))
	Copy-VerifiedStore $state.DocsRoot $stage $lockedInventory | Out-Null
	Move-Item -LiteralPath $stage -Destination $state.StoreRoot
	foreach ($junction in $lockedInventory.junctions) {
		$promotedPath = Join-Path $state.StoreRoot $junction.path
		Remove-ExactJunction $promotedPath (Join-Path $stage $junction.target)
		New-ExactJunction $promotedPath (Join-Path $state.StoreRoot $junction.target)
	}
	Assert-InventoryEqual $lockedInventory (Get-StoreInventory $state.StoreRoot) "Promoted schema-v2 store"

	$migrationStarted = $true
	$originalRoot = Join-Path $backup "anchor-original"
	New-Item -ItemType Directory -Path $originalRoot -ErrorAction Stop | Out-Null
	foreach ($name in $script:ReservedNames) {
		Move-Item -LiteralPath (Join-Path $state.DocsRoot $name) -Destination (Join-Path $originalRoot $name)
	}
	foreach ($worktree in $state.Worktrees) {
		if (Test-PathEqual $worktree $state.Anchor) {
			continue
		}
		foreach ($name in $script:ReservedNames) {
			Remove-ExactJunction `
				-Path (Join-Path (Join-Path $worktree "docs") $name) `
				-ExpectedTarget $state.Roots[$name]
		}
	}
	foreach ($worktree in $state.Worktrees) {
		foreach ($name in $script:ReservedNames) {
			New-ExactJunction `
				-Path (Join-Path (Join-Path $worktree "docs") $name) `
				-Target (Join-Path $state.StoreRoot $name)
		}
	}

	$manifestV2 = New-SchemaV2Manifest $state
	Write-JsonAtomic $state.ManifestPath $manifestV2
	foreach ($worktree in $state.Worktrees) {
		foreach ($name in $script:ReservedNames) {
			Assert-ExactJunction `
				(Join-Path (Join-Path $worktree "docs") $name) `
				(Join-Path $state.StoreRoot $name) `
				"Schema-v2 $name projection"
		}
	}
	Assert-InventoryEqual $lockedInventory (Get-StoreInventory $state.StoreRoot) "Final schema-v2 store"
	Write-Output "Migrated schema-v1 anchor store to schema v2."
	Write-Output "backup=$backup"
	Write-Output "manifest=$($state.ManifestPath)"
} catch {
	$failure = $_
	if ($migrationStarted -and (Test-Path -LiteralPath $backup -PathType Container)) {
		try {
			Restore-LegacyProjection $state $backup
			Write-Warning "Migration failed; the schema-v1 manifest and projections were restored. The verified backup and any staged schema-v2 store were retained."
		} catch {
			Write-Warning "Automatic rollback also failed: $($_.Exception.Message)"
		}
	}
	throw $failure
} finally {
	if ($lock) {
		$lock.Dispose()
	}
}
