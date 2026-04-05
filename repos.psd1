@{
    TargetRoot = 'C:\prj\p2p\eMule\eMulebb'
    AnalysisRoot = 'C:\prj\p2p\eMule\analysis'
    LogFileName = 'eMulebb-setup.log'
    Repos = @(
        @{
            Name               = 'eMule-build-v0.60'
            Path               = 'eMule-build-v0.60'
            Role               = 'BuildWorkspace'
            Series             = 'v0.60d'
            Url                = 'https://github.com/itlezy/eMule-build.git'
            BranchMode         = 'Pinned'
            Branch             = 'v0.60d-build-clean'
            HasSubmodules      = $true
            SupportsInnerSetup = $true
            InnerSetupMode     = 'WorkspacePs1'
        }
        @{
            Name               = 'eMule-build-v0.72'
            Path               = 'eMule-build-v0.72'
            Role               = 'BuildWorkspace'
            Series             = 'v0.72a'
            Url                = 'https://github.com/itlezy/eMule-build.git'
            BranchMode         = 'Pinned'
            Branch             = 'v0.72a-build-clean'
            HasSubmodules      = $true
            SupportsInnerSetup = $true
            InnerSetupMode     = 'WorkspacePs1'
        }
        @{
            Name               = 'eMule-build-tests'
            Path               = 'eMule-build-tests'
            Role               = 'Tests'
            Series             = 'v0.72a'
            Url                = 'https://github.com/itlezy/eMule-build-tests.git'
            BranchMode         = 'Pinned'
            Branch             = 'v0.72a-clean'
            HasSubmodules      = $false
            SupportsInnerSetup = $false
            InnerSetupMode     = $null
            RequiresRepos      = @('eMule-remote')
        }
        @{
            Name               = 'eMule-remote'
            Path               = 'eMule-remote'
            Role               = 'Remote'
            Series             = 'v0.72a'
            Url                = 'https://github.com/itlezy/eMule-remote.git'
            BranchMode         = 'Pinned'
            Branch             = 'v0.72a-clean'
            HasSubmodules      = $false
            SupportsInnerSetup = $false
            InnerSetupMode     = $null
        }
    )
    AnalysisRepos = @(
        @{
            Name          = 'emuleai'
            Path          = 'emuleai'
            Url           = 'https://github.com/eMuleAI/eMuleAI.git'
            BranchMode    = 'Pinned'
            Branch        = 'master'
            CompareSubdir = 'srchybrid'
        }
        @{
            Name          = 'community-0.60'
            Path          = 'community-0.60'
            Url           = 'https://github.com/irwir/eMule.git'
            BranchMode    = 'Pinned'
            Branch        = 'v0.60d'
            CompareSubdir = 'srchybrid'
        }
        @{
            Name          = 'community-0.72'
            Path          = 'community-0.72'
            Url           = 'https://github.com/irwir/eMule.git'
            BranchMode    = 'Pinned'
            Branch        = 'v0.72a'
            CompareSubdir = 'srchybrid'
        }
        @{
            Name          = 'mods-archive'
            Path          = 'mods-archive'
            Url           = 'https://github.com/itlezy/eMule-mods-archive.git'
            BranchMode    = 'Default'
            Branch        = $null
            CompareSubdir = $null
        }
    )
}
