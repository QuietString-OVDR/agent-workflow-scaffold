[CmdletBinding()]
param(
	[string]$BranchName,
	[string]$WorkKey,
	[string]$ParentWorkKey,
	[string]$IssueUrl,
	[string]$ParentIssueUrl,
	[string]$Summary,
	[string]$ParentSummary,
	[switch]$SyncMissing,
	[switch]$AllowNonWorkRef,
	[switch]$PrintBranch,
	[switch]$PrintDocDir,
	[switch]$PrintWorkKey
)

$ErrorActionPreference = "Stop"

function Invoke-GitProbe {
	param([string[]]$GitArgs)

	$gitCommand = Get-Command git -CommandType Application -ErrorAction Stop
	$oldErrorActionPreference = $ErrorActionPreference
	$oldNativeErrorActionPreference = $null
	$exitCode = $null
	$hasNativePreference = Get-Variable -Name PSNativeCommandUseErrorActionPreference -Scope Global -ErrorAction SilentlyContinue
	if ($hasNativePreference) {
		$oldNativeErrorActionPreference = $Global:PSNativeCommandUseErrorActionPreference
		$Global:PSNativeCommandUseErrorActionPreference = $false
	}
	try {
		$ErrorActionPreference = "Continue"
		$output = & $gitCommand.Source @GitArgs 2>$null
		$exitCode = $LASTEXITCODE
	} finally {
		$ErrorActionPreference = $oldErrorActionPreference
		if ($hasNativePreference) {
			$Global:PSNativeCommandUseErrorActionPreference = $oldNativeErrorActionPreference
		}
	}

	return [pscustomobject]@{
		Output = ($output | Select-Object -First 1)
		ExitCode = $exitCode
	}
}

function Invoke-GitText {
	param([string[]]$GitArgs, [switch]$AllowFailure)

	$result = Invoke-GitProbe -GitArgs $GitArgs
	if ($result.ExitCode -ne 0 -and -not $AllowFailure) {
		throw "git $($GitArgs -join ' ') failed."
	}

	if ($result.ExitCode -ne 0) {
		return $null
	}

	return $result.Output
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
	$targets = @($item.Target)
	if ($targets.Count -ne 1 -or -not $targets[0]) {
		throw "Unable to resolve $Description target: $Path"
	}
	if (-not (Test-PathEqual $targets[0] $ExpectedTarget)) {
		throw "$Description points to the wrong target: $Path -> $($targets[0]); expected $ExpectedTarget"
	}
}

