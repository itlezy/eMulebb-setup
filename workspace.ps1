#Requires -Version 7.6
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('init', 'materialize', 'status', 'validate', 'sync', 'ensure-path', 'compare', 'dep-updates')]
    [string]$Command = 'status',

    [Parameter(Position = 1)]
    [string]$CompareKey,

    [string]$EmuleWorkspaceRoot,

    [string]$WorkspaceName,

    [string]$ArtifactsSeedRoot,

    [ValidateSet('None', 'User')]
    [string]$Persist = 'None'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ScriptRoot {
    Split-Path -Parent $PSCommandPath
}

function Import-SetupConfig {
    Import-PowerShellDataFile -LiteralPath (Join-Path (Get-ScriptRoot) 'repos.psd1')
}

function Resolve-EmuleWorkspaceRoot {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [string]$OverrideRoot
    )

    $candidate = if (-not [string]::IsNullOrWhiteSpace($OverrideRoot)) {
        $OverrideRoot
    } elseif (-not [string]::IsNullOrWhiteSpace($env:EMULE_WORKSPACE_ROOT)) {
        $env:EMULE_WORKSPACE_ROOT
    } else {
        throw 'Emule workspace root is required. Pass -EmuleWorkspaceRoot or set EMULE_WORKSPACE_ROOT.'
    }

    [System.IO.Path]::GetFullPath($candidate)
}

function Resolve-WorkspaceName {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [string]$OverrideName
    )

    if (-not [string]::IsNullOrWhiteSpace($OverrideName)) {
        return $OverrideName
    }

    return $Config.DefaultWorkspaceName
}

function Get-WorkspaceRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$WorkspaceName
    )

    Join-Path $Root ('workspaces\{0}' -f $WorkspaceName)
}

function Get-WorkspaceStateRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$WorkspaceName
    )

    Join-Path (Get-WorkspaceRoot -Root $Root -WorkspaceName $WorkspaceName) 'state'
}

function Get-WorkspacePropsPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    Join-Path $Root $Config.WorkspacePropsFileName
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        $null = New-Item -ItemType Directory -Force -Path $Path
    }
}

function Set-WorkspaceRootEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $resolvedRoot = [System.IO.Path]::GetFullPath($Root)
    $env:EMULE_WORKSPACE_ROOT = $resolvedRoot
    [Environment]::SetEnvironmentVariable('EMULE_WORKSPACE_ROOT', $resolvedRoot, 'User')
}

function Test-DirectoryEmpty {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $true
    }

    $entries = @(Get-ChildItem -LiteralPath $Path -Force)
    return ($entries.Count -eq 0)
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList,

        [string]$WorkingDirectory = (Get-Location).Path
    )

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw ("Command failed ({0} {1}) with exit code {2}" -f $FilePath, ($ArgumentList -join ' '), $LASTEXITCODE)
    }
}

function Invoke-GitCapture {
    param([Parameter(Mandatory = $true)][string[]]$ArgumentList)

    $output = & git @ArgumentList 2>&1
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = @($output)
        Text = (@($output) -join "`n").Trim()
    }
}

function Get-VsWherePath {
    $cmd = Get-Command 'vswhere.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) {
        return $cmd.Source
    }

    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }) {
        $candidate = Join-Path $base 'Microsoft Visual Studio\Installer\vswhere.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    throw 'vswhere.exe not found.'
}

function Get-VsInstallPath {
    $vsWhere = Get-VsWherePath
    $installationPath = (& $vsWhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath | Select-Object -First 1).Trim()
    if ([string]::IsNullOrWhiteSpace($installationPath)) {
        throw 'Unable to resolve the active Visual Studio installation path.'
    }

    return $installationPath
}

function Get-MSBuildPath {
    $cmd = Get-Command 'MSBuild.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) {
        return $cmd.Source
    }

    $candidate = Join-Path (Get-VsInstallPath) 'MSBuild\Current\Bin\MSBuild.exe'
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw 'MSBuild.exe not found.'
    }

    return $candidate
}

function Get-CMakePath {
    $cmd = Get-Command 'cmake.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) {
        return $cmd.Source
    }

    $candidate = Join-Path (Get-VsInstallPath) 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw 'cmake.exe not found.'
    }

    return $candidate
}

function Get-PerlPath {
    $cmd = Get-Command 'perl.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) {
        return $cmd.Source
    }

    foreach ($candidate in @(
        'C:\Program Files\Git\usr\bin\perl.exe'
        'C:\Program Files (x86)\Git\usr\bin\perl.exe'
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    throw 'perl.exe not found.'
}

function Invoke-MSBuildProject {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectPath,

        [Parameter(Mandatory = $true)]
        [string]$Configuration,

        [Parameter(Mandatory = $true)]
        [string]$Platform,

        [string[]]$ExtraProperties = @()
    )

    $msbuildPath = Get-MSBuildPath
    $argumentList = @(
        $ProjectPath
        '/m'
        '/nologo'
        '/t:Build'
        "/p:Configuration=$Configuration"
        "/p:Platform=$Platform"
    ) + $ExtraProperties

    Invoke-Checked -FilePath $msbuildPath -ArgumentList $argumentList
}

function Invoke-RobocopyMirror {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    Ensure-Directory -Path $DestinationPath
    $null = & robocopy $SourcePath $DestinationPath /E /XO /R:1 /W:1 /NFL /NDL /NJH /NJS /XD .git .vs /XF .git
    if ($LASTEXITCODE -gt 7) {
        throw "robocopy failed for '$SourcePath' -> '$DestinationPath' with exit code $LASTEXITCODE."
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return
    }

    $logPath = Join-Path $Root $Config.LogFileName
    Add-Content -LiteralPath $logPath -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
}

function Get-RepoPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [hashtable]$Repo
    )

    Join-Path $Root $Repo.RelativePath
}

function Ensure-RepoAdditionalRemotes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoPath,

        [Parameter(Mandatory = $true)]
        [hashtable]$Repo
    )

    if (-not $Repo.ContainsKey('AdditionalRemotes')) {
        return
    }

    $remoteOutput = & git -C $RepoPath remote
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list git remotes for '$RepoPath'."
    }

    $existingRemotes = @($remoteOutput | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($remote in @($Repo.AdditionalRemotes)) {
        $name = [string]$remote.Name
        $url = [string]$remote.Url
        if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($url)) {
            throw "Repo '$($Repo.Name)' has an invalid additional remote entry."
        }

        if ($existingRemotes -contains $name) {
            Invoke-Checked -FilePath 'git' -ArgumentList @('-C', $RepoPath, 'remote', 'set-url', $name, $url)
        } else {
            Invoke-Checked -FilePath 'git' -ArgumentList @('-C', $RepoPath, 'remote', 'add', $name, $url)
            $existingRemotes += $name
        }
    }
}

function Get-AllRepoConfigs {
    param([Parameter(Mandatory = $true)][hashtable]$Config)

    @($Config.AppRepo) + @($Config.Repos) + @($Config.AnalysisRepos) + @($Config.ThirdPartyRepos)
}

function Get-DepUpdatesRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$WorkspaceName
    )

    Join-Path (Get-WorkspaceStateRoot -Root $Root -WorkspaceName $WorkspaceName) 'dep-updates'
}

function Get-DepUpdatesRunStamp {
    if (-not (Get-Variable -Name DepUpdatesRunStamp -Scope Script -ErrorAction SilentlyContinue)) {
        $script:DepUpdatesRunStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    }

    $script:DepUpdatesRunStamp
}

function Get-DepUpdatesRunDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$WorkspaceName
    )

    Join-Path (Get-DepUpdatesRoot -Root $Root -WorkspaceName $WorkspaceName) (Get-DepUpdatesRunStamp)
}

function Get-DepUpdatesLatestPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$WorkspaceName
    )

    Join-Path (Get-DepUpdatesRoot -Root $Root -WorkspaceName $WorkspaceName) 'latest.json'
}

function Get-ShortCommit {
    param([string]$Commit)

    if ([string]::IsNullOrWhiteSpace($Commit)) {
        return ''
    }

    if ($Commit.Length -le 8) {
        return $Commit
    }

    $Commit.Substring(0, 8)
}

function ConvertTo-VersionValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Pattern
    )

    if ($Value -match $Pattern) {
        try {
            return [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
        } catch {
            return $null
        }
    }

    $null
}

