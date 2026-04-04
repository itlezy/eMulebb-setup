[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('init', 'sync', 'status', 'validate', 'materialize', 'ensure-path')]
    [string]$Command,

    [ValidateSet('None', 'User')]
    [string]$Persist = 'None'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-PowerShell7 {
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw 'This helper requires PowerShell 7 or later.'
    }
}

function Get-ScriptRoot {
    return Split-Path -Parent $PSCommandPath
}

function Import-Config {
    $configPath = Join-Path (Get-ScriptRoot) 'repos.psd1'
    return Import-PowerShellDataFile -Path $configPath
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Message
    )

    $targetRoot = $Config.TargetRoot
    if (-not (Test-Path -LiteralPath $targetRoot)) {
        return
    }

    $logPath = Join-Path $targetRoot $Config.LogFileName
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $logPath -Value $line
}

function Get-RepoOwnerAndName {
    param([Parameter(Mandatory)][string]$Url)

    $match = [regex]::Match($Url, 'github\.com[/:](?<owner>[^/]+)/(?<name>[^/.]+)(?:\.git)?$')
    if (-not $match.Success) {
        throw "Unsupported GitHub URL format: $Url"
    }

    return @{
        Owner = $match.Groups['owner'].Value
        Name  = $match.Groups['name'].Value
    }
}

function Split-PathEntries {
    param([string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return @()
    }

    return $PathValue.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries) |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }
}

