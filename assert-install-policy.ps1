[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)]
	[string]$TargetRepo,

	[Parameter(Mandatory = $true)]
	[string]$PackageRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-GitTracked {
	param([Parameter(Mandatory = $true)][string]$RelativePath)

	$oldErrorActionPreference = $ErrorActionPreference
	try {
		$ErrorActionPreference = "Continue"
		& git -C $TargetRepo ls-files --error-unmatch -- $RelativePath *> $null
		$exitCode = $LASTEXITCODE
	} finally {
		$ErrorActionPreference = $oldErrorActionPreference
	}
	return $exitCode -eq 0
}

function Test-ExactBlock {
	param(
		[Parameter(Mandatory = $true)][string]$TargetPath,
		[Parameter(Mandatory = $true)][string]$BlockPath,
		[Parameter(Mandatory = $true)][string]$Begin,
		[Parameter(Mandatory = $true)][string]$End
	)

	if (-not (Test-Path -LiteralPath $TargetPath -PathType Leaf)) {
		return $false
	}
	$targetLines = @([IO.File]::ReadAllLines($TargetPath))
	$blockLines = @([IO.File]::ReadAllLines($BlockPath))
	$beginIndexes = @()
	$endIndexes = @()
	for ($index = 0; $index -lt $targetLines.Count; $index++) {
		if ($targetLines[$index] -ceq $Begin) { $beginIndexes += $index }
		if ($targetLines[$index] -ceq $End) { $endIndexes += $index }
	}
	if ($beginIndexes.Count -ne 1 -or $endIndexes.Count -ne 1 -or $beginIndexes[0] -ge $endIndexes[0]) {
		return $false
	}
	$managedLines = @($targetLines[$beginIndexes[0]..$endIndexes[0]])
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

$repo = [IO.Path]::GetFullPath($TargetRepo)
$package = [IO.Path]::GetFullPath($PackageRoot)
$begin = "<!-- branch-docs-starter:begin -->"
$end = "<!-- branch-docs-starter:end -->"

if ((Test-GitTracked "AGENTS.md") -and -not (Test-ExactBlock `
	-TargetPath (Join-Path $repo "AGENTS.md") `
	-BlockPath (Join-Path $package "AGENTS.branch-docs.md") `
	-Begin $begin `
	-End $end)) {
	throw "Tracked AGENTS.md is not exactly compatible; run migrate-orca-worktree-layout.ps1 with explicit authorization first."
}

if (Test-GitTracked "CLAUDE.md") {
	$claudePath = Join-Path $repo "CLAUDE.md"
	$claudeLines = if (Test-Path -LiteralPath $claudePath -PathType Leaf) {
		@([IO.File]::ReadAllLines($claudePath))
	} else {
		@()
	}
	$delegates = @($claudeLines | Where-Object { $_.Trim() -eq "@AGENTS.md" }).Count -gt 0
	$hasManagedMarker = @($claudeLines | Where-Object {
		$_ -ceq $begin -or $_ -ceq $end
	}).Count -gt 0
	$hasExactBlock = Test-ExactBlock `
		-TargetPath $claudePath `
		-BlockPath (Join-Path $package "CLAUDE.branch-docs.md") `
		-Begin $begin `
		-End $end
	if (($hasManagedMarker -and -not $hasExactBlock) -or
		(-not $hasManagedMarker -and -not $delegates)) {
		throw "Tracked CLAUDE.md is not compatible; run migrate-orca-worktree-layout.ps1 with explicit authorization first."
	}
}

if (Test-GitTracked ".gitignore") {
	$ignorePath = Join-Path $repo ".gitignore"
	if (-not (Test-ExactBlock `
		-TargetPath $ignorePath `
		-BlockPath (Join-Path $package ".agent-work.gitignore.block") `
		-Begin "# branch-docs-starter:begin" `
		-End "# branch-docs-starter:end")) {
		throw "Tracked .gitignore is not exactly compatible; run migrate-orca-worktree-layout.ps1 with explicit authorization first."
	}
	$blanketRules = @([IO.File]::ReadAllLines($ignorePath) | Where-Object {
		$_.Trim() -in @("/docs/", "docs/", "/.codex/", ".codex/")
	})
	if ($blanketRules.Count -gt 0) {
		throw "Tracked .gitignore still contains a blanket docs or .codex rule."
	}
}

exit 0
