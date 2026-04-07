@{
    DefaultEmuleWorkspaceRoot = 'C:\tmp\emule_clean_room_xx'
    DefaultWorkspaceName = 'v0.72a'
    LogFileName = 'eMulebb-setup.log'
    WorkspacePropsFileName = 'v0.72a-workspace.props'
    RootDirectories = @(
        'analysis'
        'archives'
        'repos'
        'repos\third_party'
        'workspaces'
    )
    AppRepo = @{
        Name = 'eMule'
        Url = 'https://github.com/itlezy/eMule.git'
        RelativePath = 'repos\eMule'
        Branch = 'main'
        Worktrees = @(
            @{
                Name = 'main'
                Branch = 'main'
                RelativePath = 'workspaces\v0.72a\app\eMule-main'
                Active = $true
            }
            @{
                Name = 'build'
                Branch = 'release/v0.72a-build'
                RelativePath = 'workspaces\v0.72a\app\eMule-v0.72a-build'
                Active = $true
            }
            @{
                Name = 'bugfix'
                Branch = 'release/v0.72a-bugfix'
                RelativePath = 'workspaces\v0.72a\app\eMule-v0.72a-bugfix'
                Active = $true
            }
        )
    }
    Repos = @(
        @{
            Name = 'eMule-build'
            Url = 'https://github.com/itlezy/eMule-build.git'
            RelativePath = 'repos\eMule-build'
            Branch = 'main'
        }
        @{
            Name = 'eMule-build-tests'
            Url = 'https://github.com/itlezy/eMule-build-tests.git'
            RelativePath = 'repos\eMule-build-tests'
            Branch = 'main'
        }
        @{
            Name = 'eMule-tooling'
            Url = 'https://github.com/itlezy/eMule-tooling.git'
            RelativePath = 'repos\eMule-tooling'
            Branch = 'main'
        }
        @{
            Name = 'eMule-remote'
            Url = 'https://github.com/itlezy/eMule-remote.git'
            RelativePath = 'repos\eMule-remote'
            Branch = 'main'
        }
    )
    AnalysisRepos = @(
        @{
            Name = 'emuleai'
            Url = 'https://github.com/eMuleAI/eMuleAI.git'
            RelativePath = 'analysis\emuleai'
            Branch = 'master'
            CompareSubdir = 'srchybrid'
        }
        @{
            Name = 'community-0.60'
            Url = 'https://github.com/irwir/eMule.git'
            RelativePath = 'analysis\community-0.60'
            Branch = 'v0.60d'
            CompareSubdir = 'srchybrid'
        }
        @{
            Name = 'community-0.72'
            Url = 'https://github.com/irwir/eMule.git'
            RelativePath = 'analysis\community-0.72'
            Branch = 'v0.72a'
            CompareSubdir = 'srchybrid'
        }
        @{
            Name = 'mods-archive'
            Url = 'https://github.com/itlezy/eMule-mods-archive.git'
            RelativePath = 'analysis\mods-archive'
            Branch = 'main'
            BranchOptional = $true
            CompareSubdir = $null
        }
    )
    ThirdPartyRepos = @(
        @{
            Name = 'eMule-cryptopp'
            Url = 'https://github.com/itlezy/eMule-cryptopp.git'
            RelativePath = 'repos\third_party\eMule-cryptopp'
            Branch = 'emule-build-v0.72a'
        }
        @{
            Name = 'eMule-id3lib'
            Url = 'https://github.com/itlezy/eMule-id3lib.git'
            RelativePath = 'repos\third_party\eMule-id3lib'
            Branch = 'emule-build-v0.72a'
        }
        @{
            Name = 'eMule-mbedtls'
            Url = 'https://github.com/itlezy/eMule-mbedtls.git'
            RelativePath = 'repos\third_party\eMule-mbedtls'
            Branch = 'emule-build-v0.72a'
            HasSubmodules = $true
        }
        @{
            Name = 'eMule-miniupnp'
            Url = 'https://github.com/itlezy/eMule-miniupnp.git'
            RelativePath = 'repos\third_party\eMule-miniupnp'
            Branch = 'emule-build-v0.72a'
        }
        @{
            Name = 'eMule-ResizableLib'
            Url = 'https://github.com/itlezy/eMule-ResizableLib.git'
            RelativePath = 'repos\third_party\eMule-ResizableLib'
            Branch = 'emule-build-v0.72a'
        }
        @{
            Name = 'eMule-zlib'
            Url = 'https://github.com/itlezy/eMule-zlib.git'
            RelativePath = 'repos\third_party\eMule-zlib'
            Branch = 'zlib-v1.3.2-emule'
        }
    )
}