function Test-PathEntryPresent {
    param(
        [Parameter(Mandatory)][string]$PathValue,
        [Parameter(Mandatory)][string]$Directory
    )

    $normalizedTarget = $Directory.TrimEnd('\')
    foreach ($entry in Split-PathEntries -PathValue $PathValue) {
        if ($entry.TrimEnd('\') -ieq $normalizedTarget) {
            return $true
        }
    }

    return $false
}

function Add-DirectoryToProcessPath {
    param([Parameter(Mandatory)][string]$Directory)

    if (-not (Test-PathEntryPresent -PathValue $env:PATH -Directory $Directory)) {
        $env:PATH = if ([string]::IsNullOrWhiteSpace($env:PATH)) { $Directory } else { '{0};{1}' -f $env:PATH, $Directory }
    }
}

function Add-DirectoryToUserPath {
    param([Parameter(Mandatory)][string]$Directory)

    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not (Test-PathEntryPresent -PathValue $current -Directory $Directory)) {
        $updated = if ([string]::IsNullOrWhiteSpace($current)) { $Directory } else { '{0};{1}' -f $current.TrimEnd(';'), $Directory }
        [Environment]::SetEnvironmentVariable('Path', $updated, 'User')
    }
}

function Get-RequiredTools {
    return @(
        [pscustomobject]@{
            Name          = 'pwsh'
            Executable    = 'pwsh.exe'
            CandidateDirs = @('C:\Program Files\PowerShell\7')
        }
        [pscustomobject]@{
            Name          = 'git'
            Executable    = 'git.exe'
            CandidateDirs = @('C:\Program Files\Git\cmd')
        }
        [pscustomobject]@{
            Name          = 'gh'
            Executable    = 'gh.exe'
            CandidateDirs = @('C:\Program Files\GitHub CLI')
        }
        [pscustomobject]@{
            Name          = 'cmake'
            Executable    = 'cmake.exe'
            CandidateDirs = @(
                'C:\Program Files\Microsoft Visual Studio\18\Professional\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin'
            )
        }
    )
}

function Resolve-ToolStatus {
    param([Parameter(Mandatory)]$Tool)

    $command = Get-Command $Tool.Name -ErrorAction SilentlyContinue
    $foundOnPath = $null -ne $command
    $resolvedPath = if ($foundOnPath) { $command.Source } else { $null }
    $candidateDir = $null

    if (-not $foundOnPath) {
        foreach ($dir in $Tool.CandidateDirs) {
            $candidateExe = Join-Path $dir $Tool.Executable
            if (Test-Path -LiteralPath $candidateExe) {
                $candidateDir = $dir
                break
            }
        }
    }

    return [pscustomobject]@{
        Name             = $Tool.Name
        Executable       = $Tool.Executable
        FoundOnPath      = $foundOnPath
        ResolvedPath     = $resolvedPath
        CandidateDir     = $candidateDir
        CandidateExe     = if ($candidateDir) { Join-Path $candidateDir $Tool.Executable } else { $null }
        KnownDirectories = @($Tool.CandidateDirs)
    }
}

function Ensure-RequiredTools {
    param(
        [Parameter(Mandatory)][string[]]$ToolNames,
        [Parameter(Mandatory)][hashtable]$Config,
        [ValidateSet('None', 'User')][string]$PersistMode = 'None'
    )

    Assert-PowerShell7

    $toolMap = @{}
    foreach ($tool in Get-RequiredTools) {
        $toolMap[$tool.Name] = $tool
    }

    $results = New-Object System.Collections.Generic.List[object]
    $missing = New-Object System.Collections.Generic.List[string]

    foreach ($name in $ToolNames) {
        if (-not $toolMap.ContainsKey($name)) {
            throw "Unknown tool requirement: $name"
        }

        $status = Resolve-ToolStatus -Tool $toolMap[$name]
        $sessionAdded = $false
        $persisted = $false

        if (-not $status.FoundOnPath -and $status.CandidateDir) {
            Add-DirectoryToProcessPath -Directory $status.CandidateDir
            $sessionAdded = $true

            if ($PersistMode -eq 'User') {
                Add-DirectoryToUserPath -Directory $status.CandidateDir
                $persisted = $true
            }

            $status = Resolve-ToolStatus -Tool $toolMap[$name]
        }

        if (-not $status.FoundOnPath) {
            $searched = if ($status.KnownDirectories.Count -gt 0) { $status.KnownDirectories -join ', ' } else { 'no fallback directories configured' }
            $missing.Add('{0} (searched: {1})' -f $name, $searched)
        }

        $results.Add([pscustomobject]@{
            Name         = $name
            FoundOnPath  = $status.FoundOnPath
            ResolvedPath = $status.ResolvedPath
            SessionAdded = $sessionAdded
            Persisted    = $persisted
            CandidateDir = $status.CandidateDir
        }) | Out-Null
    }

    foreach ($result in $results) {
        if ($result.FoundOnPath) {
            if ($result.Persisted) {
                Write-Host ('PATH fixed for session and user: {0} -> {1}' -f $result.Name, $result.ResolvedPath)
                Write-Log -Config $Config -Message "PATH session+user repair: $($result.Name) -> $($result.ResolvedPath)"
            } elseif ($result.SessionAdded) {
                Write-Host ('PATH fixed for session: {0} -> {1}' -f $result.Name, $result.ResolvedPath)
                Write-Log -Config $Config -Message "PATH session repair: $($result.Name) -> $($result.ResolvedPath)"
            }
        }
    }

    if ($missing.Count -gt 0) {
        throw ('Missing required tools: {0}' -f ($missing -join '; '))
    }

    return $results
}

function Get-ResolvedBranch {
    param(
        [Parameter(Mandatory)][hashtable]$Repo,
        [Parameter(Mandatory)][hashtable]$Config
    )

    if ($Repo.BranchMode -eq 'Pinned') {
        return [string]$Repo.Branch
    }

    $repoId = Get-RepoOwnerAndName -Url $Repo.Url
    $json = & gh repo view "$($repoId.Owner)/$($repoId.Name)" --json defaultBranchRef 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to resolve default branch for $($Repo.Name) with gh: $json"
    }

    $data = $json | ConvertFrom-Json
    $branch = [string]$data.defaultBranchRef.name
    if ([string]::IsNullOrWhiteSpace($branch)) {
        throw "GitHub returned an empty default branch for $($Repo.Name)."
    }

    Write-Log -Config $Config -Message "Resolved default branch for $($Repo.Name): $branch"
    return $branch
}

function Invoke-Git {
    param(
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $output = & git -C $WorkingDirectory @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    return @{
        Output   = $output
        ExitCode = $exitCode
    }
}

function Get-RepoPath {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$Repo
    )

    return Join-Path $Config.TargetRoot $Repo.Path
}

function Get-RepoByName {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Name
    )

    return @($Config.Repos | Where-Object { $_.Name -eq $Name } | Select-Object -First 1)[0]
}

function Get-ExpectedBranches {
    param([Parameter(Mandatory)][hashtable]$Repo)

    if ($Repo.ContainsKey('ExpectedBranches') -and $Repo.ExpectedBranches) {
        return @($Repo.ExpectedBranches)
    }

    return @([string]$Repo.Branch)
}