function Find-NewerMatchingTags {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Tags,

        [Parameter(Mandatory = $true)]
        [string]$Pattern,

        [Parameter(Mandatory = $true)]
        [version]$BaselineVersion
    )

    $candidates = foreach ($tag in $Tags) {
        $versionValue = ConvertTo-VersionValue -Value $tag -Pattern $Pattern
        if ($null -ne $versionValue) {
            [pscustomobject]@{
                Tag = $tag
                Version = $versionValue
            }
        }
    }

    @($candidates | Where-Object { $_.Version -gt $BaselineVersion } | Sort-Object Version -Descending)
}

function Get-RemoteTags {
    param([Parameter(Mandatory = $true)][string]$RemoteUrl)

    $result = Invoke-GitCapture -ArgumentList @('ls-remote', '--tags', '--refs', $RemoteUrl)
    if ($result.ExitCode -ne 0) {
        throw "git ls-remote --tags failed for '$RemoteUrl': $($result.Text)"
    }

    foreach ($line in $result.Output) {
        if ($line -match '^[0-9a-f]{40}\s+refs/tags/(.+)$') {
            $Matches[1]
        }
    }
}

function Get-RemoteHeadInfo {
    param([Parameter(Mandatory = $true)][string]$RemoteUrl)

    $result = Invoke-GitCapture -ArgumentList @('ls-remote', '--symref', $RemoteUrl, 'HEAD')
    if ($result.ExitCode -ne 0) {
        throw "git ls-remote --symref failed for '$RemoteUrl': $($result.Text)"
    }

    $resolvedRef = ''
    $commit = ''
    foreach ($line in $result.Output) {
        if ($line -match '^ref:\s+(\S+)\s+HEAD$') {
            $resolvedRef = $Matches[1]
            continue
        }
        if ($line -match '^([0-9a-f]{40})\s+HEAD$') {
            $commit = $Matches[1]
        }
    }

    if ([string]::IsNullOrWhiteSpace($resolvedRef) -or [string]::IsNullOrWhiteSpace($commit)) {
        throw "Unable to resolve remote HEAD for '$RemoteUrl'."
    }

    [pscustomobject]@{
        RequestedRef = 'HEAD'
        ResolvedRef = $resolvedRef
        Commit = $commit
    }
}

function Get-RemoteBranchHeadInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RemoteUrl,

        [Parameter(Mandatory = $true)]
        [string]$BranchName
    )

    $resolvedRef = "refs/heads/$BranchName"
    $result = Invoke-GitCapture -ArgumentList @('ls-remote', $RemoteUrl, $resolvedRef)
    if ($result.ExitCode -ne 0) {
        throw "git ls-remote failed for '$RemoteUrl' branch '$BranchName': $($result.Text)"
    }

    $line = @($result.Output | Select-Object -First 1)[0]
    if ([string]::IsNullOrWhiteSpace($line) -or $line -notmatch '^([0-9a-f]{40})\s+(\S+)$') {
        throw "Unable to resolve upstream branch '$BranchName' for '$RemoteUrl'."
    }

    [pscustomobject]@{
        RequestedRef = $BranchName
        ResolvedRef = $Matches[2]
        Commit = $Matches[1]
    }
}

function Get-LocalGitState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoPath,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not (Test-Path -LiteralPath $RepoPath -PathType Container)) {
        return [pscustomobject]@{
            Exists = $false
            Branch = ''
            Head = ''
            Dirty = $false
        }
    }

    $status = Get-RepoStatusObject -RepoPath $RepoPath -Name $Name
    [pscustomobject]@{
        Exists = $true
        Branch = $status.Branch
        Head = $status.Head
        Dirty = $status.Dirty
    }
}

function Get-DepUpdateTrackingResult {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Policy,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if (-not $Policy.ContainsKey('TrackingMode')) {
        throw "Dependency update policy for '$Label' is missing TrackingMode."
    }

    $trackingMode = [string]$Policy.TrackingMode
    $baselineRef = if ($Policy.ContainsKey('BaselineRef')) { [string]$Policy.BaselineRef } else { '' }
    $notes = if ($Policy.ContainsKey('Notes')) { [string]$Policy.Notes } else { '' }
    $upstreamUrl = if ($Policy.ContainsKey('UpstreamUrl')) { [string]$Policy.UpstreamUrl } else { '' }
    $upstreamRef = if ($Policy.ContainsKey('UpstreamRef')) { [string]$Policy.UpstreamRef } else { '' }

    switch ($trackingMode) {
        'none' {
            return [pscustomobject]@{
                Status = 'fork-only'
                Current = $baselineRef
                Latest = 'N/A'
                Detail = if ([string]::IsNullOrWhiteSpace($notes)) { 'no automated upstream comparison configured' } else { $notes }
                ResolvedUpstreamRef = ''
                UpstreamLatestRevision = ''
            }
        }
        'tag' {
            if ([string]::IsNullOrWhiteSpace($upstreamUrl)) {
                throw "Dependency update policy for '$Label' is missing UpstreamUrl."
            }
            if ([string]::IsNullOrWhiteSpace($baselineRef)) {
                throw "Dependency update policy for '$Label' is missing BaselineRef."
            }
            if (-not $Policy.ContainsKey('VersionPattern') -or [string]::IsNullOrWhiteSpace([string]$Policy.VersionPattern)) {
                throw "Dependency update policy for '$Label' is missing VersionPattern."
            }

            $versionPattern = [string]$Policy.VersionPattern
            $baselineVersion = ConvertTo-VersionValue -Value $baselineRef -Pattern $versionPattern
            if ($null -eq $baselineVersion) {
                throw "Unable to parse baseline ref '$baselineRef' for '$Label' with pattern '$versionPattern'."
            }

            $remoteTags = @(Get-RemoteTags -RemoteUrl $upstreamUrl)
            $newerTags = @(Find-NewerMatchingTags -Tags $remoteTags -Pattern $versionPattern -BaselineVersion $baselineVersion)
            $latestTag = if ($newerTags.Count -gt 0) { $newerTags[0].Tag } else { $baselineRef }
            $detail = if ($newerTags.Count -gt 0) {
                "{0} newer matching release(s) available" -f $newerTags.Count
            } else {
                'on latest matching release'
            }

            return [pscustomobject]@{
                Status = if ($newerTags.Count -gt 0) { 'candidate-update' } else { 'up-to-date' }
                Current = $baselineRef
                Latest = $latestTag
                Detail = $detail
                ResolvedUpstreamRef = ''
                UpstreamLatestRevision = ''
            }
        }
        'branch-head' {
            if ([string]::IsNullOrWhiteSpace($upstreamUrl)) {
                throw "Dependency update policy for '$Label' is missing UpstreamUrl."
            }
            if ([string]::IsNullOrWhiteSpace($baselineRef)) {
                throw "Dependency update policy for '$Label' is missing BaselineRef."
            }

            $remoteInfo = if ([string]::IsNullOrWhiteSpace($upstreamRef) -or $upstreamRef -eq 'HEAD') {
                Get-RemoteHeadInfo -RemoteUrl $upstreamUrl
            } else {
                Get-RemoteBranchHeadInfo -RemoteUrl $upstreamUrl -BranchName $upstreamRef
            }

            $isCurrent = ($remoteInfo.Commit -eq $baselineRef)
            return [pscustomobject]@{
                Status = if ($isCurrent) { 'up-to-date' } else { 'candidate-update' }
                Current = Get-ShortCommit -Commit $baselineRef
                Latest = Get-ShortCommit -Commit $remoteInfo.Commit
                Detail = if ($isCurrent) {
                    "matches upstream $($remoteInfo.ResolvedRef)"
                } else {
                    "upstream $($remoteInfo.ResolvedRef) differs from pinned baseline"
                }
                ResolvedUpstreamRef = $remoteInfo.ResolvedRef
                UpstreamLatestRevision = $remoteInfo.Commit
            }
        }
        default {
            throw "Unsupported TrackingMode '$trackingMode' for '$Label'."
        }
    }
}

