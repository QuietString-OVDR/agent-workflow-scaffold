#requires -Version 5.1

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
	[ValidateSet("Plan", "Verify", "Apply")]
	[string]$Mode = "Plan",

	[string]$WorkspaceRoot,

	[string[]]$Target,

	[string[]]$Profile,

	[switch]$AllDiscovered,

	[switch]$AllExistingWorktrees,

	[switch]$AllowDirtySource,

	[string]$ManifestPath,

	[string]$RunRoot,

	[switch]$NonInteractive
)

$ErrorActionPreference = "Stop"
if ($NonInteractive) {
	$ConfirmPreference = "None"
}
$script:PackageRoot = Split-Path -Parent $PSScriptRoot
$script:CommonBegin = "<!-- branch-docs-starter:begin -->"
$script:CommonEnd = "<!-- branch-docs-starter:end -->"
$script:Utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function ConvertTo-NativeArgument {
	param([AllowEmptyString()][string]$Value)

	if ($Value.Length -eq 0) {
		return '""'
	}
	if ($Value -notmatch '[\s"]') {
		return $Value
	}

	$builder = New-Object System.Text.StringBuilder
	[void]$builder.Append('"')
	$slashes = 0
	foreach ($character in $Value.ToCharArray()) {
		if ($character -eq '\') {
			$slashes++
			continue
		}
		if ($character -eq '"') {
			[void]$builder.Append(('\' * (($slashes * 2) + 1)))
			[void]$builder.Append('"')
			$slashes = 0
			continue
		}
		if ($slashes -gt 0) {
			[void]$builder.Append(('\' * $slashes))
			$slashes = 0
		}
		[void]$builder.Append($character)
	}
	if ($slashes -gt 0) {
		[void]$builder.Append(('\' * ($slashes * 2)))
	}
	[void]$builder.Append('"')
	return $builder.ToString()
}

function Invoke-NativeProcess {
	param(
		[Parameter(Mandatory = $true)][string]$FilePath,
		[Parameter(Mandatory = $true)][string[]]$ArgumentList,
		[string]$WorkingDirectory,
		[hashtable]$EnvironmentVariables
	)

	$startInfo = New-Object System.Diagnostics.ProcessStartInfo
	$startInfo.FileName = $FilePath
	$startInfo.Arguments = (($ArgumentList | ForEach-Object { ConvertTo-NativeArgument $_ }) -join " ")
	$startInfo.UseShellExecute = $false
	$startInfo.CreateNoWindow = $true
	$startInfo.RedirectStandardOutput = $true
	$startInfo.RedirectStandardError = $true
	if ($WorkingDirectory) {
		$startInfo.WorkingDirectory = $WorkingDirectory
	}
	foreach ($name in @($EnvironmentVariables.Keys)) {
		$startInfo.EnvironmentVariables[$name] = [string]$EnvironmentVariables[$name]
	}

	$process = New-Object System.Diagnostics.Process
	$process.StartInfo = $startInfo
	if (-not $process.Start()) {
		throw "Unable to start $FilePath."
	}
	$stdout = $process.StandardOutput.ReadToEnd()
	$stderr = $process.StandardError.ReadToEnd()
	$process.WaitForExit()
	$exitCode = $process.ExitCode
	$process.Dispose()

	return [pscustomobject]@{
		ExitCode = $exitCode
		StdOut = $stdout
		StdErr = $stderr
	}
}

function Invoke-Git {
	param(
		[string]$RepoRoot,
		[Parameter(Mandatory = $true)][string[]]$Arguments,
		[string]$GitDir
	)

	$gitArguments = @()
	if ($RepoRoot) {
		$gitArguments += @("-C", $RepoRoot)
	}
	if ($GitDir) {
		$gitArguments += "--git-dir=$GitDir"
	}
	$gitArguments += $Arguments
	return Invoke-NativeProcess -FilePath "git" -ArgumentList $gitArguments -EnvironmentVariables @{
		GIT_OPTIONAL_LOCKS = "0"
	}
}

function Get-NormalizedPath {
	param([Parameter(Mandatory = $true)][string]$Path)

	return [IO.Path]::GetFullPath($Path).TrimEnd('\', '/').ToLowerInvariant()
}

function Test-PathWithin {
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)][string]$Root
	)

	$normalizedPath = Get-NormalizedPath $Path
	$normalizedRoot = Get-NormalizedPath $Root
	return $normalizedPath -eq $normalizedRoot -or
		$normalizedPath.StartsWith($normalizedRoot + [IO.Path]::DirectorySeparatorChar)
}

function Get-Sha256Bytes {
	param([Parameter(Mandatory = $true)][byte[]]$Bytes)

	$sha = [Security.Cryptography.SHA256]::Create()
	try {
		return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace("-", "")
	}
	finally {
		$sha.Dispose()
	}
}

function Get-Sha256File {
	param([Parameter(Mandatory = $true)][string]$Path)

	return Get-Sha256Bytes ([IO.File]::ReadAllBytes($Path))
}

function Test-ByteOrderMark {
	param([Parameter(Mandatory = $true)][byte[]]$Bytes)

	if ($Bytes.Length -ge 4) {
		if (($Bytes[0] -eq 0x00 -and $Bytes[1] -eq 0x00 -and $Bytes[2] -eq 0xFE -and $Bytes[3] -eq 0xFF) -or
			($Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE -and $Bytes[2] -eq 0x00 -and $Bytes[3] -eq 0x00)) {
			return $true
		}
	}
	if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
		return $true
	}
	if ($Bytes.Length -ge 2 -and
		(($Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) -or
		($Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF))) {
		return $true
	}
	return $false
}

function Read-StrictUtf8File {
	param([Parameter(Mandatory = $true)][string]$Path)

	$bytes = [IO.File]::ReadAllBytes($Path)
	if (Test-ByteOrderMark $bytes) {
		throw "BOM-encoded files are unsupported: $Path"
	}
	try {
		$text = $script:Utf8Strict.GetString($bytes)
	}
	catch {
		throw "File is not valid BOM-free UTF-8: $Path"
	}
	if ($text.Contains([char]0)) {
		throw "NUL bytes are unsupported: $Path"
	}
	if ($text -match "`r(?!`n)") {
		throw "CR-only line endings are unsupported: $Path"
	}
	return [pscustomobject]@{
		Path = $Path
		Bytes = $bytes
		Text = $text
		Hash = Get-Sha256Bytes $bytes
	}
}

function Get-MarkerMatches {
	param(
		[Parameter(Mandatory = $true)][string]$Text,
		[Parameter(Mandatory = $true)][string]$Marker
	)

	$pattern = "(?m)^" + [regex]::Escape($Marker) + "(?=`r?$)"
	return @([regex]::Matches($Text, $pattern))
}

function Get-MarkerInterval {
	param(
		[Parameter(Mandatory = $true)][string]$Text,
		[Parameter(Mandatory = $true)][string]$Id,
		[Parameter(Mandatory = $true)][string]$Begin,
		[Parameter(Mandatory = $true)][string]$End
	)

	$beginMatches = Get-MarkerMatches -Text $Text -Marker $Begin
	$endMatches = Get-MarkerMatches -Text $Text -Marker $End
	if ($beginMatches.Count -eq 0 -and $endMatches.Count -eq 0) {
		return $null
	}
	if ($beginMatches.Count -ne 1 -or $endMatches.Count -ne 1) {
		throw "Block '$Id' must have exactly one begin marker and one end marker."
	}
	$beginMatch = $beginMatches[0]
	$endMatch = $endMatches[0]
	if ($endMatch.Index -le $beginMatch.Index) {
		throw "Block '$Id' has reversed markers."
	}
	return [pscustomobject]@{
		Id = $Id
		Begin = $Begin
		End = $End
		Start = $beginMatch.Index
		EndExclusive = $endMatch.Index + $endMatch.Length
		Text = $Text.Substring($beginMatch.Index, ($endMatch.Index + $endMatch.Length) - $beginMatch.Index)
	}
}

function Assert-NoOverlappingIntervals {
	param([object[]]$Intervals)

	$ordered = @($Intervals | Where-Object { $_ } | Sort-Object Start)
	for ($index = 1; $index -lt $ordered.Count; $index++) {
		if ($ordered[$index].Start -lt $ordered[$index - 1].EndExclusive) {
			throw "Managed blocks '$($ordered[$index - 1].Id)' and '$($ordered[$index].Id)' overlap or are nested."
		}
	}
}

function ConvertTo-Lf {
	param([Parameter(Mandatory = $true)][string]$Text)

	return $Text.Replace("`r`n", "`n")
}

function Get-BlockEol {
	param(
		[Parameter(Mandatory = $true)][string]$Text,
		[Parameter(Mandatory = $true)][int]$Offset
	)

	if ($Offset -gt 0) {
		$previousLf = $Text.LastIndexOf("`n", $Offset - 1)
		if ($previousLf -ge 1 -and $Text[$previousLf - 1] -eq "`r") {
			return "`r`n"
		}
		if ($previousLf -ge 0) {
			return "`n"
		}
	}
	$nextLf = $Text.IndexOf("`n", $Offset)
	if ($nextLf -ge 1 -and $Text[$nextLf - 1] -eq "`r") {
		return "`r`n"
	}
	if ($nextLf -ge 0) {
		return "`n"
	}
	return "`n"
}

function Convert-BlockEol {
	param(
		[Parameter(Mandatory = $true)][string]$Text,
		[Parameter(Mandatory = $true)][string]$Eol
	)

	return (ConvertTo-Lf $Text).Replace("`n", $Eol)
}

function Get-NormalizedRemoteId {
	param([Parameter(Mandatory = $true)][string]$RemoteUrl)

	$value = $RemoteUrl.Trim().Replace('\', '/')
	$remoteHost = $null
	$remotePath = $null
	if ($value -match '^[^@/]+@([^:]+):(.+)$') {
		$remoteHost = $Matches[1]
		$remotePath = $Matches[2]
	}
	else {
		$uri = $null
		if ([Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri) -and $uri.Host) {
			$remoteHost = $uri.Host
			$remotePath = $uri.AbsolutePath.TrimStart('/')
		}
	}
	if (-not $remoteHost -or -not $remotePath) {
		throw "Unsupported origin URL: $RemoteUrl"
	}
	if ($remotePath.EndsWith(".git", [StringComparison]::OrdinalIgnoreCase)) {
		$remotePath = $remotePath.Substring(0, $remotePath.Length - 4)
	}
	return ($remoteHost.TrimEnd('/') + "/" + $remotePath.Trim('/')).ToLowerInvariant()
}

function Get-Manifest {
	param([Parameter(Mandatory = $true)][string]$Path)

	$file = Read-StrictUtf8File $Path
	$manifest = $file.Text | ConvertFrom-Json
	if ($manifest.schemaVersion -ne 1) {
		throw "Unsupported manifest schemaVersion '$($manifest.schemaVersion)'."
	}
	Assert-Manifest -Manifest $manifest -Path $Path
	return $manifest
}

function Assert-Manifest {
	param(
		[Parameter(Mandatory = $true)]$Manifest,
		[Parameter(Mandatory = $true)][string]$Path
	)

	$knownBlocks = @($Manifest.knownBlocks)
	if ($knownBlocks.Count -eq 0) {
		throw "Manifest knownBlocks must not be empty: $Path"
	}
	$knownIds = @{}
	$knownMarkers = @{}
	foreach ($block in $knownBlocks) {
		$id = [string]$block.id
		$begin = [string]$block.begin
		$end = [string]$block.end
		if ([string]::IsNullOrWhiteSpace($id) -or
			[string]::IsNullOrWhiteSpace($begin) -or
			[string]::IsNullOrWhiteSpace($end)) {
			throw "Every manifest knownBlocks entry requires nonempty id, begin, and end values."
		}
		if ($id -notmatch '^[a-z0-9][a-z0-9-]*$') {
			throw "Manifest block id '$id' is invalid."
		}
		if ($begin -match "[`r`n]" -or $end -match "[`r`n]" -or
			$begin -notmatch '^<!-- .+ -->$' -or $end -notmatch '^<!-- .+ -->$' -or
			$begin -ceq $end) {
			throw "Manifest block '$id' has invalid marker lines."
		}
		if ($knownIds.ContainsKey($id)) {
			throw "Manifest block id '$id' is duplicated."
		}
		foreach ($marker in @($begin, $end)) {
			if ($knownMarkers.ContainsKey($marker)) {
				throw "Manifest marker '$marker' is duplicated."
			}
			$knownMarkers[$marker] = $true
		}
		$knownIds[$id] = $true
	}

	if (-not $Manifest.profiles) {
		throw "Manifest profiles must not be empty: $Path"
	}
	$profileProperties = @($Manifest.profiles.PSObject.Properties)
	if ($profileProperties.Count -eq 0) {
		throw "Manifest profiles must not be empty: $Path"
	}
	$profileSourceRoot = [IO.Path]::GetFullPath((Join-Path $script:PackageRoot "profiles"))
	$repositoryIds = @{}
	foreach ($profileProperty in $profileProperties) {
		$profileName = [string]$profileProperty.Name
		$profileConfig = $profileProperty.Value
		if ($profileName -notmatch '^[a-z0-9][a-z0-9-]*$') {
			throw "Manifest profile name '$profileName' is invalid."
		}

		$discovery = [string]$profileConfig.discovery
		if (@("direct-child", "direct-or-git-worktrees") -notcontains $discovery) {
			throw "Manifest profile '$profileName' has unsupported discovery '$discovery'."
		}
		$commonPolicy = [string]$profileConfig.commonPolicy
		if (@("standard", "standard-or-worktree-aware") -notcontains $commonPolicy) {
			throw "Manifest profile '$profileName' has unsupported commonPolicy '$commonPolicy'."
		}

		$repositoryId = [string]$profileConfig.repositoryId
		if ([string]::IsNullOrWhiteSpace($repositoryId) -or
			$repositoryId -cne $repositoryId.ToLowerInvariant() -or
			$repositoryId -notmatch '^[a-z0-9.-]+/[a-z0-9._/-]+$' -or
			$repositoryId.EndsWith(".git", [StringComparison]::OrdinalIgnoreCase) -or
			$repositoryId.Contains("..")) {
			throw "Manifest profile '$profileName' has invalid repositoryId '$repositoryId'."
		}
		if ($repositoryIds.ContainsKey($repositoryId)) {
			throw "Manifest repositoryId '$repositoryId' is used by more than one profile."
		}
		$repositoryIds[$repositoryId] = $true

		$sentinel = ([string]$profileConfig.sentinel).Replace('\', '/')
		if ([string]::IsNullOrWhiteSpace($sentinel) -or
			[IO.Path]::IsPathRooted($sentinel) -or
			$sentinel.Contains(":") -or
			$sentinel.Split('/') -contains "..") {
			throw "Manifest profile '$profileName' has invalid sentinel '$sentinel'."
		}

		if ($discovery -eq "direct-child") {
			$directoryPattern = [string]$profileConfig.directoryPattern
			if ([string]::IsNullOrWhiteSpace($directoryPattern) -or
				-not $directoryPattern.StartsWith("^", [StringComparison]::Ordinal) -or
				-not $directoryPattern.EndsWith("$", [StringComparison]::Ordinal)) {
				throw "Manifest profile '$profileName' requires an anchored directoryPattern."
			}
			try {
				[void](New-Object System.Text.RegularExpressions.Regex -ArgumentList $directoryPattern)
			}
			catch {
				throw "Manifest profile '$profileName' has invalid directoryPattern '$directoryPattern'."
			}
		}
		else {
			$directoryName = [string]$profileConfig.directoryName
			if ([string]::IsNullOrWhiteSpace($directoryName) -or
				$directoryName -ne [IO.Path]::GetFileName($directoryName) -or
				$directoryName -in @(".", "..")) {
				throw "Manifest profile '$profileName' requires a single directoryName."
			}
		}

		$blockReferences = @($profileConfig.blocks)
		if ($blockReferences.Count -eq 0) {
			throw "Manifest profile '$profileName' must reference at least one block."
		}
		$referencedIds = @{}
		foreach ($blockReference in $blockReferences) {
			$blockId = [string]$blockReference.id
			$source = [string]$blockReference.source
			if (-not $knownIds.ContainsKey($blockId)) {
				throw "Manifest profile '$profileName' references unknown block '$blockId'."
			}
			if ($referencedIds.ContainsKey($blockId)) {
				throw "Manifest profile '$profileName' references block '$blockId' more than once."
			}
			$referencedIds[$blockId] = $true
			if ([string]::IsNullOrWhiteSpace($source) -or [IO.Path]::IsPathRooted($source)) {
				throw "Manifest profile '$profileName' block '$blockId' has an invalid source path."
			}
			try {
				$sourcePath = [IO.Path]::GetFullPath((Join-Path $script:PackageRoot $source))
			}
			catch {
				throw "Manifest profile '$profileName' block '$blockId' has an invalid source path."
			}
			if (-not (Test-PathWithin -Path $sourcePath -Root $profileSourceRoot) -or
				(Get-NormalizedPath $sourcePath) -eq (Get-NormalizedPath $profileSourceRoot) -or
				[IO.Path]::GetExtension($sourcePath) -cne ".md" -or
				-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
				throw "Manifest profile '$profileName' block '$blockId' source must be an existing .md file under profiles."
			}
		}
	}

	$excludedNames = @($Manifest.excludedDirectoryNames)
	$seenExcludedNames = @{}
	foreach ($excludedNameValue in $excludedNames) {
		$excludedName = [string]$excludedNameValue
		if ([string]::IsNullOrWhiteSpace($excludedName) -or
			$excludedName -ne [IO.Path]::GetFileName($excludedName) -or
			$seenExcludedNames.ContainsKey($excludedName)) {
			throw "Manifest excludedDirectoryNames contains an invalid or duplicate entry '$excludedName'."
		}
		$seenExcludedNames[$excludedName] = $true
	}
	if (-not $seenExcludedNames.ContainsKey("client-app")) {
		throw "Manifest excludedDirectoryNames must include 'client-app'."
	}
}

function Get-ProfileProperty {
	param(
		[Parameter(Mandatory = $true)]$Manifest,
		[Parameter(Mandatory = $true)][string]$Name
	)

	$property = @($Manifest.profiles.PSObject.Properties | Where-Object { $_.Name -eq $Name })
	if ($property.Count -ne 1) {
		throw "Unknown profile '$Name'."
	}
	return $property[0].Value
}

function Get-KnownBlockProperty {
	param(
		[Parameter(Mandatory = $true)]$Manifest,
		[Parameter(Mandatory = $true)][string]$Id
	)

	$block = @($Manifest.knownBlocks | Where-Object { $_.id -eq $Id })
	if ($block.Count -ne 1) {
		throw "Manifest block '$Id' is missing or duplicated."
	}
	return $block[0]
}

function Get-CanonicalBlocks {
	param(
		[Parameter(Mandatory = $true)]$Manifest,
		[Parameter(Mandatory = $true)][string]$ProfileName
	)

	$profileConfig = Get-ProfileProperty -Manifest $Manifest -Name $ProfileName
	$result = @()
	foreach ($blockRef in $profileConfig.blocks) {
		$known = Get-KnownBlockProperty -Manifest $Manifest -Id $blockRef.id
		$sourcePath = Join-Path $script:PackageRoot $blockRef.source
		if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
			throw "Profile source is missing: $sourcePath"
		}
		$source = Read-StrictUtf8File $sourcePath
		$trimmed = $source.Text.TrimEnd("`r", "`n")
		$interval = Get-MarkerInterval -Text $trimmed -Id $known.id -Begin $known.begin -End $known.end
		if (-not $interval -or $interval.Start -ne 0 -or $interval.EndExclusive -ne $trimmed.Length) {
			throw "Profile source must contain only its marked block: $sourcePath"
		}
		$result += [pscustomobject]@{
			Id = [string]$known.id
			Begin = [string]$known.begin
			End = [string]$known.end
			SourcePath = $sourcePath
			Text = ConvertTo-Lf $trimmed
			Hash = Get-Sha256Bytes $script:Utf8NoBom.GetBytes((ConvertTo-Lf $trimmed))
		}
	}
	return $result
}

function Get-GitText {
	param(
		[Parameter(Mandatory = $true)][string]$Root,
		[Parameter(Mandatory = $true)][string[]]$Arguments,
		[string]$Description
	)

	$result = Invoke-Git -RepoRoot $Root -Arguments $Arguments
	if ($result.ExitCode -ne 0) {
		$message = if ($Description) { $Description } else { "git $($Arguments -join ' ')" }
		throw "$message failed in '$Root': $($result.StdErr.Trim())"
	}
	return $result.StdOut.TrimEnd("`r", "`n")
}

function Get-GitSourceVersion {
	$head = Get-GitText -Root $script:PackageRoot -Arguments @("rev-parse", "HEAD") -Description "Reading source HEAD"
	$status = Get-GitText -Root $script:PackageRoot -Arguments @("status", "--porcelain", "--untracked-files=normal") -Description "Reading source status"
	return [pscustomobject]@{
		Head = $head
		Dirty = [bool]$status
		Display = if ($status) { "$head+dirty" } else { $head }
	}
}

function Test-TargetIgnored {
	param(
		[Parameter(Mandatory = $true)][string]$Root,
		[Parameter(Mandatory = $true)][string]$RelativePath
	)

	$result = Invoke-Git -RepoRoot $Root -Arguments @("check-ignore", "-q", "--", $RelativePath)
	return $result.ExitCode -eq 0
}

function Test-TargetTracked {
	param(
		[Parameter(Mandatory = $true)][string]$Root,
		[Parameter(Mandatory = $true)][string]$RelativePath
	)

	$result = Invoke-Git -RepoRoot $Root -Arguments @("ls-files", "--error-unmatch", "--", $RelativePath)
	return $result.ExitCode -eq 0
}

function Test-IsLinkedWorktree {
	param([Parameter(Mandatory = $true)][string]$Root)

	$gitDir = Get-GitText -Root $Root -Arguments @("rev-parse", "--absolute-git-dir") -Description "Reading Git directory"
	$commonDir = Get-GitText -Root $Root -Arguments @("rev-parse", "--path-format=absolute", "--git-common-dir") -Description "Reading Git common directory"
	return (Get-NormalizedPath $gitDir) -ne (Get-NormalizedPath $commonDir)
}

function Get-RepositoryIdentity {
	param(
		[Parameter(Mandatory = $true)][string]$Root,
		[Parameter(Mandatory = $true)]$ProfileConfig
	)

	$topLevel = Get-GitText -Root $Root -Arguments @("rev-parse", "--show-toplevel") -Description "Reading Git top level"
	if ((Get-NormalizedPath $topLevel) -ne (Get-NormalizedPath $Root)) {
		throw "Target is not the exact Git working-tree root: $Root"
	}
	$inside = Get-GitText -Root $Root -Arguments @("rev-parse", "--is-inside-work-tree") -Description "Checking Git working tree"
	if ($inside -ne "true") {
		throw "Target is not a Git working tree: $Root"
	}
	$super = Get-GitText -Root $Root -Arguments @("rev-parse", "--show-superproject-working-tree") -Description "Checking superproject"
	if ($super) {
		throw "Nested repositories and submodules are not eligible targets: $Root"
	}
	$remote = Get-GitText -Root $Root -Arguments @("remote", "get-url", "origin") -Description "Reading origin"
	$remoteId = Get-NormalizedRemoteId $remote
	if ($remoteId -ne ([string]$ProfileConfig.repositoryId).ToLowerInvariant()) {
		throw "Origin '$remoteId' does not match expected '$($ProfileConfig.repositoryId)'."
	}
	$sentinel = [string]$ProfileConfig.sentinel
	$sentinelResult = Invoke-Git -RepoRoot $Root -Arguments @("ls-files", "--error-unmatch", "--", $sentinel)
	if ($sentinelResult.ExitCode -ne 0) {
		throw "Tracked sentinel '$sentinel' is missing."
	}
	return [pscustomobject]@{
		TopLevel = $topLevel
		RemoteId = $remoteId
		Sentinel = $sentinel
		LinkedWorktree = Test-IsLinkedWorktree $Root
	}
}

function Get-WorktreeEntries {
	param(
		[Parameter(Mandatory = $true)][string]$GitDir,
		[Parameter(Mandatory = $true)][string]$AllowedRoot
	)

	$result = Invoke-Git -GitDir $GitDir -Arguments @("worktree", "list", "--porcelain", "-z")
	if ($result.ExitCode -ne 0) {
		throw "Unable to list worktrees for '$GitDir': $($result.StdErr.Trim())"
	}
	$records = @()
	$current = $null
	foreach ($token in $result.StdOut.Split([char]0)) {
		if (-not $token) {
			continue
		}
		if ($token.StartsWith("worktree ")) {
			if ($current) {
				$records += [pscustomobject]$current
			}
			$current = [ordered]@{
				Path = $token.Substring(9)
				Bare = $false
				Locked = $false
				Prunable = $false
			}
			continue
		}
		if (-not $current) {
			continue
		}
		if ($token -eq "bare") {
			$current.Bare = $true
		}
		elseif ($token.StartsWith("locked")) {
			$current.Locked = $true
		}
		elseif ($token.StartsWith("prunable")) {
			$current.Prunable = $true
		}
	}
	if ($current) {
		$records += [pscustomobject]$current
	}

	$output = @()
	foreach ($record in $records) {
		if ($record.Bare) {
			continue
		}
		$path = [IO.Path]::GetFullPath($record.Path.Replace('/', '\'))
		$output += [pscustomobject]@{
			Path = $path
			Bare = $record.Bare
			Locked = $record.Locked
			Prunable = $record.Prunable
			Missing = -not (Test-Path -LiteralPath $path -PathType Container)
			OutsideAllowedRoot = -not (Test-PathWithin -Path $path -Root $AllowedRoot)
		}
	}
	return $output
}

function Get-DiscoveredTargets {
	param(
		[Parameter(Mandatory = $true)]$Manifest,
		[Parameter(Mandatory = $true)][string]$Root,
		[string[]]$ProfileNames
	)

	$workspaceItem = Get-Item -LiteralPath $Root -Force
	if (-not $workspaceItem.PSIsContainer) {
		throw "Workspace root is not a directory: $Root"
	}
	$excluded = @($Manifest.excludedDirectoryNames)
	$output = @()

	foreach ($profileName in $ProfileNames) {
		$config = Get-ProfileProperty -Manifest $Manifest -Name $profileName
		if ($config.discovery -eq "direct-child") {
			foreach ($directory in Get-ChildItem -LiteralPath $workspaceItem.FullName -Directory -Force) {
				if ($excluded -contains $directory.Name) {
					continue
				}
				if ($directory.Name -match $config.directoryPattern) {
					$output += [pscustomobject]@{
						Path = $directory.FullName
						Profile = $profileName
						DiscoveryIssue = $null
					}
				}
			}
			continue
		}

		if ($config.discovery -eq "direct-or-git-worktrees") {
			$container = Join-Path $workspaceItem.FullName $config.directoryName
			if (-not (Test-Path -LiteralPath $container -PathType Container)) {
				continue
			}
			$directProbe = Invoke-Git -RepoRoot $container -Arguments @("rev-parse", "--is-inside-work-tree")
			if ($directProbe.ExitCode -eq 0 -and $directProbe.StdOut.Trim() -eq "true") {
				$output += [pscustomobject]@{
					Path = [IO.Path]::GetFullPath($container)
					Profile = $profileName
					DiscoveryIssue = $null
				}
				continue
			}
			$bareProbe = Invoke-Git -GitDir $container -Arguments @("rev-parse", "--is-bare-repository")
			if ($bareProbe.ExitCode -ne 0 -or $bareProbe.StdOut.Trim() -ne "true") {
				$output += [pscustomobject]@{
					Path = [IO.Path]::GetFullPath($container)
					Profile = $profileName
					DiscoveryIssue = "Expected a working tree or bare Git worktree container."
				}
				continue
			}
			foreach ($entry in Get-WorktreeEntries -GitDir $container -AllowedRoot $container) {
				$issue = $null
				if ($entry.Locked) { $issue = "Registered worktree is locked." }
				elseif ($entry.Prunable) { $issue = "Registered worktree is prunable." }
				elseif ($entry.Missing) { $issue = "Registered worktree path is missing." }
				elseif ($entry.OutsideAllowedRoot) { $issue = "Registered worktree is outside the allowed container." }
				$output += [pscustomobject]@{
					Path = $entry.Path
					Profile = $profileName
					DiscoveryIssue = $issue
				}
			}
			continue
		}
		throw "Unsupported discovery mode '$($config.discovery)'."
	}

	$seen = @{}
	$deduplicated = @()
	foreach ($candidate in $output) {
		$key = (Get-NormalizedPath $candidate.Path) + "|" + $candidate.Profile
		if (-not $seen.ContainsKey($key)) {
			$seen[$key] = $true
			$deduplicated += $candidate
		}
	}
	return $deduplicated
}

function Get-TargetCandidates {
	param(
		[Parameter(Mandatory = $true)]$Manifest,
		[string]$Root
	)

	$profileNames = @()
	if ($Profile) {
		$profileNames += @($Profile)
	}
	else {
		$profileNames += @($Manifest.profiles.PSObject.Properties.Name)
	}
	if ($Target) {
		if ($profileNames.Count -ne 1) {
			throw "Explicit -Target requires exactly one -Profile."
		}
		return @($Target | ForEach-Object {
			[pscustomobject]@{
				Path = [IO.Path]::GetFullPath($_)
				Profile = $profileNames[0]
				DiscoveryIssue = $null
			}
		})
	}
	if (-not $Root) {
		throw "-WorkspaceRoot is required when -Target is not supplied."
	}
	$discovered = @(Get-DiscoveredTargets -Manifest $Manifest -Root $Root -ProfileNames $profileNames)
	if ($AllExistingWorktrees) {
		$discovered = @($discovered | Where-Object { $_.Profile -eq "client-build-tools" })
	}
	return $discovered
}

function Get-AllManagedIntervals {
	param(
		[Parameter(Mandatory = $true)][string]$Text,
		[Parameter(Mandatory = $true)]$Manifest
	)

	$intervals = @()
	foreach ($known in $Manifest.knownBlocks) {
		$interval = Get-MarkerInterval -Text $Text -Id $known.id -Begin $known.begin -End $known.end
		if ($interval) {
			$intervals += $interval
		}
	}
	$common = Get-MarkerInterval -Text $Text -Id "branch-docs-starter" -Begin $script:CommonBegin -End $script:CommonEnd
	if ($common) {
		$intervals += $common
	}

	$recognized = @()
	foreach ($known in $Manifest.knownBlocks) {
		$recognized += @([string]$known.begin, [string]$known.end)
	}
	$unknownMarkerPatterns = @(
		'(?m)^<!-- overdare-[a-z0-9-]+-guidance:(?:begin|end) -->(?=\r?$)',
		'(?m)^<!-- OVDR_[A-Z0-9_]+:(?:START|END) -->(?=\r?$)'
	)
	foreach ($pattern in $unknownMarkerPatterns) {
		foreach ($match in [regex]::Matches($Text, $pattern)) {
			if ($recognized -notcontains $match.Value) {
				throw "Unknown repository profile marker '$($match.Value)'."
			}
		}
	}
	Assert-NoOverlappingIntervals $intervals
	return $intervals
}

function Test-StandardCommonBlock {
	param([Parameter(Mandatory = $true)]$CommonInterval)

	$source = Read-StrictUtf8File (Join-Path $script:PackageRoot "AGENTS.branch-docs.md")
	$expected = (ConvertTo-Lf $source.Text).TrimEnd("`n")
	$actual = (ConvertTo-Lf $CommonInterval.Text).TrimEnd("`n")
	return $actual -ceq $expected
}

function Get-DesiredAgentsText {
	param(
		[Parameter(Mandatory = $true)][string]$OriginalText,
		[Parameter(Mandatory = $true)][object[]]$CanonicalBlocks,
		[Parameter(Mandatory = $true)]$Manifest
	)

	$text = $OriginalText
	[void](Get-AllManagedIntervals -Text $text -Manifest $Manifest)

	$knownExpectedIds = @($CanonicalBlocks.Id)
	foreach ($known in $Manifest.knownBlocks) {
		$interval = Get-MarkerInterval -Text $text -Id $known.id -Begin $known.begin -End $known.end
		if ($interval -and $knownExpectedIds -notcontains $known.id) {
			throw "Wrong profile block '$($known.id)' is already present."
		}
	}

	$present = @()
	foreach ($block in $CanonicalBlocks) {
		$interval = Get-MarkerInterval -Text $text -Id $block.Id -Begin $block.Begin -End $block.End
		if ($interval) {
			$present += [pscustomobject]@{ Block = $block; Interval = $interval }
		}
	}
	if ($present.Count -gt 1) {
		$actualOrder = @($present | Sort-Object { $_.Interval.Start } | ForEach-Object { $_.Block.Id })
		$expectedPresentOrder = @($CanonicalBlocks | Where-Object { $actualOrder -contains $_.Id } | ForEach-Object { $_.Id })
		if (($actualOrder -join "|") -cne ($expectedPresentOrder -join "|")) {
			throw "Existing managed profile blocks are out of canonical order."
		}
	}

	foreach ($entry in @($present | Sort-Object { $_.Interval.Start } -Descending)) {
		$eol = Get-BlockEol -Text $text -Offset $entry.Interval.Start
		$replacement = Convert-BlockEol -Text $entry.Block.Text -Eol $eol
		$text = $text.Remove(
			$entry.Interval.Start,
			$entry.Interval.EndExclusive - $entry.Interval.Start
		).Insert($entry.Interval.Start, $replacement)
	}

	foreach ($block in $CanonicalBlocks) {
		$current = Get-MarkerInterval -Text $text -Id $block.Id -Begin $block.Begin -End $block.End
		if ($current) {
			continue
		}
		$anchor = $null
		$blockIndex = [array]::IndexOf($CanonicalBlocks, $block)
		for ($nextIndex = $blockIndex + 1; $nextIndex -lt $CanonicalBlocks.Count; $nextIndex++) {
			$next = $CanonicalBlocks[$nextIndex]
			$nextInterval = Get-MarkerInterval -Text $text -Id $next.Id -Begin $next.Begin -End $next.End
			if ($nextInterval) {
				$anchor = $nextInterval.Start
				break
			}
		}
		if ($null -eq $anchor) {
			$common = Get-MarkerInterval -Text $text -Id "branch-docs-starter" -Begin $script:CommonBegin -End $script:CommonEnd
			if (-not $common) {
				throw "A structurally valid branch-docs common block is required before profile installation."
			}
			$anchor = $common.Start
		}
		$eol = Get-BlockEol -Text $text -Offset $anchor
		$rendered = Convert-BlockEol -Text $block.Text -Eol $eol
		$text = $text.Insert($anchor, $rendered + $eol + $eol)
	}

	$intervals = @()
	foreach ($block in $CanonicalBlocks) {
		$intervals += Get-MarkerInterval -Text $text -Id $block.Id -Begin $block.Begin -End $block.End
	}
	$commonInterval = Get-MarkerInterval -Text $text -Id "branch-docs-starter" -Begin $script:CommonBegin -End $script:CommonEnd
	$ordered = @($intervals | Sort-Object Start)
	if (($ordered.Id -join "|") -cne (($CanonicalBlocks.Id) -join "|")) {
		throw "Rendered profile blocks are not in canonical order."
	}
	if ($ordered[-1].EndExclusive -gt $commonInterval.Start) {
		throw "Rendered profile blocks must appear before the common branch-docs block."
	}
	return $text
}

function Get-TargetAssessment {
	param(
		[Parameter(Mandatory = $true)]$Manifest,
		[Parameter(Mandatory = $true)]$Candidate
	)

	$reasons = New-Object System.Collections.Generic.List[string]
	$root = [IO.Path]::GetFullPath($Candidate.Path)
	$profileName = [string]$Candidate.Profile
	$config = Get-ProfileProperty -Manifest $Manifest -Name $profileName
	$canonicalBlocks = @(Get-CanonicalBlocks -Manifest $Manifest -ProfileName $profileName)
	$identity = $null
	$agents = $null
	$claudeHash = $null
	$ignoreHash = $null
	$commonHash = $null
	$desiredText = $null

	if ($Candidate.DiscoveryIssue) {
		$reasons.Add([string]$Candidate.DiscoveryIssue)
	}
	if (-not (Test-Path -LiteralPath $root -PathType Container)) {
		$reasons.Add("Target directory does not exist.")
	}
	else {
		$item = Get-Item -LiteralPath $root -Force
		if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
			$reasons.Add("Target directory is a reparse point.")
		}
		try {
			$identity = Get-RepositoryIdentity -Root $root -ProfileConfig $config
		}
		catch {
			$reasons.Add($_.Exception.Message)
		}
	}

	$agentsPath = Join-Path $root "AGENTS.md"
	if (-not (Test-Path -LiteralPath $agentsPath -PathType Leaf)) {
		$reasons.Add("Root AGENTS.md is missing; install the appropriate common scaffold first.")
	}
	else {
		$item = Get-Item -LiteralPath $agentsPath -Force
		if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
			$reasons.Add("AGENTS.md is a reparse point.")
		}
		if (($item.Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0) {
			$reasons.Add("AGENTS.md is read-only.")
		}
		if (Test-TargetTracked -Root $root -RelativePath "AGENTS.md") {
			$reasons.Add("AGENTS.md is tracked by Git.")
		}
		if (-not (Test-TargetIgnored -Root $root -RelativePath "AGENTS.md")) {
			$reasons.Add("AGENTS.md is not ignored by Git.")
		}
		try {
			$agents = Read-StrictUtf8File $agentsPath
			$intervals = @(Get-AllManagedIntervals -Text $agents.Text -Manifest $Manifest)
			$common = @($intervals | Where-Object { $_.Id -eq "branch-docs-starter" })
			if ($common.Count -ne 1) {
				$reasons.Add("Exactly one structurally valid branch-docs common block is required.")
			}
			else {
				$commonHash = Get-Sha256Bytes $script:Utf8NoBom.GetBytes($common[0].Text)
				if ($config.commonPolicy -eq "standard" -and -not (Test-StandardCommonBlock $common[0])) {
					$reasons.Add("The standard common branch-docs block does not match this branch.")
				}
				if ($config.commonPolicy -eq "standard-or-worktree-aware" -and $identity) {
					if ($identity.LinkedWorktree -and
						$common[0].Text -notmatch '(?m)^## Orca Worktree Safety\r?$') {
						$reasons.Add("Linked client-build-tools worktrees require the worktree-aware common scaffold.")
					}
					elseif (-not $identity.LinkedWorktree -and -not (Test-StandardCommonBlock $common[0])) {
						$reasons.Add("Direct client-build-tools clones require the standard common branch-docs block.")
					}
				}
			}
			$desiredText = Get-DesiredAgentsText -OriginalText $agents.Text -CanonicalBlocks $canonicalBlocks -Manifest $Manifest
		}
		catch {
			$reasons.Add($_.Exception.Message)
		}
	}

	$claudePath = Join-Path $root "CLAUDE.md"
	if (-not (Test-Path -LiteralPath $claudePath -PathType Leaf)) {
		$reasons.Add("CLAUDE.md is missing; install the appropriate common scaffold first.")
	}
	else {
		$claudeItem = Get-Item -LiteralPath $claudePath -Force
		if (($claudeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
			$reasons.Add("CLAUDE.md is a reparse point.")
		}
		try {
			$claude = Read-StrictUtf8File $claudePath
			$claudeHash = $claude.Hash
			if ($claude.Text -notmatch '(?m)^@AGENTS\.md\r?$') {
				$reasons.Add("CLAUDE.md does not import @AGENTS.md.")
			}
		}
		catch {
			$reasons.Add($_.Exception.Message)
		}
	}

	$ignorePath = Join-Path $root ".gitignore"
	if (Test-Path -LiteralPath $ignorePath -PathType Leaf) {
		$ignoreHash = Get-Sha256File $ignorePath
	}

	$agentWorkPath = Join-Path $root ".agent-work"
	if (-not (Test-Path -LiteralPath $agentWorkPath -PathType Container)) {
		$reasons.Add(".agent-work is missing; install the appropriate common scaffold first.")
	}
	else {
		$agentWorkItem = Get-Item -LiteralPath $agentWorkPath -Force
		if (($agentWorkItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
			$reasons.Add(".agent-work is a reparse point.")
		}
		elseif ([IO.Path]::GetPathRoot($agentWorkPath) -cne [IO.Path]::GetPathRoot($agentsPath)) {
			$reasons.Add(".agent-work is not on the same volume as AGENTS.md.")
		}
		elseif (-not (Test-TargetIgnored -Root $root -RelativePath ".agent-work/repo-agent-config-probe")) {
			$reasons.Add(".agent-work scratch files are not ignored by Git.")
		}
	}

	$status = $null
	try {
		$status = Get-GitText -Root $root -Arguments @("status", "--porcelain=v2", "--branch") -Description "Reading target status"
	}
	catch {
		$reasons.Add($_.Exception.Message)
	}

	$state = "Blocked"
	$desiredHash = $null
	if ($reasons.Count -eq 0 -and $agents -and $null -ne $desiredText) {
		$desiredBytes = $script:Utf8NoBom.GetBytes($desiredText)
		$desiredHash = Get-Sha256Bytes $desiredBytes
		$state = if ($desiredHash -eq $agents.Hash) { "Compliant" } else { "Drift" }
	}

	return [pscustomobject]@{
		Path = $root
		Profile = $profileName
		State = $state
		Reasons = @($reasons)
		Identity = $identity
		AgentsPath = $agentsPath
		OriginalBytes = if ($agents) { $agents.Bytes } else { $null }
		OriginalHash = if ($agents) { $agents.Hash } else { $null }
		OriginalAttributes = if (Test-Path -LiteralPath $agentsPath) { [IO.File]::GetAttributes($agentsPath) } else { $null }
		DesiredText = $desiredText
		DesiredBytes = if ($null -ne $desiredText) { $script:Utf8NoBom.GetBytes($desiredText) } else { $null }
		DesiredHash = $desiredHash
		CommonHash = $commonHash
		ClaudeHash = $claudeHash
		IgnoreHash = $ignoreHash
		GitStatus = $status
	}
}

function Write-RunManifest {
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)]$Value
	)

	$json = $Value | ConvertTo-Json -Depth 8
	[IO.File]::WriteAllText($Path, $json + "`n", $script:Utf8NoBom)
}

function Acquire-TargetLocks {
	param([Parameter(Mandatory = $true)][object[]]$Assessments)

	$locks = @()
	try {
		foreach ($assessment in @($Assessments | Sort-Object Path)) {
			$lockPath = Join-Path $assessment.Path ".agent-work\repo-agent-config.lock"
			$stream = New-Object IO.FileStream(
				$lockPath,
				[IO.FileMode]::CreateNew,
				[IO.FileAccess]::Write,
				[IO.FileShare]::None
			)
			$locks += [pscustomobject]@{
				Path = $lockPath
				Stream = $stream
			}
		}
		return $locks
	}
	catch {
		foreach ($lock in $locks) {
			$lock.Stream.Dispose()
			Remove-Item -LiteralPath $lock.Path -Force -ErrorAction SilentlyContinue
		}
		throw
	}
}

function Release-TargetLocks {
	param([object[]]$Locks)

	foreach ($lock in @($Locks)) {
		try { $lock.Stream.Dispose() } catch {}
		Remove-Item -LiteralPath $lock.Path -Force -ErrorAction SilentlyContinue
	}
}

function Replace-FileAtomically {
	param(
		[Parameter(Mandatory = $true)][string]$TargetPath,
		[Parameter(Mandatory = $true)][byte[]]$Bytes,
		[Parameter(Mandatory = $true)][IO.FileAttributes]$Attributes
	)

	$targetRoot = Split-Path -Parent $TargetPath
	$tempRoot = Join-Path $targetRoot ".agent-work"
	$tempPath = Join-Path $tempRoot ("repo-agent-config-" + [Guid]::NewGuid().ToString("N") + ".tmp")
	$replaceBackupPath = Join-Path $tempRoot ("repo-agent-config-" + [Guid]::NewGuid().ToString("N") + ".replace-backup")
	try {
		[IO.File]::WriteAllBytes($tempPath, $Bytes)
		if ((Get-Sha256File $tempPath) -ne (Get-Sha256Bytes $Bytes)) {
			throw "Staged AGENTS.md hash verification failed."
		}
		[IO.File]::SetAttributes($tempPath, $Attributes)
		[IO.File]::Replace($tempPath, $TargetPath, $replaceBackupPath)
	}
	finally {
		if (Test-Path -LiteralPath $tempPath) {
			Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
		}
		if (Test-Path -LiteralPath $replaceBackupPath) {
			Remove-Item -LiteralPath $replaceBackupPath -Force -ErrorAction SilentlyContinue
		}
	}
}

function Restore-ChangedTargets {
	param([Parameter(Mandatory = $true)][object[]]$Changed)

	$unsafe = @()
	foreach ($assessment in @($Changed | Sort-Object Path -Descending)) {
		$currentHash = if (Test-Path -LiteralPath $assessment.AgentsPath) { Get-Sha256File $assessment.AgentsPath } else { $null }
		if ($currentHash -ne $assessment.DesiredHash) {
			$unsafe += $assessment.Path
			continue
		}
		Replace-FileAtomically -TargetPath $assessment.AgentsPath -Bytes $assessment.OriginalBytes -Attributes $assessment.OriginalAttributes
	}
	if ($unsafe.Count -gt 0) {
		throw "Automatic rollback was unsafe for: $($unsafe -join ', ')"
	}
}

function Apply-Assessments {
	param(
		[Parameter(Mandatory = $true)][object[]]$Assessments,
		[Parameter(Mandatory = $true)]$SourceVersion
	)

	if ($SourceVersion.Dirty -and -not $AllowDirtySource) {
		throw "Canonical source worktree is dirty. Commit/stash it or pass -AllowDirtySource explicitly."
	}
	$blocked = @($Assessments | Where-Object { $_.State -eq "Blocked" })
	if ($blocked.Count -gt 0) {
		throw "Apply preflight failed for: $($blocked.Path -join ', ')"
	}
	$drifted = @($Assessments | Where-Object { $_.State -eq "Drift" })
	if ($drifted.Count -eq 0) {
		return @()
	}

	$approved = @()
	foreach ($assessment in $drifted) {
		if ($PSCmdlet.ShouldProcess($assessment.Path, "Apply '$($assessment.Profile)' AGENTS profile")) {
			$approved += $assessment
		}
	}
	if ($approved.Count -eq 0) {
		return @()
	}

	$locks = @()
	$changed = @()
	$runRoot = $null
	try {
		$locks = @(Acquire-TargetLocks $approved)
		foreach ($assessment in $approved) {
			if ((Get-Sha256File $assessment.AgentsPath) -ne $assessment.OriginalHash) {
				throw "AGENTS.md changed after preflight: $($assessment.Path)"
			}
		}

		$runId = (Get-Date -Format "yyyyMMdd-HHmmss") + "-" + [Guid]::NewGuid().ToString("N")
		if ($RunRoot) {
			$runRoot = Join-Path ([IO.Path]::GetFullPath($RunRoot)) $runId
		}
		else {
			$runRoot = Join-Path $script:PackageRoot ".agent-work\repo-agent-config\runs\$runId"
		}
		New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
		$manifestTargets = @()
		foreach ($assessment in $approved) {
			$backupName = ($assessment.Profile + "-" + (Split-Path -Leaf $assessment.Path) + "-" + [Guid]::NewGuid().ToString("N") + ".AGENTS.md.bin")
			$backupPath = Join-Path $runRoot $backupName
			[IO.File]::WriteAllBytes($backupPath, $assessment.OriginalBytes)
			$manifestTargets += [pscustomobject]@{
				Path = $assessment.Path
				Profile = $assessment.Profile
				OriginalHash = $assessment.OriginalHash
				DesiredHash = $assessment.DesiredHash
				Backup = $backupPath
			}
		}
		Write-RunManifest -Path (Join-Path $runRoot "run.json") -Value ([pscustomobject]@{
			Source = $SourceVersion.Display
			StartedAt = (Get-Date).ToString("o")
			Targets = $manifestTargets
		})

		foreach ($assessment in $approved) {
			Replace-FileAtomically -TargetPath $assessment.AgentsPath -Bytes $assessment.DesiredBytes -Attributes $assessment.OriginalAttributes
			$changed += $assessment
			if ((Get-Sha256File $assessment.AgentsPath) -ne $assessment.DesiredHash) {
				throw "Post-write AGENTS.md hash verification failed: $($assessment.Path)"
			}
			$post = Read-StrictUtf8File $assessment.AgentsPath
			$common = Get-MarkerInterval -Text $post.Text -Id "branch-docs-starter" -Begin $script:CommonBegin -End $script:CommonEnd
			$postCommonHash = Get-Sha256Bytes $script:Utf8NoBom.GetBytes($common.Text)
			if ($postCommonHash -ne $assessment.CommonHash) {
				throw "Externally owned common block changed: $($assessment.Path)"
			}
			$claudePath = Join-Path $assessment.Path "CLAUDE.md"
			if ((Get-Sha256File $claudePath) -ne $assessment.ClaudeHash) {
				throw "CLAUDE.md changed unexpectedly: $($assessment.Path)"
			}
			$ignorePath = Join-Path $assessment.Path ".gitignore"
			if ($assessment.IgnoreHash -and (Get-Sha256File $ignorePath) -ne $assessment.IgnoreHash) {
				throw ".gitignore changed unexpectedly: $($assessment.Path)"
			}
		}
		return $changed
	}
	catch {
		$originalError = $_
		if ($changed.Count -gt 0) {
			try {
				Restore-ChangedTargets $changed
			}
			catch {
				throw "$($originalError.Exception.Message) Rollback also failed: $($_.Exception.Message)"
			}
		}
		throw $originalError
	}
	finally {
		Release-TargetLocks $locks
	}
}

function Write-AssessmentTable {
	param(
		[Parameter(Mandatory = $true)][object[]]$Assessments,
		[Parameter(Mandatory = $true)]$SourceVersion
	)

	"Source: $($SourceVersion.Display)"
	foreach ($assessment in $Assessments) {
		$reason = $assessment.Reasons -join " | "
		"$($assessment.State)`t$($assessment.Profile)`t$($assessment.Path)$(if ($reason) { "`t$reason" })"
	}
}

try {
	if (-not $ManifestPath) {
		$ManifestPath = Join-Path $script:PackageRoot "config\repo-agent-profiles.json"
	}
	$ManifestPath = [IO.Path]::GetFullPath($ManifestPath)
	$manifest = Get-Manifest $ManifestPath
	$sourceVersion = Get-GitSourceVersion
	$manifestProfileNames = @($manifest.profiles.PSObject.Properties.Name)
	foreach ($profileName in @($Profile)) {
		if ($manifestProfileNames -notcontains $profileName) {
			throw "Unknown profile '$profileName'. Available profiles: $($manifestProfileNames -join ', ')."
		}
	}

	if ($Mode -eq "Apply" -and -not $Target -and -not $AllDiscovered -and -not $AllExistingWorktrees) {
		throw "Apply requires explicit -Target, -AllDiscovered, or -AllExistingWorktrees authorization."
	}
	if ($Target -and ($AllDiscovered -or $AllExistingWorktrees)) {
		throw "-Target cannot be combined with -AllDiscovered or -AllExistingWorktrees."
	}
	if ($Target -and $WorkspaceRoot) {
		throw "-Target cannot be combined with -WorkspaceRoot."
	}
	if ($AllDiscovered -and $AllExistingWorktrees) {
		throw "-AllDiscovered and -AllExistingWorktrees are mutually exclusive."
	}
	if ($AllExistingWorktrees -and $Profile -and (@($Profile | Where-Object { $_ -ne "client-build-tools" }).Count -gt 0)) {
		throw "-AllExistingWorktrees only supports the client-build-tools profile."
	}

	$candidates = @(Get-TargetCandidates -Manifest $manifest -Root $WorkspaceRoot)
	if ($candidates.Count -eq 0) {
		throw "No target repositories were selected or discovered."
	}
	$assessments = @()
	foreach ($candidate in $candidates) {
		try {
			$assessments += Get-TargetAssessment -Manifest $manifest -Candidate $candidate
		}
		catch {
			$assessments += [pscustomobject]@{
				Path = $candidate.Path
				Profile = $candidate.Profile
				State = "Blocked"
				Reasons = @($_.Exception.Message)
			}
		}
	}

	Write-AssessmentTable -Assessments $assessments -SourceVersion $sourceVersion

	if ($Mode -eq "Apply") {
		$changed = @(Apply-Assessments -Assessments $assessments -SourceVersion $sourceVersion)
		if ($changed.Count -gt 0) {
			"Applied profiles to $($changed.Count) target(s)."
		}
		else {
			"No target files were changed."
		}
	}
	elseif ($Mode -eq "Verify") {
		$notCompliant = @($assessments | Where-Object { $_.State -ne "Compliant" })
		if ($notCompliant.Count -gt 0) {
			exit 2
		}
	}
	exit 0
}
catch {
	Write-Error $_.Exception.Message
	exit 1
}
