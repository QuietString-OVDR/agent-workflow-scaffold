#requires -Version 5.1

$ErrorActionPreference = "Stop"
$packageRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$tool = Join-Path $packageRoot "tools\repo-agent-config.ps1"
$powershell = (Get-Process -Id $PID).Path
$smokeParent = Join-Path $packageRoot ".agent-work\repo-agent-config\smoke"
$smokeRoot = Join-Path $smokeParent ([Guid]::NewGuid().ToString("N"))
$failures = 0

function Check {
	param(
		[Parameter(Mandatory = $true)][string]$Name,
		[Parameter(Mandatory = $true)][bool]$Condition,
		[string]$Detail
	)

	if ($Condition) {
		"PASS  $Name"
	}
	else {
		$script:failures++
		"FAIL  $Name$(if ($Detail) { ": $Detail" })"
	}
}

function Invoke-GitFixture {
	param(
		[Parameter(Mandatory = $true)][string]$Root,
		[Parameter(Mandatory = $true)][string[]]$Arguments
	)

	$previousErrorActionPreference = $ErrorActionPreference
	try {
		$ErrorActionPreference = "Continue"
		$output = & git -c core.autocrlf=false -C $Root @Arguments 2>&1
		$exitCode = $LASTEXITCODE
	}
	finally {
		$ErrorActionPreference = $previousErrorActionPreference
	}
	if ($exitCode -ne 0) {
		throw "git $($Arguments -join ' ') failed in ${Root}: $($output -join [Environment]::NewLine)"
	}
	return ($output -join [Environment]::NewLine)
}