function Get-LocalBranches {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-IsGitRepo -Path $Path)) {
        return @()
    }

    $result = Invoke-Git -WorkingDirectory $Path -Arguments @('for-each-ref', '--format=%(refname:short)', 'refs/heads')
    if ($result.ExitCode -ne 0) {
        return @()
    }

    return @($result.Output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-ExpectedWorkspacePaths {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$Repo
    )

    $repoPath = Get-RepoPath -Config $Config -Repo $Repo
    $depsPath = Join-Path $repoPath 'deps.psd1'
    if (-not (Test-Path -LiteralPath $depsPath)) {
        return @()
    }

    try {
        $manifest = Import-PowerShellDataFile -Path $depsPath
    } catch {
        return @()
    }

    $paths = New-Object System.Collections.Generic.List[string]
    if ($manifest.ContainsKey('Workspace') -and $manifest.Workspace.ContainsKey('AppRepo')) {
        $appRepo = $manifest.Workspace.AppRepo
        if ($appRepo.ContainsKey('Variants')) {
            foreach ($variant in @($appRepo.Variants)) {
                if ($variant.ContainsKey('Path') -and -not [string]::IsNullOrWhiteSpace([string]$variant.Path)) {
                    $paths.Add([string]$variant.Path) | Out-Null
                }
            }
        } elseif ($appRepo.ContainsKey('SeedRepo') -and $appRepo.SeedRepo.ContainsKey('Path')) {
            $paths.Add([string]$appRepo.SeedRepo.Path) | Out-Null
        }
    }

    return @($paths | Select-Object -Unique)
}

function Get-MaterializationState {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$Repo
    )

    $repoPath = Get-RepoPath -Config $Config -Repo $Repo
    $expectedBranches = @(Get-ExpectedBranches -Repo $Repo)
    $localBranches = @(Get-LocalBranches -Path $repoPath)
    $branchHits = @($expectedBranches | Where-Object { $_ -in $localBranches })

    $expectedPaths = @(Get-ExpectedWorkspacePaths -Config $Config -Repo $Repo)
    $pathHits = @()
    foreach ($relativePath in $expectedPaths) {
        if (Test-Path -LiteralPath (Join-Path $repoPath $relativePath)) {
            $pathHits += $relativePath
        }
    }

    $started = ($branchHits.Count -gt 1) -or ($pathHits.Count -gt 0)
    $complete = ($expectedBranches.Count -eq 0 -or $branchHits.Count -eq $expectedBranches.Count) -and ($expectedPaths.Count -eq 0 -or $pathHits.Count -eq $expectedPaths.Count)

    $state = if (-not $started) {
        'clone-only'
    } elseif ($complete) {
        'materialized'
    } else {
        'partial'
    }

    return [pscustomobject]@{
        State                = $state
        ExpectedBranchCount  = $expectedBranches.Count
        PresentBranchCount   = $branchHits.Count
        ExpectedPathCount    = $expectedPaths.Count
        PresentPathCount     = $pathHits.Count
    }
}

function Ensure-ExpectedBranches {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$Repo
    )

    $repoPath = Get-RepoPath -Config $Config -Repo $Repo
    foreach ($branch in Get-ExpectedBranches -Repo $Repo) {
        Write-Host "Ensuring branch $branch in $($Repo.Name)"
        Invoke-Checked -FilePath 'git' -ArgumentList @('-C', $repoPath, 'fetch', 'origin', "refs/heads/$branch:refs/heads/$branch") -WorkingDirectory $Config.TargetRoot -Label "git fetch branch $($Repo.Name) $branch"
    }
}

function Invoke-InnerValidate {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$Repo
    )

    $path = Get-RepoPath -Config $Config -Repo $Repo
    $workspacePs1 = Join-Path $path 'workspace.ps1'
    if (-not (Test-Path -LiteralPath $workspacePs1)) {
        throw "Inner validate entrypoint not found: $workspacePs1"
    }

    Invoke-Checked -FilePath 'pwsh' -ArgumentList @('-NoLogo', '-NoProfile', '-File', $workspacePs1, 'validate') -WorkingDirectory $path -Label "inner validate $($Repo.Name)"
}

