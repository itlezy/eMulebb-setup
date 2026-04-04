# eMulebb setup

This repository is meant to be cloned directly to:

- `C:\prj\p2p\eMule\eMulebb-setup`

PowerShell 7 helper for creating and maintaining this workspace:

```text
C:\prj\p2p\eMule\eMulebb\
  eMule-build-v0.60
  eMule-build-v0.72
  eMule-build-tests
  eMule-remote
```

## Prerequisites

- `pwsh` 7+
- `git`
- `gh` authenticated against GitHub
- `cmake` available on `PATH` or installed in the Visual Studio bundled CMake location

## Commands

```powershell
pwsh -File .\workspace.ps1
pwsh -File .\workspace.ps1 ensure-path
pwsh -File .\workspace.ps1 ensure-path -Persist User
pwsh -File .\workspace.ps1 init
pwsh -File .\workspace.ps1 sync
pwsh -File .\workspace.ps1 status
pwsh -File .\workspace.ps1 validate
pwsh -File .\workspace.ps1 validate -Persist User
pwsh -File .\workspace.ps1 materialize
```

## Notes

- Launching with no args opens an interactive menu.
- `init` creates `C:\prj\p2p\eMule\eMulebb` and clones the fixed repo set at pinned clean-family entry branches.
- `sync` updates clean repos only. Dirty repos are reported and left untouched.
- `materialize` runs in order: `eMule-build-v0.60`, `eMule-build-v0.72`, then `eMule-build-tests`.
- `materialize` ensures both build repos have the full four-branch clean family available locally, then delegates to each repo's native `workspace.ps1 setup`.
- `eMule-build-v0.60` is pinned to `v0.60d-build-clean`.
- `eMule-build-v0.72` is pinned to `v0.72a-build-clean`.
- `eMule-build-tests` is pinned to `v0.72a-clean` and remains a single-branch `v0.72a` tests repo.
- `eMule-remote` is pinned to `v0.72a-clean` and is the owned `v0.72a` remote companion.
- `validate` is phase-aware: after `init` it validates clone health, and after `materialize` it also validates the inner build workspaces.
- `validate` auto-repairs the current session `PATH` for missing required tools when it can discover them.
- `ensure-path` repairs the current session `PATH`; add `-Persist User` to also write the user PATH environment variable persistently.
- `eMule-build-tests` materialization is clone-only at the outer layer for now, but it is treated as depending on `eMule-remote`.
- A simple log is written to `C:\prj\p2p\eMule\eMulebb\eMulebb-setup.log`.
- This repo manages the sibling workspace root `C:\prj\p2p\eMule\eMulebb`, but that generated workspace is not tracked in this repo.