function New-DepUpdateEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$RelativePath,

        [Parameter(Mandatory = $true)]
        [string]$RepoPath,

        [string]$PinnedBranch,

        [Parameter(Mandatory = $true)]
        [hashtable]$Policy,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $localState = Get-LocalGitState -RepoPath $RepoPath -Name $Name
    $entry = [ordered]@{
        Name = $Name
        RelativePath = $RelativePath
        PinnedBranch = $PinnedBranch
        Exists = $localState.Exists
        LocalBranch = $localState.Branch
        LocalHead = $localState.Head
        LocalDirty = $localState.Dirty
        TrackingMode = if ($Policy.ContainsKey('TrackingMode')) { [string]$Policy.TrackingMode } else { '' }
        BaselineRef = if ($Policy.ContainsKey('BaselineRef')) { [string]$Policy.BaselineRef } else { '' }
        UpstreamUrl = if ($Policy.ContainsKey('UpstreamUrl')) { [string]$Policy.UpstreamUrl } else { '' }
        UpstreamRef = if ($Policy.ContainsKey('UpstreamRef')) { [string]$Policy.UpstreamRef } else { '' }
        ResolvedUpstreamRef = ''
        UpstreamLatestRevision = ''
        Current = ''
        Latest = ''
        Status = ''
        Detail = ''
        Notes = if ($Policy.ContainsKey('Notes')) { [string]$Policy.Notes } else { '' }
        ChildComponents = @()
    }

    try {
        if (-not $localState.Exists) {
            throw "Pinned dependency path is missing: $RepoPath"
        }

        $tracking = Get-DepUpdateTrackingResult -Policy $Policy -Label $Label
        $entry.Current = $tracking.Current
        $entry.Latest = $tracking.Latest
        $entry.Status = $tracking.Status
        $entry.Detail = $tracking.Detail
        $entry.ResolvedUpstreamRef = $tracking.ResolvedUpstreamRef
        $entry.UpstreamLatestRevision = $tracking.UpstreamLatestRevision
    } catch {
        $entry.Status = 'error'
        $entry.Current = if ($entry.BaselineRef) { $entry.BaselineRef } else { '' }
        $entry.Latest = '?'
        $entry.Detail = $_.Exception.Message
    }

    [pscustomobject]$entry
}

function Get-DepUpdateEntries {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($repo in @($Config.ThirdPartyRepos)) {
        if (-not $repo.ContainsKey('UpdatePolicy')) {
            throw "Third-party repo '$($repo.Name)' is missing UpdatePolicy metadata."
        }

        $policy = @{} + $repo.UpdatePolicy
        $repoPath = Get-RepoPath -Root $Root -Repo $repo
        $entry = New-DepUpdateEntry -Name $repo.Name -RelativePath $repo.RelativePath -RepoPath $repoPath -PinnedBranch $repo.Branch -Policy $policy -Label $repo.Name

        $children = [System.Collections.Generic.List[object]]::new()
        $childComponents = if ($policy.ContainsKey('ChildComponents')) { @($policy.ChildComponents) } else { @() }
        foreach ($child in $childComponents) {
            $childPolicy = @{} + $child
            $childName = [string]$childPolicy.Name
            if ([string]::IsNullOrWhiteSpace($childName)) {
                throw "Child component metadata for '$($repo.Name)' is missing Name."
            }

            $childRelativePath = if ($childPolicy.ContainsKey('RelativePath')) {
                Join-Path $repo.RelativePath ([string]$childPolicy.RelativePath)
            } else {
                $repo.RelativePath
            }
            $childRepoPath = if ($childPolicy.ContainsKey('RelativePath')) {
                Join-Path $repoPath ([string]$childPolicy.RelativePath)
            } else {
                $repoPath
            }

            $children.Add((New-DepUpdateEntry -Name $childName -RelativePath $childRelativePath -RepoPath $childRepoPath -PinnedBranch '' -Policy $childPolicy -Label ("{0}/{1}" -f $repo.Name, $childName))) | Out-Null
        }

        $entry.ChildComponents = @($children)
        $entries.Add($entry) | Out-Null
    }

    @($entries)
}

function Get-DepUpdateCounts {
    param([Parameter(Mandatory = $true)][object[]]$Entries)

    $counts = [ordered]@{
        'up-to-date' = @($Entries | Where-Object { $_.Status -eq 'up-to-date' }).Count
        'candidate-update' = @($Entries | Where-Object { $_.Status -eq 'candidate-update' }).Count
        'fork-only' = @($Entries | Where-Object { $_.Status -eq 'fork-only' }).Count
        'error' = @($Entries | Where-Object { $_.Status -eq 'error' }).Count
    }

    [pscustomobject]$counts
}

function Get-DepUpdateStatusColor {
    param([Parameter(Mandatory = $true)][string]$Status)

    switch ($Status) {
        'up-to-date' { 'Green' }
        'candidate-update' { 'Yellow' }
        'fork-only' { 'DarkGray' }
        'error' { 'Red' }
        default { 'White' }
    }
}

function Write-DepUpdateConsoleReport {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Entries,

        [Parameter(Mandatory = $true)]
        [string]$SummaryPath
    )

    $format = "  {0,-24} {1,-12} {2,-18} {3,-18} {4,-17} {5}"

    Write-Host ''
    Write-Host 'Dependency update advisory report' -ForegroundColor Cyan
    Write-Host ''
    Write-Host ($format -f 'DEPENDENCY', 'TRACKING', 'CURRENT', 'LATEST', 'STATUS', 'DETAIL') -ForegroundColor DarkGray
    Write-Host ('  ' + ('-' * 110)) -ForegroundColor DarkGray

    foreach ($entry in $Entries) {
        Write-Host ($format -f $entry.Name, $entry.TrackingMode, $entry.Current, $entry.Latest, $entry.Status, $entry.Detail) -ForegroundColor (Get-DepUpdateStatusColor -Status $entry.Status)
        foreach ($child in @($entry.ChildComponents)) {
            Write-Host ($format -f ("  + $($child.Name)"), $child.TrackingMode, $child.Current, $child.Latest, $child.Status, $child.Detail) -ForegroundColor (Get-DepUpdateStatusColor -Status $child.Status)
        }
    }

    $topLevelCounts = Get-DepUpdateCounts -Entries $Entries
    $childEntries = foreach ($entry in $Entries) { @($entry.ChildComponents) }
    $childCounts = Get-DepUpdateCounts -Entries @($childEntries)

    Write-Host ('  ' + ('-' * 110)) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host ('  Top-level counts: up-to-date={0} candidate-update={1} fork-only={2} error={3}' -f $topLevelCounts.'up-to-date', $topLevelCounts.'candidate-update', $topLevelCounts.'fork-only', $topLevelCounts.error)
    if (@($childEntries).Count -gt 0) {
        Write-Host ('  Child counts:     up-to-date={0} candidate-update={1} fork-only={2} error={3}' -f $childCounts.'up-to-date', $childCounts.'candidate-update', $childCounts.'fork-only', $childCounts.error)
    }
    Write-Host ("  JSON report: $SummaryPath")
    Write-Host ''
}

function Write-DepUpdateArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$WorkspaceName,

        [Parameter(Mandatory = $true)]
        [object[]]$Entries
    )

    $depUpdatesRoot = Get-DepUpdatesRoot -Root $Root -WorkspaceName $WorkspaceName
    $runDirectory = Get-DepUpdatesRunDirectory -Root $Root -WorkspaceName $WorkspaceName
    Ensure-Directory -Path $depUpdatesRoot
    Ensure-Directory -Path $runDirectory

    $childEntries = foreach ($entry in $Entries) { @($entry.ChildComponents) }
    $report = [ordered]@{
        WorkspaceRoot = $Root
        WorkspaceName = $WorkspaceName
        GeneratedAt = (Get-Date).ToString('o')
        SetupRepoRoot = Get-ScriptRoot
        Counts = Get-DepUpdateCounts -Entries $Entries
        ChildComponentCounts = Get-DepUpdateCounts -Entries @($childEntries)
        Dependencies = @($Entries)
    }

    $json = $report | ConvertTo-Json -Depth 20
    $summaryPath = Join-Path $runDirectory 'summary.json'
    $latestPath = Get-DepUpdatesLatestPath -Root $Root -WorkspaceName $WorkspaceName
    Set-Content -LiteralPath $summaryPath -Value $json -Encoding utf8
    Set-Content -LiteralPath $latestPath -Value $json -Encoding utf8

    [pscustomobject]@{
        SummaryPath = $summaryPath
        LatestPath = $latestPath
        Counts = $report.Counts
        ChildComponentCounts = $report.ChildComponentCounts
    }
}

function Get-ManagedAppWorktrees {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [switch]$IncludeInactive
    )

    $worktrees = @($Config.AppRepo.Worktrees)
    if ($IncludeInactive) {
        return @($worktrees)
    }

    return @($worktrees | Where-Object {
        if ($_.ContainsKey('Active')) {
            return [bool]$_.Active
        }

        return $true
    })
}