function Write-Utf8 {
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
		[switch]$Bom
	)

	$parent = Split-Path -Parent $Path
	if ($parent -and -not (Test-Path -LiteralPath $parent)) {
		New-Item -ItemType Directory -Path $parent -Force | Out-Null
	}
	$encoding = New-Object System.Text.UTF8Encoding($Bom.IsPresent)
	[IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Get-Hash {
	param([Parameter(Mandatory = $true)][string]$Path)

	return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-CommonBlock {
	param([switch]$WorktreeAware)

	$text = [IO.File]::ReadAllText((Join-Path $packageRoot "AGENTS.branch-docs.md")).TrimEnd("`r", "`n")
	if ($WorktreeAware) {
		$addition = @"
## Orca Worktree Safety
- This fixture represents a worktree-aware common block owned by another branch.

"@
		$text = $text.Replace("## Code Lookup Bootstrap", $addition + "## Code Lookup Bootstrap")
	}
	return $text
}

function Initialize-LocalSetup {
	param(
		[Parameter(Mandatory = $true)][string]$Root,
		[switch]$WorktreeAware,
		[switch]$BomAgents,
		[string]$AdditionalAgentsText
	)

	$common = Get-CommonBlock -WorktreeAware:$WorktreeAware
	$agents = "# Repository Guidelines`n`n"
	if ($AdditionalAgentsText) {
		$agents += $AdditionalAgentsText.TrimEnd("`r", "`n") + "`n`n"
	}
	$agents += $common + "`n"
	Write-Utf8 -Path (Join-Path $Root "AGENTS.md") -Text $agents -Bom:$BomAgents

	$claudeBlock = [IO.File]::ReadAllText((Join-Path $packageRoot "CLAUDE.branch-docs.md")).TrimEnd("`r", "`n")
	Write-Utf8 -Path (Join-Path $Root "CLAUDE.md") -Text ("# Claude Code Instructions`n`n" + $claudeBlock + "`n")

	$agentWork = Join-Path $Root ".agent-work"
	New-Item -ItemType Directory -Path $agentWork -Force | Out-Null
}

function New-FixtureRepo {
	param(
		[Parameter(Mandatory = $true)][string]$Name,
		[Parameter(Mandatory = $true)][ValidateSet("client", "sandbox", "client-build-tools")][string]$Profile,
		[switch]$WorktreeAware,
		[switch]$BomAgents,
		[string]$AdditionalAgentsText
	)

	$root = Join-Path $smokeRoot $Name
	New-Item -ItemType Directory -Path $root -Force | Out-Null
	& git init -q $root
	if ($LASTEXITCODE -ne 0) { throw "git init failed: $root" }

	$sentinel = $null
	$origin = $null
	switch ($Profile) {
		"client" {
			$sentinel = "Meta/Meta.uproject"
			$origin = "git@github.krafton.com:sbx/client.git"
		}
		"sandbox" {
			$sentinel = "Sandbox/Sandbox.uproject"
			$origin = "git@github.krafton.com:sbx/sandbox.git"
		}
		"client-build-tools" {
			$sentinel = "projectbuildtool.sln"
			$origin = "git@github.krafton.com:sbx/client-build-tools.git"
		}
	}

	Write-Utf8 -Path (Join-Path $root $sentinel) -Text "fixture`n"
	$ignore = @"
/AGENTS.md
/CLAUDE.md
/.agent-work/
"@
	Write-Utf8 -Path (Join-Path $root ".gitignore") -Text $ignore
	Invoke-GitFixture -Root $root -Arguments @("remote", "add", "origin", $origin) | Out-Null
	Invoke-GitFixture -Root $root -Arguments @("add", "--", ".gitignore", $sentinel) | Out-Null
	Invoke-GitFixture -Root $root -Arguments @(
		"-c", "user.name=Repo Agent Config Tests",
		"-c", "user.email=repo-agent-config@example.invalid",
		"commit", "-q", "-m", "fixture"
	) | Out-Null

	Initialize-LocalSetup -Root $root -WorktreeAware:$WorktreeAware -BomAgents:$BomAgents -AdditionalAgentsText $AdditionalAgentsText
	return $root
}

function Invoke-ProfileTool {
	param(
		[Parameter(Mandatory = $true)][string[]]$Arguments,
		[string]$ToolPath = $tool
	)

	$commandArguments = @(
		"-NoProfile",
		"-ExecutionPolicy", "Bypass",
		"-File", $ToolPath
	) + @($Arguments | ForEach-Object {
		if ($_ -ceq '-Confirm:$false') { "-NonInteractive" } else { $_ }
	})
	$previousErrorActionPreference = $ErrorActionPreference
	try {
		$ErrorActionPreference = "Continue"
		$output = & $powershell @commandArguments 2>&1
		$exitCode = $LASTEXITCODE
	}
	finally {
		$ErrorActionPreference = $previousErrorActionPreference
	}
	return [pscustomobject]@{
		ExitCode = $exitCode
		Output = ($output -join [Environment]::NewLine)
	}
}

function New-DirtySourcePackage {
	$root = Join-Path $smokeRoot "dirty-source-package"
	New-Item -ItemType Directory -Path (Join-Path $root "tools") -Force | Out-Null
	New-Item -ItemType Directory -Path (Join-Path $root "config") -Force | Out-Null
	Copy-Item -LiteralPath (Join-Path $packageRoot "tools\repo-agent-config.ps1") -Destination (Join-Path $root "tools\repo-agent-config.ps1")
	Copy-Item -LiteralPath (Join-Path $packageRoot "config\repo-agent-profiles.json") -Destination (Join-Path $root "config\repo-agent-profiles.json")
	Copy-Item -LiteralPath (Join-Path $packageRoot "profiles") -Destination $root -Recurse
	Copy-Item -LiteralPath (Join-Path $packageRoot "AGENTS.branch-docs.md") -Destination (Join-Path $root "AGENTS.branch-docs.md")
	Write-Utf8 -Path (Join-Path $root "source-state.txt") -Text "clean`n"

	& git init -q $root
	if ($LASTEXITCODE -ne 0) { throw "git init failed: $root" }
	Invoke-GitFixture -Root $root -Arguments @("add", "--", ".") | Out-Null
	Invoke-GitFixture -Root $root -Arguments @(
		"-c", "user.name=Repo Agent Config Tests",
		"-c", "user.email=repo-agent-config@example.invalid",
		"commit", "-q", "-m", "controlled source"
	) | Out-Null
	Write-Utf8 -Path (Join-Path $root "source-state.txt") -Text "dirty`n"
	return (Join-Path $root "tools\repo-agent-config.ps1")
}

function Assert-BlockBeforeCommon {
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)][string]$Marker
	)

	$text = [IO.File]::ReadAllText($Path)
	return $text.IndexOf($Marker, [StringComparison]::Ordinal) -ge 0 -and
		$text.IndexOf($Marker, [StringComparison]::Ordinal) -lt
		$text.IndexOf("<!-- branch-docs-starter:begin -->", [StringComparison]::Ordinal)
}

