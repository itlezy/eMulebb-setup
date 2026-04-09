#Requires -Version 7.6
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('init', 'materialize', 'status', 'validate', 'sync', 'ensure-path', 'compare')]
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
        $Config.DefaultEmuleWorkspaceRoot
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

function Get-AllRepoConfigs {
    param([Parameter(Mandatory = $true)][hashtable]$Config)

    @($Config.AppRepo) + @($Config.Repos) + @($Config.AnalysisRepos) + @($Config.ThirdPartyRepos)
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
        return $repoPath
    }

    Invoke-Checked -FilePath 'git' -ArgumentList @('-C', $repoPath, 'fetch', 'origin', '--prune')
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
            Invoke-Checked -FilePath 'git' -ArgumentList @('-C', $targetPath, 'merge', '--ff-only', ("refs/remotes/origin/{0}" -f $worktree.Branch))
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

function Get-AppPropertyOverrides {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    @(
        "/p:WorkspaceRoot=$Root\"
        "/p:CryptoPpRoot=$(Join-Path $Root 'repos\third_party\eMule-cryptopp\')"
        "/p:Id3libRoot=$(Join-Path $Root 'repos\third_party\eMule-id3lib\')"
        "/p:MbedTlsRoot=$(Join-Path $Root 'repos\third_party\eMule-mbedtls\')"
        "/p:MiniUpnpRoot=$(Join-Path $Root 'repos\third_party\eMule-miniupnp\')"
        "/p:ResizableLibRoot=$(Join-Path $Root 'repos\third_party\eMule-ResizableLib\')"
        "/p:ZlibRoot=$(Join-Path $Root 'repos\third_party\eMule-zlib\')"
    )
}

function Get-AppBuildMatrix {
    @(
        @{ Configuration = 'Debug'; Platform = 'x64' }
        @{ Configuration = 'Release'; Platform = 'x64' }
        @{ Configuration = 'Debug'; Platform = 'ARM64' }
        @{ Configuration = 'Release'; Platform = 'ARM64' }
    )
}

function Get-TestBuildMatrix {
    @(
        @{ Configuration = 'Debug'; Platform = 'x64' }
        @{ Configuration = 'Release'; Platform = 'x64' }
    )
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
  </PropertyGroup>
  <ItemDefinitionGroup>
    <ClCompile>
      <AdditionalIncludeDirectories>$(ThirdPartyRoot)eMule-cryptopp;$(ThirdPartyRoot)eMule-ResizableLib;$(ThirdPartyRoot)eMule-zlib;$(ThirdPartyRoot)eMule-miniupnp;%(AdditionalIncludeDirectories)</AdditionalIncludeDirectories>
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
    $content = @"
@{
    EmuleWorkspaceRoot = '..\..'
    Workspace = @{
        Name = '$WorkspaceName'
        AppRepo = @{
            SeedRepo = @{
                Name = 'eMule'
                Path = '..\..\repos\eMule'
            }
            Variants = @(
                @{ Name = 'main'; Path = 'app\eMule-main'; Branch = 'main' }
                @{ Name = 'oracle'; Path = 'app\eMule-v0.72a-oracle'; Branch = 'oracle/v0.72a-build' }
                @{ Name = 'bugfix'; Path = 'app\eMule-v0.72a-bugfix'; Branch = 'release/v0.72a-bugfix' }
                @{ Name = 'build'; Path = 'app\eMule-v0.72a-build'; Branch = 'release/v0.72a-build' }
            )
        }
        Repos = @{
            Build = '..\..\repos\eMule-build'
            Tests = '..\..\repos\eMule-build-tests'
            Tooling = '..\..\repos\eMule-tooling'
            Remote = '..\..\repos\eMule-remote'
            ThirdParty = '..\..\repos\third_party'
        }
    }
}
"@
    Set-Content -LiteralPath $manifestPath -Value $content -Encoding utf8
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
    'sync' { Invoke-Init -Root $resolvedRoot -Config $config -WorkspaceName $resolvedWorkspaceName -SeedRoot $ArtifactsSeedRoot; break }
    'init' { Invoke-Init -Root $resolvedRoot -Config $config -WorkspaceName $resolvedWorkspaceName -SeedRoot $ArtifactsSeedRoot; break }
    'materialize' { Invoke-Materialize -Root $resolvedRoot -Config $config -WorkspaceName $resolvedWorkspaceName -SeedRoot $ArtifactsSeedRoot; break }
    'status' { Invoke-Status -Root $resolvedRoot -Config $config; break }
    'validate' { Invoke-Validate -Root $resolvedRoot -Config $config -WorkspaceName $resolvedWorkspaceName; break }
    'compare' { Invoke-Compare -Root $resolvedRoot -Config $config -Key $CompareKey; break }
    default { throw "Unsupported command '$Command'." }
}