function Get-BranchDocsLayout {
	param([Parameter(Mandatory = $true)][string]$WorktreeRoot)

	$commonDir = Normalize-Path (Invoke-GitText -GitArgs @("-C", $WorktreeRoot, "rev-parse", "--path-format=absolute", "--git-common-dir"))
	$manifestPath = Join-Path $commonDir "branch-docs-starter/manifest.json"
	if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
		$docsRoot = Join-Path $WorktreeRoot "docs"
		return [pscustomobject]@{
			ManifestPath = $null
			CommonDir = $commonDir
			AnchorRepoRoot = $WorktreeRoot
			StoreRoot = $docsRoot
			DocsRoot = $docsRoot
			BranchesRoot = (Join-Path $docsRoot "branches")
			WorkRoot = (Join-Path $docsRoot "work")
			IndexRoot = (Join-Path $docsRoot "index")
			LockPath = (Join-Path $commonDir "branch-docs-starter/lifecycle.lock")
		}
	}

	$manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
	if (-not $manifest.schemaVersion) {
		throw "Unsupported branch-docs manifest schema in $manifestPath"
	}
	if ([int]$manifest.schemaVersion -eq 2) {
		if ($manifest.layout -cne "git-common-dir-store-v1") {
			throw "Unsupported schema-v2 branch-docs layout in $manifestPath"
		}
		if ($manifest.storeRelativePath -cne "branch-docs-starter/store") {
			throw "Unsupported schema-v2 branch-docs store path in $manifestPath"
		}

		$storeRoot = Normalize-Path (Join-Path $commonDir ([string]$manifest.storeRelativePath))
		$branchesRoot = Join-Path $storeRoot "branches"
		$workRoot = Join-Path $storeRoot "work"
		$indexRoot = Join-Path $storeRoot "index"
		$docsRoot = Join-Path $WorktreeRoot "docs"
		Assert-PhysicalDirectory $storeRoot "Common branch-docs store root"
		Assert-PhysicalDirectory $branchesRoot "Canonical branches root"
		Assert-PhysicalDirectory $workRoot "Canonical work root"
		Assert-PhysicalDirectory $indexRoot "Canonical index root"
		Assert-PhysicalDirectory $docsRoot "Worktree docs root"
		Assert-ExactJunction (Join-Path $docsRoot "branches") $branchesRoot "Worktree branches projection"
		Assert-ExactJunction (Join-Path $docsRoot "work") $workRoot "Worktree work projection"
		Assert-ExactJunction (Join-Path $docsRoot "index") $indexRoot "Worktree index projection"

		return [pscustomobject]@{
			ManifestPath = $manifestPath
			CommonDir = $commonDir
			AnchorRepoRoot = $null
			StoreRoot = $storeRoot
			DocsRoot = $docsRoot
			BranchesRoot = $branchesRoot
			WorkRoot = $workRoot
			IndexRoot = $indexRoot
			LockPath = (Join-Path $commonDir "branch-docs-starter/lifecycle.lock")
		}
	}
	if ([int]$manifest.schemaVersion -ne 1) {
		throw "Unsupported branch-docs manifest schema in $manifestPath"
	}
	foreach ($property in @("anchorRepoRoot", "commonDir", "branchesRoot", "workRoot", "indexRoot")) {
		if (-not $manifest.PSObject.Properties[$property] -or -not $manifest.$property) {
			throw "Manifest property '$property' is missing in $manifestPath"
		}
	}
	if (-not (Test-PathEqual $manifest.commonDir $commonDir)) {
		throw "Manifest common directory does not match the current worktree."
	}

	$anchorRoot = Normalize-Path $manifest.anchorRepoRoot
	$anchorTopLevel = Normalize-Path (Invoke-GitText -GitArgs @("-C", $anchorRoot, "rev-parse", "--show-toplevel"))
	$anchorGitDir = Normalize-Path (Invoke-GitText -GitArgs @("-C", $anchorRoot, "rev-parse", "--path-format=absolute", "--git-dir"))
	$anchorCommonDir = Normalize-Path (Invoke-GitText -GitArgs @("-C", $anchorRoot, "rev-parse", "--path-format=absolute", "--git-common-dir"))
	if (-not (Test-PathEqual $anchorTopLevel $anchorRoot) -or
		-not (Test-PathEqual $anchorCommonDir $commonDir) -or
		-not (Test-PathEqual $anchorGitDir $anchorCommonDir)) {
		throw "Manifest anchor is not the main worktree for the current Git common directory."
	}
	$docsRoot = Join-Path $anchorRoot "docs"
	$branchesRoot = Normalize-Path $manifest.branchesRoot
	$workRoot = Normalize-Path $manifest.workRoot
	$indexRoot = Normalize-Path $manifest.indexRoot
	if (-not (Test-PathEqual $branchesRoot (Join-Path $docsRoot "branches")) -or
		-not (Test-PathEqual $workRoot (Join-Path $docsRoot "work")) -or
		-not (Test-PathEqual $indexRoot (Join-Path $docsRoot "index"))) {
		throw "Manifest canonical roots do not match the anchor reserved namespace."
	}
	Assert-PhysicalDirectory $docsRoot "Anchor docs root"
	Assert-PhysicalDirectory $branchesRoot "Canonical branches root"
	Assert-PhysicalDirectory $workRoot "Canonical work root"
	Assert-PhysicalDirectory $indexRoot "Canonical index root"

	return [pscustomobject]@{
		ManifestPath = $manifestPath
		CommonDir = $commonDir
		AnchorRepoRoot = $anchorRoot
		StoreRoot = $docsRoot
		DocsRoot = $docsRoot
		BranchesRoot = $branchesRoot
		WorkRoot = $workRoot
		IndexRoot = $indexRoot
		LockPath = (Join-Path $commonDir "branch-docs-starter/lifecycle.lock")
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

function Resolve-RepoRoot {
	$scriptRepo = Normalize-Path (Split-Path -Parent $PSScriptRoot)
	$superRoot = Invoke-GitText -GitArgs @("-C", $scriptRepo, "rev-parse", "--show-superproject-working-tree") -AllowFailure
	if ($superRoot) {
		return (Resolve-Path -LiteralPath $superRoot).Path
	}

	$topLevel = Invoke-GitText -GitArgs @("-C", $scriptRepo, "rev-parse", "--show-toplevel") -AllowFailure
	if ($topLevel) {
		return (Resolve-Path -LiteralPath $topLevel).Path
	}

	$current = $scriptRepo
	while ($current -and $current -ne [IO.Path]::GetPathRoot($current)) {
		if (Test-Path -LiteralPath (Join-Path $current ".git")) {
			return $current
		}
		$current = Split-Path -Parent $current
	}

	throw "Unable to resolve git work tree root from $scriptRepo."
}

function Normalize-BranchName {
	param([string]$RawBranch)

	$normalized = $RawBranch -replace '^refs/heads/', ''
	$normalized = $normalized -replace '^refs/remotes/', ''
	$normalized = $normalized -replace '^origin/', ''

	if ([string]::IsNullOrWhiteSpace($normalized)) {
		throw "Branch name is empty."
	}

	& git -C / check-ref-format --branch $normalized *> $null
	if ($LASTEXITCODE -ne 0) {
		throw "Invalid branch name: $RawBranch"
	}

	return $normalized
}

function Get-CurrentBranch {
	param([string]$RepoRoot)

	$result = Invoke-GitProbe -GitArgs @("-C", $RepoRoot, "symbolic-ref", "--quiet", "--short", "HEAD")
	if ($result.ExitCode -eq 0) {
		if (-not $result.Output) {
			throw "git symbolic-ref returned an empty branch name for $RepoRoot."
		}
		return (Normalize-BranchName $result.Output)
	}

	if ($result.ExitCode -eq 1) {
		return $null
	}

	throw "Unable to resolve current branch from $RepoRoot. git symbolic-ref failed with exit code $($result.ExitCode)."
}

function Get-DocumentationBranchName {
	param([string]$RawBranchName)

	if ($RawBranchName -match '^(.+)-b+$') {
		return $Matches[1]
	}

	return $RawBranchName
}

function Get-BranchDocDir {
	param([string]$DocumentationBranchName)

	$branchDocDir = $DocumentationBranchName -replace '/', '~'
	switch -Regex ($branchDocDir.ToLowerInvariant()) {
		'^(con|prn|aux|nul|com[1-9]|lpt[1-9])$' { return "_$branchDocDir" }
		default { return $branchDocDir }
	}
}

function Get-JiraKeysFromBranch {
	param([string]$RawBranchName)

	$matches = [regex]::Matches($RawBranchName, '(?i)(?<![A-Z0-9])OVDR-[0-9]+(?![A-Z0-9])')
	$keys = @()
	foreach ($match in $matches) {
		$key = $match.Value.ToUpperInvariant()
		if ($keys -notcontains $key) {
			$keys += $key
		}
	}
	return $keys
}

function Normalize-WorkKey {
	param(
		[Parameter(Mandatory = $true)][string]$Value,
		[Parameter(Mandatory = $true)][string]$ParameterName
	)

	$normalized = $Value.Trim().ToUpperInvariant()
	if ($normalized -notmatch '^[A-Z][A-Z0-9_]*-[1-9][0-9]*$') {
		throw "$ParameterName must be a Jira key such as OVDR-123: $Value"
	}
	return $normalized
}

function Get-OriginRepo {
	param([string]$RepoRoot)

	$origin = Invoke-GitText -GitArgs @("-C", $RepoRoot, "remote", "get-url", "origin") -AllowFailure
	if (-not $origin) {
		return @{
			Repo = (Split-Path -Leaf $RepoRoot)
			ProjectKey = (Split-Path -Leaf $RepoRoot)
		}
	}

	$clean = $origin.Trim()
	$clean = $clean -replace '\.git$', ''

	if ($clean -match '^[^@]+@[^:]+:(.+)$') {
		$path = $Matches[1]
	} elseif ($clean -match 'https?://[^/]+/(.+)$') {
		$path = $Matches[1]
	} else {
		$path = $clean
	}

	$parts = $path -split '[\\/]'
	if ($parts.Count -ge 2) {
		$repo = "$($parts[$parts.Count - 2])/$($parts[$parts.Count - 1])"
	} else {
		$repo = $parts[$parts.Count - 1]
	}

	return @{
		Repo = $repo
		ProjectKey = ($repo -replace '/', '~')
	}
}

function Read-JsonFile {
	param($Path, $DefaultValue)

	if (-not (Test-Path -LiteralPath $Path)) {
		return $DefaultValue
	}

	$text = [IO.File]::ReadAllText($Path)
	if ([string]::IsNullOrWhiteSpace($text)) {
		return $DefaultValue
	}

	return ($text | ConvertFrom-Json)
}

function Write-JsonFile {
	param($Path, $Value)

	$parent = Split-Path -Parent $Path
	if (-not (Test-Path -LiteralPath $parent)) {
		New-Item -ItemType Directory -Path $parent | Out-Null
	}

	$json = $Value | ConvertTo-Json -Depth 16
	$encoding = New-Object System.Text.UTF8Encoding $false
	$tempPath = Join-Path $parent ("branch-docs-json-" + [Guid]::NewGuid().ToString("N") + ".tmp")
	$backupPath = Join-Path $parent ("branch-docs-json-" + [Guid]::NewGuid().ToString("N") + ".bak")
	try {
		[IO.File]::WriteAllText($tempPath, "$json`n", $encoding)
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

function Write-Utf8NewAtomic {
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)][string]$Text
	)

	$parent = Split-Path -Parent $Path
	if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
		New-Item -ItemType Directory -Path $parent | Out-Null
	}
	$tempPath = Join-Path $parent ("branch-docs-template-" + [Guid]::NewGuid().ToString("N") + ".tmp")
	try {
		[IO.File]::WriteAllText($tempPath, $Text, (New-Object Text.UTF8Encoding $false))
		if ([IO.File]::Exists($Path)) {
			throw "Template target appeared during atomic creation: $Path"
		}
		[IO.File]::Move($tempPath, $Path)
	} finally {
		if (Test-Path -LiteralPath $tempPath) {
			Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
		}
	}
}