function Assert-RepoHealthyForMaterialize {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$Repo
    )

    $status = Get-RepoStatusInfo -Config $Config -Repo $Repo
    if (-not $status.Exists) {
        Clone-Repo -Config $Config -Repo $Repo
        $status = Get-RepoStatusInfo -Config $Config -Repo $Repo
    }

    if (-not $status.IsGitRepo) {
        throw "$($Repo.Name) is not a git repo."
    }

    if ($status.OriginUrl -ne $Repo.Url) {
        throw "$($Repo.Name) has the wrong origin."
    }

    if ($status.Dirty) {
        throw "$($Repo.Name) is dirty."
    }

    if ($status.BranchCurrent -ne $status.BranchExpected) {
        Invoke-Checked -FilePath 'git' -ArgumentList @('-C', $status.Path, 'checkout', $status.BranchExpected) -WorkingDirectory $Config.TargetRoot -Label "git checkout $($Repo.Name)"
    }
}

function Test-IsGitRepo {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    $result = Invoke-Git -WorkingDirectory $Path -Arguments @('rev-parse', '--show-toplevel')
    return $result.ExitCode -eq 0
}

function Get-RepoStatusInfo {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$Repo
    )

    $path = Get-RepoPath -Config $Config -Repo $Repo
    $branch = Get-ResolvedBranch -Repo $Repo -Config $Config

    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{
            Name           = $Repo.Name
            Path           = $path
            Exists         = $false
            IsGitRepo      = $false
            BranchExpected = $branch
            BranchCurrent  = $null
            OriginUrl      = $null
            Commit         = $null
            Dirty          = $false
            Healthy        = $false
            Problem        = 'missing'
        }
    }

    if (-not (Test-IsGitRepo -Path $path)) {
        return [pscustomobject]@{
            Name           = $Repo.Name
            Path           = $path
            Exists         = $true
            IsGitRepo      = $false
            BranchExpected = $branch
            BranchCurrent  = $null
            OriginUrl      = $null
            Commit         = $null
            Dirty          = $false
            Healthy        = $false
            Problem        = 'not-a-git-repo'
        }
    }

    $origin = (Invoke-Git -WorkingDirectory $path -Arguments @('remote', 'get-url', 'origin')).Output | Select-Object -First 1
    $currentBranch = (Invoke-Git -WorkingDirectory $path -Arguments @('branch', '--show-current')).Output | Select-Object -First 1
    $commit = (Invoke-Git -WorkingDirectory $path -Arguments @('rev-parse', 'HEAD')).Output | Select-Object -First 1
    $dirtyOutput = (Invoke-Git -WorkingDirectory $path -Arguments @('status', '--porcelain')).Output
    $dirty = [bool]($dirtyOutput | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $problem = $null
    if ($origin -ne $Repo.Url) {
        $problem = 'wrong-origin'
    } elseif ($currentBranch -ne $branch) {
        $problem = 'wrong-branch'
    } elseif ($dirty) {
        $problem = 'dirty'
    }

    return [pscustomobject]@{
        Name           = $Repo.Name
        Path           = $path
        Exists         = $true
        IsGitRepo      = $true
        BranchExpected = $branch
        BranchCurrent  = $currentBranch
        OriginUrl      = $origin
        Commit         = $commit
        Dirty          = $dirty
        Healthy        = [string]::IsNullOrWhiteSpace($problem)
        Problem        = $problem
    }
}

function Assert-Prereqs {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [switch]$RequireCMake
    )

    $required = @('pwsh', 'git', 'gh')
    if ($RequireCMake) {
        $required += 'cmake'
    }

    Ensure-RequiredTools -ToolNames $required -Config $Config -PersistMode $Persist | Out-Null

    $authOutput = & gh auth status 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "gh is installed but not authenticated: $authOutput"
    }
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter()][string[]]$ArgumentList = @(),
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$Label
    )

    & $FilePath @ArgumentList 2>&1 | ForEach-Object { $_ }
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE."
    }
}