function Get-HookInstallTargets {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    $targets = [System.Collections.Generic.List[string]]::new()
    $targets.Add((Get-ScriptRoot)) | Out-Null
    foreach ($repo in @($Config.Repos | Where-Object { $_.Name -in @('eMule-build', 'eMule-build-tests', 'eMule-tooling') })) {
        $targets.Add((Get-RepoPath -Root $Root -Repo $repo)) | Out-Null
    }
    foreach ($worktree in @(Get-ManagedAppWorktrees -Config $Config)) {
        $targets.Add((Join-Path $Root $worktree.RelativePath)) | Out-Null
    }

    $targets.ToArray()
}

function Get-ExpectedSharedHooksPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    [System.IO.Path]::GetFullPath((Join-Path $Root 'repos\eMule-tooling\hooks'))
}

function Get-AnalysisRepos {
    param([Parameter(Mandatory = $true)][hashtable]$Config)

    @($Config.AnalysisRepos)
}

function Get-AnalysisCompareRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [hashtable]$Repo
    )

    $repoPath = Get-RepoPath -Root $Root -Repo $Repo
    $compareSubdir = if ($Repo.ContainsKey('CompareSubdir')) { [string]$Repo.CompareSubdir } else { '' }
    if ([string]::IsNullOrWhiteSpace($compareSubdir)) {
        return $repoPath
    }

    return Join-Path $repoPath $compareSubdir
}

function Get-LocalVariantCompareTargets {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    $targets = @()
    foreach ($worktree in @(Get-ManagedAppWorktrees -Config $Config)) {
        $targetName = 'local-072-{0}' -f $worktree.Name
        $targetPath = Join-Path $Root ($worktree.RelativePath + '\srchybrid')
        $targets += [pscustomobject]@{
            Name = $targetName
            Path = $targetPath
        }
    }

    return @($targets)
}

function Get-LocalVariantTargetMap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    $map = @{}
    foreach ($target in Get-LocalVariantCompareTargets -Root $Root -Config $Config) {
        $map[$target.Name] = $target
    }

    $map
}

function Get-WinMergePath {
    foreach ($candidate in @(
        'C:\Program Files\WinMerge\WinMergeU.exe'
        'C:\Program Files (x86)\WinMerge\WinMergeU.exe'
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    $command = Get-Command 'WinMergeU.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) {
        return $command.Source
    }

    throw 'WinMergeU.exe was not found. Install WinMerge or add it to PATH.'
}

function Get-CompareRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $localTargets = Get-LocalVariantTargetMap -Root $Root -Config $Config
    if ($localTargets.ContainsKey($Name)) {
        return $localTargets[$Name].Path
    }

    $repo = @(Get-AnalysisRepos -Config $Config | Where-Object { $_.Name -eq $Name } | Select-Object -First 1)[0]
    if ($null -eq $repo) {
        throw "Unknown compare target: $Name"
    }

    return Get-AnalysisCompareRoot -Root $Root -Repo $repo
}

function New-ComparePreset {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,

        [Parameter(Mandatory = $true)]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [string]$Category,

        [Parameter(Mandatory = $true)]
        [string]$LeftName,

        [Parameter(Mandatory = $true)]
        [string]$RightName
    )

    [pscustomobject]@{
        Key = $Key
        Label = $Label
        Category = $Category
        LeftName = $LeftName
        RightName = $RightName
    }
}

function Get-ComparePresets {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    $presets = @()
    $localTargetNames = @((Get-LocalVariantCompareTargets -Root $Root -Config $Config).Name)

    foreach ($right in $localTargetNames) {
        $presets += New-ComparePreset -Key ("emuleai-vs-{0}" -f $right) -Label ("eMuleAI vs {0}" -f $right) -Category 'eMuleAI vs local' -LeftName 'emuleai' -RightName $right
        $presets += New-ComparePreset -Key ("community-060-vs-{0}" -f $right) -Label ("Community 0.60 vs {0}" -f $right) -Category 'Community 0.60 vs local' -LeftName 'community-0.60' -RightName $right
        $presets += New-ComparePreset -Key ("community-072-vs-{0}" -f $right) -Label ("Community 0.72 vs {0}" -f $right) -Category 'Community 0.72 vs local' -LeftName 'community-0.72' -RightName $right
        $presets += New-ComparePreset -Key ("mods-archive-vs-{0}" -f $right) -Label ("Mods archive vs {0}" -f $right) -Category 'Mods Archive' -LeftName 'mods-archive' -RightName $right
        $presets += New-ComparePreset -Key ("stale-experimental-clean-vs-{0}" -f $right) -Label ("Stale experimental clean vs {0}" -f $right) -Category 'Stale experimental reference' -LeftName 'stale-v0.72a-experimental-clean' -RightName $right
    }

    return @($presets)
}

function Invoke-ComparePreset {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        $Preset
    )

    $winMergePath = Get-WinMergePath
    $leftPath = Get-CompareRoot -Root $Root -Config $Config -Name $Preset.LeftName
    $rightPath = Get-CompareRoot -Root $Root -Config $Config -Name $Preset.RightName

    foreach ($target in @(
        [pscustomobject]@{ Name = $Preset.LeftName; Path = $leftPath }
        [pscustomobject]@{ Name = $Preset.RightName; Path = $rightPath }
    )) {
        if (-not (Test-Path -LiteralPath $target.Path)) {
            throw "Compare target path missing for $($target.Name): $($target.Path)"
        }
    }

    Start-Process -FilePath $winMergePath -ArgumentList @($leftPath, $rightPath) | Out-Null
}

function Write-CompareLauncher {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$PresetKey,

        [Parameter(Mandatory = $true)]
        [string]$WorkspaceScriptPath,

        [Parameter(Mandatory = $true)]
        [string]$WorkspaceRoot
    )

    $content = @(
        '@ECHO OFF'
        'pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" compare "{1}" -EmuleWorkspaceRoot "{2}"' -f $WorkspaceScriptPath, $PresetKey, $WorkspaceRoot
    )

    Set-Content -LiteralPath $Path -Value $content -Encoding ascii
}

function Write-CompareMenuLauncher {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$WorkspaceScriptPath,

        [Parameter(Mandatory = $true)]
        [string]$WorkspaceRoot,

        [string]$Key
    )

    $argumentSuffix = if ([string]::IsNullOrWhiteSpace($Key)) { '' } else { ' "{0}"' -f $Key }
    $content = @(
        '@ECHO OFF'
        'pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" compare{1} -EmuleWorkspaceRoot "{2}"' -f $WorkspaceScriptPath, $argumentSuffix, $WorkspaceRoot
    )

    Set-Content -LiteralPath $Path -Value $content -Encoding ascii
}

function Get-CompareOutputRoot {
    param([Parameter(Mandatory = $true)][string]$Root)

    Join-Path $Root 'analysis\compare'
}

function Write-CompareLaunchers {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    $compareRoot = Get-CompareOutputRoot -Root $Root
    $modsRoot = Join-Path $compareRoot 'mods-archive'
    $workspaceScriptPath = Join-Path (Get-ScriptRoot) 'workspace.ps1'

    Ensure-Directory -Path (Join-Path $Root 'analysis')
    Ensure-Directory -Path $compareRoot
    Ensure-Directory -Path $modsRoot

    Write-CompareMenuLauncher -Path (Join-Path $compareRoot 'open-compare-menu.cmd') -WorkspaceScriptPath $workspaceScriptPath -WorkspaceRoot $Root
    Write-CompareMenuLauncher -Path (Join-Path $modsRoot 'open-mods-archive-menu.cmd') -WorkspaceScriptPath $workspaceScriptPath -WorkspaceRoot $Root -Key 'mods-archive'

    foreach ($preset in Get-ComparePresets -Root $Root -Config $Config) {
        $destinationRoot = if ($preset.Category -eq 'Mods Archive') { $modsRoot } else { $compareRoot }
        Write-CompareLauncher -Path (Join-Path $destinationRoot ('{0}.cmd' -f $preset.Key)) -PresetKey $preset.Key -WorkspaceScriptPath $workspaceScriptPath -WorkspaceRoot $Root
    }
}

