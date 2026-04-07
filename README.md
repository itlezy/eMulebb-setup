# eMulebb setup

PowerShell helper for materializing a canonical multi-repo eMule workspace under
`EMULE_WORKSPACE_ROOT`.

## Layout

```text
EMULE_WORKSPACE_ROOT\
  repos\
    eMule\
    eMule-build\
    eMule-build-tests\
    eMule-tooling\
    eMule-remote\
    third_party\
      eMule-cryptopp\
      eMule-id3lib\
      eMule-mbedtls\
      eMule-miniupnp\
      eMule-ResizableLib\
      eMule-zlib\
  workspaces\
    v0.72a\
      deps.psd1
      app\
        eMule-main\
        eMule-v0.72a-build\
        eMule-v0.72a-bugfix\
      artifacts\
      scripts\
      state\
        EMULE-STATUS.md
  analysis\
    emuleai\
    community-0.60\
    community-0.72\
    mods-archive\
    compare\
  archives\
```

## Prerequisites

- `pwsh` 7+
- `git`
- `gh` authenticated against GitHub
- `cmake` available on `PATH` or discoverable by the helper

## Commands

```powershell
pwsh -File .\workspace.ps1 ensure-path
pwsh -File .\workspace.ps1 init -EmuleWorkspaceRoot <workspace-root>
pwsh -File .\workspace.ps1 materialize -EmuleWorkspaceRoot <workspace-root>
pwsh -File .\workspace.ps1 materialize -EmuleWorkspaceRoot <workspace-root> -ArtifactsSeedRoot <third-party-seed-root>
pwsh -File .\workspace.ps1 status -EmuleWorkspaceRoot <workspace-root>
pwsh -File .\workspace.ps1 validate -EmuleWorkspaceRoot <workspace-root>
pwsh -File .\workspace.ps1 compare -EmuleWorkspaceRoot <workspace-root>
pwsh -File .\workspace.ps1 compare <preset-key> -EmuleWorkspaceRoot <workspace-root>
```

## Notes

- `EMULE_WORKSPACE_ROOT` may be provided with `-EmuleWorkspaceRoot` or the `EMULE_WORKSPACE_ROOT` environment variable.
- `materialize` creates the canonical repo pool, the `v0.72a` workspace manifest, the shared workspace props file, and the three active app worktrees.
- `materialize` also clones the comparison repos under `analysis` and regenerates the WinMerge launchers under `analysis\compare`.
- The app repo is canonical under `repos\eMule`; active 0.72 series work is done in worktrees under `workspaces\v0.72a\app`.
- `repos\eMule-build` owns the canonical build, test, coverage, and live-diff orchestration.
- The tests repo is expected on `main`.
- `materialize` actively manages only the canonical 0.72a app worktrees and removes legacy app worktrees from the workspace app directory.
- `compare` launches WinMerge for built-in presets that compare `emuleai`, `community-0.60`, `community-0.72`, and `mods-archive` against the canonical local 0.72a worktrees.
- `-ArtifactsSeedRoot` is optional and is intended for local validation flows where dependency build outputs should be copied from an existing `third_party` tree.