function Clone-Repo {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$Repo
    )

    $targetPath = Get-RepoPath -Config $Config -Repo $Repo
    $branch = Get-ResolvedBranch -Repo $Repo -Config $Config

    if (Test-Path -LiteralPath $targetPath) {
        return
    }

    Ensure-Directory -Path $Config.TargetRoot
    Write-Host "Cloning $($Repo.Name) -> $targetPath"
    Write-Log -Config $Config -Message "Clone start: $($Repo.Name) [$branch]"

    Invoke-Checked -FilePath 'git' -ArgumentList @('clone', '--branch', $branch, $Repo.Url, $targetPath) -WorkingDirectory $Config.TargetRoot -Label "git clone $($Repo.Name)"

    if ($Repo.HasSubmodules) {
        Update-Submodules -Config $Config -Repo $Repo
    }

    Write-Log -Config $Config -Message "Clone complete: $($Repo.Name) [$branch]"
}

function Update-Submodules {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$Repo
    )

    $targetPath = Get-RepoPath -Config $Config -Repo $Repo
    if (-not (Test-IsGitRepo -Path $targetPath)) {
        throw "Cannot update submodules for non-repo path: $targetPath"
    }

    Write-Host "Updating submodules for $($Repo.Name)"
    Write-Log -Config $Config -Message "Submodule update start: $($Repo.Name)"
    Invoke-Checked -FilePath 'git' -ArgumentList @('-C', $targetPath, 'submodule', 'update', '--init', '--recursive') -WorkingDirectory $Config.TargetRoot -Label "git submodule update $($Repo.Name)"
    Write-Log -Config $Config -Message "Submodule update complete: $($Repo.Name)"
}

function Sync-Repo {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$Repo
    )

    $status = Get-RepoStatusInfo -Config $Config -Repo $Repo
    if (-not $status.Exists) {
        Clone-Repo -Config $Config -Repo $Repo
        return [pscustomobject]@{ Name = $Repo.Name; Result = 'cloned' }
    }

    if (-not $status.IsGitRepo) {
        return [pscustomobject]@{ Name = $Repo.Name; Result = 'blocked'; Reason = 'not-a-git-repo' }
    }

    if ($status.OriginUrl -ne $Repo.Url) {
        return [pscustomobject]@{ Name = $Repo.Name; Result = 'blocked'; Reason = 'wrong-origin' }
    }

    if ($status.Dirty) {
        return [pscustomobject]@{ Name = $Repo.Name; Result = 'blocked'; Reason = 'dirty' }
    }

    $path = $status.Path
    $branch = $status.BranchExpected
    Write-Host "Syncing $($Repo.Name)"
    Write-Log -Config $Config -Message "Sync start: $($Repo.Name) [$branch]"

    Invoke-Checked -FilePath 'git' -ArgumentList @('-C', $path, 'fetch', '--all', '--prune') -WorkingDirectory $Config.TargetRoot -Label "git fetch $($Repo.Name)"
    Invoke-Checked -FilePath 'git' -ArgumentList @('-C', $path, 'checkout', $branch) -WorkingDirectory $Config.TargetRoot -Label "git checkout $($Repo.Name)"
    Invoke-Checked -FilePath 'git' -ArgumentList @('-C', $path, 'pull', '--ff-only', 'origin', $branch) -WorkingDirectory $Config.TargetRoot -Label "git pull $($Repo.Name)"

    if ($Repo.HasSubmodules) {
        Update-Submodules -Config $Config -Repo $Repo
    }

    Write-Log -Config $Config -Message "Sync complete: $($Repo.Name) [$branch]"
    return [pscustomobject]@{ Name = $Repo.Name; Result = 'synced' }
}

function Show-Status {
    param([Parameter(Mandatory)][hashtable]$Config)

    $rows = foreach ($repo in $Config.Repos) {
        $info = Get-RepoStatusInfo -Config $Config -Repo $repo
        [pscustomobject]@{
            Name           = $info.Name
            Problem        = if ($info.Healthy) { 'ok' } else { $info.Problem }
            BranchExpected = $info.BranchExpected
            BranchCurrent  = $info.BranchCurrent
            Dirty          = $info.Dirty
            Materialize    = if ($repo.Role -eq 'BuildWorkspace') {
                $state = Get-MaterializationState -Config $Config -Repo $repo
                '{0} ({1}/{2} branches, {3}/{4} paths)' -f $state.State, $state.PresentBranchCount, $state.ExpectedBranchCount, $state.PresentPathCount, $state.ExpectedPathCount
            } elseif ($repo.Role -eq 'Tests') {
                'clone-only'
            } else {
                'n/a'
            }
            Commit         = $info.Commit
            Path           = $info.Path
        }
    }

    $rows | Format-Table -AutoSize
}