function Show-CompareMenu {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [string]$Category
    )

    $presets = @(Get-ComparePresets -Root $Root -Config $Config)
    if (-not [string]::IsNullOrWhiteSpace($Category)) {
        $presets = @($presets | Where-Object { $_.Category -eq $Category })
    }

    if ($presets.Count -eq 0) {
        throw 'No compare presets are available.'
    }

    while ($true) {
        Write-Host ''
        Write-Host 'WinMerge compare presets'

        $index = 1
        foreach ($preset in $presets) {
            Write-Host ('{0}. [{1}] {2}' -f $index, $preset.Category, $preset.Label)
            $index++
        }

        Write-Host ('{0}. exit' -f $index)
        Write-Host ''

        $choice = Read-Host 'Select a compare preset'
        if ($choice -eq [string]$index) {
            return
        }

        $selected = 0
        if ([int]::TryParse($choice, [ref]$selected) -and $selected -ge 1 -and $selected -lt $index) {
            Invoke-ComparePreset -Root $Root -Config $Config -Preset $presets[$selected - 1]
            return
        }

        Write-Warning ('Choose 1-{0}.' -f $index)
    }
}

function Invoke-Compare {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [string]$Key
    )

    Write-CompareLaunchers -Root $Root -Config $Config

    if ([string]::IsNullOrWhiteSpace($Key)) {
        Show-CompareMenu -Root $Root -Config $Config
        return
    }

    if ($Key -eq 'mods-archive') {
        Show-CompareMenu -Root $Root -Config $Config -Category 'Mods Archive'
        return
    }

    $preset = @(Get-ComparePresets -Root $Root -Config $Config | Where-Object { $_.Key -eq $Key } | Select-Object -First 1)[0]
    if ($null -eq $preset) {
        throw "Unknown compare preset: $Key"
    }

    Invoke-ComparePreset -Root $Root -Config $Config -Preset $preset
}

function Ensure-RequiredTools {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('None', 'User')]
        [string]$PersistMode
    )

    $toolCandidates = @(
        @{ Name = 'pwsh'; Executable = 'pwsh.exe'; Directory = 'C:\Program Files\PowerShell\7' }
        @{ Name = 'git'; Executable = 'git.exe'; Directory = 'C:\Program Files\Git\cmd' }
        @{ Name = 'gh'; Executable = 'gh.exe'; Directory = 'C:\Program Files\GitHub CLI' }
        @{ Name = 'cmake'; Executable = 'cmake.exe'; Directory = 'C:\Program Files\Microsoft Visual Studio\18\Professional\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin' }
    )

    foreach ($tool in $toolCandidates) {
        $resolved = Get-Command $tool.Name -ErrorAction SilentlyContinue
        if ($resolved) {
            continue
        }

        if (-not (Test-Path -LiteralPath (Join-Path $tool.Directory $tool.Executable) -PathType Leaf)) {
            throw "Required tool '$($tool.Name)' is not available on PATH and no fallback was found."
        }

        if ($env:PATH -notlike "*$($tool.Directory)*") {
            $env:PATH = '{0};{1}' -f $env:PATH, $tool.Directory
            if ($PersistMode -eq 'User') {
                $currentUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
                if ($currentUserPath -notlike "*$($tool.Directory)*") {
                    [Environment]::SetEnvironmentVariable('Path', ('{0};{1}' -f $currentUserPath.TrimEnd(';'), $tool.Directory), 'User')
                }
            }
        }
    }
}

function Ensure-RepoClone {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [hashtable]$Repo
    )

    $repoPath = Get-RepoPath -Root $Root -Repo $Repo
    Ensure-Directory -Path (Split-Path -Parent $repoPath)

    if (-not (Test-Path -LiteralPath $repoPath -PathType Container)) {
        $cloneArgs = @('clone')
        if ($Repo.ContainsKey('HasSubmodules') -and $Repo.HasSubmodules) {
            $cloneArgs += '--recurse-submodules'
        }
        if (-not ($Repo.ContainsKey('BranchOptional') -and $Repo.BranchOptional)) {
            $cloneArgs += @('--branch', $Repo.Branch)
        }
        $cloneArgs += @($Repo.Url, $repoPath)
        Invoke-Checked -FilePath 'git' -ArgumentList $cloneArgs
        Ensure-RepoAdditionalRemotes -RepoPath $repoPath -Repo $Repo
        return $repoPath
    }

    Invoke-Checked -FilePath 'git' -ArgumentList @('-C', $repoPath, 'fetch', 'origin', '--prune')
    Ensure-RepoAdditionalRemotes -RepoPath $repoPath -Repo $Repo
    if (-not $Repo.ContainsKey('Worktrees')) {
        Invoke-Checked -FilePath 'git' -ArgumentList @('-C', $repoPath, 'checkout', $Repo.Branch)
        Invoke-Checked -FilePath 'git' -ArgumentList @('-C', $repoPath, 'pull', '--ff-only', 'origin', $Repo.Branch)
    }
    if ($Repo.ContainsKey('HasSubmodules') -and $Repo.HasSubmodules) {
        Invoke-Checked -FilePath 'git' -ArgumentList @('-C', $repoPath, 'submodule', 'update', '--init', '--recursive')
    }
    return $repoPath
}

function Ensure-RootLayout {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [string]$WorkspaceName
    )

    Ensure-Directory -Path $Root
    foreach ($relativePath in @($Config.RootDirectories)) {
        Ensure-Directory -Path (Join-Path $Root $relativePath)
    }

    $workspaceRoot = Get-WorkspaceRoot -Root $Root -WorkspaceName $WorkspaceName
    foreach ($relativePath in @('app', 'artifacts', 'logs', 'scripts', 'state')) {
        Ensure-Directory -Path (Join-Path $workspaceRoot $relativePath)
    }
}

function Assert-MaterializeBootstrapRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return
    }

    if (Test-DirectoryEmpty -Path $Root) {
        return
    }

    throw ("Materialize expects a new empty workspace root. Refusing to use existing populated root '{0}'. Use status, validate, or sync for an existing workspace." -f $Root)
}

function Ensure-AppBranches {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoPath,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    foreach ($worktree in @(Get-ManagedAppWorktrees -Config $Config)) {
        $branchExists = (& git -C $RepoPath show-ref --verify --quiet ("refs/heads/{0}" -f $worktree.Branch)); $branchExitCode = $LASTEXITCODE
        if ($branchExitCode -eq 0) {
            continue
        }

        Invoke-Checked -FilePath 'git' -ArgumentList @('-C', $RepoPath, 'fetch', 'origin', ("refs/heads/{0}:refs/remotes/origin/{0}" -f $worktree.Branch))
        $branchExists = (& git -C $RepoPath show-ref --verify --quiet ("refs/heads/{0}" -f $worktree.Branch)); $branchExitCode = $LASTEXITCODE
        if ($branchExitCode -ne 0) {
            Invoke-Checked -FilePath 'git' -ArgumentList @('-C', $RepoPath, 'branch', '--track', $worktree.Branch, ("origin/{0}" -f $worktree.Branch))
        }
    }
}

function Ensure-AppAnchorCheckout {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoPath,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    $currentBranchOutput = & git -C $RepoPath branch --show-current
    $currentBranch = if ([string]::IsNullOrWhiteSpace($currentBranchOutput)) { '' } else { $currentBranchOutput.Trim() }
    if ($currentBranch -ne $Config.AppRepo.Branch) {
        return
    }

    Invoke-Checked -FilePath 'git' -ArgumentList @('-C', $RepoPath, 'checkout', '--detach', ("refs/remotes/origin/{0}" -f $Config.AppRepo.Branch))
}

function Ensure-AppWorktrees {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    $repoPath = Get-RepoPath -Root $Root -Repo $Config.AppRepo
    Ensure-AppBranches -RepoPath $repoPath -Config $Config
    Ensure-AppAnchorCheckout -RepoPath $repoPath -Config $Config

    foreach ($worktree in @(Get-ManagedAppWorktrees -Config $Config)) {
        $targetPath = Join-Path $Root $worktree.RelativePath
        Ensure-Directory -Path (Split-Path -Parent $targetPath)

        if (-not (Test-Path -LiteralPath $targetPath -PathType Container)) {
            Invoke-Checked -FilePath 'git' -ArgumentList @('-C', $repoPath, 'worktree', 'add', $targetPath, $worktree.Branch)
        } else {
            Invoke-Checked -FilePath 'git' -ArgumentList @('-C', $targetPath, 'fetch', 'origin', '--prune')
            Invoke-Checked -FilePath 'git' -ArgumentList @('-C', $targetPath, 'checkout', $worktree.Branch)
            $isDirty = -not [string]::IsNullOrWhiteSpace((& git -C $targetPath status --short))
            if ($isDirty) {
                Write-Warning "Worktree '$targetPath' is dirty; skipping fast-forward for managed branch '$($worktree.Branch)'."
                continue
            }
            $remoteBranch = "refs/remotes/origin/{0}" -f $worktree.Branch
            & git -C $targetPath show-ref --verify --quiet $remoteBranch
            if ($LASTEXITCODE -eq 0) {
                Invoke-Checked -FilePath 'git' -ArgumentList @('-C', $targetPath, 'merge', '--ff-only', $remoteBranch)
            }
        }
    }
}

