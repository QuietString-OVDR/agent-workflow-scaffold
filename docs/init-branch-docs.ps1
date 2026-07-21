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

function Resolve-RepoRoot {
	$superRoot = Invoke-GitText -GitArgs @("rev-parse", "--show-superproject-working-tree") -AllowFailure
	if ($superRoot) {
		return (Resolve-Path -LiteralPath $superRoot).Path
	}

	$topLevel = Invoke-GitText -GitArgs @("rev-parse", "--show-toplevel") -AllowFailure
	if ($topLevel) {
		return (Resolve-Path -LiteralPath $topLevel).Path
	}

	$current = (Get-Location).Path
	while ($current -and $current -ne [IO.Path]::GetPathRoot($current)) {
		if (Test-Path -LiteralPath (Join-Path $current ".git")) {
			return $current
		}
		$current = Split-Path -Parent $current
	}

	throw "Unable to resolve git work tree root from $(Get-Location)."
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
	[IO.File]::WriteAllText($Path, "$json`n", $encoding)
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

	if (-not (Test-Path -LiteralPath $TemplateRoot)) {
		throw "Template root not found: $TemplateRoot"
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
		$encoding = New-Object System.Text.UTF8Encoding $false
		[IO.File]::WriteAllText($targetFile, $text, $encoding)
	}
}

function Ensure-Junction {
	param([string]$LinkPath, [string]$TargetPath)

	if (Test-Path -LiteralPath $LinkPath) {
		$item = Get-Item -LiteralPath $LinkPath -Force
		if ($item.LinkType -eq "Junction" -or $item.LinkType -eq "SymbolicLink") {
			return
		}

		Write-Warning "Compatibility path already exists as a physical directory: $LinkPath"
		Write-Warning "Leaving it untouched. Canonical work docs are under $TargetPath."
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
$docsRoot = Join-Path $repoRoot "docs"
$branchesRoot = Join-Path $docsRoot "branches"
$workRoot = Join-Path $docsRoot "work"
$indexRoot = Join-Path $docsRoot "index"
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

$bindingsIndex = Read-JsonFile $bindingsPath ([pscustomobject][ordered]@{ version = 1; bindings = @() })
$binding = Get-BranchBinding $bindingsIndex $repoName $rawBranchName
$jiraKeys = @(Get-JiraKeysFromBranch $rawBranchName)

$resolvedWorkKey = $null
if ($WorkKey) {
	$resolvedWorkKey = $WorkKey.ToUpperInvariant()
} elseif ($binding -and $binding.workKey) {
	$resolvedWorkKey = ([string]$binding.workKey).ToUpperInvariant()
} elseif ($jiraKeys.Count -eq 1) {
	$resolvedWorkKey = $jiraKeys[0]
} elseif ($jiraKeys.Count -gt 1) {
	throw "Branch contains multiple Jira keys. Add an exact branch binding or pass -WorkKey. Branch: $rawBranchName"
}

if ($ParentWorkKey) {
	$ParentWorkKey = $ParentWorkKey.ToUpperInvariant()
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
	$canonicalRoot = Join-Path $workRoot $resolvedWorkKey
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
