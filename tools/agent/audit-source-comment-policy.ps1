[CmdletBinding()]
param(
	[string]$RepoRoot = ".",
	[int]$MinAddedLogicLines = 30,
	[switch]$Staged,
	[switch]$FailOnWarning,
	[switch]$Quiet
)

$ErrorActionPreference = "Stop"

function Invoke-Git {
	param(
		[string[]]$Arguments
	)

	$Output = & git @Arguments
	if ($LASTEXITCODE -ne 0) {
		throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
	}

	return $Output
}

function Normalize-GitPath {
	param(
		[string]$Path
	)

	$Normalized = $Path.Trim()
	if ($Normalized -match " => ") {
		$Normalized = ($Normalized -replace "^.* => ", "").Trim()
		$Normalized = $Normalized.TrimEnd([char]"}")
	}

	return ($Normalized -replace "\\", "/")
}

function Test-SourcePath {
	param(
		[string]$Path
	)

	$Normalized = Normalize-GitPath $Path
	# 생성물과 캐시 경로는 주석 정책 검토 대상에서 제외한다.
	if ($Normalized -match "(^|/)(Binaries|Intermediate|Saved|DerivedDataCache|node_modules|\.agent-work|\.codex)(/|$)") {
		return $false
	}

	if ($Normalized -match "(^|/)Generated(/|$)") {
		return $false
	}

	if ($Normalized -match "(\.generated\.h|\.gen\.cpp|\.designer\.cs|\.g\.cs)$") {
		return $false
	}

	$Extension = [System.IO.Path]::GetExtension($Normalized).ToLowerInvariant()
	$SourceExtensions = @(
		".c", ".cc", ".cpp", ".cxx",
		".h", ".hh", ".hpp", ".hxx", ".inl", ".ipp",
		".cs", ".java", ".kt", ".kts",
		".m", ".mm", ".swift",
		".js", ".jsx", ".ts", ".tsx"
	)

	return $SourceExtensions -contains $Extension
}

function Escape-MarkdownTableValue {
	param(
		[string]$Value
	)

	return (($Value -replace "\|", "\|") -replace "`r?`n", " ")
}

$GitCommand = Get-Command git -ErrorAction SilentlyContinue
if ($null -eq $GitCommand) {
	throw "git was not found in PATH"
}

$ResolvedRepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$RepoTop = (Invoke-Git @("-C", $ResolvedRepoRoot, "rev-parse", "--show-toplevel") | Select-Object -First 1)
if ([string]::IsNullOrWhiteSpace($RepoTop)) {
	throw "Unable to resolve git repository root from $ResolvedRepoRoot"
}

$RepoTop = $RepoTop.Trim()
$ModeArgs = @()
$DiffMode = "working tree"
if ($Staged) {
	$ModeArgs += "--cached"
	$DiffMode = "staged"
}

$NumstatArgs = @("-C", $RepoTop, "diff", "--numstat", "--no-ext-diff") + $ModeArgs + @("--")
$NumstatLines = Invoke-Git $NumstatArgs

$CheckedFiles = New-Object System.Collections.Generic.List[object]
$Warnings = New-Object System.Collections.Generic.List[object]

foreach ($Line in $NumstatLines) {
	if ([string]::IsNullOrWhiteSpace($Line)) {
		continue
	}

	$Parts = $Line -split "`t"
	if ($Parts.Count -lt 3) {
		continue
	}

	if ($Parts[0] -notmatch "^\d+$") {
		continue
	}

	$AddedLines = [int]$Parts[0]
	if ($AddedLines -le 0) {
		continue
	}

	$RawPath = ($Parts[2..($Parts.Count - 1)] -join "`t")
	$Path = Normalize-GitPath $RawPath
	if ((Test-SourcePath $Path) -eq $false) {
		continue
	}

	$DiffArgs = @("-C", $RepoTop, "diff", "--unified=0", "--no-ext-diff") + $ModeArgs + @("--", $RawPath)
	$PatchLines = Invoke-Git $DiffArgs
	$AddedLogicLines = 0
	$AddedCommentLines = 0
	$AddedKoreanCommentLines = 0

	foreach ($PatchLine in $PatchLines) {
		if ($PatchLine.StartsWith("+++") -or ($PatchLine.StartsWith("+") -eq $false)) {
			continue
		}

		$AddedText = $PatchLine.Substring(1)
		if ([string]::IsNullOrWhiteSpace($AddedText)) {
			continue
		}

		$Trimmed = $AddedText.TrimStart()
		if ($Trimmed -match "^(//|/\*|\*)") {
			$AddedCommentLines += 1
			if ($Trimmed -match "[\uAC00-\uD7A3]") {
				$AddedKoreanCommentLines += 1
			}
			continue
		}

		$AddedLogicLines += 1
	}

	$Checked = [pscustomobject]@{
		Path = $Path
		AddedLines = $AddedLines
		AddedLogicLines = $AddedLogicLines
		AddedCommentLines = $AddedCommentLines
		AddedKoreanCommentLines = $AddedKoreanCommentLines
	}
	$CheckedFiles.Add($Checked) | Out-Null

	# 큰 로직 변경인데 신규 주석이 없을 때만 검토 경고를 낸다.
	if ($AddedLogicLines -ge $MinAddedLogicLines -and $AddedCommentLines -eq 0) {
		$Warnings.Add([pscustomobject]@{
			Path = $Path
			AddedLines = $AddedLines
			AddedLogicLines = $AddedLogicLines
			AddedCommentLines = $AddedCommentLines
			Reason = "Large source diff has no added implementation comment lines; review whether Korean explanation comments are needed."
		}) | Out-Null
	}
}