function Validate-Workspace {
    param([Parameter(Mandatory)][hashtable]$Config)

    Assert-Prereqs -Config $Config -RequireCMake

    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($repo in $Config.Repos) {
        $info = Get-RepoStatusInfo -Config $Config -Repo $repo
        if (-not $info.Healthy) {
            $problems.Add("$($repo.Name): $($info.Problem)")
            continue
        }

        if ($repo.Role -eq 'BuildWorkspace') {
            $state = Get-MaterializationState -Config $Config -Repo $repo
            if ($state.State -eq 'partial') {
                $problems.Add("$($repo.Name): partial materialization ($($state.PresentBranchCount)/$($state.ExpectedBranchCount) branches, $($state.PresentPathCount)/$($state.ExpectedPathCount) paths)")
                continue
            }

            if ($state.State -eq 'materialized') {
                try {
                    Invoke-InnerValidate -Config $Config -Repo $repo
                } catch {
                    $problems.Add("$($repo.Name): $($_.Exception.Message)")
                }
            }
        } elseif ($repo.Role -eq 'Tests') {
            foreach ($requiredName in @($repo.RequiresRepos)) {
                $requiredRepo = Get-RepoByName -Config $Config -Name $requiredName
                if ($null -eq $requiredRepo) {
                    $problems.Add("$($repo.Name): required repo metadata missing for $requiredName")
                    continue
                }

                $requiredInfo = Get-RepoStatusInfo -Config $Config -Repo $requiredRepo
                if (-not $requiredInfo.Healthy) {
                    $problems.Add("$($repo.Name): required repo $requiredName is not ready ($($requiredInfo.Problem))")
                }
            }
        }
    }

    if ($problems.Count -gt 0) {
        $problems | ForEach-Object { Write-Warning $_ }
        throw 'Workspace validation failed.'
    }

    Write-Host 'Workspace validation passed.'
}

function Invoke-InnerSetup {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$Repo
    )

    $path = Get-RepoPath -Config $Config -Repo $Repo
    if (-not (Test-IsGitRepo -Path $path)) {
        throw "Build workspace missing or invalid: $path"
    }

    if ($Repo.HasSubmodules) {
        Update-Submodules -Config $Config -Repo $Repo
    }

    Write-Host "Running inner setup for $($Repo.Name)"
    Write-Log -Config $Config -Message "Inner setup start: $($Repo.Name)"

    switch ([string]$Repo.InnerSetupMode) {
        'WorkspacePs1' {
            $workspacePs1 = Join-Path $path 'workspace.ps1'
            if (-not (Test-Path -LiteralPath $workspacePs1)) {
                throw "Inner setup entrypoint not found: $workspacePs1"
            }

            Invoke-Checked -FilePath 'pwsh' -ArgumentList @('-NoLogo', '-NoProfile', '-File', $workspacePs1, 'setup') -WorkingDirectory $path -Label "inner setup $($Repo.Name)"
        }
        default {
            throw "Unsupported inner setup mode for $($Repo.Name): $($Repo.InnerSetupMode)"
        }
    }

    Write-Log -Config $Config -Message "Inner setup complete: $($Repo.Name)"
}

function Invoke-Init {
    param([Parameter(Mandatory)][hashtable]$Config)

    Assert-Prereqs -Config $Config
    Ensure-Directory -Path $Config.TargetRoot

    $failures = New-Object System.Collections.Generic.List[string]
    foreach ($repo in $Config.Repos) {
        try {
            Clone-Repo -Config $Config -Repo $repo
        } catch {
            $failures.Add("$($repo.Name): $($_.Exception.Message)")
        }
    }

    if ($failures.Count -gt 0) {
        $failures | ForEach-Object { Write-Warning $_ }
        throw 'One or more repositories failed to initialize.'
    }
}

function Invoke-SyncAll {
    param([Parameter(Mandatory)][hashtable]$Config)

    Assert-Prereqs -Config $Config
    Ensure-Directory -Path $Config.TargetRoot

    $failures = New-Object System.Collections.Generic.List[string]
    foreach ($repo in $Config.Repos) {
        try {
            $result = Sync-Repo -Config $Config -Repo $repo
            if ($result.Result -eq 'blocked') {
                $failures.Add("$($repo.Name): $($result.Reason)")
            }
        } catch {
            $failures.Add("$($repo.Name): $($_.Exception.Message)")
        }
    }

    if ($failures.Count -gt 0) {
        $failures | ForEach-Object { Write-Warning $_ }
        throw 'One or more repositories failed to sync cleanly.'
    }
}

