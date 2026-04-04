@{
    TargetRoot = 'C:\prj\p2p\eMule\eMulebb'
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
            ExpectedBranches   = @(
                'v0.60d-build-clean'
                'v0.60d-bugfix-clean'
                'v0.60d-broadband-clean'
                'v0.60d-experimental-clean'
            )
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
            ExpectedBranches   = @(
                'v0.72a-build-clean'
                'v0.72a-bugfix-clean'
                'v0.72a-broadband-clean'
                'v0.72a-experimental-clean'
            )
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
}