function Ensure-ObjectProperty {
	param($Object, [string]$Name, $Value)

	$property = $Object.PSObject.Properties[$Name]
	if ($property) {
		$property.Value = $Value
	} else {
		$Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
	}
}

function Add-Unique {
	param($Items, [string]$Value)

	$result = @()
	foreach ($item in @($Items)) {
		if ($null -ne $item -and "$item" -ne "" -and $result -notcontains "$item") {
			$result += "$item"
		}
	}
	if ($Value -and $result -notcontains $Value) {
		$result += $Value
	}
	return $result
}

function Get-BranchBinding {
	param($BindingsIndex, [string]$Repo, [string]$RawBranchName)

	foreach ($binding in @($BindingsIndex.bindings)) {
		if ($binding.repo -eq $Repo -and $binding.branch -eq $RawBranchName) {
			return $binding
		}
	}

	return $null
}

function Update-BranchBinding {
	param($BindingsIndex, [string]$Repo, [string]$RawBranchName, [string]$BranchDocDir, [string]$ResolvedWorkKey)

	$bindings = @($BindingsIndex.bindings)
	$found = $false
	for ($i = 0; $i -lt $bindings.Count; $i++) {
		if ($bindings[$i].repo -eq $Repo -and $bindings[$i].branch -eq $RawBranchName) {
			Ensure-ObjectProperty $bindings[$i] "workKey" $ResolvedWorkKey
			Ensure-ObjectProperty $bindings[$i] "branchDocDir" $BranchDocDir
			$found = $true
			break
		}
	}

	if (-not $found) {
		$bindings += [pscustomobject][ordered]@{
			repo = $Repo
			branch = $RawBranchName
			workKey = $ResolvedWorkKey
			branchDocDir = $BranchDocDir
		}
	}

	Ensure-ObjectProperty $BindingsIndex "bindings" $bindings
}