function Invoke-Materialize {
    param([Parameter(Mandatory)][hashtable]$Config)

    Assert-Prereqs -Config $Config -RequireCMake
    Ensure-Directory -Path $Config.TargetRoot

    $orderedNames = @('eMule-build-v0.60', 'eMule-build-v0.72', 'eMule-build-tests')
    foreach ($name in $orderedNames) {
        $repo = Get-RepoByName -Config $Config -Name $name
        if ($null -eq $repo) {
            continue
        }

        Assert-RepoHealthyForMaterialize -Config $Config -Repo $repo

        if ($repo.Role -eq 'BuildWorkspace') {
            Ensure-ExpectedBranches -Config $Config -Repo $repo
        }

        if ($repo.Name -eq 'eMule-build-tests') {
            foreach ($requiredName in @($repo.RequiresRepos)) {
                $requiredRepo = Get-RepoByName -Config $Config -Name $requiredName
                if ($null -eq $requiredRepo) {
                    throw "$($repo.Name) requires missing repo metadata for $requiredName."
                }

                $requiredInfo = Get-RepoStatusInfo -Config $Config -Repo $requiredRepo
                if (-not $requiredInfo.Healthy) {
                    throw "$($repo.Name) requires $requiredName on branch $($requiredInfo.BranchExpected)."
                }
            }

            Write-Host "Tests repo $($repo.Name) is cloned and aligned; no inner materialization entrypoint is defined."
            Write-Log -Config $Config -Message "Materialize complete: $($repo.Name) (clone-only tests repo)"
            continue
        }

        if ($repo.SupportsInnerSetup) {
            Invoke-InnerSetup -Config $Config -Repo $repo
        }
    }
}

function Invoke-EnsurePath {
    param([Parameter(Mandatory)][hashtable]$Config)

    $results = Ensure-RequiredTools -ToolNames @('pwsh', 'git', 'gh', 'cmake') -Config $Config -PersistMode $Persist
    $results |
        Select-Object Name, FoundOnPath, SessionAdded, Persisted, ResolvedPath |
        Format-Table -AutoSize
}

function Show-Menu {
    Write-Host ''
    Write-Host 'eMulebb setup'
    Write-Host '1. status'
    Write-Host '2. validate'
    Write-Host '3. init'
    Write-Host '4. sync'
    Write-Host '5. materialize'
    Write-Host '6. ensure-path (session)'
    Write-Host '7. ensure-path (session + user)'
    Write-Host '8. exit'
    Write-Host ''
}

function Resolve-InteractiveSelection {
    while ($true) {
        Show-Menu
        $choice = Read-Host 'Select an action'
        switch ($choice) {
            '1' { return @{ Command = 'status'; Persist = 'None' } }
            '2' { return @{ Command = 'validate'; Persist = 'None' } }
            '3' { return @{ Command = 'init'; Persist = 'None' } }
            '4' { return @{ Command = 'sync'; Persist = 'None' } }
            '5' { return @{ Command = 'materialize'; Persist = 'None' } }
            '6' { return @{ Command = 'ensure-path'; Persist = 'None' } }
            '7' { return @{ Command = 'ensure-path'; Persist = 'User' } }
            '8' { return @{ Command = 'exit'; Persist = 'None' } }
            default { Write-Warning 'Choose 1-8.' }
        }
    }
}

$config = Import-Config

if ([string]::IsNullOrWhiteSpace($Command)) {
    $selection = Resolve-InteractiveSelection
    if ($selection.Command -eq 'exit') {
        return
    }

    $Command = $selection.Command
    $Persist = $selection.Persist
}

switch ($Command) {
    'init' { Invoke-Init -Config $config }
    'sync' { Invoke-SyncAll -Config $config }
    'status' { Show-Status -Config $config }
    'validate' { Validate-Workspace -Config $config }
    'materialize' { Invoke-Materialize -Config $config }
    'ensure-path' { Invoke-EnsurePath -Config $config }
    default { throw "Unsupported command: $Command" }
}
