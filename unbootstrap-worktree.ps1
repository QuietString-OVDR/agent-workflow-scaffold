[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)]
	[string]$TargetRepo,

	[Parameter(Mandatory = $true)]
	[string]$AnchorRepo,

	[switch]$VerifyOnly,
	[int]$LockTimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-Git {
	param(
		[Parameter(Mandatory = $true)][string]$Repo,
		[Parameter(Mandatory = $true)][string[]]$Arguments
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
	if ($exitCode -ne 0) {
		throw "git -C `"$Repo`" $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
	}
	return (($output | ForEach-Object { "$_" }) -join "`n").Trim()
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

	$root = Normalize-Path (Invoke-Git $Repo @("rev-parse", "--show-toplevel"))
	return [pscustomobject]@{
		Root = $root
		GitDir = (Normalize-Path (Invoke-Git $root @("rev-parse", "--path-format=absolute", "--git-dir")))
		CommonDir = (Normalize-Path (Invoke-Git $root @("rev-parse", "--path-format=absolute", "--git-common-dir")))
	}
}

function Enter-LifecycleLock {
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[int]$TimeoutSeconds
	)

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

function Get-ExactJunction {
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)][string]$ExpectedTarget
	)

	$item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
	if (-not $item) {
		return $null
	}
	if ($item.LinkType -ne "Junction") {
		throw "Removal path is not a junction: $Path"
	}
	$targets = @($item.Target)
	if ($targets.Count -ne 1 -or -not $targets[0]) {
		throw "Unable to resolve junction target: $Path"
	}
	$target = Normalize-Path $targets[0]
	if (-not (Test-PathEqual $target $ExpectedTarget)) {
		throw "Wrong junction target at $Path. Expected '$ExpectedTarget', found '$target'."
	}
	return [pscustomobject]@{
		Path = $Path
		Target = $target
	}
}

function Remove-JunctionLeaf {
	param([Parameter(Mandatory = $true)][string]$Path)

	& cmd.exe /d /c rmdir "`"$Path`"" 2>&1 | Out-Null
	if ($LASTEXITCODE -ne 0) {
		throw "Failed to remove junction leaf: $Path"
	}
	if (Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue) {
		throw "Junction leaf still exists after removal: $Path"
	}
}

if ($env:OS -ne "Windows_NT") {
	throw "unbootstrap-worktree.ps1 supports native Windows only."
}
if ($LockTimeoutSeconds -lt 1) {
	throw "-LockTimeoutSeconds must be at least 1."
}

$targetContext = Get-RepoContext $TargetRepo
$anchorContext = Get-RepoContext $AnchorRepo
if (Test-PathEqual $targetContext.Root $anchorContext.Root) {
	throw "Refusing to unbootstrap the primary anchor."
}
if (-not (Test-PathEqual $targetContext.CommonDir $anchorContext.CommonDir)) {
	throw "Target and anchor do not share the same Git common directory."
}
if (-not (Test-PathEqual $anchorContext.GitDir $anchorContext.CommonDir)) {
	throw "AnchorRepo must be the main worktree."
}

$manifestPath = Join-Path $anchorContext.CommonDir "branch-docs-starter/manifest.json"
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
	throw "Branch-docs manifest not found: $manifestPath"
}
$manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
if (-not $manifest.schemaVersion -or [int]$manifest.schemaVersion -ne 1) {
	throw "Unsupported branch-docs manifest schema."
}
foreach ($property in @("anchorRepoRoot", "commonDir", "branchesRoot", "indexRoot", "workRoot")) {
	if (-not $manifest.PSObject.Properties[$property] -or -not $manifest.$property) {
		throw "Manifest property '$property' is missing."
	}
}
if (-not (Test-PathEqual $manifest.anchorRepoRoot $anchorContext.Root)) {
	throw "Manifest anchor does not match -AnchorRepo."
}
$expectedDocsRoot = Join-Path $anchorContext.Root "docs"
if (-not (Test-PathEqual $manifest.commonDir $anchorContext.CommonDir) -or
	-not (Test-PathEqual $manifest.branchesRoot (Join-Path $expectedDocsRoot "branches")) -or
	-not (Test-PathEqual $manifest.indexRoot (Join-Path $expectedDocsRoot "index")) -or
	-not (Test-PathEqual $manifest.workRoot (Join-Path $expectedDocsRoot "work"))) {
	throw "Manifest roots do not match the exact anchor repository layout."
}

$docsRoot = Join-Path $targetContext.Root "docs"
$docsItem = Get-Item -LiteralPath $docsRoot -Force -ErrorAction SilentlyContinue
if (-not $docsItem -or -not ($docsItem -is [IO.DirectoryInfo]) -or
	($docsItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
	throw "Child docs root must be a physical non-reparse directory: $docsRoot"
}

$links = @(
	Get-ExactJunction (Join-Path $docsRoot "branches") $manifest.branchesRoot
	Get-ExactJunction (Join-Path $docsRoot "index") $manifest.indexRoot
	Get-ExactJunction (Join-Path $docsRoot "work") $manifest.workRoot
)
$links = @($links | Where-Object { $null -ne $_ })
foreach ($target in @($manifest.branchesRoot, $manifest.indexRoot, $manifest.workRoot)) {
	if (-not (Test-Path -LiteralPath $target -PathType Container)) {
		throw "Canonical target is missing: $target"
	}
}

if ($VerifyOnly) {
	if ($links.Count -eq 0) {
		Write-Output "Verified already-unbootstrapped child: $($targetContext.Root)"
	} else {
		Write-Output "Verified $($links.Count) remaining removable branch-docs junction(s): $($targetContext.Root)"
	}
	exit 0
}

if ($links.Count -eq 0) {
	Write-Output "Branch-docs junction leaves were already removed: $($targetContext.Root)"
	exit 0
}

$lockPath = Join-Path $anchorContext.CommonDir "branch-docs-starter/lifecycle.lock"
$lock = $null
$alreadyRemoved = $false
try {
	$lock = Enter-LifecycleLock $lockPath $LockTimeoutSeconds
	$lockedLinks = @(
		Get-ExactJunction (Join-Path $docsRoot "branches") $manifest.branchesRoot
		Get-ExactJunction (Join-Path $docsRoot "index") $manifest.indexRoot
		Get-ExactJunction (Join-Path $docsRoot "work") $manifest.workRoot
	)
	$lockedLinks = @($lockedLinks | Where-Object { $null -ne $_ })
	if ($lockedLinks.Count -eq 0) {
		$alreadyRemoved = $true
	}
	if (-not $alreadyRemoved) {
		foreach ($link in $lockedLinks) {
			Remove-JunctionLeaf $link.Path
			if (-not (Test-Path -LiteralPath $link.Target -PathType Container)) {
				throw "Canonical target disappeared while removing junction leaf: $($link.Target)"
			}
		}
	}
} finally {
	if ($lock) {
		$lock.Dispose()
	}
}

if ($alreadyRemoved) {
	Write-Output "Branch-docs junction leaves were already removed: $($targetContext.Root)"
} else {
	Write-Output "Removed branch-docs junction leaves before worktree deletion: $($targetContext.Root)"
}