function Remove-ReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function Remove-LegacyAppDependencyLinks {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    foreach ($worktree in @(Get-ManagedAppWorktrees -Config $Config)) {
        $worktreeRoot = Join-Path $Root $worktree.RelativePath
        foreach ($name in @('cryptopp', 'id3lib', 'mbedtls', 'miniupnpc', 'ResizableLib', 'zlib')) {
            Remove-ReparsePoint -Path (Join-Path $worktreeRoot $name)
        }
    }
}

function Write-WorkspaceProps {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    $propsPath = Get-WorkspacePropsPath -Root $Root -Config $Config
    $content = @'
<?xml version="1.0" encoding="utf-8"?>
<Project ToolsVersion="Current" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup>
    <WorkspaceRoot>$([MSBuild]::EnsureTrailingSlash('$(WorkspaceRoot)'))</WorkspaceRoot>
    <ReposRoot>$(WorkspaceRoot)repos\</ReposRoot>
    <ThirdPartyRoot>$(ReposRoot)third_party\</ThirdPartyRoot>
    <NlohmannJsonRoot>$(ThirdPartyRoot)eMule-nlohmann-json\single_include\</NlohmannJsonRoot>
  </PropertyGroup>
  <ItemDefinitionGroup>
    <ClCompile>
      <AdditionalIncludeDirectories>$(NlohmannJsonRoot);$(ThirdPartyRoot)eMule-cryptopp;$(ThirdPartyRoot)eMule-ResizableLib;$(ThirdPartyRoot)eMule-zlib;$(ThirdPartyRoot)eMule-miniupnp;%(AdditionalIncludeDirectories)</AdditionalIncludeDirectories>
    </ClCompile>
  </ItemDefinitionGroup>
</Project>
'@
    Set-Content -LiteralPath $propsPath -Value $content -Encoding utf8
}

function Write-WorkspaceManifest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [string]$WorkspaceName
    )

    $workspaceRoot = Get-WorkspaceRoot -Root $Root -WorkspaceName $WorkspaceName
    $manifestPath = Join-Path $workspaceRoot 'deps.psd1'
    $manifest = New-ExpectedWorkspaceManifestContract -Root $Root -Config $Config -WorkspaceName $WorkspaceName
    $variantLines = foreach ($variant in @($manifest.Workspace.AppRepo.Variants)) {
        "                @{{ Name = '{0}'; Path = '{1}'; Branch = '{2}' }}" -f $variant.Name, $variant.Path, $variant.Branch
    }
    $content = @"
@{
    EmuleWorkspaceRoot = '$($manifest.EmuleWorkspaceRoot)'
    Workspace = @{
        Name = '$($manifest.Workspace.Name)'
        AppRepo = @{
            SeedRepo = @{
                Name = '$($manifest.Workspace.AppRepo.SeedRepo.Name)'
                Path = '$($manifest.Workspace.AppRepo.SeedRepo.Path)'
                Branch = '$($manifest.Workspace.AppRepo.SeedRepo.Branch)'
            }
            Variants = @(
$($variantLines -join "`r`n")
            )
        }
        Repos = @{
            Build = '$($manifest.Workspace.Repos.Build)'
            Tests = '$($manifest.Workspace.Repos.Tests)'
            Tooling = '$($manifest.Workspace.Repos.Tooling)'
            Amutorrent = '$($manifest.Workspace.Repos.Amutorrent)'
            ThirdParty = '$($manifest.Workspace.Repos.ThirdParty)'
        }
    }
}
"@
    Set-Content -LiteralPath $manifestPath -Value $content -Encoding utf8
}

function Normalize-WorkspaceContractPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = $Path.Trim() -replace '/', '\'
    while ($normalized.StartsWith('.\')) {
        $normalized = $normalized.Substring(2)
    }

    return $normalized
}

function Get-WorkspaceContractRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath,

        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    return Normalize-WorkspaceContractPath -Path ([System.IO.Path]::GetRelativePath($BasePath, $TargetPath))
}

function Get-RequiredContractValue {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Table,

        [Parameter(Mandatory = $true)]
        [string]$Key,

        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    if (-not $Table.ContainsKey($Key)) {
        throw "Workspace manifest contract is missing '$Context.$Key'."
    }

    return $Table[$Key]
}

function New-ExpectedWorkspaceManifestContract {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [string]$WorkspaceName
    )

    $workspaceRoot = Get-WorkspaceRoot -Root $Root -WorkspaceName $WorkspaceName
    $seedRepoPath = Get-RepoPath -Root $Root -Repo $Config.AppRepo
    $namedRepos = @{}
    foreach ($repo in @($Config.Repos)) {
        $namedRepos[[string]$repo.Name] = $repo
    }

    $expectedRepos = [ordered]@{}
    foreach ($entry in @(
        @{ ContractKey = 'Build'; RepoName = 'eMule-build' }
        @{ ContractKey = 'Tests'; RepoName = 'eMule-build-tests' }
        @{ ContractKey = 'Tooling'; RepoName = 'eMule-tooling' }
        @{ ContractKey = 'Amutorrent'; RepoName = 'amutorrent' }
    )) {
        if (-not $namedRepos.ContainsKey($entry.RepoName)) {
            throw "Setup config is missing repo '$($entry.RepoName)' required for the workspace manifest contract."
        }

        $expectedRepos[$entry.ContractKey] = Get-WorkspaceContractRelativePath -BasePath $workspaceRoot -TargetPath (Get-RepoPath -Root $Root -Repo $namedRepos[$entry.RepoName])
    }
    $expectedRepos['ThirdParty'] = Get-WorkspaceContractRelativePath -BasePath $workspaceRoot -TargetPath (Join-Path $Root 'repos\third_party')

    $expectedVariants = foreach ($worktree in @(Get-ManagedAppWorktrees -Config $Config)) {
        [ordered]@{
            Name = [string]$worktree.Name
            Path = Get-WorkspaceContractRelativePath -BasePath $workspaceRoot -TargetPath (Join-Path $Root $worktree.RelativePath)
            Branch = [string]$worktree.Branch
        }
    }

    [ordered]@{
        EmuleWorkspaceRoot = Get-WorkspaceContractRelativePath -BasePath $workspaceRoot -TargetPath $Root
        Workspace = [ordered]@{
            Name = $WorkspaceName
            AppRepo = [ordered]@{
                SeedRepo = [ordered]@{
                    Name = [string]$Config.AppRepo.Name
                    Path = Get-WorkspaceContractRelativePath -BasePath $workspaceRoot -TargetPath $seedRepoPath
                    Branch = [string]$Config.AppRepo.Branch
                }
                Variants = @($expectedVariants)
            }
            Repos = $expectedRepos
        }
    }
}

