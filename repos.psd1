@{
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
                Name = 'community'
                Branch = 'release/v0.72a-community'
                RelativePath = 'workspaces\v0.72a\app\eMule-v0.72a-community'
                Active = $true
            }
            @{
                Name = 'broadband'
                Branch = 'release/v0.72a-broadband'
                RelativePath = 'workspaces\v0.72a\app\eMule-v0.72a-broadband'
                Active = $true
            }
            @{
                Name = 'tracing-harness'
                Branch = 'tracing-harness/v0.72a-community'
                RelativePath = 'workspaces\v0.72a\app\eMule-v0.72a-tracing-harness-community'
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
            Name = 'amutorrent'
            Url = 'https://github.com/itlezy/amutorrent.git'
            RelativePath = 'repos\amutorrent'
            Branch = 'main'
            AdditionalRemotes = @(
                @{
                    Name = 'upstream'
                    Url = 'https://github.com/got3nks/amutorrent.git'
                }
            )
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
        @{
            Name = 'stale-v0.72a-experimental-clean'
            Url = 'https://github.com/itlezy/eMule.git'
            RelativePath = 'analysis\stale-v0.72a-experimental-clean'
            Branch = 'stale/v0.72a-experimental-clean'
            CompareSubdir = 'srchybrid'
        }
    )
    ThirdPartyRepos = @(
        @{
            Name = 'eMule-cryptopp'
            Url = 'https://github.com/itlezy/eMule-cryptopp.git'
            RelativePath = 'repos\third_party\eMule-cryptopp'
            Branch = 'CRYPTOPP_8_4_0-pristine'
            UpdatePolicy = @{
                UpstreamUrl = 'https://github.com/weidai11/cryptopp.git'
                TrackingMode = 'tag'
                BaselineRef = 'CRYPTOPP_8_4_0'
                VersionPattern = '^CRYPTOPP_(\d+)_(\d+)_(\d+)$'
            }
        }
        @{
            Name = 'eMule-id3lib'
            Url = 'https://github.com/itlezy/eMule-id3lib.git'
            RelativePath = 'repos\third_party\eMule-id3lib'
            Branch = 'id3lib-v3.9.1-emule'
            UpdatePolicy = @{
                TrackingMode = 'none'
                BaselineRef = 'v3.9.1'
                Notes = 'Patch baked into fork; no automated upstream comparison.'
            }
        }
        @{
            Name = 'eMule-mbedtls'
            Url = 'https://github.com/itlezy/eMule-mbedtls.git'
            RelativePath = 'repos\third_party\eMule-mbedtls'
            Branch = 'mbedtls-v4.1.0-emule'
            HasSubmodules = $true
            UpdatePolicy = @{
                UpstreamUrl = 'https://github.com/Mbed-TLS/mbedtls.git'
                TrackingMode = 'tag'
                BaselineRef = 'mbedtls-4.1.0'
                VersionPattern = '^mbedtls-(\d+)\.(\d+)\.(\d+)$'
                ChildComponents = @(
                    @{
                        Name = 'tf-psa-crypto'
                        RelativePath = 'tf-psa-crypto'
                        UpstreamUrl = 'https://github.com/Mbed-TLS/TF-PSA-Crypto.git'
                        TrackingMode = 'tag'
                        BaselineRef = 'v1.1.0'
                        VersionPattern = '^v(\d+)\.(\d+)\.(\d+)$'
                    }
                )
            }
        }
        @{
            Name = 'eMule-miniupnp'
            Url = 'https://github.com/itlezy/eMule-miniupnp.git'
            RelativePath = 'repos\third_party\eMule-miniupnp'
            Branch = 'miniupnpc-master-emule'
            UpdatePolicy = @{
                UpstreamUrl = 'https://github.com/miniupnp/miniupnp.git'
                TrackingMode = 'branch-head'
                UpstreamRef = 'master'
                BaselineRef = '0cc037f8b0d563334bace7af4e00e9041cfa97e6'
            }
        }
        @{
            Name = 'eMule-libpcpnatpmp'
            Url = 'https://github.com/itlezy/eMule-libpcpnatpmp.git'
            RelativePath = 'repos\third_party\eMule-libpcpnatpmp'
            Branch = 'libpcpnatpmp-master-emule'
            UpdatePolicy = @{
                UpstreamUrl = 'https://github.com/libpcpnatpmp/libpcpnatpmp.git'
                TrackingMode = 'branch-head'
                UpstreamRef = 'master'
                BaselineRef = '7ab2f9475a242f3714715d7580e1001e9e8a7497'
            }
        }
        @{
            Name = 'eMule-ResizableLib'
            Url = 'https://github.com/itlezy/eMule-ResizableLib.git'
            RelativePath = 'repos\third_party\eMule-ResizableLib'
            Branch = 'ResizableLib-bebab50-emule'
            UpdatePolicy = @{
                UpstreamUrl = 'https://github.com/ppescher/resizablelib.git'
                TrackingMode = 'branch-head'
                UpstreamRef = 'master'
                BaselineRef = 'bebab50a5dbfbb0913b64d23b86d1c3110677c41'
            }
        }
        @{
            Name = 'eMule-nlohmann-json'
            Url = 'https://github.com/itlezy/eMule-nlohmann-json.git'
            RelativePath = 'repos\third_party\eMule-nlohmann-json'
            Branch = 'json-v3.11.3-emule'
            UpdatePolicy = @{
                UpstreamUrl = 'https://github.com/nlohmann/json.git'
                TrackingMode = 'tag'
                BaselineRef = 'v3.11.3'
                VersionPattern = '^v(\d+)\.(\d+)\.(\d+)$'
            }
        }
        @{
            Name = 'eMule-zlib'
            Url = 'https://github.com/itlezy/eMule-zlib.git'
            RelativePath = 'repos\third_party\eMule-zlib'
            Branch = 'zlib-v1.3.2-emule'
            UpdatePolicy = @{
                UpstreamUrl = 'https://github.com/madler/zlib.git'
                TrackingMode = 'tag'
                BaselineRef = 'v1.3.2'
                VersionPattern = '^v(\d+)\.(\d+)\.(\d+)$'
            }
        }
    )
}
