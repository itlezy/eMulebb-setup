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
        eMule-v0.72a-oracle\
        eMule-v0.72a-build\
        eMule-v0.72a-bugfix\
      artifacts\
      scripts\
      state\
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

Build and test orchestration lives in `repos\eMule-build\workspace.ps1`:

```powershell
pwsh -File .\repos\eMule-build\workspace.ps1 build-libs  -EmuleWorkspaceRoot <workspace-root> -Config <Debug|Release> -Platform x64
pwsh -File .\repos\eMule-build\workspace.ps1 build-app   -EmuleWorkspaceRoot <workspace-root> -Config <Debug|Release> -Platform x64
pwsh -File .\repos\eMule-build\workspace.ps1 build-tests -EmuleWorkspaceRoot <workspace-root> -Config <Debug|Release> -Platform x64
pwsh -File .\repos\eMule-build\workspace.ps1 test        -EmuleWorkspaceRoot <workspace-root> -Config <Debug|Release> -Platform x64
pwsh -File .\repos\eMule-build\workspace.ps1 full        -EmuleWorkspaceRoot <workspace-root> -Config <Debug|Release> -Platform x64
```

## Notes

- `EMULE_WORKSPACE_ROOT` may be provided with `-EmuleWorkspaceRoot` or the `EMULE_WORKSPACE_ROOT` environment variable.
- `materialize` creates the canonical repo pool, the `v0.72a` workspace manifest, the shared workspace props file, and the managed app worktrees for `main`, `oracle`, `build`, and `bugfix`.
- `materialize` also clones the comparison repos under `analysis` and regenerates the WinMerge launchers under `analysis\compare`.
- The app repo is canonical under `repos\eMule`; active 0.72 series work is done in worktrees under `workspaces\v0.72a\app`.
- `repos\eMule-build` owns the canonical build, test, coverage, and live-diff orchestration.
- `eMulebb-setup` is the front-door workspace helper only; it does not provide build or test commands.
- The tests repo is expected on `main`.
- `materialize` actively manages only the canonical 0.72a app worktrees and removes legacy app worktrees from the workspace app directory.
- `compare` launches WinMerge for built-in presets that compare `emuleai`, `community-0.60`, `community-0.72`, and `mods-archive` against the canonical local 0.72a worktrees.
- `-ArtifactsSeedRoot` is optional and is intended for local validation flows where dependency build outputs should be copied from an existing `third_party` tree.

## Documentation Map

This README describes the canonical workspace layout and setup commands.

Use the repo-local READMEs for operational detail:

- `EMULE_WORKSPACE_ROOT\repos\eMule-tooling\docs\WORKSPACE_POLICY.md` for the
  full workspace policy, active branches, worktree roles, and dependency-pin
  authority
- `repos\eMule-build\README.md` for build and test orchestration
- `repos\eMule-build-tests\README.md` for the shared harness model
- `repos\eMule-tooling\README.md` and `repos\eMule-tooling\docs\INDEX.md` for
  deeper design notes, audits, and planning artifacts
- `repos\eMule-remote\README.md` for the companion app runtime surface

Repo-local `AGENTS.md` files are intentionally agent-facing and should stay
short. They should capture repo-specific editing rules and point to the central
workspace policy document instead of duplicating it.