function Get-IssueUrlForKey {
	param([string]$Key, [string]$ExplicitUrl, [string]$JiraBaseUrl)

	if ($ExplicitUrl) {
		return $ExplicitUrl
	}
	if ($Key -and $JiraBaseUrl) {
		return "$JiraBaseUrl/browse/$Key"
	}
	return $null
}

function Ensure-WorkItem {
	param(
		$WorkItemsIndex,
		[string]$ResolvedWorkKey,
		[string]$IssueType,
		[string]$ItemSummary,
		[string]$ItemStatus,
		[string]$ParentKey,
		[string]$RawBranchName,
		[string]$BranchDocDir,
		[string]$WorkRootRelative,
		[string]$ItemIssueUrl,
		[string]$Source
	)

	if (-not $WorkItemsIndex.items) {
		Ensure-ObjectProperty $WorkItemsIndex "items" ([pscustomobject]@{})
	}

	$itemProperty = $WorkItemsIndex.items.PSObject.Properties[$ResolvedWorkKey]
	if ($itemProperty) {
		$item = $itemProperty.Value
	} else {
		$item = [pscustomobject][ordered]@{}
		$WorkItemsIndex.items | Add-Member -NotePropertyName $ResolvedWorkKey -NotePropertyValue $item
	}

	Ensure-ObjectProperty $item "workKey" $ResolvedWorkKey
	Ensure-ObjectProperty $item "issueUrl" $ItemIssueUrl
	Ensure-ObjectProperty $item "issueType" $IssueType
	Ensure-ObjectProperty $item "summary" $ItemSummary
	Ensure-ObjectProperty $item "status" $ItemStatus
	Ensure-ObjectProperty $item "parentKey" $ParentKey
	if (-not $item.childKeys) {
		Ensure-ObjectProperty $item "childKeys" @()
	}
	Ensure-ObjectProperty $item "branchNames" @(Add-Unique $item.branchNames $RawBranchName)
	Ensure-ObjectProperty $item "workRoot" $WorkRootRelative
	Ensure-ObjectProperty $item "branchDocDirs" @(Add-Unique $item.branchDocDirs $BranchDocDir)
	Ensure-ObjectProperty $item "source" $Source
	Ensure-ObjectProperty $item "refreshedAt" (Get-Date -Format "yyyy-MM-ddTHH:mm:ssK")
	if (-not $item.notes) {
		Ensure-ObjectProperty $item "notes" ""
	}

	return $item
}