function ConvertTo-NormalizedWorkspaceManifestContract {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Manifest
    )

    $workspace = Get-RequiredContractValue -Table $Manifest -Key 'Workspace' -Context 'manifest'
    $appRepo = Get-RequiredContractValue -Table $workspace -Key 'AppRepo' -Context 'manifest.Workspace'
    $seedRepo = Get-RequiredContractValue -Table $appRepo -Key 'SeedRepo' -Context 'manifest.Workspace.AppRepo'
    $repos = Get-RequiredContractValue -Table $workspace -Key 'Repos' -Context 'manifest.Workspace'
    $variants = @(Get-RequiredContractValue -Table $appRepo -Key 'Variants' -Context 'manifest.Workspace.AppRepo')

    $normalizedVariants = foreach ($variant in $variants) {
        [ordered]@{
            Name = [string](Get-RequiredContractValue -Table $variant -Key 'Name' -Context 'manifest.Workspace.AppRepo.Variants[]')
            Path = Normalize-WorkspaceContractPath -Path ([string](Get-RequiredContractValue -Table $variant -Key 'Path' -Context 'manifest.Workspace.AppRepo.Variants[]'))
            Branch = [string](Get-RequiredContractValue -Table $variant -Key 'Branch' -Context 'manifest.Workspace.AppRepo.Variants[]')
        }
    }

    [ordered]@{
        EmuleWorkspaceRoot = Normalize-WorkspaceContractPath -Path ([string](Get-RequiredContractValue -Table $Manifest -Key 'EmuleWorkspaceRoot' -Context 'manifest'))
        Workspace = [ordered]@{
            Name = [string](Get-RequiredContractValue -Table $workspace -Key 'Name' -Context 'manifest.Workspace')
            AppRepo = [ordered]@{
                SeedRepo = [ordered]@{
                    Name = [string](Get-RequiredContractValue -Table $seedRepo -Key 'Name' -Context 'manifest.Workspace.AppRepo.SeedRepo')
                    Path = Normalize-WorkspaceContractPath -Path ([string](Get-RequiredContractValue -Table $seedRepo -Key 'Path' -Context 'manifest.Workspace.AppRepo.SeedRepo'))
                    Branch = [string](Get-RequiredContractValue -Table $seedRepo -Key 'Branch' -Context 'manifest.Workspace.AppRepo.SeedRepo')
                }
                Variants = @($normalizedVariants)
            }
            Repos = [ordered]@{
                Build = Normalize-WorkspaceContractPath -Path ([string](Get-RequiredContractValue -Table $repos -Key 'Build' -Context 'manifest.Workspace.Repos'))
                Tests = Normalize-WorkspaceContractPath -Path ([string](Get-RequiredContractValue -Table $repos -Key 'Tests' -Context 'manifest.Workspace.Repos'))
                Tooling = Normalize-WorkspaceContractPath -Path ([string](Get-RequiredContractValue -Table $repos -Key 'Tooling' -Context 'manifest.Workspace.Repos'))
                Amutorrent = Normalize-WorkspaceContractPath -Path ([string](Get-RequiredContractValue -Table $repos -Key 'Amutorrent' -Context 'manifest.Workspace.Repos'))
                ThirdParty = Normalize-WorkspaceContractPath -Path ([string](Get-RequiredContractValue -Table $repos -Key 'ThirdParty' -Context 'manifest.Workspace.Repos'))
            }
        }
    }
}

function Assert-WorkspaceManifestContract {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [string]$WorkspaceName
    )

    $workspaceRoot = Get-WorkspaceRoot -Root $Root -WorkspaceName $WorkspaceName
    $manifestPath = Join-Path $workspaceRoot 'deps.psd1'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Workspace manifest contract is missing: $manifestPath"
    }

    $actualManifest = ConvertTo-NormalizedWorkspaceManifestContract -Manifest (Import-PowerShellDataFile -LiteralPath $manifestPath)
    $expectedManifest = New-ExpectedWorkspaceManifestContract -Root $Root -Config $Config -WorkspaceName $WorkspaceName

    $actualJson = $actualManifest | ConvertTo-Json -Depth 8 -Compress
    $expectedJson = $expectedManifest | ConvertTo-Json -Depth 8 -Compress
    if ($actualJson -ne $expectedJson) {
        throw @"
Workspace manifest contract drift detected: $manifestPath
Regenerate it with:
  pwsh -File .\workspace.ps1 sync -EmuleWorkspaceRoot $Root

Expected: $expectedJson
Actual:   $actualJson
"@
    }
}

function Overlay-SeedArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [string]$SeedRoot
    )

    if ([string]::IsNullOrWhiteSpace($SeedRoot)) {
        return
    }

    $resolvedSeedRoot = [System.IO.Path]::GetFullPath($SeedRoot)
    if (-not (Test-Path -LiteralPath $resolvedSeedRoot -PathType Container)) {
        throw "Artifacts seed root '$resolvedSeedRoot' does not exist."
    }

    foreach ($repo in @($Config.ThirdPartyRepos)) {
        $sourcePath = Join-Path $resolvedSeedRoot $repo.Name
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
            continue
        }

        $destinationPath = Get-RepoPath -Root $Root -Repo $repo
        Invoke-RobocopyMirror -SourcePath $sourcePath -DestinationPath $destinationPath
    }
}

function Remove-LegacyAppWorktrees {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    $managedWorktreePaths = @(Get-ManagedAppWorktrees -Config $Config | ForEach-Object { [System.IO.Path]::GetFullPath((Join-Path $Root $_.RelativePath)) })
    if ($managedWorktreePaths.Count -eq 0) {
        return
    }

    $appRoot = Split-Path -Parent $managedWorktreePaths[0]
    if (-not (Test-Path -LiteralPath $appRoot -PathType Container)) {
        return
    }

    $repoPath = Get-RepoPath -Root $Root -Repo $Config.AppRepo
    foreach ($entry in Get-ChildItem -LiteralPath $appRoot -Directory -Force) {
        $fullPath = [System.IO.Path]::GetFullPath($entry.FullName)
        if ($managedWorktreePaths -contains $fullPath) {
            continue
        }

        $gitMetadataPath = Join-Path $fullPath '.git'
        if (Test-Path -LiteralPath $gitMetadataPath) {
            Invoke-Checked -FilePath 'git' -ArgumentList @('-C', $repoPath, 'worktree', 'remove', '--force', $fullPath)
            continue
        }

        Remove-Item -LiteralPath $fullPath -Recurse -Force
    }

    Invoke-Checked -FilePath 'git' -ArgumentList @('-C', $repoPath, 'worktree', 'prune')
}

function Get-RepoStatusObject {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoPath,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $branchOutput = & git -C $RepoPath branch --show-current
    $branch = if ([string]::IsNullOrWhiteSpace($branchOutput)) { '' } else { $branchOutput.Trim() }
    if ([string]::IsNullOrWhiteSpace($branch)) {
        $branch = '(detached)'
    }

    $headOutput = & git -C $RepoPath rev-parse HEAD
    $head = if ([string]::IsNullOrWhiteSpace($headOutput)) { '(unknown)' } else { $headOutput.Trim() }

    $statusOutput = & git -C $RepoPath status --short

    [pscustomobject]@{
        Name = $Name
        Path = $RepoPath
        Branch = $branch
        Head = $head
        Dirty = -not [string]::IsNullOrWhiteSpace($statusOutput)
    }
}

function Install-WorkspaceHooks {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    $installerPath = Join-Path (Get-RepoPath -Root $Root -Repo ($Config.Repos | Where-Object { $_.Name -eq 'eMule-tooling' } | Select-Object -First 1)) 'helpers\install-editorconfig-hook.ps1'
    if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
        throw "Missing shared hook installer: $installerPath"
    }

    foreach ($targetPath in @(Get-HookInstallTargets -Root $Root -Config $Config)) {
        if (-not (Test-Path -LiteralPath $targetPath -PathType Container)) {
            throw "Missing hook install target: $targetPath"
        }

        Invoke-Checked -FilePath 'pwsh' -ArgumentList @(
            '-NoLogo',
            '-NoProfile',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            $installerPath,
            '-RepoRoot',
            $targetPath
        )
    }
}

function Assert-WorkspaceHooksInstalled {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    $expectedHooksPath = Get-ExpectedSharedHooksPath -Root $Root
    $sharedPreCommitPath = Join-Path $expectedHooksPath 'pre-commit'
    if (-not (Test-Path -LiteralPath $sharedPreCommitPath -PathType Leaf)) {
        throw "Shared pre-commit hook is missing: $sharedPreCommitPath"
    }

    foreach ($targetPath in @(Get-HookInstallTargets -Root $Root -Config $Config)) {
        if (-not (Test-Path -LiteralPath $targetPath -PathType Container)) {
            throw "Missing hook validation target: $targetPath"
        }

        $hooksPathOutput = & git -C $targetPath config --local --get core.hooksPath 2>$null
        $exitCode = $LASTEXITCODE
        $hooksPath = if ($exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($hooksPathOutput)) {
            [System.IO.Path]::GetFullPath($hooksPathOutput.Trim())
        } else {
            ''
        }

        if ($hooksPath -ne $expectedHooksPath) {
            throw "Hook path drift detected for '$targetPath'. Expected core.hooksPath '$expectedHooksPath'."
        }

        $resolvedHooksPathOutput = & git -C $targetPath rev-parse --git-path hooks 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($resolvedHooksPathOutput)) {
            throw "Unable to resolve git hooks path for '$targetPath'."
        }

        $resolvedHooksPath = [System.IO.Path]::GetFullPath($resolvedHooksPathOutput.Trim())
        if ($resolvedHooksPath -ne $expectedHooksPath) {
            throw "Resolved hooks path drift detected for '$targetPath'. Expected '$expectedHooksPath', found '$resolvedHooksPath'."
        }

        $autocrlfOutput = & git -C $targetPath config --local --get core.autocrlf 2>$null
        $autocrlf = if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($autocrlfOutput)) {
            $autocrlfOutput.Trim()
        } else {
            ''
        }

        if ($autocrlf -ne 'false') {
            throw "Line-ending config drift detected for '$targetPath'. Expected core.autocrlf false."
        }
    }
}