function Remove-SmokeRoot {
	$resolvedParent = [IO.Path]::GetFullPath($smokeParent).TrimEnd('\')
	$resolvedRoot = [IO.Path]::GetFullPath($smokeRoot).TrimEnd('\')
	if (-not $resolvedRoot.StartsWith($resolvedParent + "\", [StringComparison]::OrdinalIgnoreCase)) {
		throw "Refusing to remove smoke path outside its task root: $resolvedRoot"
	}
	if (Test-Path -LiteralPath $resolvedRoot) {
		Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
	}
}

try {
	New-Item -ItemType Directory -Path $smokeRoot -Force | Out-Null
	$runRoot = Join-Path $smokeRoot "runs"

	"=== Client profile apply and idempotency ==="
	$client = New-FixtureRepo -Name "client1" -Profile client
	$agentsPath = Join-Path $client "AGENTS.md"
	$claudePath = Join-Path $client "CLAUDE.md"
	$ignorePath = Join-Path $client ".gitignore"
	$commonBefore = Get-Hash $agentsPath
	$claudeBefore = Get-Hash $claudePath
	$ignoreBefore = Get-Hash $ignorePath
	$agentsAttributesBefore = (Get-Item -LiteralPath $agentsPath -Force).Attributes
	$indexReportedPath = Invoke-GitFixture -Root $client -Arguments @("rev-parse", "--git-path", "index")
	$indexPath = if ([IO.Path]::IsPathRooted($indexReportedPath)) {
		[IO.Path]::GetFullPath($indexReportedPath)
	}
	else {
		[IO.Path]::GetFullPath((Join-Path $client $indexReportedPath))
	}
	$indexBefore = Get-Hash $indexPath

	$plan = Invoke-ProfileTool @("-Mode", "Plan", "-Target", $client, "-Profile", "client")
	Check "Plan reports drift" ($plan.ExitCode -eq 0 -and $plan.Output -match "Drift") $plan.Output
	Check "Plan is read-only" ((Get-Hash $agentsPath) -eq $commonBefore)
	Check "Plan preserves Git index bytes" ((Get-Hash $indexPath) -eq $indexBefore)
	$driftVerify = Invoke-ProfileTool @("-Mode", "Verify", "-Target", $client, "-Profile", "client")
	Check "Verify returns drift exit code" ($driftVerify.ExitCode -eq 2 -and $driftVerify.Output -match "Drift") $driftVerify.Output
	Check "Verify is read-only" ((Get-Hash $agentsPath) -eq $commonBefore)
	Check "Verify preserves Git index bytes" ((Get-Hash $indexPath) -eq $indexBefore)
	$dirtySourceTool = New-DirtySourcePackage
	$dirtySourceApply = Invoke-ProfileTool -ToolPath $dirtySourceTool -Arguments @(
		"-Mode", "Apply",
		"-Target", $client,
		"-Profile", "client",
		"-RunRoot", $runRoot,
		'-Confirm:$false'
	)
	Check "Dirty canonical source blocks Apply by default" (
		$dirtySourceApply.ExitCode -ne 0 -and
		$dirtySourceApply.Output -match "Canonical source worktree is dirty"
	) $dirtySourceApply.Output
	Check "Dirty-source refusal leaves target unchanged" ((Get-Hash $agentsPath) -eq $commonBefore)

	$apply = Invoke-ProfileTool @(
		"-Mode", "Apply",
		"-Target", $client,
		"-Profile", "client",
		"-AllowDirtySource",
		"-RunRoot", $runRoot,
		'-Confirm:$false'
	)
	Check "Client Apply succeeds" ($apply.ExitCode -eq 0) $apply.Output
	Check "Clean-build guard precedes common block" (Assert-BlockBeforeCommon $agentsPath "<!-- OVDR_UNREAL_CLEAN_BUILD_GUARD:START -->")
	Check "Client profile precedes common block" (Assert-BlockBeforeCommon $agentsPath "<!-- overdare-client-guidance:begin -->")
	Check "Guard appears exactly once" (([regex]::Matches([IO.File]::ReadAllText($agentsPath), "<!-- OVDR_UNREAL_CLEAN_BUILD_GUARD:START -->")).Count -eq 1)
	Check "Client profile appears exactly once" (([regex]::Matches([IO.File]::ReadAllText($agentsPath), "<!-- overdare-client-guidance:begin -->")).Count -eq 1)
	Check "Client profile requires clone-specific Uproject" (
		[IO.File]::ReadAllText($agentsPath) -match [regex]::Escape("<repo-root>\Meta\MetaN.uproject")
	)
	Check "Client profile derives N from the clone basename" (
		[IO.File]::ReadAllText($agentsPath) -match 'matching `clientN`'
	)
	Check "Client profile forbids Meta run-config fallback" (
		[IO.File]::ReadAllText($agentsPath) -match 'do not require or fall back to `Meta`'
	)
	Check "CLAUDE.md remains byte-identical" ((Get-Hash $claudePath) -eq $claudeBefore)
	Check ".gitignore remains byte-identical" ((Get-Hash $ignorePath) -eq $ignoreBefore)
	Check "AGENTS.md attributes are preserved" ((Get-Item -LiteralPath $agentsPath -Force).Attributes -eq $agentsAttributesBefore)

	$afterFirstApply = Get-Hash $agentsPath
	$secondApply = Invoke-ProfileTool @(
		"-Mode", "Apply",
		"-Target", $client,
		"-Profile", "client",
		"-AllowDirtySource",
		"-RunRoot", $runRoot,
		'-Confirm:$false'
	)
	Check "Second Apply succeeds" ($secondApply.ExitCode -eq 0) $secondApply.Output
	Check "Second Apply is byte-idempotent" ((Get-Hash $agentsPath) -eq $afterFirstApply)
	$verify = Invoke-ProfileTool @("-Mode", "Verify", "-Target", $client, "-Profile", "client")
	Check "Verify reports compliant" ($verify.ExitCode -eq 0 -and $verify.Output -match "Compliant") $verify.Output

	"=== Sandbox composition ==="
	$sandbox = New-FixtureRepo -Name "sandbox1" -Profile sandbox
	$sandboxApply = Invoke-ProfileTool @(
		"-Mode", "Apply",
		"-Target", $sandbox,
		"-Profile", "sandbox",
		"-AllowDirtySource",
		"-RunRoot", $runRoot,
		'-Confirm:$false'
	)
	$sandboxText = [IO.File]::ReadAllText((Join-Path $sandbox "AGENTS.md"))
	Check "Sandbox Apply succeeds" ($sandboxApply.ExitCode -eq 0) $sandboxApply.Output
	Check "Sandbox contains one guard" (([regex]::Matches($sandboxText, "<!-- OVDR_UNREAL_CLEAN_BUILD_GUARD:START -->")).Count -eq 1)
	Check "Sandbox contains one profile" (([regex]::Matches($sandboxText, "<!-- overdare-sandbox-guidance:begin -->")).Count -eq 1)
	Check "Sandbox profile requires clone-specific Uproject" (
		$sandboxText -match [regex]::Escape("<repo-root>\Sandbox\SandboxN.uproject")
	)
	Check "Sandbox profile derives N from the clone basename" (
		$sandboxText -match 'matching `sandboxN`'
	)
	Check "Sandbox profile forbids Sandbox run-config fallback" (
		$sandboxText -match 'do not require or fall back to\s+`Sandbox`'
	)

	"=== Wrong profile and encoding failures ==="
	$wrongBlock = [IO.File]::ReadAllText((Join-Path $packageRoot "profiles\sandbox\AGENTS.profile.md"))
	$wrong = New-FixtureRepo -Name "client2" -Profile client -AdditionalAgentsText $wrongBlock
	$wrongHash = Get-Hash (Join-Path $wrong "AGENTS.md")
	$wrongResult = Invoke-ProfileTool @(
		"-Mode", "Apply",
		"-Target", $wrong,
		"-Profile", "client",
		"-AllowDirtySource",
		"-RunRoot", $runRoot,
		'-Confirm:$false'
	)
	Check "Wrong profile blocks Apply" ($wrongResult.ExitCode -ne 0 -and $wrongResult.Output -match "preflight")
	Check "Wrong profile target is unchanged" ((Get-Hash (Join-Path $wrong "AGENTS.md")) -eq $wrongHash)

	$bom = New-FixtureRepo -Name "client3" -Profile client -BomAgents
	$bomHash = Get-Hash (Join-Path $bom "AGENTS.md")
	$bomResult = Invoke-ProfileTool @(
		"-Mode", "Apply",
		"-Target", $bom,
		"-Profile", "client",
		"-AllowDirtySource",
		"-RunRoot", $runRoot,
		'-Confirm:$false'
	)
	Check "BOM target blocks Apply" ($bomResult.ExitCode -ne 0 -and $bomResult.Output -match "preflight")
	Check "BOM target is unchanged" ((Get-Hash (Join-Path $bom "AGENTS.md")) -eq $bomHash)

	$unknownGuard = New-FixtureRepo -Name "client4" -Profile client -AdditionalAgentsText @"
<!-- OVDR_UNKNOWN_GUARD:START -->
Unknown guard fixture.
<!-- OVDR_UNKNOWN_GUARD:END -->
"@
	$unknownGuardHash = Get-Hash (Join-Path $unknownGuard "AGENTS.md")
	$unknownGuardResult = Invoke-ProfileTool @(
		"-Mode", "Apply",
		"-Target", $unknownGuard,
		"-Profile", "client",
		"-AllowDirtySource",
		"-RunRoot", $runRoot,
		'-Confirm:$false'
	)
	Check "Unknown guard marker blocks Apply" (
		$unknownGuardResult.ExitCode -ne 0 -and
		$unknownGuardResult.Output -match "Unknown repository profile marker"
	) $unknownGuardResult.Output
	Check "Unknown guard target is unchanged" ((Get-Hash (Join-Path $unknownGuard "AGENTS.md")) -eq $unknownGuardHash)

	$reparseAgentWork = New-FixtureRepo -Name "client5" -Profile client
	$reparseAgentsPath = Join-Path $reparseAgentWork "AGENTS.md"
	$reparseAgentWorkPath = Join-Path $reparseAgentWork ".agent-work"
	$redirectedAgentWorkPath = Join-Path $smokeRoot "redirected-agent-work"
	Remove-Item -LiteralPath $reparseAgentWorkPath -Recurse -Force
	New-Item -ItemType Directory -Path $redirectedAgentWorkPath -Force | Out-Null
	New-Item -ItemType Junction -Path $reparseAgentWorkPath -Target $redirectedAgentWorkPath | Out-Null
	$reparseAgentsHash = Get-Hash $reparseAgentsPath
	$reparseAgentWorkResult = Invoke-ProfileTool @(
		"-Mode", "Apply",
		"-Target", $reparseAgentWork,
		"-Profile", "client",
		"-AllowDirtySource",
		"-RunRoot", $runRoot,
		'-Confirm:$false'
	)
	Check "Reparse-point .agent-work blocks Apply" (
		$reparseAgentWorkResult.ExitCode -ne 0 -and
		$reparseAgentWorkResult.Output -match "\.agent-work is a reparse point"
	) $reparseAgentWorkResult.Output
	Check "Reparse-point refusal leaves AGENTS.md unchanged" ((Get-Hash $reparseAgentsPath) -eq $reparseAgentsHash)
	Check "Reparse-point refusal writes no redirected lock" (-not (Test-Path -LiteralPath (Join-Path $redirectedAgentWorkPath "repo-agent-config.lock")))

	"=== Direct client-build-tools profile ==="
	$buildTools = New-FixtureRepo -Name "client-build-tools-direct" -Profile client-build-tools
	$buildAgents = Join-Path $buildTools "AGENTS.md"
	$buildBeforeText = [IO.File]::ReadAllText($buildAgents)
	$buildCommonStart = $buildBeforeText.IndexOf("<!-- branch-docs-starter:begin -->", [StringComparison]::Ordinal)
	$buildCommonBefore = $buildBeforeText.Substring($buildCommonStart)
	$buildApply = Invoke-ProfileTool @(
		"-Mode", "Apply",
		"-Target", $buildTools,
		"-Profile", "client-build-tools",
		"-AllowDirtySource",
		"-RunRoot", $runRoot,
		'-Confirm:$false'
	)
	$buildAfterText = [IO.File]::ReadAllText($buildAgents)
	$buildCommonAfter = $buildAfterText.Substring($buildAfterText.IndexOf("<!-- branch-docs-starter:begin -->", [StringComparison]::Ordinal))
	Check "Build-tools Apply succeeds" ($buildApply.ExitCode -eq 0) $buildApply.Output
	Check "Build-tools profile precedes common" (Assert-BlockBeforeCommon $buildAgents "<!-- overdare-client-build-tools-guidance:begin -->")
	Check "Standard common suffix is byte-preserved" ($buildCommonAfter -ceq $buildCommonBefore)
	Check "Build-tools excludes Unreal guard" ($buildAfterText -notmatch "OVDR_UNREAL_CLEAN_BUILD_GUARD")

	$directWithWorktreeCommon = New-FixtureRepo -Name "client-build-tools-wrong-common" -Profile client-build-tools -WorktreeAware
	$directWrongCommonResult = Invoke-ProfileTool @(
		"-Mode", "Plan",
		"-Target", $directWithWorktreeCommon,
		"-Profile", "client-build-tools"
	)
	Check "Direct build-tools clone rejects worktree-aware common" (
		$directWrongCommonResult.ExitCode -eq 0 -and
		$directWrongCommonResult.Output -match "Blocked" -and
		$directWrongCommonResult.Output -match "require the standard common"
	) $directWrongCommonResult.Output

	"=== Bare client-build-tools container and linked-worktree discovery ==="
	$worktreeWorkspace = Join-Path $smokeRoot "worktree-workspace"
	New-Item -ItemType Directory -Path $worktreeWorkspace -Force | Out-Null
	$buildToolsSeed = New-FixtureRepo -Name "client-build-tools-seed" -Profile client-build-tools
	$bareContainer = Join-Path $worktreeWorkspace "client-build-tools"
	& git clone -q --bare $buildToolsSeed $bareContainer
	if ($LASTEXITCODE -ne 0) { throw "git clone --bare failed: $bareContainer" }
	Invoke-GitFixture -Root $bareContainer -Arguments @(
		"remote", "set-url", "origin", "git@github.krafton.com:sbx/client-build-tools.git"
	) | Out-Null
	$linkedBuildTools = Join-Path $bareContainer "master"
	& git "--git-dir=$bareContainer" worktree add -q $linkedBuildTools master
	if ($LASTEXITCODE -ne 0) { throw "git worktree add failed: $linkedBuildTools" }

	Initialize-LocalSetup -Root $linkedBuildTools
	$linkedMissingPolicy = Invoke-ProfileTool @(
		"-Mode", "Plan",
		"-WorkspaceRoot", $worktreeWorkspace,
		"-Profile", "client-build-tools"
	)
	Check "Linked worktree without safety policy is blocked" (
		$linkedMissingPolicy.ExitCode -eq 0 -and
		$linkedMissingPolicy.Output -match "Blocked" -and
		$linkedMissingPolicy.Output -match "worktree-aware common scaffold"
	) $linkedMissingPolicy.Output

	Initialize-LocalSetup -Root $linkedBuildTools -WorktreeAware
	$linkedAgents = Join-Path $linkedBuildTools "AGENTS.md"
	$linkedBeforeText = [IO.File]::ReadAllText($linkedAgents)
	$linkedCommonStart = $linkedBeforeText.IndexOf("<!-- branch-docs-starter:begin -->", [StringComparison]::Ordinal)
	$linkedCommonBefore = $linkedBeforeText.Substring($linkedCommonStart)
	$linkedPlan = Invoke-ProfileTool @(
		"-Mode", "Plan",
		"-WorkspaceRoot", $worktreeWorkspace,
		"-Profile", "client-build-tools"
	)
	Check "Bare-container discovery selects linked worktree" (
		$linkedPlan.ExitCode -eq 0 -and
		$linkedPlan.Output -match "Drift" -and
		$linkedPlan.Output -match [regex]::Escape($linkedBuildTools)
	) $linkedPlan.Output
	Check "Bare-container discovery never selects bare root" (
		$linkedPlan.Output -notmatch ("Drift`tclient-build-tools`t" + [regex]::Escape($bareContainer) + "(`r?`n|$)")
	) $linkedPlan.Output

	$linkedApply = Invoke-ProfileTool @(
		"-Mode", "Apply",
		"-WorkspaceRoot", $worktreeWorkspace,
		"-Profile", "client-build-tools",
		"-AllExistingWorktrees",
		"-AllowDirtySource",
		"-RunRoot", $runRoot,
		'-Confirm:$false'
	)
	$linkedAfterText = [IO.File]::ReadAllText($linkedAgents)
	$linkedCommonAfter = $linkedAfterText.Substring($linkedAfterText.IndexOf("<!-- branch-docs-starter:begin -->", [StringComparison]::Ordinal))
	Check "All-existing-worktrees Apply succeeds" ($linkedApply.ExitCode -eq 0) $linkedApply.Output
	Check "Linked worktree receives build-tools profile" (Assert-BlockBeforeCommon $linkedAgents "<!-- overdare-client-build-tools-guidance:begin -->")
	Check "Linked worktree common suffix is byte-preserved" ($linkedCommonAfter -ceq $linkedCommonBefore)
	Check "Bare container remains free of AGENTS.md" (-not (Test-Path -LiteralPath (Join-Path $bareContainer "AGENTS.md")))

	"=== Discovery exclusions ==="
	$discoveryRoot = Join-Path $smokeRoot "workspace"
	New-Item -ItemType Directory -Path $discoveryRoot -Force | Out-Null
	$discoverClient = New-FixtureRepo -Name "workspace\client4" -Profile client
	$clientApp = New-FixtureRepo -Name "workspace\client-app" -Profile client
	$discovery = Invoke-ProfileTool @("-Mode", "Plan", "-WorkspaceRoot", $discoveryRoot, "-Profile", "client")
	Check "Anchored discovery finds clientN" ($discovery.ExitCode -eq 0 -and $discovery.Output -match [regex]::Escape($discoverClient)) $discovery.Output
	Check "Discovery excludes client-app" ($discovery.Output -notmatch [regex]::Escape($clientApp)) $discovery.Output

	"=== Selection flag validation ==="
	$unknownProfile = Invoke-ProfileTool @("-Mode", "Plan", "-Target", $client, "-Profile", "not-in-manifest")
	Check "Unknown manifest profile is rejected" (
		$unknownProfile.ExitCode -ne 0 -and $unknownProfile.Output -match "Unknown profile"
	) $unknownProfile.Output

	$invalidPolicyManifestPath = Join-Path $smokeRoot "invalid-policy-manifest.json"
	$invalidPolicyManifest = Get-Content -Raw -LiteralPath (Join-Path $packageRoot "config\repo-agent-profiles.json") | ConvertFrom-Json
	$invalidPolicyManifest.profiles.sandbox.commonPolicy = "standrad"
	Write-Utf8 -Path $invalidPolicyManifestPath -Text ($invalidPolicyManifest | ConvertTo-Json -Depth 20)
	$invalidPolicyResult = Invoke-ProfileTool @(
		"-Mode", "Plan",
		"-Target", $client,
		"-Profile", "client",
		"-ManifestPath", $invalidPolicyManifestPath
	)
	Check "Invalid unselected profile policy rejects whole manifest" (
		$invalidPolicyResult.ExitCode -ne 0 -and
		$invalidPolicyResult.Output -match "unsupported\s+commonPolicy"
	) $invalidPolicyResult.Output

	$escapingSourceManifestPath = Join-Path $smokeRoot "escaping-source-manifest.json"
	$escapingSourceManifest = Get-Content -Raw -LiteralPath (Join-Path $packageRoot "config\repo-agent-profiles.json") | ConvertFrom-Json
	$escapingSourceManifest.profiles.client.blocks[0].source = "..\outside.md"
	Write-Utf8 -Path $escapingSourceManifestPath -Text ($escapingSourceManifest | ConvertTo-Json -Depth 20)
	$escapingSourceResult = Invoke-ProfileTool @(
		"-Mode", "Plan",
		"-Target", $client,
		"-Profile", "client",
		"-ManifestPath", $escapingSourceManifestPath
	)
	Check "Profile source cannot escape profiles directory" (
		$escapingSourceResult.ExitCode -ne 0 -and
		$escapingSourceResult.Output -match "source must be an existing .md file under profiles"
	) $escapingSourceResult.Output

	$conflictingSelection = Invoke-ProfileTool @(
		"-Mode", "Plan",
		"-Target", $client,
		"-Profile", "client",
		"-AllDiscovered"
	)
	Check "Conflicting target selectors are rejected" (
		$conflictingSelection.ExitCode -ne 0 -and
		$conflictingSelection.Output -match "cannot be combined"
	) $conflictingSelection.Output
	$ignoredWorkspaceRoot = Invoke-ProfileTool @(
		"-Mode", "Plan",
		"-Target", $client,
		"-WorkspaceRoot", $discoveryRoot,
		"-Profile", "client"
	)
	Check "Explicit target rejects ignored workspace root" (
		$ignoredWorkspaceRoot.ExitCode -ne 0 -and
		$ignoredWorkspaceRoot.Output -match "cannot be combined\s+with\s+-WorkspaceRoot"
	) $ignoredWorkspaceRoot.Output

	"=== Lock refusal ==="
	$lockedText = [IO.File]::ReadAllText($agentsPath).Replace(
		"The canonical Unreal client project is",
		"The drifted Unreal client project is"
	)
	Write-Utf8 -Path $agentsPath -Text $lockedText
	$lockPath = Join-Path $client ".agent-work\repo-agent-config.lock"
	Write-Utf8 -Path $lockPath -Text "held"
	$lockedHash = Get-Hash $agentsPath
	$lockResult = Invoke-ProfileTool @(
		"-Mode", "Apply",
		"-Target", $client,
		"-Profile", "client",
		"-AllowDirtySource",
		"-RunRoot", $runRoot,
		'-Confirm:$false'
	)
	Check "Existing lock blocks Apply" ($lockResult.ExitCode -ne 0) $lockResult.Output
	Check "Existing lock leaves target bytes unchanged" ((Get-Hash $agentsPath) -eq $lockedHash)
	Remove-Item -LiteralPath $lockPath -Force

	"=== Final ==="
	Check "No tracked fixture files leaked into package" (-not (git -C $packageRoot status --short | Select-String -SimpleMatch ".agent-work"))
	if ($failures -gt 0) {
		throw "$failures smoke test(s) failed."
	}
	"REPO AGENT CONFIG SMOKE PASSED"
}
finally {
	Remove-SmokeRoot
}