function Ensure-ParentWorkItem {
	param(
		$WorkItemsIndex,
		[string]$ResolvedParentKey,
		[string]$ChildKey,
		[string]$ItemSummary,
		[string]$ItemIssueUrl,
		[string]$WorkRootRelative,
		[string]$Source
	)

	if (-not $ResolvedParentKey) {
		return
	}

	if (-not $WorkItemsIndex.items) {
		Ensure-ObjectProperty $WorkItemsIndex "items" ([pscustomobject]@{})
	}

	$itemProperty = $WorkItemsIndex.items.PSObject.Properties[$ResolvedParentKey]
	if ($itemProperty) {
		$item = $itemProperty.Value
	} else {
		$item = [pscustomobject][ordered]@{}
		$WorkItemsIndex.items | Add-Member -NotePropertyName $ResolvedParentKey -NotePropertyValue $item
	}

	Ensure-ObjectProperty $item "workKey" $ResolvedParentKey
	Ensure-ObjectProperty $item "issueUrl" $ItemIssueUrl
	Ensure-ObjectProperty $item "issueType" "Epic"
	Ensure-ObjectProperty $item "summary" $ItemSummary
	Ensure-ObjectProperty $item "status" ""
	Ensure-ObjectProperty $item "parentKey" $null
	Ensure-ObjectProperty $item "childKeys" @(Add-Unique $item.childKeys $ChildKey)
	if (-not $item.branchNames) {
		Ensure-ObjectProperty $item "branchNames" @()
	}
	Ensure-ObjectProperty $item "workRoot" $WorkRootRelative
	if (-not $item.branchDocDirs) {
		Ensure-ObjectProperty $item "branchDocDirs" @()
	}
	Ensure-ObjectProperty $item "source" $Source
	Ensure-ObjectProperty $item "refreshedAt" (Get-Date -Format "yyyy-MM-ddTHH:mm:ssK")
	if (-not $item.notes) {
		Ensure-ObjectProperty $item "notes" "Parent owns shared decisions, rollout, and validation rollup."
	}
}