$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$ReportDir = Join-Path $RepoTop ".agent-work\comment-policy-audit"
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
# 감사 결과는 대상 repo의 로컬 작업 영역 아래에 남긴다.
$MarkdownPath = Join-Path $ReportDir "$Timestamp-source-comment-policy-audit.md"
$JsonPath = Join-Path $ReportDir "$Timestamp-source-comment-policy-audit.json"

$Markdown = New-Object System.Collections.Generic.List[string]
$Markdown.Add("# Source Comment Policy Audit") | Out-Null
$Markdown.Add("") | Out-Null
$Markdown.Add("- Repo: ``$RepoTop``") | Out-Null
$Markdown.Add("- Mode: $DiffMode") | Out-Null
$Markdown.Add("- Min added logic lines: $MinAddedLogicLines") | Out-Null
$Markdown.Add("- Checked source files: $($CheckedFiles.Count)") | Out-Null
$Markdown.Add("- Warnings: $($Warnings.Count)") | Out-Null
$Markdown.Add("") | Out-Null

if ($Warnings.Count -gt 0) {
	$Markdown.Add("## Warnings") | Out-Null
	$Markdown.Add("") | Out-Null
	$Markdown.Add("| File | Added Lines | Added Logic Lines | Added Comment Lines | Reason |") | Out-Null
	$Markdown.Add("| --- | ---: | ---: | ---: | --- |") | Out-Null
	foreach ($Warning in $Warnings) {
		$Markdown.Add("| $(Escape-MarkdownTableValue $Warning.Path) | $($Warning.AddedLines) | $($Warning.AddedLogicLines) | $($Warning.AddedCommentLines) | $(Escape-MarkdownTableValue $Warning.Reason) |") | Out-Null
	}
	$Markdown.Add("") | Out-Null
}

if ($CheckedFiles.Count -gt 0) {
	$Markdown.Add("## Checked Files") | Out-Null
	$Markdown.Add("") | Out-Null
	$Markdown.Add("| File | Added Lines | Added Logic Lines | Added Comment Lines | Korean Comment Lines |") | Out-Null
	$Markdown.Add("| --- | ---: | ---: | ---: | ---: |") | Out-Null
	foreach ($Checked in $CheckedFiles) {
		$Markdown.Add("| $(Escape-MarkdownTableValue $Checked.Path) | $($Checked.AddedLines) | $($Checked.AddedLogicLines) | $($Checked.AddedCommentLines) | $($Checked.AddedKoreanCommentLines) |") | Out-Null
	}
}

$CheckedFileArray = $CheckedFiles.ToArray()
$WarningArray = $Warnings.ToArray()

$Report = [pscustomobject]@{
	RepoRoot = $RepoTop
	Mode = $DiffMode
	MinAddedLogicLines = $MinAddedLogicLines
	CheckedFiles = $CheckedFileArray
	Warnings = $WarningArray
	MarkdownPath = $MarkdownPath
	JsonPath = $JsonPath
}

Set-Content -LiteralPath $MarkdownPath -Value $Markdown -Encoding UTF8
Set-Content -LiteralPath $JsonPath -Value ($Report | ConvertTo-Json -Depth 6) -Encoding UTF8

if ($Quiet -eq $false) {
	Write-Output "Source comment policy audit: $($Warnings.Count) warning(s), $($CheckedFiles.Count) source file(s) checked."
	Write-Output "Report: $MarkdownPath"
	if ($Warnings.Count -gt 0) {
		foreach ($Warning in $Warnings) {
			Write-Output "WARNING: $($Warning.Path) - $($Warning.Reason)"
		}
	}
}

if ($FailOnWarning -and $Warnings.Count -gt 0) {
	exit 1
}

exit 0