function Invoke-Init {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [string]$WorkspaceName,

        [string]$SeedRoot
    )

    Ensure-RootLayout -Root $Root -Config $Config -WorkspaceName $WorkspaceName
    foreach ($repo in Get-AllRepoConfigs -Config $Config) {
        $repoPath = Ensure-RepoClone -Root $Root -Repo $repo
        Write-Log -Root $Root -Config $Config -Message ("Repo ready: {0} [{1}]" -f $repo.Name, $repoPath)
    }
    Overlay-SeedArtifacts -Root $Root -Config $Config -SeedRoot $SeedRoot
    Write-WorkspaceProps -Root $Root -Config $Config
    Write-WorkspaceManifest -Root $Root -Config $Config -WorkspaceName $WorkspaceName
    Write-CompareLaunchers -Root $Root -Config $Config
}

function Invoke-Materialize {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [string]$WorkspaceName,

        [string]$SeedRoot
    )

    Assert-MaterializeBootstrapRoot -Root $Root
    Invoke-Init -Root $Root -Config $Config -WorkspaceName $WorkspaceName -SeedRoot $SeedRoot
    Ensure-AppWorktrees -Root $Root -Config $Config
    Remove-LegacyAppWorktrees -Root $Root -Config $Config
    Remove-LegacyAppDependencyLinks -Root $Root -Config $Config
    Write-CompareLaunchers -Root $Root -Config $Config
    Install-WorkspaceHooks -Root $Root -Config $Config
    Set-WorkspaceRootEnvironment -Root $Root
    $legacyStatusPath = Join-Path (Get-WorkspaceRoot -Root $Root -WorkspaceName $WorkspaceName) 'state\EMULE-STATUS.md'
    if (Test-Path -LiteralPath $legacyStatusPath -PathType Leaf) {
        Remove-Item -LiteralPath $legacyStatusPath -Force
    }
    Write-Log -Root $Root -Config $Config -Message 'Materialize complete.'
}

function Invoke-Status {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    foreach ($repo in Get-AllRepoConfigs -Config $Config) {
        $repoPath = Get-RepoPath -Root $Root -Repo $repo
        if (-not (Test-Path -LiteralPath $repoPath -PathType Container)) {
            Write-Host ("[missing] {0} -> {1}" -f $repo.Name, $repoPath)
            continue
        }

        $status = Get-RepoStatusObject -RepoPath $repoPath -Name $repo.Name
        Write-Host ("[{0}] {1} @ {2} dirty={3}" -f $status.Name, $status.Branch, $status.Head, $status.Dirty)
    }
}

function Invoke-DepUpdates {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [string]$WorkspaceName
    )

    $workspaceRoot = Get-WorkspaceRoot -Root $Root -WorkspaceName $WorkspaceName
    if (-not (Test-Path -LiteralPath $workspaceRoot -PathType Container)) {
        throw "Workspace root is missing: $workspaceRoot. Run init, materialize, or sync first."
    }

    $entries = Get-DepUpdateEntries -Root $Root -Config $Config
    $artifacts = Write-DepUpdateArtifacts -Root $Root -WorkspaceName $WorkspaceName -Entries $entries
    Write-DepUpdateConsoleReport -Entries $entries -SummaryPath $artifacts.SummaryPath

    if ($artifacts.Counts.error -gt 0 -or $artifacts.ChildComponentCounts.error -gt 0) {
        throw "Dependency update report completed with errors. See $($artifacts.SummaryPath)."
    }
}

function Invoke-Validate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [string]$WorkspaceName
    )

    $workspaceRoot = Get-WorkspaceRoot -Root $Root -WorkspaceName $WorkspaceName
    $requiredPaths = @(
        $workspaceRoot
        (Join-Path $workspaceRoot 'deps.psd1')
        (Get-WorkspacePropsPath -Root $Root -Config $Config)
    )
    foreach ($worktree in @(Get-ManagedAppWorktrees -Config $Config)) {
        $requiredPaths += (Join-Path $Root $worktree.RelativePath)
    }

    foreach ($repo in Get-AllRepoConfigs -Config $Config) {
        $requiredPaths += (Get-RepoPath -Root $Root -Repo $repo)
    }
    $requiredPaths += (Get-CompareOutputRoot -Root $Root)

    $missing = @($requiredPaths | Where-Object { -not (Test-Path -LiteralPath $_) })
    if ($missing.Count -gt 0) {
        throw ("Validation failed. Missing paths:`n{0}" -f ($missing -join [Environment]::NewLine))
    }

    Assert-WorkspaceManifestContract -Root $Root -Config $Config -WorkspaceName $WorkspaceName

    $null = Get-WinMergePath
    foreach ($target in Get-LocalVariantCompareTargets -Root $Root -Config $Config) {
        if (-not (Test-Path -LiteralPath $target.Path)) {
            throw ("Validation failed. Compare target missing: {0} [{1}]" -f $target.Name, $target.Path)
        }
    }
    foreach ($repo in Get-AnalysisRepos -Config $Config) {
        $compareRoot = Get-AnalysisCompareRoot -Root $Root -Repo $repo
        if (-not (Test-Path -LiteralPath $compareRoot)) {
            throw ("Validation failed. Analysis compare target missing: {0} [{1}]" -f $repo.Name, $compareRoot)
        }
    }

    Assert-WorkspaceHooksInstalled -Root $Root -Config $Config

    $buildRepo = @($Config.Repos | Where-Object { $_.Name -eq 'eMule-build' } | Select-Object -First 1)[0]
    if ($null -eq $buildRepo) {
        throw 'Validation failed. eMule-build repo is not configured.'
    }

    $buildWorkspacePath = Join-Path (Get-RepoPath -Root $Root -Repo $buildRepo) 'workspace.ps1'
    if (-not (Test-Path -LiteralPath $buildWorkspacePath -PathType Leaf)) {
        throw "Validation failed. Missing build workspace helper: $buildWorkspacePath"
    }

    Invoke-Checked -FilePath 'pwsh' -ArgumentList @(
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $buildWorkspacePath,
        'validate',
        '-EmuleWorkspaceRoot',
        $Root,
        '-WorkspaceName',
        $WorkspaceName
    )

    Write-Host 'Validation passed.'
}

function Remove-StaleGeneratedArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoPath,

        [Parameter(Mandatory = $true)]
        [ValidateSet('zlib', 'mbedtls')]
        [string]$Kind
    )

    $paths = switch ($Kind) {
        'zlib' { @((Join-Path $RepoPath 'cmake-build-x64')) }
        'mbedtls' { @((Join-Path $RepoPath 'visualc\VS2017-x64'), (Join-Path $RepoPath 'visualc\VS2017\x64')) }
    }

    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }
}

$config = Import-SetupConfig
$resolvedRoot = Resolve-EmuleWorkspaceRoot -Config $config -OverrideRoot $EmuleWorkspaceRoot
$resolvedWorkspaceName = Resolve-WorkspaceName -Config $config -OverrideName $WorkspaceName

switch ($Command) {
    'ensure-path' { Ensure-RequiredTools -PersistMode $Persist; break }
    'sync' {
        Invoke-Init -Root $resolvedRoot -Config $config -WorkspaceName $resolvedWorkspaceName -SeedRoot $ArtifactsSeedRoot
        Ensure-AppWorktrees -Root $resolvedRoot -Config $config
        Install-WorkspaceHooks -Root $resolvedRoot -Config $config
        break
    }
    'init' { Invoke-Init -Root $resolvedRoot -Config $config -WorkspaceName $resolvedWorkspaceName -SeedRoot $ArtifactsSeedRoot; break }
    'materialize' { Invoke-Materialize -Root $resolvedRoot -Config $config -WorkspaceName $resolvedWorkspaceName -SeedRoot $ArtifactsSeedRoot; break }
    'status' { Invoke-Status -Root $resolvedRoot -Config $config; break }
    'dep-updates' { Invoke-DepUpdates -Root $resolvedRoot -Config $config -WorkspaceName $resolvedWorkspaceName; break }
    'validate' { Invoke-Validate -Root $resolvedRoot -Config $config -WorkspaceName $resolvedWorkspaceName; break }
    'compare' { Invoke-Compare -Root $resolvedRoot -Config $config -Key $CompareKey; break }
    default { throw "Unsupported command '$Command'." }
}