function Sync-Template {
	param([string]$TemplateRoot, [string]$TargetRoot, [hashtable]$Replacements)

	if (-not (Test-Path -LiteralPath $TemplateRoot -PathType Container)) {
		throw "Template root not found: $TemplateRoot"
	}
	Assert-PhysicalDirectory $TemplateRoot "Branch-doc template root"
	$templateReparse = @(Get-ChildItem -LiteralPath $TemplateRoot -Recurse -Force |
		Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
	if ($templateReparse.Count -gt 0) {
		throw "Branch-doc template contains a reparse point: $($templateReparse[0].FullName)"
	}

	$targetItem = Get-Item -LiteralPath $TargetRoot -Force -ErrorAction SilentlyContinue
	if ($targetItem) {
		Assert-PhysicalDirectory $TargetRoot "Canonical work root"
		$targetReparse = @(Get-ChildItem -LiteralPath $TargetRoot -Recurse -Force |
			Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
		if ($targetReparse.Count -gt 0) {
			throw "Canonical work root contains a reparse point: $($targetReparse[0].FullName)"
		}
	}

	foreach ($directory in Get-ChildItem -LiteralPath $TemplateRoot -Directory -Recurse) {
		$relative = $directory.FullName.Substring($TemplateRoot.Length).TrimStart('\', '/')
		$targetDirectory = Join-Path $TargetRoot $relative
		if (-not (Test-Path -LiteralPath $targetDirectory)) {
			New-Item -ItemType Directory -Path $targetDirectory | Out-Null
		}
	}

	if (-not (Test-Path -LiteralPath $TargetRoot)) {
		New-Item -ItemType Directory -Path $TargetRoot | Out-Null
	}

	foreach ($sourceFile in Get-ChildItem -LiteralPath $TemplateRoot -File -Recurse) {
		$relative = $sourceFile.FullName.Substring($TemplateRoot.Length).TrimStart('\', '/')
		$targetFile = Join-Path $TargetRoot $relative
		if (Test-Path -LiteralPath $targetFile) {
			$targetFileItem = Get-Item -LiteralPath $targetFile -Force
			if ($targetFileItem -is [IO.DirectoryInfo] -or
				($targetFileItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
				throw "Existing canonical template target must be a regular non-reparse file: $targetFile"
			}
			if ([string]::IsNullOrWhiteSpace([IO.File]::ReadAllText($targetFile))) {
				throw "Existing canonical template target is empty or whitespace-only: $targetFile"
			}
			continue
		}

		$targetParent = Split-Path -Parent $targetFile
		if (-not (Test-Path -LiteralPath $targetParent)) {
			New-Item -ItemType Directory -Path $targetParent | Out-Null
		}

		$text = [IO.File]::ReadAllText($sourceFile.FullName)
		foreach ($key in $Replacements.Keys) {
			$text = $text.Replace($key, [string]$Replacements[$key])
		}
		Write-Utf8NewAtomic $targetFile $text
	}
}

function Ensure-Junction {
	param([string]$LinkPath, [string]$TargetPath)

	$item = Get-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue
	if ($item) {
		if ($item.LinkType -ne "Junction") {
			throw "Compatibility path exists but is not a junction: $LinkPath"
		}
		$targets = @($item.Target)
		if ($targets.Count -ne 1 -or -not $targets[0]) {
			throw "Unable to resolve compatibility junction target: $LinkPath"
		}
		if (-not (Test-PathEqual $targets[0] $TargetPath)) {
			throw "Compatibility junction points to the wrong target: $LinkPath -> $($targets[0]); expected $TargetPath"
		}
		return
	}

	$parent = Split-Path -Parent $LinkPath
	if (-not (Test-Path -LiteralPath $parent)) {
		New-Item -ItemType Directory -Path $parent | Out-Null
	}

	$command = "mklink /J ""$LinkPath"" ""$TargetPath"""
	& cmd.exe /d /c $command | Out-Host
	if ($LASTEXITCODE -ne 0) {
		throw "Failed to create junction: $LinkPath -> $TargetPath"
	}
}

$repoRoot = Resolve-RepoRoot
$layout = Get-BranchDocsLayout $repoRoot
$docsRoot = $layout.DocsRoot
$branchesRoot = $layout.BranchesRoot
$workRoot = $layout.WorkRoot
$indexRoot = $layout.IndexRoot
$templateRoot = Join-Path $branchesRoot "_template"
$bindingsPath = Join-Path $indexRoot "branch-bindings.json"
$workItemsPath = Join-Path $indexRoot "work-items.json"

$currentBranch = Get-CurrentBranch $repoRoot
if ($BranchName) {
	$rawBranchName = Normalize-BranchName $BranchName
} else {
	$rawBranchName = $currentBranch
}

if (-not $rawBranchName) {
	if ($PrintBranch -or $PrintDocDir -or $PrintWorkKey) {
		throw "Unable to detect current branch from $repoRoot because HEAD is detached."
	}
	if ($AllowNonWorkRef) {
		throw "Detached HEAD requires -BranchName when -AllowNonWorkRef is used."
	}
	Write-Output "Branch docs skipped: HEAD is detached. Continue without branch documentation unless the user explicitly requests it."
	exit 0
}

$documentationBranchName = Get-DocumentationBranchName $rawBranchName
$branchDocDir = Get-BranchDocDir $documentationBranchName
$repoInfo = Get-OriginRepo $repoRoot
$repoName = $repoInfo.Repo
$projectKey = $repoInfo.ProjectKey
$jiraBaseUrl = "https://overdare.atlassian.net"

$lifecycleLock = Enter-LifecycleLock $layout.LockPath
try {
$lockedLayout = Get-BranchDocsLayout $repoRoot
foreach ($property in @("CommonDir", "StoreRoot", "DocsRoot", "BranchesRoot", "WorkRoot", "IndexRoot", "LockPath")) {
	if (-not (Test-PathEqual $layout.$property $lockedLayout.$property)) {
		throw "Branch-docs layout changed while waiting for the lifecycle lock: $property"
	}
}
$layout = $lockedLayout
$docsRoot = $layout.DocsRoot
$branchesRoot = $layout.BranchesRoot
$workRoot = $layout.WorkRoot
$indexRoot = $layout.IndexRoot
$templateRoot = Join-Path $branchesRoot "_template"
$bindingsPath = Join-Path $indexRoot "branch-bindings.json"
$workItemsPath = Join-Path $indexRoot "work-items.json"
if (-not $BranchName) {
	$lockedCurrentBranch = Get-CurrentBranch $repoRoot
	if ($lockedCurrentBranch -cne $currentBranch) {
		throw "Current branch changed while waiting for the lifecycle lock."
	}
}
$bindingsIndex = Read-JsonFile $bindingsPath ([pscustomobject][ordered]@{ version = 1; bindings = @() })
$binding = Get-BranchBinding $bindingsIndex $repoName $rawBranchName
$jiraKeys = @(Get-JiraKeysFromBranch $rawBranchName)

$resolvedWorkKey = $null
if ($WorkKey) {
	$resolvedWorkKey = Normalize-WorkKey $WorkKey "-WorkKey"
} elseif ($binding -and $binding.workKey) {
	$resolvedWorkKey = Normalize-WorkKey ([string]$binding.workKey) "Bound work key"
} elseif ($jiraKeys.Count -eq 1) {
	$resolvedWorkKey = Normalize-WorkKey $jiraKeys[0] "Branch work key"
} elseif ($jiraKeys.Count -gt 1) {
	throw "Branch contains multiple Jira keys. Add an exact branch binding or pass -WorkKey. Branch: $rawBranchName"
}

if ($ParentWorkKey) {
	$ParentWorkKey = Normalize-WorkKey $ParentWorkKey "-ParentWorkKey"
}

if ($PrintBranch) {
	Write-Output $documentationBranchName
	exit 0
}

if ($PrintDocDir) {
	Write-Output $branchDocDir
	exit 0
}

if ($PrintWorkKey) {
	if ($resolvedWorkKey) {
		Write-Output $resolvedWorkKey
	}
	exit 0
}

if (-not $AllowNonWorkRef -and -not $currentBranch) {
	Write-Output "Branch docs skipped: HEAD is detached. Continue without branch documentation unless the user explicitly requests it."
	exit 0
}

if (-not $AllowNonWorkRef -and (($currentBranch -ceq "master") -or ($rawBranchName -ceq "master"))) {
	Write-Output "Branch docs skipped: the current or requested branch is master. Continue without branch documentation unless the user explicitly requests it."
	exit 0
}

New-Item -ItemType Directory -Path $branchesRoot, $workRoot, $indexRoot -Force | Out-Null

$replacements = @{
	"__BRANCH_NAME__" = $documentationBranchName
	"__BRANCH_DOC_DIR_NAME__" = $branchDocDir
	"__WORK_KEY__" = $(if ($resolvedWorkKey) { $resolvedWorkKey } else { $documentationBranchName })
	"__PARENT_WORK_KEY__" = $(if ($ParentWorkKey) { $ParentWorkKey } else { "" })
	"__ISSUE_URL__" = $(if ($IssueUrl) { $IssueUrl } elseif ($resolvedWorkKey) { "$jiraBaseUrl/browse/$resolvedWorkKey" } else { "" })
}

if ($resolvedWorkKey) {
	$canonicalRoot = Normalize-Path (Join-Path $workRoot $resolvedWorkKey)
	if (-not (Test-PathEqual (Split-Path -Parent $canonicalRoot) $workRoot)) {
		throw "Resolved work root escaped the canonical work directory: $canonicalRoot"
	}
	Sync-Template $templateRoot $canonicalRoot $replacements
	Ensure-Junction (Join-Path $branchesRoot $branchDocDir) $canonicalRoot

	Update-BranchBinding $bindingsIndex $repoName $rawBranchName $branchDocDir $resolvedWorkKey
	Write-JsonFile $bindingsPath $bindingsIndex

	$workItemsIndex = Read-JsonFile $workItemsPath ([pscustomobject][ordered]@{
		version = 1
		project = [pscustomobject][ordered]@{
			repo = $repoName
			projectKey = $projectKey
			jiraBaseUrl = $jiraBaseUrl
		}
		items = [pscustomobject]@{}
	})
	Ensure-ObjectProperty $workItemsIndex "version" 1
	Ensure-ObjectProperty $workItemsIndex "project" ([pscustomobject][ordered]@{
		repo = $repoName
		projectKey = $projectKey
		jiraBaseUrl = $jiraBaseUrl
	})

	$relativeWorkRoot = "docs/work/$resolvedWorkKey"
	Ensure-WorkItem `
		-WorkItemsIndex $workItemsIndex `
		-ResolvedWorkKey $resolvedWorkKey `
		-IssueType "Task" `
		-ItemSummary $(if ($Summary) { $Summary } else { "" }) `
		-ItemStatus "" `
		-ParentKey $ParentWorkKey `
		-RawBranchName $rawBranchName `
		-BranchDocDir $branchDocDir `
		-WorkRootRelative $relativeWorkRoot `
		-ItemIssueUrl (Get-IssueUrlForKey $resolvedWorkKey $IssueUrl $jiraBaseUrl) `
		-Source $(if ($IssueUrl -or $ParentIssueUrl -or $ParentWorkKey) { "user" } else { "manual" }) | Out-Null

	if ($ParentWorkKey) {
		Ensure-ParentWorkItem `
			-WorkItemsIndex $workItemsIndex `
			-ResolvedParentKey $ParentWorkKey `
			-ChildKey $resolvedWorkKey `
			-ItemSummary $(if ($ParentSummary) { $ParentSummary } else { "" }) `
			-ItemIssueUrl (Get-IssueUrlForKey $ParentWorkKey $ParentIssueUrl $jiraBaseUrl) `
			-WorkRootRelative "docs/work/$ParentWorkKey" `
			-Source $(if ($ParentIssueUrl) { "user" } else { "manual" })
	}

	Write-JsonFile $workItemsPath $workItemsIndex
	Write-Output "Work docs ready: $canonicalRoot"
	Write-Output "Branch compatibility path: $(Join-Path $branchesRoot $branchDocDir)"
} else {
	$legacyRoot = Join-Path $branchesRoot $branchDocDir
	if ((Test-Path -LiteralPath $legacyRoot) -and -not $SyncMissing) {
		Write-Output "Branch docs already exist: $legacyRoot"
		Write-Output "Use -SyncMissing to add only missing template files."
		exit 0
	}

	Sync-Template $templateRoot $legacyRoot $replacements
	Write-Output "Branch docs ready: $legacyRoot"
}
} finally {
	if ($lifecycleLock) {
		$lifecycleLock.Dispose()
	}
}

exit 0
